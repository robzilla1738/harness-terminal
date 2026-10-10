import Foundation
import MCP
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Framing and resource bounds only; the official SDK owns JSON-RPC, lifecycle,
/// negotiation, dispatch and cancellation. Stdout contains protocol frames exclusively.
actor BoundedStdioTransport: Transport {
    nonisolated let logger = Logger(label: "com.harness.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var reader: Task<Void, Never>?
    private var input = Data()
    private var requests: Set<String> = []
    private var writerRunning = false
    private struct PendingOutput { var data: Data, completion: CheckedContinuation<Void, Error> }
    private var outputs: [PendingOutput] = []
    private var outputBytes = 0
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stream = pair.stream; continuation = pair.continuation
    }
    func connect() async throws {
        guard !connected else { return }
        for fd in [STDIN_FILENO, STDOUT_FILENO] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw MCPError.internalError("MCP stdio could not be configured") }
        }
        signal(SIGPIPE, SIG_IGN)
        connected = true
        reader = Task { [weak self] in await self?.readLoop() }
    }
    func disconnect() async {
        connected = false; reader?.cancel(); reader = nil
        continuation.finish()
        let pending = outputs; outputs.removeAll(); outputBytes = 0
        for value in pending { value.completion.resume(throwing: CancellationError()) }
    }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func send(_ data: Data) async throws {
        guard connected, data.count <= 2 << 20, outputs.count < 32, outputBytes + data.count <= 4 << 20 else { throw MCPError.internalError("MCP output exceeded its bounded queue") }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let replies = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        for object in replies { if let id = Self.id(object["id"]) { requests.remove(id) } }
        try await withCheckedThrowingContinuation { completion in
            outputs.append(PendingOutput(data: data + Data([10]), completion: completion)); outputBytes += data.count + 1
            if !writerRunning { writerRunning = true; Task { await self.writeLoop() } }
        }
    }
    private func writeLoop() async {
        defer { writerRunning = false }
        while connected, !outputs.isEmpty {
            let value = outputs.removeFirst(); var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            do {
                while offset < value.data.count {
                    guard connected, DispatchTime.now().uptimeNanoseconds < deadline else { throw MCPError.internalError("MCP output consumer stopped reading") }
                    let count = value.data.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                    if count > 0 { offset += count }
                    else if count < 0, errno == EINTR { continue }
                    else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { try await Task.sleep(for: .milliseconds(10)) }
                    else { throw MCPError.internalError("MCP stdout closed") }
                }
                outputBytes = max(0, outputBytes - value.data.count); value.completion.resume()
            } catch {
                outputBytes = max(0, outputBytes - value.data.count); value.completion.resume(throwing: error)
                await disconnect(); return
            }
        }
    }
    private func readLoop() async {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while connected, !Task.isCancelled {
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { continuation.finish(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { try? await Task.sleep(for: .milliseconds(10)); continue }
                continuation.finish(throwing: MCPError.internalError("MCP stdin failed")); return
            }
            input.append(contentsOf: bytes.prefix(count))
            while let end = input.firstIndex(of: 10) {
                let frame = Data(input[..<end]); input = Data(input.dropFirst(end + 1))
                guard frame.count <= 256 << 10 else { await rejectConnection("MCP input frame exceeds 256 KiB"); return }
                if frame.isEmpty { continue }
                let parsed = try? JSONSerialization.jsonObject(with: frame)
                let messages: [[String: Any]]
                if let object = parsed as? [String: Any] { messages = [object] }
                else if let batch = parsed as? [[String: Any]], !batch.isEmpty, batch.count <= 32 { messages = batch }
                else if parsed is [Any] { await rejectConnection("MCP batch exceeds its request limit"); return }
                else { messages = [] } // SDK returns the protocol parse error.
                for object in messages {
                    if let id = Self.id(object["id"]), object["method"] != nil {
                        guard !requests.contains(id), requests.count < 32 else { await rejectConnection("MCP request queue is full or contains a duplicate identity"); return }
                        requests.insert(id)
                    }
                    if object["method"] as? String == "notifications/cancelled", let params = object["params"] as? [String: Any], let id = Self.id(params["requestId"]) { requests.remove(id) }
                }
                switch continuation.yield(frame) {
                case .enqueued: break
                case .dropped: await rejectConnection("MCP input exceeded its bounded queue"); return
                case .terminated: return
                @unknown default: await rejectConnection("MCP input stream failed"); return
                }
                await Task.yield()
            }
            if input.count > 256 << 10 { await rejectConnection("MCP input frame exceeds 256 KiB"); return }
        }
    }
    private func rejectConnection(_ reason: String) async {
        continuation.finish(throwing: MCPError.invalidRequest(reason)); await disconnect()
    }
    private static func id(_ value: Any?) -> String? {
        guard let value, value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
