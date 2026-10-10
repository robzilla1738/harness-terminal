import Foundation
import HarnessCore

/// Closed capture has one retention boundary for disk and unavailable-key memory.
/// Catalog entries contain only surface IDs and close times; text remains in the
/// authenticated streaming store. Layout surfaces are protected during migration.
final class ClosedHistoryStore {
    private struct Entry { var file: ScrollbackFile?; var closedAt: Date }
    private struct Catalog: Codable { var version: Int; var entries: [String: Date] }
    private var entries: [String: Entry] = [:]
    private(set) var evicted = false
    private(set) var failure: String?
    private let maximumBytes: Int
    private let catalogURL: URL?
    private let historyDirectory: URL?
    private var catalogBytes: Data?
    init(maximumBytes: Int = 32 << 20, catalogURL: URL? = nil, historyDirectory: URL? = nil, protectedSurfaces: Set<String> = [], unavailable: String? = nil) {
        self.maximumBytes = maximumBytes; self.catalogURL = catalogURL; self.historyDirectory = historyDirectory
        failure = unavailable
        guard unavailable == nil else { return }
        guard let catalogURL else { return }
        do {
            catalogBytes = try PrivateFile.read(catalogURL)
            if let bytes = catalogBytes {
                let catalog = try JSONDecoder().decode(Catalog.self, from: bytes)
                guard catalog.version == 1, catalog.entries.count <= 4096,
                      catalog.entries.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.timeIntervalSince1970.isFinite }) else { throw PrivateFile.Failure.unavailable }
                entries = catalog.entries.filter { !protectedSurfaces.contains($0.key) }.mapValues { Entry(file: nil, closedAt: $0) }
            }
            // Legacy orphaned files have no trustworthy close timestamp. Start a
            // conservative retention interval once, without inferring process survival.
            if let historyDirectory, FileManager.default.fileExists(atPath: historyDirectory.path) {
                guard let files = FileManager.default.enumerator(at: historyDirectory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { throw PrivateFile.Failure.unavailable }
                var count = 0
                for case let file as URL in files {
                    count += 1
                    guard count <= 16384 else { throw PrivateFile.Failure.unavailable }
                    guard ["scroll", "park"].contains(file.pathExtension) else { continue }
                    let id = file.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: id) != nil, !protectedSurfaces.contains(id), entries[id] == nil else { continue }
                    entries[id] = Entry(file: nil, closedAt: .now)
                }
            }
            try save(); prune(now: .now)
        } catch { failure = "Closed-history retention could not be recovered; files were retained for repair. " + error.localizedDescription }
    }
    func retain(_ file: ScrollbackFile?, surfaceID: String, at: Date = .now) {
        guard UUID(uuidString: surfaceID) != nil, let file else { return }
        file.flush()
        guard file.captureEnabled else { return }
        entries[surfaceID] = Entry(file: file, closedAt: at)
        persist(); maintain(now: at)
    }
    func retained(_ surfaceID: String) -> ScrollbackFile? { prune(now: .now); return entries[surfaceID]?.file }
    func adopted(_ surfaceID: String) { entries.removeValue(forKey: surfaceID); persist() }
    func take(_ surfaceID: String) -> ScrollbackFile? {
        prune(now: .now)
        let result = entries.removeValue(forKey: surfaceID)?.file; persist(); return result
    }
    func purge(_ surfaceID: String) {
        let file = entries.removeValue(forKey: surfaceID)?.file
        file?.delete()
        do { try removeFiles(surfaceID); try save() } catch { failure = "Closed history could not be removed: " + error.localizedDescription }
    }
    func recoveryFiles() -> [ScrollbackFile] { prune(now: .now); return entries.values.compactMap(\.file) }
    func recover(protectedSurfaces: Set<String>) {
        guard failure != nil, let catalogURL else { return }
        let recovered = ClosedHistoryStore(maximumBytes: maximumBytes, catalogURL: catalogURL, historyDirectory: historyDirectory, protectedSurfaces: protectedSurfaces)
        guard recovered.failure == nil else { failure = recovered.failure; return }
        for (id, entry) in entries where !protectedSurfaces.contains(id) { recovered.entries[id] = entry }
        entries = recovered.entries; catalogBytes = recovered.catalogBytes; failure = nil
        persist(); prune(now: .now)
    }
    func maintain(now: Date = .now) {
        if failure != nil {
            // Even unavailable/corrupt retention metadata cannot permit unbounded RAM.
            var bytes = entries.values.reduce(0) { $0 + ($1.file?.bufferedBytes ?? 0) }
            for (id, entry) in entries.sorted(by: { $0.value.closedAt < $1.value.closedAt }) where bytes > maximumBytes || entries.count > 500 {
                let buffered = entry.file?.bufferedBytes ?? 0
                bytes -= buffered; entries.removeValue(forKey: id)
                if buffered > 0 { evicted = true }
            }
        } else { prune(now: now) }
    }
    private func prune(now: Date) {
        // A corrupt or unavailable catalog cannot authorize deletion.
        guard failure == nil else { return }
        let ordered = entries.sorted { ($0.value.closedAt, $0.key) < ($1.value.closedAt, $1.key) }
        var bytes = entries.values.reduce(0) { $0 + ($1.file?.bufferedBytes ?? 0) }
        var changed = false
        for (id, entry) in ordered {
            guard entry.closedAt < now.addingTimeInterval(-14 * 86400) || entries.count > 500 || bytes > maximumBytes else { continue }
            do {
                let buffered = entry.file?.bufferedBytes ?? 0
                try removeFiles(id)
                entry.file?.delete()
                bytes -= buffered
                entries.removeValue(forKey: id); changed = true
                if buffered > 0 { evicted = true }
            } catch { failure = "Closed-history pruning could not remove retained files: " + error.localizedDescription; break }
        }
        if changed { persist() }
    }
    private func removeFiles(_ surfaceID: String) throws {
        guard let directory = historyDirectory else { return }
        guard UUID(uuidString: surfaceID) != nil else { throw PrivateFile.Failure.unavailable }
        for name in [surfaceID + ".scroll", surfaceID + ".scroll.sizes", surfaceID + ".park"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    private func persist() { do { try save() } catch { failure = "Closed-history retention could not be saved: " + error.localizedDescription } }
    private func save() throws {
        guard let catalogURL else { return }
        // Never overwrite a catalog whose recovery failed with a partial model.
        guard failure == nil else { throw PrivateFile.Failure.unavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Catalog(version: 1, entries: entries.mapValues(\.closedAt)))
        _ = try PrivateFile.replace(catalogURL, data: bytes, expected: catalogBytes, backup: false)
        catalogBytes = bytes
    }
}
