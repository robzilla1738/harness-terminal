import CHarnessBase64
import Foundation

/// Base64 decode of a borrowed buffer. `Data(base64Encoded: Data(slice))` copies the
/// source first; OSC 52 and OSC 1337 bodies are megabytes and that copy sits on `feed`.
enum Base64Bytes {
    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, options: Data.Base64DecodingOptions = []) -> Data? {
        guard let base = bytes.baseAddress, bytes.count > 0 else {
            return Data(base64Encoded: Data(), options: options)
        }
        // The decode reads `view` before returning and does not keep it. `.none` must not
        // outlive this call — the pointer belongs to the parser's current feed buffer.
        let view = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
            count: bytes.count,
            deallocator: .none
        )
        return Data(base64Encoded: view, options: options)
    }

    /// OSC 52 text. The arm64 decoder writes straight into the `String`. A -1
    /// (or bytes that are not UTF-8) falls through to `decode`, which still
    /// accepts the non-standard paddings Foundation accepts.
    static func decodeClipboardText(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        if let base = bytes.baseAddress, bytes.count > 0, bytes.count & 3 == 0,
           let text = fastClipboardText(base, count: bytes.count) {
            return text
        }
        guard let data = decode(bytes), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func fastClipboardText(_ base: UnsafePointer<UInt8>, count: Int) -> String? {
        // The NEON loop stores 16 bytes per 12 output bytes. `count / 4 * 3` is the
        // decoded length before padding; +16 covers that overlap.
        let capacity = count / 4 * 3 + 16
        var rejected = false
        let text = String(unsafeUninitializedCapacity: capacity) { buffer in
            guard let dst = buffer.baseAddress else {
                rejected = true
                return 0
            }
            var nonASCII: Int32 = 0
            let decoded = harness_base64_decode(base, count, dst, &nonASCII)
            guard decoded > 0 else {
                rejected = true
                return 0
            }
            if nonASCII != 0 {
                let data = Data(bytes: dst, count: decoded)
                guard String(data: data, encoding: .utf8) != nil else {
                    rejected = true
                    return 0
                }
            }
            return decoded
        }
        return rejected ? nil : text
    }
}
