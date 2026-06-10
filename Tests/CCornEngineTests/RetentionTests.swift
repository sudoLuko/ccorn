import Foundation
import Testing

/// Session-record retention policy (SessionStore.applyRetention): archived
/// records past the age limit are dropped, the total is capped with archived
/// evicted before active and oldest activity first, live sessions always
/// survive, and the count plateaus instead of growing unbounded.
@Suite struct RetentionTests {

    private func makeStore() throws -> SessionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccorn-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionStore(supportDir: dir)
    }

    private func record(_ n: Int, archived: Bool = false) -> SessionRecord {
        SessionRecord(uuid: "uuid-\(n)", path: "/tmp/p\(n)", title: "t\(n)", archived: archived)
    }

    @Test func archivedPastAgeIsPruned() throws {
        let store = try makeStore()
        let now = Date()
        store.saveRecords([record(1, archived: true), record(2, archived: true), record(3)])
        let mtimes = [
            "uuid-1": now.addingTimeInterval(-100 * 24 * 3600), // archived + ancient: pruned
            "uuid-2": now.addingTimeInterval(-5 * 24 * 3600),   // archived + recent: kept
            "uuid-3": now.addingTimeInterval(-100 * 24 * 3600), // ancient but active: kept
        ]
        store.applyRetention(transcriptMtimes: mtimes, keeping: [], now: now)
        #expect(store.loadRecords().map(\.uuid).sorted() == ["uuid-2", "uuid-3"])
    }

    /// A record with no transcript mtime at all counts as infinitely old —
    /// the transcript-existence prune normally removes it first, but retention
    /// must not treat "unknown" as "fresh".
    @Test func archivedWithoutMtimeCountsAsOld() throws {
        let store = try makeStore()
        store.saveRecords([record(1, archived: true)])
        store.applyRetention(transcriptMtimes: [:], keeping: [], now: Date())
        #expect(store.loadRecords().isEmpty)
    }

    @Test func liveUUIDsAlwaysSurvive() throws {
        let store = try makeStore()
        let now = Date()
        store.saveRecords([record(1, archived: true)])
        store.applyRetention(transcriptMtimes: [:], keeping: ["uuid-1"], now: now)
        #expect(store.loadRecords().count == 1)
    }

    @Test func capEvictsArchivedFirstThenOldest() throws {
        let store = try makeStore()
        let now = Date()
        // 6 records, cap 3: one archived (fresh) + five active of varying age.
        store.saveRecords([
            record(1, archived: true),
            record(2), record(3), record(4), record(5), record(6),
        ])
        var mtimes: [String: Date] = [:]
        for n in 1...6 {
            mtimes["uuid-\(n)"] = now.addingTimeInterval(TimeInterval(-n) * 3600)
        }
        // uuid-6 is the oldest active, uuid-1 is archived (evicted first
        // despite being the freshest).
        store.applyRetention(transcriptMtimes: mtimes, keeping: [],
                             archivedMaxAge: 90 * 24 * 3600, maxRecords: 3, now: now)
        #expect(store.loadRecords().map(\.uuid).sorted() == ["uuid-2", "uuid-3", "uuid-4"])
    }

    @Test func capNeverEvictsLive() throws {
        let store = try makeStore()
        let now = Date()
        store.saveRecords([record(1), record(2), record(3)])
        let mtimes = [
            "uuid-1": now.addingTimeInterval(-3 * 3600),
            "uuid-2": now.addingTimeInterval(-2 * 3600),
            "uuid-3": now.addingTimeInterval(-1 * 3600),
        ]
        // uuid-1 is the oldest but live; uuid-2 is evicted instead.
        store.applyRetention(transcriptMtimes: mtimes, keeping: ["uuid-1"],
                             maxRecords: 2, now: now)
        #expect(store.loadRecords().map(\.uuid).sorted() == ["uuid-1", "uuid-3"])
    }

    /// The persisted count plateaus at the cap: pumping more records through
    /// retention never exceeds maxRecords, and an at-cap store is untouched.
    @Test func countPlateausAtCap() throws {
        let store = try makeStore()
        let now = Date()
        var mtimes: [String: Date] = [:]
        store.saveRecords((1...600).map { n in
            mtimes["uuid-\(n)"] = now.addingTimeInterval(TimeInterval(-n))
            return record(n)
        })
        store.applyRetention(transcriptMtimes: mtimes, keeping: [],
                             maxRecords: 500, now: now)
        #expect(store.loadRecords().count == 500)

        // Idempotent at the cap: re-running drops nothing further.
        store.applyRetention(transcriptMtimes: mtimes, keeping: [],
                             maxRecords: 500, now: now)
        #expect(store.loadRecords().count == 500)
        // The survivors are the 500 most recently active.
        #expect(!store.loadRecords().contains { $0.uuid == "uuid-600" })
        #expect(store.loadRecords().contains { $0.uuid == "uuid-1" })
    }

    @Test func underCapAndFreshIsUntouched() throws {
        let store = try makeStore()
        let now = Date()
        store.saveRecords([record(1), record(2, archived: true)])
        let mtimes = [
            "uuid-1": now,
            "uuid-2": now.addingTimeInterval(-3600),
        ]
        store.applyRetention(transcriptMtimes: mtimes, keeping: [], now: now)
        #expect(store.loadRecords().count == 2)
    }
}
