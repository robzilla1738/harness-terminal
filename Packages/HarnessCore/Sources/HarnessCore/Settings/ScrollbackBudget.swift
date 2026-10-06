import Foundation

/// One scrollback ceiling for the daemon replay ring and the GUI line history.
/// `scrollbackLines == 0` is the unlimited sentinel. Both sides stop at this byte
/// cap, so the GUI cannot keep a second unbounded copy.
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
