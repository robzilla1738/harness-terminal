import Foundation
#if os(Linux)
import Glibc
#endif
#if os(macOS)
import Security
import LocalAuthentication
import CryptoKit
#endif

/// Credentials have a separate storage boundary. Public IPC supports setting and
/// deleting a reference, never reading secret values. No credential enters settings.
public enum CredentialStore {
    public static func save(_ values: [String: String], reference: UUID, allowInteraction: Bool = false) throws {
        guard !values.isEmpty, values.count <= 8, values.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 64 && !$0.value.isEmpty && $0.value.utf8.count <= 8192 }) else { throw CredentialError.invalid }
        let data = try JSONEncoder().encode(values)
        #if os(macOS)
        let query = try keychainQuery(reference, allowInteraction: allowInteraction)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var addition = query; addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError.keychain(added) }
        } else if result != errSecSuccess { throw CredentialError.keychain(result) }
        #else
        let url = try linuxURL(reference)
        _ = try PrivateFile.replace(url, data: data, expected: PrivateFile.read(url), backup: false)
        #endif
    }
    public static func load(_ reference: UUID) throws -> [String: String] {
        let data: Data
        #if os(macOS)
        var query = try keychainQuery(reference, allowInteraction: false)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data else { throw CredentialError.keychain(status) }
        data = bytes
        #else
        guard let bytes = try PrivateFile.read(linuxURL(reference)) else { throw CredentialError.missing }
        data = bytes
        #endif
        guard data.count <= 65536 else { throw CredentialError.invalid }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    public static func remove(_ reference: UUID, allowInteraction: Bool = false) throws {
        #if os(macOS)
        let result = SecItemDelete(try keychainQuery(reference, allowInteraction: allowInteraction) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CredentialError.keychain(result) }
        #else
        let url = try linuxURL(reference)
        if try PrivateFile.read(url) != nil { try FileManager.default.removeItem(at: url) }
        #endif
    }
    #if os(macOS)
    private static func keychainQuery(_ reference: UUID, allowInteraction: Bool) throws -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        let home = SHA256.hash(data: Data(HarnessPaths.applicationSupport.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.robert.harness.credentials.v1",
            kSecAttrAccount as String: home + ":" + reference.uuidString,
            kSecAttrAccessGroup as String: try HarnessKeychainAccess.sharedGroup(),
            kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
    #else
    private static func linuxURL(_ reference: UUID) throws -> URL {
        let directory = HarnessPaths.applicationSupport.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CredentialError.invalid }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw CredentialError.invalid }
        return directory.appendingPathComponent(reference.uuidString + ".json")
    }
    #endif
}
public enum CredentialError: Error, LocalizedError {
    case invalid, missing, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalid: "Credential storage or input is invalid."
        case .missing: "The credential reference is unavailable."
        case let .keychain(status): "The credential is locked or unavailable (Keychain status \(status))."
        }
    }
}
#if os(macOS)
enum HarnessKeychainAccess {
    static func sharedGroup() throws -> String {
        // Read the running task's OS-validated entitlements. Reopening static
        // code at its old path fails after an atomic app/helper update removes
        // that bundle, even though the original signed process is still alive.
        guard let task = SecTaskCreateFromSelf(nil),
              let team = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) as? String,
              team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
              groups.contains(team + ".com.robert.harness.history") else { throw unavailable() }
        return team + ".com.robert.harness.history"
    }
    private static func unavailable() -> HistoryProtectionError {
        .keyUnavailable("Credential and history storage requires signed Harness components with the shared Keychain entitlement.")
    }
}
#endif
