import Foundation

/// Raw replay retention and the legacy line-count policy are separate from decoded memory.
/// `scrollbackLines == 0` removes the configured line cap, but raw replay still stops at
/// 512 MiB. The terminal engine independently caps decoded history at 512 MiB, accounting
/// for stored row widths, row/ring metadata, and exceptional clusters. Wide rows can reach
/// that limit before the requested line count. Active viewport and rendering caches are extra.
public enum ScrollbackBudget {
    public static let bytesPerLine = 160
    /// 512 MiB of raw PTY output. Far more replay than a reattach needs, and the
    /// same ceiling `ScrollbackFile` persists.
    public static let unlimitedSafetyCapBytes = 512 * 1024 * 1024

    /// Line cap for a daemon ring of `bytes`. `bytes <= 0` is the unlimited
    /// sentinel and maps to the safety ceiling, never to "keep every line".
    public static func lineCap(daemonScrollbackBytes bytes: Int) -> Int {
        let capped = bytes <= 0 ? unlimitedSafetyCapBytes : bytes
        return max(1, capped / bytesPerLine)
    }
}
