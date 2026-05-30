import Foundation

/// Recursive merge for decoded JSON objects (`[String: Any]`). Used when Harness has
/// to fold keys into a config file it doesn't own — e.g. writing agent hooks into the
/// user's `~/.claude/settings.json` without clobbering their model/permissions/MCP
/// settings. Lives in HarnessCore so it's covered by the (portable) core test suite.
public enum JSONMerge {
    /// Returns `base` with `addition` merged in:
    /// - nested objects merge key-by-key (recursively),
    /// - arrays union — only entries `base` doesn't already contain are appended, so the
    ///   merge is idempotent and never duplicates or drops the caller's existing entries,
    /// - scalars (and type mismatches) take the value from `addition`.
    public static func deepMerge(_ base: [String: Any], _ addition: [String: Any]) -> [String: Any] {
        var result = base
        for (key, addValue) in addition {
            if let baseDict = result[key] as? [String: Any], let addDict = addValue as? [String: Any] {
                result[key] = deepMerge(baseDict, addDict)
            } else if let baseArray = result[key] as? [Any], let addArray = addValue as? [Any] {
                var combined = baseArray
                for element in addArray where !baseArray.contains(where: { jsonEqual($0, element) }) {
                    combined.append(element)
                }
                result[key] = combined
            } else {
                result[key] = addValue
            }
        }
        return result
    }

    /// Structural equality for JSON values, used to dedupe array entries on merge.
    public static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs as? NSObject) ?? false
    }
}
