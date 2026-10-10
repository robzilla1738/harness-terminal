import Foundation
import HarnessCore
import HarnessRemoteProtocol
import HarnessTerminalEngine

struct MobileHistorySnapshot: Sendable {
    var text: TerminalTextSnapshot
    var hyperlinks: [UInt32: String]
    var cellCount: Int
}

extension RealPty {
    func mobileHistorySnapshot() -> MobileHistorySnapshot? {
        // Take rows and link definitions under the same parser lock: OSC 8 ids must not
        // be resolved against a different generation of the terminal.
        withMobileHistory { term in
            let text = term.textSnapshot()
            guard text.lineCount <= 100_000, text.lineCount * term.cols <= 1_000_000 else { return nil }
            var links: [UInt32: String] = [:]
            var cells = 0
            for index in 0..<text.lineCount {
                let row = text.line(index)
                cells += row.count
                guard cells <= 1_000_000 else { return nil }
                for cell in row where cell.hyperlinkID != 0 && links[cell.hyperlinkID] == nil {
                    links[cell.hyperlinkID] = term.hyperlinkURL(id: cell.hyperlinkID)
                }
            }
            return MobileHistorySnapshot(text: text, hyperlinks: links, cellCount: cells)
        }
    }
}
extension SessionPty {
    func mobileHistorySnapshot() -> MobileHistorySnapshot? {
        // Take rows and link definitions under the same parser lock: OSC 8 ids must not
        // be resolved against a different generation of the terminal.
        withMobileHistory { term in
            let text = term.textSnapshot()
            guard text.lineCount <= 100_000, text.lineCount * term.cols <= 1_000_000 else { return nil }
            var links: [UInt32: String] = [:]
            var cells = 0
            for index in 0..<text.lineCount {
                let row = text.line(index)
                cells += row.count
                guard cells <= 1_000_000 else { return nil }
                for cell in row where cell.hyperlinkID != 0 && links[cell.hyperlinkID] == nil {
                    links[cell.hyperlinkID] = term.hyperlinkURL(id: cell.hyperlinkID)
                }
            }
            return MobileHistorySnapshot(text: text, hyperlinks: links, cellCount: cells)
        }
    }
}

extension SurfaceRegistry {
    func matchedMobileHistorySnapshot(_ match: OutputSearchMatch, revision: Int, cancelled: FlagBox) -> MobileHistorySnapshot? {
        // Registry -> authoritative parser is the same lock order used by registry capture.
        // Hold topology stable until the immutable rows have been captured.
        lock.lock()
        defer { lock.unlock() }
        let snapshot = editor.snapshot
        guard revision >= 0, snapshot.revision >= revision, !cancelled.read(),
              let workspace = snapshot.workspaces.first(where: { $0.id == match.workspaceID }),
              let session = workspace.sessions.first(where: { $0.id == match.sessionID }),
              let tab = session.tabs.first(where: { $0.id == match.tabID }),
              tab.rootPane.allLeaves().contains(where: { $0.id == match.paneID && $0.surfaceID == match.surfaceID }),
              let pty = sessions[match.surfaceID.uuidString] else { return nil }
        return pty.mobileHistorySnapshot()
    }

    func mobileHistorySnapshot(surfaceID: String) -> MobileHistorySnapshot? {
        lock.lock()
        let session = sessions[surfaceID]
        lock.unlock()
        return session?.mobileHistorySnapshot()
    }
}

/// Immutable COW rows are cached on the host, never serialized as one giant payload.
/// Retention is bounded by cells as well as token count; expired tokens cannot name fresh rows.
final class MobileHistoryStore: @unchecked Sendable {
    private struct Entry {
        var surfaceID: String
        var epoch: String
        var snapshot: MobileHistorySnapshot
        var expiresAt: Date
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval = 60

    func matchedPage(_ match: OutputSearchMatch, epoch: String, load: () -> MobileHistorySnapshot?) -> IPCResponse {
        guard let captured = load(), (0..<captured.text.lineCount).contains(match.line),
              OutputSearch.fingerprint(captured.text.logicalText(startingAt: match.line).text.text) == match.lineFingerprint else {
            return .error("This output moved or expired, or its pane moved or closed. Search again.")
        }
        // Validate and page the very same immutable rows. Fresh output or a scrollback roll
        // after this point cannot turn the opened result into a different line.
        return page(surfaceID: match.surfaceID.uuidString, token: nil,
                    before: min(captured.text.lineCount, match.line + 128), count: 256,
                    epoch: epoch, targetRow: match.line, load: { captured })
    }

    func page(surfaceID: String, token: String?, before: Int?, count: Int, epoch: String, targetRow: Int? = nil,
              load: () -> MobileHistorySnapshot?) -> IPCResponse {
        guard count > 0, count <= 256, before.map({ $0 >= 0 }) ?? true else {
            return .error("History count must be 1...256 and before must be nonnegative")
        }
        var loaded: MobileHistorySnapshot?
        if token == nil {
            loaded = load()
            guard loaded != nil else { return .error("Pane history unavailable or larger than the mobile history budget") }
        }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now && $0.value.epoch == epoch }
        let key: String
        var entry: Entry
        if let token {
            guard let found = entries[token], found.surfaceID == surfaceID, found.epoch == epoch else {
                return .error("History expired. Fetch a new history snapshot.")
            }
            key = token
            entry = found
        } else {
            guard let loaded else { return .error("History unavailable") }
            while entries.count >= 4 || entries.values.reduce(loaded.cellCount, { $0 + $1.snapshot.cellCount }) > 2_000_000 {
                guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else { break }
                entries.removeValue(forKey: oldest)
            }
            key = UUID().uuidString
            entry = Entry(surfaceID: surfaceID, epoch: epoch, snapshot: loaded, expiresAt: now.addingTimeInterval(lifetime))
        }
        let text = entry.snapshot.text
        guard before.map({ $0 <= text.lineCount }) ?? true else { return .error("History position is outside this snapshot") }
        let end = before ?? text.lineCount
        let start = max(0, end - count)
        var rows: [RemoteHistoryRow] = []
        var wireBudget = 0
        for index in start..<end {
            let cells = text.line(index).map { cell in
                var flags: UInt16 = 0
                if cell.bold { flags |= 1 }; if cell.faint { flags |= 2 }; if cell.italic { flags |= 4 }
                if cell.blink { flags |= 8 }; if cell.inverse { flags |= 16 }; if cell.invisible { flags |= 32 }
                if cell.strikethrough { flags |= 64 }; if cell.overline { flags |= 128 }
                flags |= cell.underline.rawValue << 8
                return RemoteHistoryCell(text: cell.resolvedCluster(in: text.clusters),
                    width: cell.width == .wide ? 2 : cell.width == .spacerTail ? 0 : 1,
                    foreground: Self.color(cell.foreground), background: Self.color(cell.background), flags: flags,
                    hyperlink: entry.snapshot.hyperlinks[cell.hyperlinkID])
            }
            wireBudget += cells.reduce(0) { $0 + $1.text.utf8.count + ($1.hyperlink?.utf8.count ?? 0) + 160 }
            guard wireBudget <= 4 * 1024 * 1024 else { return .error("History page too large; request fewer rows") }
            rows.append(RemoteHistoryRow(wrapped: text.isWrapped(index), cells: cells))
        }
        entry.expiresAt = now.addingTimeInterval(lifetime)
        entries[key] = entry
        let page = RemoteHistoryPage(token: key, epoch: epoch, totalRows: text.lineCount, startRow: start, rows: rows, expiresAt: entry.expiresAt, targetRow: targetRow)
        do { return .text(String(decoding: try JSONEncoder().encode(page), as: UTF8.self)) }
        catch { return .error("Could not encode history page") }
    }

    private static func color(_ color: TerminalGridColor) -> String {
        switch color {
        case .none: return "default"
        case let .palette(index): return "palette:\(index)"
        case let .rgb(r, g, b): return String(format: "#%02x%02x%02x", r, g, b)
        }
    }
}
