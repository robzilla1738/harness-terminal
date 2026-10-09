import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local interface addresses: discovery never joins a VPN or probes other machines.
public struct MobileConnectionAddress: Equatable, Sendable {
    public let host: String
    public let interface: String
    public var isVPN: Bool {
        let bytes = host.split(separator: ".").compactMap { Int($0) }
        return bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
    }
    public var title: String { "\(isVPN ? "Tailscale / VPN" : "Local network") · \(host)" }

    private var preference: Int {
        if isVPN { return 1 }
        // Prefer Wi-Fi/Ethernet over container bridges and other virtual interfaces.
        return ["en", "eth", "wl"].contains(where: interface.hasPrefix) ? 0 : 2
    }

    public static func available() throws -> [Self] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { freeifaddrs(first) }
        var result: [Self] = []
        var next = first
        while let current = next {
            defer { next = current.pointee.ifa_next }
            let entry = current.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !host.hasPrefix("169.254."), host != "0.0.0.0", !result.contains(where: { $0.host == host }) else { continue }
            result.append(Self(host: host, interface: String(cString: entry.ifa_name)))
        }
        return result.sorted {
            if $0.preference != $1.preference { return $0.preference < $1.preference }
            return $0.interface.localizedStandardCompare($1.interface) == .orderedAscending
        }
    }
}
