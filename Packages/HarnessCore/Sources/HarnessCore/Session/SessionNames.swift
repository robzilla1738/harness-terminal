import Foundation

/// Friendly two-word names for new sessions ("drifting cedar"): easier to say, type in a
/// target, and tell apart than "Session 4". Short, lowercase, and unlikely to collide with a
/// real project name.
public enum SessionNames {
    static let adjectives = [
        "amber", "brisk", "calm", "clever", "coastal", "crisp", "drifting", "dusky", "eager", "early",
        "fading", "gentle", "gilded", "hidden", "hollow", "humming", "lucid", "mellow", "misty", "nimble",
        "patient", "quiet", "rapid", "restless", "rising", "rustic", "silver", "sleepy", "steady", "sunlit",
        "swift", "tidal", "velvet", "wandering", "whispering", "wild",
    ]
    static let nouns = [
        "aspen", "basin", "birch", "brook", "canyon", "cedar", "cinder", "comet", "coral", "creek",
        "delta", "dune", "ember", "fern", "fjord", "glacier", "grove", "harbor", "heron", "lagoon",
        "lantern", "maple", "meadow", "mesa", "orchid", "pebble", "pine", "prairie", "quartz", "reef",
        "ridge", "river", "sparrow", "summit", "thicket", "willow",
    ]

    /// A name no session in `existing` already has, case-insensitively. After many misses it
    /// adds a number rather than looping forever.
    public static func generate<G: RandomNumberGenerator>(avoiding existing: Set<String>, using generator: inout G) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        for _ in 0 ..< 64 {
            let name = "\(adjectives.randomElement(using: &generator)!) \(nouns.randomElement(using: &generator)!)"
            if !taken.contains(name) { return name }
        }
        let base = "\(adjectives.randomElement(using: &generator)!) \(nouns.randomElement(using: &generator)!)"
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    public static func generate(avoiding existing: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(avoiding: existing, using: &generator)
    }
}
