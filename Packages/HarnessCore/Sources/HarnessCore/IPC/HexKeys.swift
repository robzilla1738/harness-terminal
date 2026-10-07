import Foundation

/// `send-keys -H` and `pane.send_key {hex:true}`: each token is a hex byte (`1b`, `0x5b`,
/// `41`). Non-hex tokens are skipped. Lets scripts inject raw byte sequences a terminal
/// program expects.
public enum HexKeys {
    public static func bytes(_ tokens: [String]) -> Data {
        var out = Data()
        for token in tokens {
            let digits = token.hasPrefix("0x") || token.hasPrefix("0X") ? String(token.dropFirst(2)) : token
            if let byte = UInt8(digits, radix: 16) { out.append(byte) }
        }
        return out
    }
}
