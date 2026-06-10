import Foundation

/// Watches a single file for content changes and fires `onChange` (debounced) on the main queue.
///
/// Survives **atomic saves** — write-to-temp + rename, which most editors *and* our own
/// `JSONEncoder` + `Data.write(options: .atomic)` use: the vnode source's fd points at the old
/// (now-unlinked) inode after a rename, so a `.rename`/`.delete` event re-arms the watch on the
/// path. Best-effort — if the path can't be opened yet (first run, mid-rename), it retries.
///
/// `onChange` is debounced so a burst of writes (or a rename immediately followed by the watcher
/// re-arming and seeing the new file) collapses into one callback.
final class FileWatcher {
    private let url: URL
    private let debounce: DispatchTimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.robert.harness.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: DispatchWorkItem?

    init(url: URL, debounce: DispatchTimeInterval = .milliseconds(200), onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    deinit {
        source?.cancel()
        pendingChange?.cancel()
    }

    /// (Re)open the path and install a vnode source. Each source owns the fd it was built from and
    /// closes it in its own cancel handler, so cancelling the previous source here is the single
    /// close path (no double-close). Runs on `queue`.
    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there yet (first run / mid-rename) — retry shortly.
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.scheduleChange()
            // An atomic save renames/unlinks the watched inode; follow the path to the new file.
            if flags.contains(.rename) || flags.contains(.delete) {
                self.arm()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        // Capture only the (Sendable) callback — not `self` — so the debounce item and its
        // main-queue hop don't send the non-Sendable watcher across queue boundaries.
        let callback = onChange
        let work = DispatchWorkItem {
            DispatchQueue.main.async { callback() }
        }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
