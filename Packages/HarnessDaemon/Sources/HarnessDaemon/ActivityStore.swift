import Foundation
import CSQLite
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The daemon's transactional ledger. Sensitive payloads are sealed before SQLite
/// sees them, so database pages, journals, WALs, and temporary pages contain envelopes.
final class ActivityStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.harness.activity-store")
    private let url: URL
    private var database: OpaquePointer?
    private var protection: HistoryProtection
    private var diskProtection: HistoryProtection
    private var memoryOnly = false
    private var memoryIndexKey: Data?
    private var indexProtection: HistoryProtection?
    private var writable: Bool
    private(set) var unavailableReason: String?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL = HarnessPaths.sessionsDirectory.appendingPathComponent("activity.sqlite"),
         protection: HistoryProtection = .system(), writable: Bool = true) {
        self.url = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        diskProtection = protection; self.protection = protection; self.writable = writable
        do { try open() }
        catch {
            unavailableReason = "Activity history is unavailable; live activity remains in bounded memory. " + error.localizedDescription
            closeOnQueue(); memoryOnly = true
            do { try openMemory() } catch { unavailableReason = "Activity tracking could not open its memory store." }
        }
    }
    deinit { closeOnQueue() }
    var availability: String? { queue.sync { unavailableReason ?? diskProtection.unavailableReason } }
    var protectionKind: HistoryProtection.Kind { queue.sync { diskProtection.kind } }
    func recoverConfiguredProtection() throws { try recover(protection: queue.sync { diskProtection }) }
    private func open() throws {
        if diskProtection.kind == .keyUnavailable { memoryOnly = true; unavailableReason = diskProtection.unavailableReason; try openMemory(); return }
        if !writable, !FileManager.default.fileExists(atPath: url.path) { memoryOnly = true; try openMemory(); return }
        if writable {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = openFile(url.path, flags: O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw LedgerError.storage }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else { throw LedgerError.storage }
        }
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        // Resolve the now-existing parent (macOS /var is a symlink), while preserving
        // NOFOLLOW for the database leaf itself.
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { throw LedgerError.storage }
        let parent = String(cString: resolved); free(resolved)
        let path = URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent).path
        let code = sqlite3_open_v2(path, &database, flags, nil)
        guard code == SQLITE_OK else { throw LedgerError.database(sqlite3_extended_errcode(database)) }
        sqlite3_busy_timeout(database, 3000)
        try execute("PRAGMA temp_store=MEMORY")
        if writable {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; PRAGMA journal_size_limit=4194304")
            try schema()
        } else {
            let version = try rows("PRAGMA user_version").first?.integer(0)
            guard version == 1 else { throw LedgerError.version }
        }
        guard try rows("PRAGMA quick_check").first?.string(0) == "ok" else { throw LedgerError.storage }

    }
    private func openMemory() throws {
        #if os(macOS)
        protection = try HistoryProtection(keyMaterial: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        memoryIndexKey = key; indexProtection = try HistoryProtection(keyMaterial: key)
        #endif
        guard sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw LedgerError.storage }
        try execute("PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON; PRAGMA max_page_count=8192")
        try schema()
    }
    private func schema() throws {
        let version = try rows("PRAGMA user_version").first?.integer(0) ?? 0
        guard version <= 1 else { throw LedgerError.version }
        try execute("""
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, host TEXT NOT NULL, surface TEXT NOT NULL,
                started REAL NOT NULL, ended REAL, updated REAL NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS runs_surface ON runs(surface, ended, started);
            CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                run TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, at REAL NOT NULL, kind TEXT NOT NULL,
                dedup BLOB, payload BLOB NOT NULL, UNIQUE(run,dedup));
            CREATE INDEX IF NOT EXISTS events_run ON events(run,sequence);
            CREATE INDEX IF NOT EXISTS events_at ON events(at,run,kind);
            CREATE TABLE IF NOT EXISTS objects(kind TEXT NOT NULL, id TEXT NOT NULL, updated REAL NOT NULL,
                revision INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id));
            CREATE INDEX IF NOT EXISTS objects_updated ON objects(kind,updated);
            PRAGMA user_version=1;
            COMMIT;
            """)
    }
    func suspend() throws {
        try queue.sync {
            if writable, !memoryOnly { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
            writable = false
            if !memoryOnly { closeOnQueue() }
        }
    }
    func activate() throws {
        try queue.sync {
            guard !writable else { return }
            writable = true
            if !memoryOnly { closeOnQueue(); try open() }
        }
    }
    func flush() throws { try queue.sync { if writable, !memoryOnly { try execute("PRAGMA wal_checkpoint(PASSIVE)") } } }
    func memoryCheckpoint(maximumBytes: Int = 3 << 20) throws -> ActivityMemoryCheckpoint? {
        try queue.sync { try memoryCheckpointOnQueue(maximumBytes: maximumBytes) }
    }
    private func memoryCheckpointOnQueue(maximumBytes: Int) throws -> ActivityMemoryCheckpoint? {
            guard memoryOnly else { return nil }
            let runs: [AgentRun] = try rows("SELECT id,revision,payload FROM runs ORDER BY started,id").map {
                try unseal($0.blob(2), identity: "run:" + $0.string(0), revision: $0.integer(1))
            }
            let events: [RunEvent] = try rows("SELECT sequence,id,run,payload FROM events ORDER BY sequence").map {
                try unseal($0.blob(3), identity: "event:" + $0.string(1) + ":" + $0.string(2), revision: $0.integer(0))
            }
            let objects: [ActivityMemoryCheckpoint.Object] = try rows("SELECT kind,id,updated,revision,payload FROM objects").map {
                let row = $0
                let value = try protection.open(row.blob(4), identity: "object:" + row.string(0) + ":" + row.string(1), sequence: UInt64(row.integer(3)))
                return .init(kind: row.string(0), id: row.string(1), data: value, at: Date(timeIntervalSince1970: row.real(2)))
            }
            let checkpoint = ActivityMemoryCheckpoint(runs: runs, events: events, objects: objects, indexKey: memoryIndexKey)
            guard try JSONEncoder().encode(checkpoint).count <= maximumBytes else { throw LedgerError.limit }
            return checkpoint
    }
    func restoreMemory(_ checkpoint: ActivityMemoryCheckpoint, maximumBytes: Int = 3 << 20, recoveringToDisk: Bool = false) throws {
        guard checkpoint.runs.count <= 2000, checkpoint.events.count <= 4096,
              try JSONEncoder().encode(checkpoint).count <= maximumBytes else { throw LedgerError.limit }
        try queue.sync {
            try requireWrite()
            #if os(macOS)
            if !recoveringToDisk, let key = checkpoint.indexKey {
                guard key.count == 32 else { throw LedgerError.storage }
                memoryIndexKey = key; indexProtection = try HistoryProtection(keyMaterial: key)
            }
            #endif
            try transaction {
                for run in checkpoint.runs { try saveOnQueue(run) }
                for event in checkpoint.events {
                    guard let row = try rows("SELECT revision,payload FROM runs WHERE id=?", [.text(event.runID.uuidString)]).first else { continue }
                    var run: AgentRun = try unseal(row.blob(1), identity: "run:" + event.runID.uuidString, revision: row.integer(0))
                    _ = try recordOnQueue(event, reducing: &run)
                }
                let objects = try checkpoint.objects.map { object -> LedgerObject in
                    var id = object.id
                    if recoveringToDisk, object.kind == "usage-watermark" {
                        let watermark = try JSONDecoder().decode(UsageWatermark.self, from: object.data)
                        guard let seed = watermark.seed else { throw LedgerError.storage }
                        id = try protection.indexTag(Data(seed.utf8), domain: "usage-watermark").map { String(format: "%02x", $0) }.joined()
                    }
                    return try LedgerObject(kind: object.kind, id: id, rawData: object.data, at: object.at)
                }
                try saveObjectsOnQueue(objects)
            }
        }
    }
    /// Keep the original memory database until the entire encrypted import commits.
    /// A failed key lookup, database open, or import leaves live tracking intact.
    func recover(protection nextProtection: HistoryProtection) throws {
        guard nextProtection.kind != .keyUnavailable else { throw HistoryProtectionError.keyUnavailable(nextProtection.unavailableReason ?? "History key is unavailable.") }
        try queue.sync {
            try requireWrite()
            guard memoryOnly else { return }
            guard let checkpoint = try memoryCheckpointOnQueue(maximumBytes: 32 << 20) else { return }
            let candidate = ActivityStore(url: url, protection: nextProtection)
            guard !candidate.memoryOnly else { throw HistoryProtectionError.keyUnavailable(candidate.availability ?? "Encrypted activity storage is unavailable.") }
            try candidate.authenticateExistingRecords()
            try candidate.restoreMemory(checkpoint, maximumBytes: 32 << 20, recoveringToDisk: true)
            closeOnQueue()
            database = candidate.database; candidate.database = nil
            protection = candidate.protection; diskProtection = nextProtection
            indexProtection = candidate.indexProtection; memoryIndexKey = candidate.memoryIndexKey
            memoryOnly = false; unavailableReason = nil
        }
    }
    private func authenticateExistingRecords() throws {
        try queue.sync {
            // Authenticate in bounded pages before an unlock can merge new data into
            // an existing ledger. A wrong key or damaged record preserves memory.
            for table in ["runs", "events", "objects"] {
                var position: Int64 = 0
                while true {
                    let page: [Row]
                    switch table {
                    case "runs": page = try rows("SELECT rowid,id,revision,payload FROM runs WHERE rowid>? ORDER BY rowid LIMIT 256", [.integer(position)])
                    case "events": page = try rows("SELECT sequence,id,run,payload FROM events WHERE sequence>? ORDER BY sequence LIMIT 256", [.integer(position)])
                    default: page = try rows("SELECT rowid,kind,id,revision,payload FROM objects WHERE rowid>? ORDER BY rowid LIMIT 256", [.integer(position)])
                    }
                    for row in page {
                        let identity: String, revision: Int64, payload: Data
                        switch table {
                        case "runs": identity = "run:" + row.string(1); revision = row.integer(2); payload = row.blob(3)
                        case "events": identity = "event:" + row.string(1) + ":" + row.string(2); revision = row.integer(0); payload = row.blob(3)
                        default: identity = "object:" + row.string(1) + ":" + row.string(2); revision = row.integer(3); payload = row.blob(4)
                        }
                        guard revision > 0 else { throw LedgerError.storage }
                        _ = try protection.open(payload, identity: identity, sequence: UInt64(revision))
                        position = row.integer(0)
                    }
                    if page.count < 256 { break }
                }
            }
        }
    }
    func save(_ run: AgentRun) throws {
        try queue.sync {
            try requireWrite(); try transaction { try saveOnQueue(run) }
            if run.endedAt != nil { try pruneOnQueue(now: .now) }
            try boundMemory()
        }
    }
    private func saveOnQueue(_ run: AgentRun) throws {
        let id = run.id.uuidString
        let revision = (try rows("SELECT revision FROM runs WHERE id=?", [.text(id)]).first?.integer(0) ?? 0) + 1
        let payload = try seal(run, identity: "run:" + id, revision: revision)
        try execute("INSERT INTO runs VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET ended=excluded.ended, updated=excluded.updated, revision=excluded.revision,payload=excluded.payload",
            [.text(id), .text(run.hostID.uuidString), .text(run.surfaceID), .real(run.startedAt.timeIntervalSince1970),
             run.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null, .real(run.observedAt.timeIntervalSince1970), .integer(revision), .blob(payload)])
        let attribution = RunUsageAttribution(run)
        let previous = try rows("SELECT revision,payload FROM objects WHERE kind='run-attribution' AND id=?", [.text(id)]).first
        let prior: RunUsageAttribution? = try previous.map { try unseal($0.blob(1), identity: "object:run-attribution:" + id, revision: $0.integer(0)) }
        if prior != attribution { try saveObjectsOnQueue([LedgerObject(kind: "run-attribution", id: id, value: attribution)]) }
    }
    @discardableResult
    func record(_ event: RunEvent, reducing run: inout AgentRun) throws -> Bool {
        var next = run
        let inserted = try queue.sync {
            try requireWrite()
            return try transaction {
                try recordOnQueue(event, reducing: &next)
            }
        }
        if inserted {
            run = next
            try queue.sync {
                if next.endedAt != nil { try pruneOnQueue(now: .now) }
                try boundMemory()
            }
        }
        return inserted
    }
    private func recordOnQueue(_ event: RunEvent, reducing next: inout AgentRun) throws -> Bool {
                if !(try rows("SELECT 1 FROM events WHERE id=? LIMIT 1", [.text(event.id.uuidString)])).isEmpty { return false }
                let dedup = try event.deduplicationID.map { try protection.indexTag(Data($0.utf8), domain: "event-dedup:" + next.id.uuidString) }
                if let dedup, !(try rows("SELECT 1 FROM events WHERE run=? AND dedup=? LIMIT 1", [.text(next.id.uuidString), .blob(dedup)])).isEmpty { return false }
                AgentRunReducer.apply(event, to: &next)
                try saveOnQueue(next)
                let sequence = (try rows("SELECT seq FROM sqlite_sequence WHERE name='events'").first?.integer(0) ?? 0) + 1
                let payload = try seal(event, identity: "event:" + event.id.uuidString + ":" + next.id.uuidString, revision: sequence)
                try execute("INSERT INTO events(sequence,id,run,at,kind,dedup,payload) VALUES(?,?,?,?,?,?,?)",
                    [.integer(sequence), .text(event.id.uuidString), .text(next.id.uuidString), .real(event.at.timeIntervalSince1970), .text(event.kind.rawValue), dedup.map(Value.blob) ?? .null, .blob(payload)])
                return true
    }
    func list(surfaceID: String? = nil, activeOnly: Bool = false, offset: Int = 0, limit: Int = 100) throws -> RunPage {
        try queue.sync {
            let cap = min(max(limit, 1), 500), start = max(offset, 0)
            var predicates: [String] = [], values: [Value] = []
            if let surfaceID { predicates.append("surface=?"); values.append(.text(surfaceID)) }
            if activeOnly { predicates.append("ended IS NULL") }
            let predicate = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
            values += [.integer(Int64(cap + 1)), .integer(Int64(start))]
            let records = try rows("SELECT id,revision,payload FROM runs" + predicate + " ORDER BY started DESC,id LIMIT ? OFFSET ?", values)
            let runs: [AgentRun] = try records.prefix(cap).map { try unseal($0.blob(2), identity: "run:" + $0.string(0), revision: $0.integer(1)) }
            return RunPage(runs: runs, nextOffset: records.count > cap ? start + cap : nil, historyUnavailable: unavailableReason)
        }
    }
    func run(_ id: UUID) throws -> AgentRun? {
        try queue.sync {
            guard let row = try rows("SELECT revision,payload FROM runs WHERE id=?", [.text(id.uuidString)]).first else { return nil }
            return try unseal(row.blob(1), identity: "run:" + id.uuidString, revision: row.integer(0))
        }
    }
    func execution(surfaceID: String, generation: String, parentID: UUID) throws -> AgentRun? {
        try queue.sync {
            for row in try rows("SELECT id,revision,payload FROM runs WHERE surface=? ORDER BY started DESC,id", [.text(surfaceID)]) {
                let run: AgentRun = try unseal(row.blob(2), identity: "run:" + row.string(0), revision: row.integer(1))
                if run.processGeneration == generation, run.parentRunID == parentID { return run }
            }
            return nil
        }
    }
    func events(runID: UUID, offset: Int = 0, limit: Int = 200) throws -> [RunEvent] {
        try queue.sync { try eventsOnQueue(runID: runID, offset: offset, limit: min(max(limit, 1), 500)) }
    }
    private func eventsOnQueue(runID: UUID, offset: Int, limit: Int?) throws -> [RunEvent] {
        let sql = "SELECT sequence,id,payload FROM events WHERE run=? ORDER BY sequence" + (limit == nil ? "" : " LIMIT ? OFFSET ?")
        var args: [Value] = [.text(runID.uuidString)]
        if let limit { args += [.integer(Int64(limit)), .integer(Int64(max(0, offset)))] }
        return try rows(sql, args).map { try unseal($0.blob(2), identity: "event:" + $0.string(1) + ":" + runID.uuidString, revision: $0.integer(0)) }
    }
    func object<T: Decodable>(_ type: T.Type, kind: String, id: String) throws -> T? {
        try queue.sync {
            guard let row = try rows("SELECT revision,payload FROM objects WHERE kind=? AND id=?", [.text(kind), .text(id)]).first else { return nil }
            return try unseal(row.blob(1), identity: "object:\(kind):\(id)", revision: row.integer(0))
        }
    }
    struct SequencedEvent { var sequence: Int64; var event: RunEvent }
    func latestEventSequence() throws -> Int64 {
        try queue.sync { try rows("SELECT seq FROM sqlite_sequence WHERE name='events'").first?.integer(0) ?? 0 }
    }
    func scheduledEvents(after sequence: Int64, limit: Int = 200) throws -> [SequencedEvent] {
        try queue.sync {
            try rows("SELECT sequence,id,run,payload FROM events WHERE sequence>? ORDER BY sequence LIMIT ?", [.integer(sequence), .integer(Int64(min(200, max(1, limit))))]).map {
                SequencedEvent(sequence: $0.integer(0), event: try unseal($0.blob(3), identity: "event:" + $0.string(1) + ":" + $0.string(2), revision: $0.integer(0)))
            }
        }
    }
    func recordPolicyAudit(_ audit: HookPolicyAudit) throws {
        try queue.sync {
            try requireWrite(); try transaction {
                try saveObjectsOnQueue([LedgerObject(kind: "hook-policy-audit", id: audit.id.uuidString, value: audit)])
                try execute("DELETE FROM objects WHERE kind='hook-policy-audit' AND (updated<? OR id NOT IN (SELECT id FROM objects WHERE kind='hook-policy-audit' ORDER BY updated DESC,id LIMIT 500))", [.real(Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970)])
            }; try boundMemory()
        }
    }
    func objectCount(kind: String) throws -> Int {
        try queue.sync { Int(try rows("SELECT count(*) FROM objects WHERE kind=?", [.text(kind)]).first?.integer(0) ?? 0) }
    }
    func objectUpdatedAt(kind: String, id: String) throws -> Date? {
        try queue.sync {
            try rows("SELECT updated FROM objects WHERE kind=? AND id=?", [.text(kind), .text(id)]).first.map { Date(timeIntervalSince1970: $0.real(0)) }
        }
    }
    func objects<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        try queue.sync {
            try rows("SELECT id,revision,payload FROM objects WHERE kind=? ORDER BY updated,id", [.text(kind)]).map {
                try unseal($0.blob(2), identity: "object:" + kind + ":" + $0.string(0), revision: $0.integer(1))
            }
        }
    }
    func objectPage<T: Decodable>(_ type: T.Type, kind: String, offset: Int = 0, limit: Int = 500, idPrefix: String? = nil, orderByIdentity: Bool = false) throws -> [T] {
        try queue.sync {
            try rows("SELECT id,revision,payload FROM objects WHERE kind=?" + (idPrefix == nil ? "" : " AND substr(id,1,?)=?") + " ORDER BY " + (orderByIdentity ? "id" : "updated,id") + " LIMIT ? OFFSET ?",
                     [.text(kind)] + (idPrefix.map { [.integer(Int64($0.count)), .text($0)] } ?? []) + [.integer(Int64(min(501, max(1, limit)))), .integer(Int64(max(0, offset)))]).map {
                try unseal($0.blob(2), identity: "object:" + kind + ":" + $0.string(0), revision: $0.integer(1))
            }
        }
    }
    func removeTranscriptBinding(_ id: String) throws {
        try queue.sync {
            try requireWrite(); try transaction {
                try execute("DELETE FROM objects WHERE kind IN ('transcript-binding','transcript-cursor') AND id=?", [.text(id)])
            }
        }
    }
    func removeObjects(kind: String, ids: [String]) throws {
        guard ids.count <= 1024 else { throw LedgerError.limit }
        try queue.sync {
            try requireWrite(); try transaction {
                for id in ids { try execute("DELETE FROM objects WHERE kind=? AND id=?", [.text(kind), .text(id)]) }
            }
        }
    }
    func opaqueIdentifier(_ value: String, domain: String) throws -> String {
        try queue.sync { try (indexProtection ?? protection).indexTag(Data(value.utf8), domain: domain).map { String(format: "%02x", $0) }.joined() }
    }
    func digestEvents(from: Date, to: Date, surfaceID: String? = nil, limit: Int = 200) throws -> (DigestTotals, [RunEvent], Bool) {
        try queue.sync {
            let bounds: [Value] = [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
            let filter = surfaceID == nil ? "" : " AND r.surface=?"
            let values = bounds + (surfaceID.map { [Value.text($0)] } ?? [])
            let count = try rows("SELECT count(*) FROM runs r WHERE r.started>=? AND r.started<?" + filter, values).first?.integer(0) ?? 0
            let grouped = try rows("SELECT e.kind,count(*) FROM events e JOIN runs r ON e.run=r.id WHERE e.at>=? AND e.at<?" + filter + " GROUP BY e.kind", values)
            let counts = Dictionary(uniqueKeysWithValues: grouped.map { ($0.string(0), Int($0.integer(1))) })
            let cap = min(max(limit, 1), 200)
            let records = try rows("SELECT e.sequence,e.id,e.run,e.payload FROM events e JOIN runs r ON e.run=r.id WHERE e.at>=? AND e.at<?" + filter + " ORDER BY e.at DESC,e.sequence DESC LIMIT ?", values + [.integer(Int64(cap + 1))])
            let events: [RunEvent] = try records.prefix(cap).map {
                try unseal($0.blob(3), identity: "event:" + $0.string(1) + ":" + $0.string(2), revision: $0.integer(0))
            }
            return (DigestTotals.recorded(executions: Int(count), eventCounts: counts), events.reversed(), records.count > cap)
        }
    }
    /// Uses the same event-count mapping as the host digest, independent of its
    /// display timeline. Aggregate usage metadata survives the closed-detail bound.
    func repositoryDigests(hostID: UUID, from: Date, to: Date, offset: Int, limit: Int, cancelled: @escaping () -> Bool = { false }) throws -> RepositoryDigestPage {
        let budget = RepositoryQueryBudget(cancelled: cancelled)
        do { return try queue.sync {
            sqlite3_progress_handler(database, 1000, { context in
                guard let context else { return 1 }
                return Unmanaged<RepositoryQueryBudget>.fromOpaque(context).takeUnretainedValue().stopped ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(budget) {} }
            guard (0...1_000_000).contains(offset), (1...100).contains(limit) else { throw RepositoryDigestError.page }
            guard !budget.stopped else { throw RepositoryDigestError.budget }
            var eventCounts: [UUID: [String: Int]] = [:], started: Set<UUID> = []
            for row in try rows("SELECT run,kind,count(*) FROM events WHERE at>=? AND at<? GROUP BY run,kind", [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) {
                guard let id = UUID(uuidString: row.string(0)) else { throw LedgerError.storage }
                eventCounts[id, default: [:]][row.string(1)] = Int(row.integer(2))
            }
            for row in try rows("SELECT id FROM runs WHERE started>=? AND started<?", [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) {
                guard let id = UUID(uuidString: row.string(0)) else { throw LedgerError.storage }; started.insert(id)
            }
            var buckets: [RunUsageBucket] = [], pageOffset = 0
            let firstDayEnd = (floor(from.timeIntervalSince1970 / 86400) + 1) * 86400
            repeat {
                guard !budget.stopped else { throw LedgerError.limit }
                let page = try rows("SELECT id,revision,payload FROM objects WHERE kind='run-usage' AND updated>=? AND updated<? ORDER BY id LIMIT 500 OFFSET ?",
                    [.real(firstDayEnd), .real(to.timeIntervalSince1970 + 86400), .integer(Int64(pageOffset))])
                for row in page {
                    guard !budget.stopped else { throw RepositoryDigestError.budget }
                    let bucket: RunUsageBucket = try unseal(row.blob(2), identity: "object:run-usage:" + row.string(0), revision: row.integer(1))
                    if bucket.from < to, bucket.to > from { buckets.append(bucket) }
                }
                if page.count < 500 { break }; pageOffset += page.count
            } while true
            let ids = Set(eventCounts.keys).union(started).union(buckets.map(\.runID))
            var reports: [String: RepositoryActivityDigest] = [:], assignments: [UUID: String] = [:]
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard !budget.stopped else { throw LedgerError.limit }
                let attribution: RunUsageAttribution?
                if let row = try rows("SELECT revision,payload FROM objects WHERE kind='run-attribution' AND id=?", [.text(id.uuidString)]).first {
                    attribution = try unseal(row.blob(1), identity: "object:run-attribution:" + id.uuidString, revision: row.integer(0))
                } else if let row = try rows("SELECT revision,payload FROM runs WHERE id=?", [.text(id.uuidString)]).first {
                    let run: AgentRun = try unseal(row.blob(1), identity: "run:" + id.uuidString, revision: row.integer(0)); attribution = RunUsageAttribution(run)
                } else { attribution = nil }
                if let attribution { guard attribution.runID == id else { throw LedgerError.storage } }
                let repository = attribution?.repository?.commonDirectory, key = repository ?? "unknown"
                assignments[id] = key
                var report = reports[key] ?? RepositoryActivityDigest(repository: repository, worktrees: [], totals: DigestTotals(), usage: [], coverageWarnings: [
                    "Totals include retained events; closed execution detail expires after 14 days or 500 closed executions.",
                    "Usage includes only observations attributable within a recorded execution. Historical cumulative baselines and uncertain intervals remain in host profile totals. Account-wide limits are not repeated here."
                ])
                if let worktree = attribution?.repository?.worktree, !report.worktrees.contains(worktree) { report.worktrees.append(worktree); report.worktrees.sort() }
                try report.totals.add(.recorded(executions: started.contains(id) ? 1 : 0, eventCounts: eventCounts[id] ?? [:]))
                reports[key] = report
            }
            for bucket in buckets {
                guard let key = assignments[bucket.runID], var report = reports[key] else { throw LedgerError.storage }
                var profile = report.usage.first { $0.id == bucket.profileID } ?? ProfileUsage(id: bucket.profileID, profile: bucket.profile, provider: bucket.provider)
                try profile.counters.add(bucket.counters); profile.observedAt = max(profile.observedAt ?? .distantPast, bucket.observedAt)
                report.usage.removeAll { $0.id == profile.id }; report.usage.append(profile)
                report.usage.sort { $0.id.uuidString < $1.id.uuidString }; reports[key] = report
            }
            for row in try rows("SELECT id,revision,payload FROM objects WHERE kind='test-execution' AND updated>=? AND updated<=?", [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) {
                guard !budget.stopped else { throw LedgerError.limit }
                let execution: TestExecution = try unseal(row.blob(2), identity: "object:test-execution:" + row.string(0), revision: row.integer(1))
                let key = execution.repository?.commonDirectory ?? "unknown"
                var report = reports[key] ?? RepositoryActivityDigest(repository: execution.repository?.commonDirectory, worktrees: [], totals: DigestTotals(), usage: [], coverageWarnings: ["Only explicitly tracked test commands produce test results; unknown outcomes are never passing results."])
                if let directory = execution.repository?.worktree, !report.worktrees.contains(directory) { report.worktrees.append(directory); report.worktrees.sort() }
                var tests = report.tests ?? TestExecutionSummary(); tests.record(execution); report.tests = tests; reports[key] = report
            }
            guard !budget.stopped else { throw LedgerError.limit }
            let ordered = reports.values.sorted { ($0.repository ?? "~unknown") < ($1.repository ?? "~unknown") }
            return RepositoryDigestPage(hostID: hostID, from: from, to: to, reports: Array(ordered.dropFirst(offset).prefix(limit)), nextOffset: offset + limit < ordered.count ? offset + limit : nil, historyUnavailable: unavailableReason)
        } } catch {
            if budget.cancelled() { throw ProcessCaptureError.cancelled }
            if budget.stopped { throw RepositoryDigestError.budget }
            throw error
        }
    }
    private final class RepositoryQueryBudget {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        let cancelled: () -> Bool
        init(cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
        var stopped: Bool { cancelled() || ProcessInfo.processInfo.systemUptime >= deadline }
    }
    /// Cursor and usage updates share this transaction; no observation can advance a
    /// cursor without its counters, or increment counters without its cursor.
    func saveObjects(_ objects: [LedgerObject]) throws {
        try queue.sync {
            try requireWrite(); try transaction {
                try saveObjectsOnQueue(objects)
            }; try boundMemory()
        }
    }
    private func saveObjectsOnQueue(_ objects: [LedgerObject]) throws {
                for object in objects {
                    let revision = (try rows("SELECT revision FROM objects WHERE kind=? AND id=?", [.text(object.kind), .text(object.id)]).first?.integer(0) ?? 0) + 1
                    let payload = try protection.seal(object.data, identity: "object:\(object.kind):\(object.id)", sequence: UInt64(revision))
                    try execute("INSERT INTO objects VALUES(?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET updated=excluded.updated,revision=excluded.revision,payload=excluded.payload",
                        [.text(object.kind), .text(object.id), .real(object.at.timeIntervalSince1970), .integer(revision), .blob(payload)])
                    if object.kind == "fanout" {
                        let group = try JSONDecoder().decode(FanoutGroup.self, from: object.data)
                        if group.isActive {
                            try saveObjectsOnQueue([LedgerObject(kind: "fanout-active", id: group.id.uuidString, value: group.id)])
                        } else { try execute("DELETE FROM objects WHERE kind='fanout-active' AND id=?", [.text(group.id.uuidString)]) }
                    }
                }
    }
    func testSummary(from: Date, to: Date, surfaceID: String? = nil, repository: String? = nil) throws -> TestExecutionSummary {
        try queue.sync {
            var summary = TestExecutionSummary()
            for row in try rows("SELECT id,revision,payload FROM objects WHERE kind='test-execution' AND updated>=? AND updated<=?", [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) {
                let execution: TestExecution = try unseal(row.blob(2), identity: "object:test-execution:" + row.string(0), revision: row.integer(1))
                guard surfaceID == nil || surfaceID == execution.sourceSurfaceID || surfaceID == execution.test.surfaceID,
                      repository == nil || execution.repository?.commonDirectory == repository else { continue }
                summary.record(execution)
            }
            return summary
        }
    }
    func removeCapturedText(surfaceID: String) throws {
        try queue.sync {
            try requireWrite(); try transaction {
                // Retain structural execution identity, but purge associated event detail,
                // captured messages, launch arguments, and cached summaries together.
                let records = try rows("SELECT id,revision,payload FROM runs WHERE surface=?", [.text(surfaceID)])
                for row in records {
                    var run: AgentRun = try unseal(row.blob(2), identity: "run:" + row.string(0), revision: row.integer(1))
                    run.message = nil; run.launch = nil; run.conversationID = nil; run.profile = "private"
                    run.directory = nil; run.directorySource = nil; run.repository = nil; run.repositoryUnavailable = nil
                    try saveOnQueue(run)
                    try execute("DELETE FROM events WHERE run=?", [.text(row.string(0))])
                    try execute("DELETE FROM objects WHERE kind IN ('transcript-binding','run-usage') AND id=?", [.text(row.string(0))])
                }
                for row in try rows("SELECT id,revision,payload FROM objects WHERE kind='run-attribution'") {
                    let attribution: RunUsageAttribution = try unseal(row.blob(2), identity: "object:run-attribution:" + row.string(0), revision: row.integer(1))
                    if attribution.surfaceID == surfaceID {
                        try execute("DELETE FROM objects WHERE kind='run-usage' AND id LIKE ?", [.text(row.string(0) + ":%")])
                        try execute("DELETE FROM objects WHERE kind='run-attribution' AND id=?", [.text(row.string(0))])
                    }
                }
                let bindings: [(String, TranscriptBinding)] = try rows("SELECT id,revision,payload FROM objects WHERE kind='transcript-binding'").map {
                    ($0.string(0), try unseal($0.blob(2), identity: "object:transcript-binding:" + $0.string(0), revision: $0.integer(1)))
                }
                for (id, binding) in bindings where binding.surfaceID == surfaceID {
                    try execute("DELETE FROM objects WHERE kind IN ('transcript-binding','transcript-cursor') AND id=?", [.text(id)])
                }
                for row in try rows("SELECT id,revision,payload FROM objects WHERE kind='test-execution'") {
                    var execution: TestExecution = try unseal(row.blob(2), identity: "object:test-execution:" + row.string(0), revision: row.integer(1))
                    if execution.sourceSurfaceID == surfaceID || execution.test.surfaceID == surfaceID {
                        execution.removeCapturedText()
                        try saveObjectsOnQueue([LedgerObject(kind: "test-execution", id: execution.id.uuidString, value: execution, at: execution.test.outcome?.observedAt ?? execution.test.acceptedAt)])
                    }
                }
                for row in try rows("SELECT id,revision,payload FROM objects WHERE kind='fanout'") {
                    var group: FanoutGroup = try unseal(row.blob(2), identity: "object:fanout:" + row.string(0), revision: row.integer(1))
                    if group.participants.contains(where: { $0.surfaceID == surfaceID || $0.tests.contains(where: { $0.surfaceID == surfaceID }) }) {
                        group.removeCapturedText()
                        try saveObjectsOnQueue([LedgerObject(kind: "fanout", id: group.id.uuidString, value: group)])
                    }
                }
                try execute("DELETE FROM objects WHERE kind IN ('digest','summary','transcript-excerpt')")
                // Invalidate callbacks built before this transaction as well as
                // prose already stored. Structural submission IDs remain deduplicated.
                try saveObjectsOnQueue([LedgerObject(kind: "ai-privacy", id: "global", value: UUID())])
                try execute("DELETE FROM objects WHERE kind='shell-command' AND id=?", [.text(surfaceID)])
            }
            if !memoryOnly { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        }
    }
    func summaryPrivacyGeneration() throws -> Int64 {
        try queue.sync { try rows("SELECT revision FROM objects WHERE kind='ai-privacy' AND id='global'").first?.integer(0) ?? 0 }
    }
    func saveSummary(_ record: AISummaryRecord, privacyGeneration: Int64) throws {
        try queue.sync {
            try requireWrite(); try transaction {
                let current = try rows("SELECT revision FROM objects WHERE kind='ai-privacy' AND id='global'").first?.integer(0) ?? 0
                var full = record, receipt = record; receipt.output = nil
                if current != privacyGeneration {
                    receipt.state = .cancelled; receipt.failure = "Persistence changed during generation; captured result text was discarded. No automatic retry was submitted."
                    try saveObjectsOnQueue([LedgerObject(kind: "ai-request", id: record.id.uuidString, value: receipt)])
                } else {
                    if full.output != nil { full.failure = nil }
                    try saveObjectsOnQueue([LedgerObject(kind: "ai-request", id: record.id.uuidString, value: receipt), LedgerObject(kind: "summary", id: record.id.uuidString, value: full)])
                }
            }
        }
    }
    func prune(now: Date = .now) throws {
        try queue.sync {
            try requireWrite(); try pruneOnQueue(now: now)
        }
    }
    private func pruneOnQueue(now: Date) throws {
        try transaction {
            try execute("DELETE FROM runs WHERE ended IS NOT NULL AND (ended<? OR id NOT IN (SELECT id FROM runs WHERE ended IS NOT NULL ORDER BY ended DESC,id LIMIT 500))", [.real(now.addingTimeInterval(-14 * 86400).timeIntervalSince1970)])
            let cutoff = now.addingTimeInterval(-90 * 86400).timeIntervalSince1970
            try execute("DELETE FROM objects WHERE kind IN ('usage','run-statistics','profile-limits','run-usage') AND updated<?", [.real(cutoff)])
            try execute("DELETE FROM objects WHERE kind='run-attribution' AND updated<? AND id NOT IN (SELECT id FROM runs WHERE ended IS NULL)", [.real(cutoff)])
            // Active file cursors and cumulative watermarks cannot be evicted separately.
            // Retired scopes remain for the same 90-day aggregate horizon to avoid
            // recounting historical usage when a conversation is resumed.
            let scopes = Set(try rows("SELECT id,revision,payload FROM objects WHERE kind='transcript-binding'").map { row -> String in
                let binding: TranscriptBinding = try unseal(row.blob(2), identity: "object:transcript-binding:" + row.string(0), revision: row.integer(1))
                return binding.scope
            })
            for row in try rows("SELECT id,revision,payload FROM objects WHERE kind='usage-watermark' AND updated<?", [.real(cutoff)]) {
                let watermark: UsageWatermark = try unseal(row.blob(2), identity: "object:usage-watermark:" + row.string(0), revision: row.integer(1))
                // Older records without a rekey seed remain conservative dedup state.
                if let scope = watermark.seed?.split(separator: ":", maxSplits: 1).first.map(String.init), !scopes.contains(scope) {
                    try execute("DELETE FROM objects WHERE kind='usage-watermark' AND id=?", [.text(row.string(0))])
                }
            }
            try execute("DELETE FROM objects WHERE kind='notification-observed' AND updated<?", [.real(now.addingTimeInterval(-14 * 86400).timeIntervalSince1970)])
            try execute("DELETE FROM objects WHERE kind IN ('notification-pending','notification-diagnostics') AND updated<?", [.real(now.addingTimeInterval(-3600).timeIntervalSince1970)])
            try execute("DELETE FROM objects WHERE kind='notification-control' AND updated<? AND id NOT IN (SELECT surface FROM runs WHERE ended IS NULL) AND id NOT IN (SELECT 'run:'||id FROM runs WHERE ended IS NULL)", [.real(now.addingTimeInterval(-14 * 86400).timeIntervalSince1970)])
            try execute("DELETE FROM objects WHERE kind='shell-command' AND updated<? AND id NOT IN (SELECT surface FROM runs WHERE ended IS NULL)", [.real(now.addingTimeInterval(-14 * 86400).timeIntervalSince1970)])
            let summaryReceipts = try rows("SELECT id,revision,payload FROM objects WHERE kind='ai-request'").map { row -> AISummaryRecord in
                try unseal(row.blob(2), identity: "object:ai-request:" + row.string(0), revision: row.integer(1))
            }.filter { $0.state != .submitted }.sorted { ($0.finishedAt ?? $0.submittedAt) > ($1.finishedAt ?? $1.submittedAt) }
            for (index, receipt) in summaryReceipts.enumerated() where index >= 500 || (receipt.finishedAt ?? receipt.submittedAt) < now.addingTimeInterval(-14 * 86400) {
                try execute("DELETE FROM objects WHERE kind IN ('ai-request','summary') AND id=?", [.text(receipt.id.uuidString)])
            }
            try execute("DELETE FROM objects WHERE kind='summary' AND id NOT IN (SELECT id FROM objects WHERE kind='ai-request')")
            let testExecutions = try rows("SELECT id,revision,payload FROM objects WHERE kind='test-execution'").map { row -> TestExecution in
                try unseal(row.blob(2), identity: "object:test-execution:" + row.string(0), revision: row.integer(1))
            }
            let closedTests = testExecutions.filter { !$0.test.mayBeRunning }.sorted { ($0.test.outcome?.observedAt ?? $0.test.acceptedAt) > ($1.test.outcome?.observedAt ?? $1.test.acceptedAt) }
            var expiredTests: Set<UUID> = []
            for (index, execution) in closedTests.enumerated() where index >= 500 || (execution.test.outcome?.observedAt ?? execution.test.acceptedAt) < now.addingTimeInterval(-14 * 86400) {
                expiredTests.insert(execution.id)
                try execute("DELETE FROM objects WHERE kind='test-execution' AND id=?", [.text(execution.id.uuidString)])
            }
            let groups = try rows("SELECT id,revision,payload FROM objects WHERE kind='fanout'").map { row -> FanoutGroup in
                try unseal(row.blob(2), identity: "object:fanout:" + row.string(0), revision: row.integer(1))
            }
            for var group in groups where group.participants.contains(where: { $0.tests.contains(where: { expiredTests.contains($0.id) && $0.detailExpired != true }) }) {
                for index in group.participants.indices { for ti in group.participants[index].tests.indices where expiredTests.contains(group.participants[index].tests[ti].id) { group.participants[index].tests[ti].launch = nil; group.participants[index].tests[ti].failure = nil; group.participants[index].tests[ti].detailExpired = true } }
                try saveObjectsOnQueue([LedgerObject(kind: "fanout", id: group.id.uuidString, value: group)])
            }
            let closed = groups.filter { !$0.isActive }.sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }
            for (index, var group) in closed.enumerated() where index >= 500 || (group.finishedAt ?? group.updatedAt) < now.addingTimeInterval(-14 * 86400) {
                if group.participants.allSatisfy({ $0.worktreeID == nil || $0.cleanedUp }) {
                    try execute("DELETE FROM objects WHERE kind='fanout' AND id=?", [.text(group.id.uuidString)])
                } else if !group.captureDisabled {
                    // Management identity outlives captured detail so dirty or
                    // unpushed work can still be inspected and safely cleaned up.
                    group.removeCapturedText()
                    try saveObjectsOnQueue([LedgerObject(kind: "fanout", id: group.id.uuidString, value: group)])
                }
            }
        }
    }
    private func boundMemory() throws {
        guard memoryOnly else { return }
        try execute("DELETE FROM events WHERE sequence NOT IN (SELECT sequence FROM events ORDER BY sequence DESC LIMIT 4096)")
        // Cursors and watermarks cannot be evicted independently of accounting.
        // SQLite's memory page cap rejects a whole transaction before advancing either.
        try execute("DELETE FROM runs WHERE ended IS NOT NULL AND id NOT IN (SELECT id FROM runs WHERE ended IS NOT NULL ORDER BY ended DESC LIMIT 500)")
        var bytes = try rows("SELECT (SELECT coalesce(sum(length(payload)),0) FROM events)+(SELECT coalesce(sum(length(payload)),0) FROM objects)").first?.integer(0) ?? 0
        while bytes > 32 << 20 {
            try execute("DELETE FROM events WHERE sequence IN (SELECT sequence FROM events ORDER BY sequence LIMIT 128)")
            let next = try rows("SELECT (SELECT coalesce(sum(length(payload)),0) FROM events)+(SELECT coalesce(sum(length(payload)),0) FROM objects)").first?.integer(0) ?? 0
            if next == bytes {
                try execute("DELETE FROM objects WHERE kind IN ('digest','summary','transcript-excerpt') AND rowid IN (SELECT rowid FROM objects WHERE kind IN ('digest','summary','transcript-excerpt') ORDER BY updated LIMIT 32)")
                let remaining = try rows("SELECT (SELECT coalesce(sum(length(payload)),0) FROM events)+(SELECT coalesce(sum(length(payload)),0) FROM objects)").first?.integer(0) ?? 0
                if remaining == bytes { throw LedgerError.limit }
                unavailableReason = "Activity memory retention reached its byte budget; older detail is unavailable."
            }
            bytes = try rows("SELECT (SELECT coalesce(sum(length(payload)),0) FROM events)+(SELECT coalesce(sum(length(payload)),0) FROM objects)").first?.integer(0) ?? 0
        }
    }
    private func requireWrite() throws { guard writable, database != nil else { throw LedgerError.noLease } }
    private func seal<T: Encodable>(_ value: T, identity: String, revision: Int64) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64 * 1024 else { throw LedgerError.limit }
        return try protection.seal(data, identity: identity, sequence: UInt64(revision))
    }
    private func unseal<T: Decodable>(_ data: Data, identity: String, revision: Int64) throws -> T {
        guard revision > 0 else { throw LedgerError.storage }
        return try JSONDecoder().decode(T.self, from: protection.open(data, identity: identity, sequence: UInt64(revision)))
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func closeOnQueue() { if let database { sqlite3_close_v2(database) }; database = nil }
    private enum Value { case text(String), blob(Data), integer(Int64), real(Double), null }
    private struct Row {
        var values: [Value]
        func integer(_ index: Int) -> Int64 { if case let .integer(value) = values[index] { return value }; return 0 }
        func string(_ index: Int) -> String { if case let .text(value) = values[index] { return value }; return "" }
        func blob(_ index: Int) -> Data { if case let .blob(value) = values[index] { return value }; return Data() }
        func real(_ index: Int) -> Double { if case let .real(value) = values[index] { return value }; return 0 }
    }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LedgerError.storage }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1), result: Int32
                switch value {
                case let .text(text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
                case let .blob(data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
                case let .real(value): result = sqlite3_bind_double(statement, index, value)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw LedgerError.storage }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        if values.isEmpty {
            guard let database else { throw LedgerError.storage }
            let code = sqlite3_exec(database, sql, nil, nil, nil)
            guard code == SQLITE_OK else { throw LedgerError.database(code) }
            return
        }
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LedgerError.storage }
    }
    private func rows(_ sql: String, _ values: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw LedgerError.storage }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { row.append(.blob(Data())) }
                default: row.append(.null)
                }
            }
            result.append(Row(values: row))
        }
    }
}
private func openFile(_ path: String, flags: Int32) -> Int32 { open(path, flags, 0o600) }
struct LedgerObject: Sendable {
    var kind: String, id: String, data: Data, at: Date
    // Catalogs are bounded discovery documents, not individual activity records.
    // Keep the same allowance when restoring an encrypted memory checkpoint.
    private static func maximumBytes(for kind: String) -> Int { kind == "ai-catalog" ? 4 << 20 : 64 * 1024 }
    init<T: Encodable>(kind: String, id: String, value: T, at: Date = .now) throws {
        self.kind = kind; self.id = id; data = try JSONEncoder().encode(value); self.at = at
        guard data.count <= Self.maximumBytes(for: kind) else { throw LedgerError.limit }
    }
    init(kind: String, id: String, rawData: Data, at: Date) throws {
        guard rawData.count <= Self.maximumBytes(for: kind) else { throw LedgerError.limit }
        self.kind = kind; self.id = id; data = rawData; self.at = at
    }
}
struct ActivityMemoryCheckpoint: Codable, Sendable {
    struct Object: Codable, Sendable { var kind: String, id: String, data: Data, at: Date }
    var runs: [AgentRun], events: [RunEvent], objects: [Object]
    var indexKey: Data?
}
enum LedgerError: Error, LocalizedError {
    case storage, version, noLease, limit
    case database(Int32)
    var errorDescription: String? {
        switch self {
        case .storage: "Activity storage could not complete the operation."
        case let .database(code): "Activity storage could not complete the operation (SQLite status \(code))."
        case .version: "Activity storage requires a compatible Harness daemon."
        case .noLease: "This daemon does not hold the activity-store write lease."
        case .limit: "Activity payload exceeds its bounded storage limit."
        }
    }
}
