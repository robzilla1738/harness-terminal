import Foundation
#if os(macOS)
import CryptoKit
import Security
import LocalAuthentication
#endif

/// Sensitive records are sealed before reaching a file or SQLite binding. A missing
/// key is a distinct state: callers retain bounded memory and never write plaintext.
public struct HistoryProtection: Sendable {
    public enum Kind: String, Codable, Sendable { case keychainEncrypted, keyUnavailable, ownerOnlyLinux }
    public let kind: Kind
    public let unavailableReason: String?
    private let material: Data?
    private static let encryptedMagic = Data("HARNSEC1".utf8)
    private static let plainMagic = Data("HARNPLN1".utf8)
    public init(keyMaterial: Data) throws {
        guard keyMaterial.count == 32 else { throw HistoryProtectionError.invalidKey }
        #if os(macOS)
        kind = .keychainEncrypted; material = keyMaterial; unavailableReason = nil
        #else
        throw HistoryProtectionError.encryptionUnavailable
        #endif
    }
    private init(kind: Kind, material: Data? = nil, reason: String? = nil) {
        self.kind = kind; self.material = material; unavailableReason = reason
    }
    public static func unavailable(_ reason: String) -> HistoryProtection { .init(kind: .keyUnavailable, reason: reason) }
    public static func system(home: URL = HarnessPaths.applicationSupport, allowInteraction: Bool = false) -> HistoryProtection {
        #if os(macOS)
        do { return try HistoryProtection(keyMaterial: HistoryMasterKey.loadOrCreate(home: home, allowInteraction: allowInteraction)) }
        catch { return .unavailable(error.localizedDescription) }
        #else
        return .init(kind: .ownerOnlyLinux)
        #endif
    }
    public func seal(_ plain: Data, identity: String, sequence: UInt64) throws -> Data {
        guard plain.count <= 64 << 20 else { throw HistoryProtectionError.recordTooLarge }
        let header = try Self.header(identity: identity, sequence: sequence, encrypted: kind == .keychainEncrypted)
        switch kind {
        case .keyUnavailable: throw HistoryProtectionError.keyUnavailable(unavailableReason ?? "History key is unavailable.")
        case .ownerOnlyLinux: return header + plain
        case .keychainEncrypted:
            #if os(macOS)
            guard let material else { throw HistoryProtectionError.invalidKey }
            let box = try AES.GCM.seal(plain, using: SymmetricKey(data: material), nonce: AES.GCM.Nonce(), authenticating: header)
            guard let combined = box.combined else { throw HistoryProtectionError.corruptRecord }
            return header + combined
            #else
            throw HistoryProtectionError.encryptionUnavailable
            #endif
        }
    }
    public func open(_ record: Data, identity: String, sequence: UInt64) throws -> Data {
        let header = try Self.header(identity: identity, sequence: sequence, encrypted: kind == .keychainEncrypted)
        guard record.count <= (64 << 20) + 8192, record.starts(with: header) else { throw HistoryProtectionError.identityMismatch }
        let payload = Data(record.dropFirst(header.count))
        switch kind {
        case .keyUnavailable: throw HistoryProtectionError.keyUnavailable(unavailableReason ?? "History key is unavailable.")
        case .ownerOnlyLinux:
            guard record.starts(with: Self.plainMagic) else { throw HistoryProtectionError.encryptionUnavailable }
            return payload
        case .keychainEncrypted:
            #if os(macOS)
            guard let material else { throw HistoryProtectionError.invalidKey }
            do { return try AES.GCM.open(AES.GCM.SealedBox(combined: payload), using: SymmetricKey(data: material), authenticating: header) }
            catch { throw HistoryProtectionError.corruptRecord }
            #else
            throw HistoryProtectionError.encryptionUnavailable
            #endif
        }
    }
    /// Explicit import of a Linux owner-only record. Its framing is checked, but
    /// plaintext has no cryptographic authenticity and is never labelled encrypted.
    public static func openLinuxRecordForImport(_ record: Data, identity: String, sequence: UInt64) throws -> Data {
        let header = try Self.header(identity: identity, sequence: sequence, encrypted: false)
        guard record.count <= (64 << 20) + 8192, record.starts(with: header) else { throw HistoryProtectionError.identityMismatch }
        return Data(record.dropFirst(header.count))
    }

    /// Parse only the envelope framing, then authenticate the claimed order and identity.
    public func open(_ record: Data, identity: String) throws -> (data: Data, sequence: UInt64) {
        let record = Data(record)
        guard record.count >= 18 else { throw HistoryProtectionError.corruptRecord }
        let length = record[8..<10].reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= 4096, record.count >= 18 + length else { throw HistoryProtectionError.corruptRecord }
        let sequence = record[(10 + length)..<(18 + length)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (try open(record, identity: identity, sequence: sequence), sequence)
    }
    public static func isProtectedRecord(_ data: Data) -> Bool { data.starts(with: encryptedMagic) || data.starts(with: plainMagic) }
    /// A domain-separated, stable opaque index for provider event identities. The
    /// identity itself is still stored only inside its authenticated envelope.
    public func indexTag(_ data: Data, domain: String) throws -> Data {
        switch kind {
        case .keyUnavailable: throw HistoryProtectionError.keyUnavailable(unavailableReason ?? "History key is unavailable.")
        case .ownerOnlyLinux: return Data(domain.utf8) + Data([0]) + data
        case .keychainEncrypted:
            #if os(macOS)
            guard let material else { throw HistoryProtectionError.invalidKey }
            return Data(HMAC<SHA256>.authenticationCode(for: Data(domain.utf8) + Data([0]) + data, using: SymmetricKey(data: material)))
            #else
            throw HistoryProtectionError.encryptionUnavailable
            #endif
        }
    }
    private static func header(identity: String, sequence: UInt64, encrypted: Bool) throws -> Data {
        let bytes = Data(identity.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw HistoryProtectionError.identityMismatch }
        var header = encrypted ? encryptedMagic : plainMagic
        withUnsafeBytes(of: UInt16(bytes.count).bigEndian) { header.append(contentsOf: $0) }
        header.append(bytes)
        withUnsafeBytes(of: sequence.bigEndian) { header.append(contentsOf: $0) }
        return header
    }
}

public enum HistoryProtectionError: Error, LocalizedError {
    case invalidKey, encryptionUnavailable, corruptRecord, identityMismatch, recordTooLarge
    case keyUnavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidKey: "History key has an invalid format."
        case .encryptionUnavailable: "This component cannot access the configured history encryption."
        case .corruptRecord: "History authentication failed; the record was not opened."
        case .identityMismatch: "History identity, order, or envelope version is invalid."
        case .recordTooLarge: "History record exceeds its bounded storage limit."
        case let .keyUnavailable(reason): reason
        }
    }
}

#if os(macOS)
private enum HistoryMasterKey {
    static func loadOrCreate(home: URL, allowInteraction: Bool) throws -> Data {
        // Modern data-protection Keychain sharing uses signed entitlements rather
        // than an adjacent key file or a deprecated path-based access-control list.
        let group = try HarnessKeychainAccess.sharedGroup()
        let account = SHA256.hash(data: Data(home.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.robert.harness.history.master.v1",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        func read() throws -> Data? {
            var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw HistoryProtectionError.keyUnavailable("History key is locked or unavailable (Keychain status \(status)). Running programs continue; captured history stays in bounded memory.")
            }
            guard let data = result as? Data, data.count == 32 else {
                throw HistoryProtectionError.keyUnavailable("The stored history key has invalid data. Restore the original key before recovering existing history. Running programs continue; captured history stays in bounded memory.")
            }
            return data
        }
        if let data = try read() { return data }
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw HistoryProtectionError.invalidKey }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecDuplicateItem, let existing = try read() { return existing }
        guard added == errSecSuccess else { throw HistoryProtectionError.keyUnavailable("History key could not be stored (Keychain status \(added)); plaintext capture is disabled.") }
        return data
    }

}
#endif
