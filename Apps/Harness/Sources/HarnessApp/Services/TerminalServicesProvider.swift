import AppKit

/// Backs the Finder folder right-click services "New Harness Tab Here" / "New Harness Window Here"
/// declared in `Info.plist` (`NSServices`). Registered via `NSApp.servicesProvider` in `AppDelegate`.
///
/// The `@objc` method base names MUST match the `NSMessage` values in the plist (`openTab` /
/// `openWindow`) — AppKit dispatches the service by that selector, on the main thread.
@MainActor
final class TerminalServicesProvider: NSObject {
    @objc func openTab(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pasteboard, asWindow: false, error: error)
    }

    @objc func openWindow(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pasteboard, asWindow: true, error: error)
    }

    private func open(_ pasteboard: NSPasteboard, asWindow: Bool, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let directories = Self.directories(from: pasteboard)
        guard !directories.isEmpty else {
            error.pointee = "Select a folder to open in Harness." as NSString
            return
        }
        // Route through AppDelegate so the open inherits its cold-launch daemon-readiness/retry queue.
        (NSApp.delegate as? AppDelegate)?.handleServiceOpen(directories: directories, asWindow: asWindow)
    }

    /// Folder URLs carried by the service pasteboard, most-reliable source first. Filtered to
    /// directories so "New Terminal *Here*" always targets the folder itself.
    private static func directories(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls = objects
        }
        if urls.isEmpty,
           let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        if urls.isEmpty, let string = pasteboard.string(forType: .string) {
            urls = [URL(fileURLWithPath: (string as NSString).expandingTildeInPath)]
        }
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
