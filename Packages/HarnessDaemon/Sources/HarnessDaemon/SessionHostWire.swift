import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded, nonblocking channel. All framing and writes belong to its serial queue.
/// Raw public IPC frames can pass through without changing their wire representation.
final class SessionHostChannel: @unchecked Sendable {
    let fd: Int32
    private let descriptor: ChannelDescriptor
    private let queue = DispatchQueue(label: "com.harness.session-host.channel")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var input = Data(), output = Data()
    private var inputOffset = 0, outputOffset = 0
    private var ended = false
    private var endingAfterWrites = false
    private var drainDeadline: DispatchSourceTimer?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onEnd: (@Sendable () -> Void)?
    init(fd: Int32) {
        self.fd = fd
        descriptor = ChannelDescriptor(fd)
        queue.setSpecific(key: queueKey, value: true)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        setNoSigPipe(fd)
    }
    func start(onFrame: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void = {}) {
        queue.sync {
            guard !ended else { return }
            self.onFrame = onFrame; self.onEnd = onEnd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readReady() }
            descriptor.register(source)
            reader = source; source.resume()
        }
    }
    func send(_ data: Data) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { enqueue(data) }
        else { queue.sync { enqueue(data) } }
    }
    private func enqueue(_ data: Data) {
        guard !ended else { return }
        guard data.count <= 32 << 20, output.count - outputOffset <= (32 << 20) - data.count else { finish(); return }
        if outputOffset > 0, outputOffset >= output.count / 2 { output.removeFirst(outputOffset); outputOffset = 0 }
        output.append(data)
        flush()
    }
    private func flush() {
        while !ended, outputOffset < output.count {
            let sent = output.withUnsafeBytes { raw in
                #if canImport(Darwin)
                Darwin.send(fd, raw.baseAddress!.advanced(by: outputOffset), raw.count - outputOffset, 0)
                #else
                Glibc.send(fd, raw.baseAddress!.advanced(by: outputOffset), raw.count - outputOffset, Int32(MSG_NOSIGNAL))
                #endif
            }
            if sent > 0 { outputOffset += sent }
            else if sent < 0, errno == EINTR { continue }
            else if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    descriptor.register(source)
                    writer = source; source.resume()
                }
                return
            } else { finish(); return }
        }
        output.removeAll(keepingCapacity: true); outputOffset = 0
        writer?.cancel(); writer = nil
        if endingAfterWrites { finish() }
    }
    private func readReady() {
        guard !ended else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<16 {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { input.append(contentsOf: bytes.prefix(count)) }
            else if count < 0, errno == EINTR { continue }
            else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { finish(); return }
            while input.count - inputOffset >= 4 {
                let binary = input[inputOffset] == 0xf5 || input[inputOffset] == 0xf6
                let header = binary ? 5 : 4
                guard input.count - inputOffset >= header else { break }
                let begin = inputOffset + (binary ? 1 : 0)
                let length = input[begin..<(begin + 4)].reduce(0) { $0 << 8 | Int($1) }
                guard length <= IPCCodec.maxPayloadLength else { finish(); return }
                guard input.count - inputOffset >= header + length else { break }
                let frame = Data(input[inputOffset..<(inputOffset + header + length)])
                inputOffset += header + length
                onFrame?(frame)
            }
            if inputOffset > 0, inputOffset >= input.count / 2 { input = Data(input.dropFirst(inputOffset)); inputOffset = 0 }
            if input.count - inputOffset > IPCCodec.maxPayloadLength + 5 { finish(); return }
        }
    }
    func closeAfterWrites() {
        queue.async { [self] in
            guard !ended else { return }
            endingAfterWrites = true; reader?.cancel(); reader = nil
            if output.count == outputOffset { finish(); return }
            let deadline = DispatchSource.makeTimerSource(queue: queue)
            deadline.schedule(deadline: .now() + 2)
            // Retain the channel until its bounded drain ends, even when its owner
            // removes the subscription immediately after the final exit record.
            deadline.setEventHandler { [self] in finish() }
            drainDeadline = deadline; deadline.resume(); flush()
        }
    }
    func closeChannel() { queue.async { [weak self] in self?.finish() } }
    private func finish() {
        guard !ended else { return }; ended = true
        drainDeadline?.cancel(); drainDeadline = nil
        reader?.cancel(); writer?.cancel(); reader = nil; writer = nil
        descriptor.retire()
        input.removeAll(); output.removeAll()
        let callback = onEnd; onEnd = nil; onFrame = nil; callback?()
    }
    deinit { reader?.cancel(); writer?.cancel(); descriptor.retire() }
}

/// A cancelled dispatch source may still refer to its descriptor. Keep the
/// descriptor allocated until every reader/writer cancellation has completed,
/// including writers removed after a successful flush, so a new channel cannot
/// inherit a descriptor still watched by an old source.
final class ChannelDescriptor: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var sources = 0
    private var retiring = false
    private var closed = false
    init(_ fd: Int32) { self.fd = fd }
    func register(_ source: any DispatchSourceProtocol, onCancel: @escaping @Sendable () -> Void = {}) {
        lock.lock(); sources += 1; lock.unlock()
        source.setCancelHandler { [self] in
            onCancel()
            lock.lock(); defer { lock.unlock() }
            sources -= 1
            closeIfRetired()
        }
    }
    func retire() {
        lock.lock(); defer { lock.unlock() }
        if !retiring { retiring = true; _ = shutdown(fd, Int32(SHUT_RDWR)) }
        closeIfRetired()
    }
    private func closeIfRetired() {
        if retiring, sources == 0, !closed { closed = true; close(fd) }
    }
}

final class SessionHostListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.harness.session-host.accept")
    private var source: DispatchSourceRead?
    private let path: String
    private var identity: (dev_t, ino_t)?
    init(path: String) { self.path = path }
    func start(_ acceptChannel: @escaping @Sendable (SessionHostChannel) -> Void) throws {
        guard path.utf8.count < HarnessPaths.maxSocketPathLength else { throw DaemonError.socketFailed }
        let fd = makeUnixStreamSocket()
        guard fd >= 0 else { throw DaemonError.socketFailed }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { raw in withUnsafeMutablePointer(to: &address.sun_path) {
            _ = strncpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), raw, pathCapacity - 1)
        } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result == 0 else { close(fd); throw DaemonError.socketFailed }
        _ = chmod(path, 0o600)
        var info = stat(); if lstat(path, &info) == 0 { identity = (info.st_dev, info.st_ino) }
        guard listen(fd, 128) == 0 else { close(fd); throw DaemonError.socketFailed }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            for _ in 0..<32 {
                let client = accept(fd, nil, nil)
                if client >= 0 { acceptChannel(SessionHostChannel(fd: client)) }
                else if errno == EINTR { continue }
                else { break }
            }
        }
        source.setCancelHandler { close(fd) }; self.source = source; source.resume()
    }
    func stop() {
        source?.cancel(); source = nil
        var info = stat()
        if let identity, lstat(path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { _ = unlink(path) }
    }
    deinit { stop() }
}
