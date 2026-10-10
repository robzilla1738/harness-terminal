import Foundation

/// Typed local sections update independently and retain unknown/newer keys.
public enum SettingsSectionStorage {
    @discardableResult
    public static func save<T: Encodable>(_ value: T, key: String, url: URL = HarnessPaths.settingsURL, rootValues: [String: Bool] = [:], events: [String: Bool]? = nil) throws -> URL? {
        let prior = try PrivateFile.read(url)
        var root = try prior.map { bytes -> [String: Any] in
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw PrivateFile.Failure.unavailable
            }
            return value
        } ?? [:]
        var section = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        if key == "notificationPolicy", var notification = section as? [String: Any] {
            notification.removeValue(forKey: "banners"); notification.removeValue(forKey: "chimes"); notification.removeValue(forKey: "events")
            section = notification
        }
        root[key] = section
        for (key, value) in rootValues { root[key] = value }
        if let events { root["notificationEvents"] = events }
        return try PrivateFile.replace(url, data: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted]), expected: prior)
    }
}
