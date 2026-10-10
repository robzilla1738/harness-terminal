import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class WorktreeService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.harness.worktrees", qos: .utility)
    private let store: ActivityStore
    private let hostID: UUID
    private let hostIdentityFailure: String?
    private var settings: WorktreeSettings
    private let settingsURL: URL
    private let lockDirectory: URL
    private let executable: URL
    init(store: ActivityStore, hostID: UUID, settings: WorktreeSettings, settingsURL: URL = HarnessPaths.settingsURL, hostIdentityFailure: String? = nil,
         lockDirectory: URL = HarnessPaths.applicationSupport.appendingPathComponent("worktree-leases"), executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) {
        self.store = store; self.hostID = hostID; self.hostIdentityFailure = hostIdentityFailure; self.settings = settings; self.settingsURL = settingsURL
        self.lockDirectory = lockDirectory; self.executable = executable
    }
    private func repositoryLease(_ repository: GitRepository, cancelled: () -> Bool) throws -> ManagedGitLease {
        let identity = try store.opaqueIdentifier(repository.commonDirectory, domain: "worktree-operation-lease")
        return try ManagedGitLease(url: lockDirectory.appendingPathComponent(identity + ".lock"), cancelled: cancelled)
    }
    func handle(_ operation: WorktreeOperation, cancelled: () -> Bool) throws -> Data {
        try queue.sync {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let lease: ManagedGitLease?
            switch operation {
            case let .inspect(id), let .compare(id), let .remove(id), let .difftoolCommand(id):
                lease = try repositoryLease(recorded(id).repository, cancelled: cancelled)
            default: lease = nil
            }
            defer { withExtendedLifetime(lease) {} }
            switch operation {
            case let .configure(value):
                if let value { try value.validate(); _ = try SettingsSectionStorage.save(value, key: "worktrees", url: settingsURL); settings = value }
                return try encoder.encode(settings)
            case let .list(offset, limit):
                guard offset >= 0, (1...100).contains(limit) else { throw ManagedWorktreeError.budget }
                let records = try store.objectPage(ManagedWorktree.self, kind: "managed-worktree", offset: offset, limit: limit + 1)
                return try encoder.encode(WorktreePage(worktrees: Array(records.prefix(limit)), nextOffset: records.count > limit ? offset + limit : nil, historyUnavailable: store.availability))
            case let .create(id, directory, base): return try encoder.encode(create(id: id, directory: directory, base: base, cancelled: cancelled))
            case let .inspect(id):
                try durable(); var record = try recorded(id)
                if record.state == .removed { try removeMarker(&record); return try encoder.encode(record) }
                if record.state == .removing, !FileManager.default.fileExists(atPath: record.directory) {
                    record.state = .removed; record.note = "Worktree removal reconciled; its committed branch remains addressable."; record.failure = nil; record.failedDuring = nil; try save(&record); try removeMarker(&record)
                } else {
                    let previous = record.state == .failed ? (record.failedDuring ?? .creating) : record.state
                    do {
                        try verify(record, requireBase: previous == .creating, cancelled: cancelled)
                        record.state = .ready; record.failure = nil; record.failedDuring = nil; try save(&record)
                    } catch {
                        record.state = .failed; record.failedDuring = previous
                        record.failure = "The recorded operation could not be reconciled. Files were retained. " + error.localizedDescription
                        try save(&record)
                    }
                }
                return try encoder.encode(record)
            case let .compare(id):
                let record = try recorded(id); try verify(record, requireBase: false, cancelled: cancelled)
                let head = try HarnessGit.commit("HEAD", in: record.directory, cancelled: cancelled)
                let committed = try HarnessGit.stats(HarnessGit.run(directory: record.directory, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", record.baseCommit, head, "--"], cancelled: cancelled))
                let working = try HarnessGit.stats(HarnessGit.run(directory: record.directory, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", head, "--"], cancelled: cancelled))
                let untracked = try HarnessGit.run(directory: record.directory, arguments: ["ls-files", "--others", "--exclude-standard", "-z"], cancelled: cancelled).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                guard untracked.count <= 4096 else { throw ManagedWorktreeError.budget }
                let patch: String?, unavailable: String?
                do {
                    let data = try HarnessGit.run(directory: record.directory, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--no-color", record.baseCommit, "--"], limit: 1 << 20, cancelled: cancelled)
                    patch = String(data: data, encoding: .utf8); unavailable = patch == nil ? "The diff is not valid UTF-8; use the configured difftool." : nil
                } catch { patch = nil; unavailable = "The full patch is unavailable within the bounded view. Use the difftool handoff. " + error.localizedDescription }
                return try encoder.encode(WorktreeComparison(worktree: record, head: head, committed: committed, workingTree: working, untrackedFiles: untracked, patch: patch, patchUnavailable: unavailable))
            case let .remove(id):
                guard let lease else { throw ManagedWorktreeError.busy }
                return try encoder.encode(remove(id, lease: lease, cancelled: cancelled))
            case let .difftoolCommand(id):
                let record = try recorded(id); try verify(record, requireBase: false, cancelled: cancelled)
                let command = "git -C " + ShellQuoting.quote(record.directory) + " difftool --no-prompt " + ShellQuoting.quote(record.baseCommit) + " --"
                return try encoder.encode(["command": command])
            }
        }
    }
    private func durable() throws { guard store.availability == nil, hostIdentityFailure == nil else { throw ManagedWorktreeError.unavailableHistory } }
    private func recorded(_ id: UUID) throws -> ManagedWorktree {
        guard let record = try store.object(ManagedWorktree.self, kind: "managed-worktree", id: id.uuidString) else { throw ManagedWorktreeError.missing }
        guard record.id == id, record.hostID == nil || record.hostID == hostID else { throw ManagedWorktreeError.identity }
        return record
    }
    private func save(_ record: inout ManagedWorktree) throws {
        record.updatedAt = .now
        try store.saveObjects([LedgerObject(kind: "managed-worktree", id: record.id.uuidString, value: record)])
    }
    private struct Marker: Codable, Equatable { var id: UUID; var baseCommit: String }
    private func markerURL(_ record: ManagedWorktree) -> URL { URL(fileURLWithPath: record.directory).deletingLastPathComponent().appendingPathComponent(record.id.uuidString + ".harness-worktree.json") }
    private func create(id: UUID, directory: String, base: String?, cancelled: () -> Bool) throws -> ManagedWorktree {
        try durable(); try settings.validate()
        let repository = try HarnessGit.repository(at: directory, cancelled: cancelled)
        let lease = try repositoryLease(repository, cancelled: cancelled)
        defer { withExtendedLifetime(lease) {} }
        if let prior = try store.object(ManagedWorktree.self, kind: "managed-worktree", id: id.uuidString) {
            guard prior.hostID == nil || prior.hostID == hostID else { throw ManagedWorktreeError.identity }
            guard prior.repository.worktree == (try HarnessGit.repository(at: directory, cancelled: cancelled)).worktree else { throw ManagedWorktreeError.identity }
            if let base { guard try HarnessGit.commit(base, in: directory, cancelled: cancelled) == prior.baseCommit else { throw ManagedWorktreeError.identity } }
            return prior // Retried operation identities never create another directory.
        }
        guard try pruneClosedRecords() < 500 else { throw ManagedWorktreeError.budget }
        let pinned = try HarnessGit.commit(base ?? "HEAD", in: repository.worktree, cancelled: cancelled)
        if base == nil {
            guard try HarnessGit.clean(repository.worktree, cancelled: cancelled) else { throw GitOperationError.dirty }
            guard try HarnessGit.commit("HEAD", in: repository.worktree, cancelled: cancelled) == pinned else { throw GitOperationError.changed }
        }
        let configured = settings.directory.map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL }
            ?? HarnessPaths.applicationSupport.appendingPathComponent("worktrees", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let repositoryID = try store.opaqueIdentifier(repository.commonDirectory, domain: "worktree-repository")
        let parent = configured.appendingPathComponent(repositoryID, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), parent.resolvingSymlinksInPath() == parent else { throw GitOperationError.path }
        let target = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ManagedWorktreeError.identity }
        var record = ManagedWorktree(id: id, hostID: hostID, repository: repository, directory: target.path, baseCommit: pinned, branch: "harness/" + id.uuidString.lowercased())
        let marker = markerURL(record)
        let bytes = try JSONEncoder().encode(Marker(id: id, baseCommit: pinned))
        _ = try PrivateFile.replace(marker, data: bytes, expected: nil, backup: false)
        try save(&record)
        do {
            if parent.path.hasPrefix(repository.worktree + "/") { try exclude(parent, repository: repository, cancelled: cancelled) }
            try ManagedGitWorker.run("add", record: record, lease: lease, executable: executable, cancelled: cancelled)
            try verify(record, requireBase: true, cancelled: cancelled)
            record.state = .ready; try save(&record); return record
        } catch {
            record.state = .failed; record.failedDuring = .creating
            record.failure = "Creation did not complete. Inspect this recorded ID before retrying; a partial worktree is retained. " + error.localizedDescription
            try save(&record); throw error
        }
    }
    private func exclude(_ parent: URL, repository: GitRepository, cancelled: () -> Bool) throws {
        let bytes = try HarnessGit.run(directory: repository.worktree, arguments: ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], limit: 8192, cancelled: cancelled)
        var path = String(decoding: bytes, as: UTF8.self); if path.last == "\n" { path.removeLast() }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw GitOperationError.path }
        let file = URL(fileURLWithPath: path), prior = try PrivateFile.read(file)
        let relative = String(parent.path.dropFirst(repository.worktree.count + 1))
        guard !relative.contains("\n"), !relative.contains("\r") else { throw GitOperationError.path }
        let escaped = relative.reduce(into: "") { result, char in if "\\*?!#[] ".contains(char) { result += "\\" }; result.append(char) }
        let line = "/" + escaped + "/"
        var content = prior ?? Data()
        if !String(decoding: content, as: UTF8.self).split(separator: "\n").contains(Substring(line)) {
            if !content.isEmpty, content.last != 10 { content.append(10) }
            content.append(Data((line + "\n").utf8)); _ = try PrivateFile.replace(file, data: content, expected: prior)
        }
    }
    private func verify(_ record: ManagedWorktree, requireBase: Bool, cancelled: () -> Bool) throws {
        let directory = URL(fileURLWithPath: record.directory).standardizedFileURL
        guard directory.resolvingSymlinksInPath() == directory,
              directory.lastPathComponent == record.id.uuidString,
              let bytes = try PrivateFile.read(markerURL(record), maximumBytes: 4096),
              (try? JSONDecoder().decode(Marker.self, from: bytes)) == Marker(id: record.id, baseCommit: record.baseCommit) else { throw ManagedWorktreeError.identity }
        let actual = try HarnessGit.repository(at: directory.path, cancelled: cancelled)
        guard actual.commonDirectory == record.repository.commonDirectory,
              ProcessScan.directory(actual.worktree, isWithin: record.directory), ProcessScan.directory(record.directory, isWithin: actual.worktree) else { throw ManagedWorktreeError.identity }
        let registrations = try HarnessGit.run(directory: record.directory, arguments: ["worktree", "list", "--porcelain", "-z"], cancelled: cancelled)
        let registered = registrations.split(separator: 0).contains { field in
            let prefix = Data("worktree ".utf8)
            guard field.starts(with: prefix), let path = String(data: field.dropFirst(prefix.count), encoding: .utf8) else { return false }
            return ProcessScan.directory(path, isWithin: record.directory) && ProcessScan.directory(record.directory, isWithin: path)
        }
        guard registered else { throw ManagedWorktreeError.identity }
        let branchBytes = try HarnessGit.run(directory: directory.path, arguments: ["symbolic-ref", "--quiet", "HEAD"], limit: 4096, cancelled: cancelled)
        guard String(decoding: branchBytes, as: UTF8.self).trimmingCharacters(in: .newlines) == "refs/heads/" + record.branch else { throw ManagedWorktreeError.identity }
        if requireBase { guard try HarnessGit.commit("HEAD", in: directory.path, cancelled: cancelled) == record.baseCommit else { throw ManagedWorktreeError.identity } }
    }
    private func remove(_ id: UUID, lease: ManagedGitLease, cancelled: () -> Bool) throws -> ManagedWorktree {
        try durable(); var record = try recorded(id)
        if record.state == .removed { try removeMarker(&record); return record }
        try verify(record, requireBase: false, cancelled: cancelled)
        guard try HarnessGit.clean(record.directory, cancelled: cancelled) else { throw ManagedWorktreeError.dirty }
        let pids = ProcessScan.livePIDs()
        guard !pids.isEmpty, pids.count <= 65536 else { throw ManagedWorktreeError.active }
        for pid in pids {
            if cancelled() { throw ProcessCaptureError.cancelled }
            if let cwd = ProcessScan.workingDirectory(pid), ProcessScan.directory(cwd, isWithin: record.directory) { throw ManagedWorktreeError.active }
        }
        let unpushed = try HarnessGit.run(directory: record.directory, arguments: ["rev-list", "--count", record.baseCommit + "..HEAD", "--not", "--remotes"], limit: 4096, cancelled: cancelled)
        guard String(decoding: unpushed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { throw ManagedWorktreeError.unpushed }
        record.state = .removing; try save(&record)
        do {
            // Git validates dirtiness again. Never --force and never recursive
            // deletion of a path inferred from a directory name.
            try ManagedGitWorker.run("remove", record: record, lease: lease, executable: executable, cancelled: cancelled)
            record.state = .removed; record.note = "Worktree removed. Its branch is retained so committed work remains addressable."; record.failure = nil; try save(&record)
            try removeMarker(&record)
            return record
        } catch {
            record.failure = "Cleanup did not complete. Inspect the recorded worktree before retrying. " + error.localizedDescription
            try save(&record); throw error
        }
    }
    private func removeMarker(_ record: inout ManagedWorktree) throws {
        let marker = markerURL(record)
        do {
            guard let data = try PrivateFile.read(marker, maximumBytes: 4096) else {
                if record.failure != nil { record.failure = nil; try save(&record) }; return
            }
            guard (try? JSONDecoder().decode(Marker.self, from: data)) == Marker(id: record.id, baseCommit: record.baseCommit) else { throw ManagedWorktreeError.identity }
            try FileManager.default.removeItem(at: marker)
            if record.failure != nil { record.failure = nil; try save(&record) }
        } catch {
            record.failure = "The worktree was removed, but its management marker could not be cleaned up. Inspect this ID to retry. " + error.localizedDescription
            try save(&record)
        }
    }
    private func pruneClosedRecords() throws -> Int {
        var offset = 0, closed: [ManagedWorktree] = [], active = 0
        repeat {
            let page = try store.objectPage(ManagedWorktree.self, kind: "managed-worktree", offset: offset, limit: 500)
            closed += page.filter { $0.state == .removed }; active += page.filter { $0.state != .removed }.count
            if page.count < 500 { break }; offset += page.count
            guard offset <= 4096 else { throw ManagedWorktreeError.budget }
        } while true
        let sorted = closed.sorted { $0.updatedAt > $1.updatedAt }
        let expired = sorted.enumerated().filter { $0.offset >= 500 || $0.element.updatedAt < Date().addingTimeInterval(-14 * 86400) }.map { $0.element.id.uuidString }
        if !expired.isEmpty { try store.removeObjects(kind: "managed-worktree", ids: expired) }
        return active
    }
}
