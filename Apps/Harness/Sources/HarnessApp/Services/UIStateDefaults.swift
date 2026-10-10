import Foundation
import CryptoKit
import HarnessCore

/// Signed previews share the application's bundle identifier. Keep their
/// structural UI preferences separate from the regular installation and other homes.
enum UIStateDefaults {
    static func key(_ name: String) -> String {
        guard HarnessPaths.hasHomeOverride else { return name }
        let identity = SHA256.hash(data: Data(HarnessPaths.applicationSupport.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "com.robert.harness.home." + identity + "." + name
    }
}
