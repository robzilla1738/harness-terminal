import Foundation
import CHarnessQR
import HarnessRemoteProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct MobilePairingQR {
    let modules: [[Bool]]

    init(_ text: String) throws {
        var scratch = [UInt8](repeating: 0, count: Int(HarnessQRBufferLength))
        var code = scratch
        guard qrcodegen_encodeText(text, &scratch, &code, qrcodegen_Ecc_MEDIUM,
                                  qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true) else {
            throw RemoteFailure(code: "pairingCode", message: "This connection is too long for a QR code. Use Copy Connection instead.")
        }
        let size = Int(qrcodegen_getSize(code))
        modules = (0..<size).map { y in (0..<size).map { x in qrcodegen_getModule(code, Int32(x), Int32(y)) } }
    }

    var terminalText: String {
        let size = modules.count
        func black(_ x: Int, _ y: Int) -> Bool { (0..<size).contains(x) && (0..<size).contains(y) && modules[y][x] }
        return stride(from: -4, to: size + 4, by: 2).map { y in
            let row = (-4..<size + 4).map { x in
                switch (black(x, y), black(x, y + 1)) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
            }.joined()
            // Fixed black on white keeps the quiet zone scannable in every terminal theme.
            return "\u{1b}[30;47m" + row + "\u{1b}[0m"
        }.joined(separator: "\n")
    }
}

extension HarnessCLI {
    static func handleMobilePair(_ args: [String]) throws {
        if args.contains("--help") || args.contains("-h") {
            print("Usage: harness-cli pair [--host <LAN or Tailscale address>] [--port <SSH port>] [--json | --link]\nScan the QR in Harness on your phone. SSH must be enabled on this host.")
            return
        }
        let info = try mobilePairingInfo(args)
        if args.contains("--json") { print(String(decoding: try JSONEncoder().encode(info), as: UTF8.self)) }
        else if args.contains("--link") { print(try info.connectionURL().absoluteString) }
        else { try printMobilePairing(info) }
    }

    static func printMobilePairing(_ info: RemotePairingInfo) throws {
        let link = try info.connectionURL().absoluteString
        let qr = try MobilePairingQR(link)
        var window = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window)
        print("\nConnect your phone\n\(info.username)@\(info.host):\(info.port)\n")
        if window.ws_col == 0 || Int(window.ws_col) >= qr.modules.count + 8 { print(qr.terminalText) }
        else { print("Widen this terminal to \(qr.modules.count + 8) columns to show the QR code, or paste the link below.") }
        print("\n1. Open Harness on your phone and tap Scan QR code.\n2. Scan, then enter your host password once to install a device key.\n\nUse the same network, or Tailscale on both devices. SSH must be enabled.\nThis code contains no password or private key.\n\nConnection link:\n\(link)\n")
    }
}
