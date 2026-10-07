import Foundation

/// A copy fades the selection only when the pasteboard accepted the text.
public enum CopyConfirmation {
    public static func fadesSelection(pasteboardAccepted: Bool) -> Bool {
        pasteboardAccepted
    }
}
