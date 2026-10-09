import Foundation
import XCTest
import HarnessRemoteProtocol
@testable import HarnessCLI
#if os(macOS)
import AppKit
import Vision
#endif

final class MobilePairingQRTests: XCTestCase {
    func testMalformedOptionsFailBeforeReadingHostKeys() {
        for options in [["pair", "--host"], ["pair", "--port"], ["pair", "--unknown"],
                        ["pair", "--json", "--link"], ["pair", "--host", "studio.local", "--port", "wrong"]] {
            XCTAssertThrowsError(try HarnessCLI.mobilePairingInfo(options))
        }
    }

    func testPrintedQRUsesAQuietZoneAndFixedContrast() throws {
        let qr = try MobilePairingQR("harness://connect")
        let rows = qr.terminalText.components(separatedBy: "\n")
        XCTAssertEqual(rows.count, (qr.modules.count + 9) / 2)
        XCTAssertTrue(rows.allSatisfy { $0.hasPrefix("\u{1b}[30;47m    ") && $0.hasSuffix("    \u{1b}[0m") })
    }

    func testTerminalQRRequiresEnoughHeightAsWellAsWidth() throws {
        let qr = try MobilePairingQR(String(repeating: "connection", count: 25))
        XCTAssertFalse(qr.fits(columns: 120, rows: 24))
        XCTAssertFalse(qr.fits(columns: 30, rows: 80))
        XCTAssertTrue(qr.fits(columns: 120, rows: 80))
    }

    #if os(macOS)
    func testCameraDecoderReadsThePortablePairingQR() throws {
        let info = RemotePairingInfo(host: "studio.local", username: "person",
            fingerprint: "SHA256:" + Data(repeating: 9, count: 32).base64EncodedString().dropLast(),
            executablePath: "/Applications/Harness.app/Contents/MacOS/harness-cli")
        let text = try info.connectionURL().absoluteString
        let qr = try MobilePairingQR(text)
        let side = qr.modules.count + 8
        let scale = 8, width = side * scale
        var pixels = [UInt8](repeating: 255, count: width * width)
        for y in 0..<qr.modules.count {
            for x in 0..<qr.modules.count where qr.modules[y][x] {
                for dy in 0..<scale { for dx in 0..<scale { pixels[((y + 4) * scale + dy) * width + (x + 4) * scale + dx] = 0 } }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        XCTAssertEqual(request.results?.first?.payloadStringValue, text)
    }
    #endif
}
