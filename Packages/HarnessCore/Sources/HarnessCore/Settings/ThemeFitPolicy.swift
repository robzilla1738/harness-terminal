import Foundation

/// Light appearance turns Oklab contrast correction on. Dark leaves it off.
/// A stored bool is the user's choice and wins. Reduce Motion is not an input:
/// this is a color adjustment, not an animation.
public enum ThemeFitPolicy {
    public static func enabled(stored: Bool?, appearanceIsLight: Bool, reduceMotion: Bool = false) -> Bool {
        _ = reduceMotion
        return stored ?? appearanceIsLight
    }

    /// `nil` keeps the appearance default. An explicit bool is stored only when
    /// the toggle disagrees with that default.
    public static func stored(toggleOn: Bool, appearanceIsLight: Bool) -> Bool? {
        toggleOn == appearanceIsLight ? nil : toggleOn
    }
}
