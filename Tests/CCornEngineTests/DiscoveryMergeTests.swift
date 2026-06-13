import Foundation
import Testing

/// Precedence resolution for the discovered ("unmanaged") surface — the fix for
/// the directory-keyed flip, where two concurrent sessions in one directory
/// collapsed into a single row that alternated identity as each wrote its
/// transcript. The surface is now session-granular: live external sessions are
/// individual UUID-keyed rows; fully-dormant directories collapse to one summary.
@Suite struct DiscoveryMergeTests {

    // MARK: - Builders

    private func session(_ uuid: String, modified: TimeInterval = 0) -> DiscoveredSession {
        DiscoveredSession(uuid: uuid,
                          transcriptPath: "/tmp/\(uuid).jsonl",
                          modified: Date(timeIntervalSince1970: modified))
    }

    private func project(_ key: String, path: String?,
                         sessions: [DiscoveredSession]) -> DiscoveredProject {
        DiscoveredProject(encodedKey: key, projectDir: "/root/\(key)",
                          resolvedPath: path, sessions: sessions)
    }

    private func candidate(_ uuid: String, cwd: String,
                           pid: Int32 = 1) -> UnmanagedClaudeFinder.Candidate {
        UnmanagedClaudeFinder.Candidate(pid: pid, sessionId: uuid, cwd: cwd)
    }

    // MARK: - The flip

    /// Two concurrent live sessions in ONE directory must become TWO distinct
    /// UUID-keyed rows — never a single directory row. This is the core fix.
    @Test func twoLiveSessionsInOneDirectoryAreTwoRows() {
        let dir = "/Users/luke/dev/ccorn"
        let proj = project("-Users-luke-dev-ccorn", path: dir, sessions: [
            session("uuid-A", modified: 200),
            session("uuid-B", modified: 100),
            session("old-1", modified: 50),   // dormant historical transcripts
            session("old-2", modified: 40),
        ])
        let live = [candidate("uuid-A", cwd: dir, pid: 11),
                    candidate("uuid-B", cwd: dir, pid: 22)]

        let r = DiscoveryMerge.resolve(projects: [proj], liveCandidates: live,
                                       managedUUIDs: [], managedPaths: [], recordUUIDs: [])

        #expect(r.live.map(\.uuid) == ["uuid-A", "uuid-B"])
        #expect(r.live.allSatisfy { $0.path == dir })
        #expect(r.liveUUIDs == ["uuid-A", "uuid-B"])
        // The directory has live sessions, so it does NOT also emit a dormant
        // summary — the 36 historical transcripts don't flood the list.
        #expect(r.dormantDirKeys.isEmpty)
    }

    /// Resolution is independent of which transcript was written most recently —
    /// the property that broke before (most-recent-wins flip).
    @Test func resolutionIsStableAcrossTranscriptRecency() {
        let dir = "/Users/luke/dev/ccorn"
        let live = [candidate("uuid-A", cwd: dir), candidate("uuid-B", cwd: dir)]

        func resolveWith(newest: String) -> DiscoveryMerge.Resolution {
            let proj = project("-d", path: dir, sessions: [
                session("uuid-A", modified: newest == "uuid-A" ? 999 : 1),
                session("uuid-B", modified: newest == "uuid-B" ? 999 : 1),
            ])
            return DiscoveryMerge.resolve(projects: [proj], liveCandidates: live,
                                          managedUUIDs: [], managedPaths: [], recordUUIDs: [])
        }
        // Flipping the newest transcript must not change the resolution.
        #expect(resolveWith(newest: "uuid-A") == resolveWith(newest: "uuid-B"))
    }

    // MARK: - Dormant summary

    /// A directory with only historical transcripts (no live process, no record)
    /// collapses to exactly one summary row.
    @Test func dormantDirectoryCollapsesToOneSummary() {
        let proj = project("-Users-luke-dev-ledger", path: "/Users/luke/dev/ledger",
                           sessions: [session("h1", modified: 10), session("h2", modified: 5)])
        let r = DiscoveryMerge.resolve(projects: [proj], liveCandidates: [],
                                       managedUUIDs: [], managedPaths: [], recordUUIDs: [])
        #expect(r.live.isEmpty)
        #expect(r.dormantDirKeys == ["-Users-luke-dev-ledger"])
    }

    /// A directory that holds a persisted record is already represented by that
    /// record's Stopped row — no dormant summary on top of it.
    @Test func directoryWithRecordHasNoDormantSummary() {
        let proj = project("-d", path: "/Users/luke/dev/x",
                           sessions: [session("rec-uuid"), session("other")])
        let r = DiscoveryMerge.resolve(projects: [proj], liveCandidates: [],
                                       managedUUIDs: [], managedPaths: [],
                                       recordUUIDs: ["rec-uuid"])
        #expect(r.dormantDirKeys.isEmpty)
    }

    /// A directory with a managed CCorn window emits no dormant summary (the
    /// managed row represents it) — matched by path, so it holds even when the
    /// managed session's UUID isn't among the directory's discovered transcripts.
    @Test func managedDirectoryHasNoDormantSummary() {
        let dir = "/Users/luke/dev/ccorn"
        let proj = project("-d", path: dir, sessions: [session("h1")])
        let r = DiscoveryMerge.resolve(projects: [proj], liveCandidates: [],
                                       managedUUIDs: ["managed-uuid"],
                                       managedPaths: [dir], recordUUIDs: [])
        #expect(r.dormantDirKeys.isEmpty)
    }

    // MARK: - Precedence

    /// A managed session never also appears as a live discovered row.
    @Test func managedSessionExcludedFromLive() {
        let dir = "/Users/luke/dev/ccorn"
        let live = [candidate("managed-uuid", cwd: dir), candidate("ext-uuid", cwd: dir)]
        let r = DiscoveryMerge.resolve(projects: [], liveCandidates: live,
                                       managedUUIDs: ["managed-uuid"],
                                       managedPaths: [dir], recordUUIDs: [])
        #expect(r.live.map(\.uuid) == ["ext-uuid"])
    }

    /// A managed + external session in the SAME directory: the external one
    /// still surfaces as its own live row (live rows are not path-gated).
    @Test func externalSessionSurfacesAlongsideManagedInSameDir() {
        let dir = "/Users/luke/dev/ccorn"
        let r = DiscoveryMerge.resolve(projects: [], liveCandidates: [candidate("ext", cwd: dir)],
                                       managedUUIDs: ["mgd"], managedPaths: [dir], recordUUIDs: [])
        #expect(r.live.map(\.uuid) == ["ext"])
    }

    /// A live session whose UUID also has a Stopped record: the live row wins
    /// (liveUUIDs carries it, so AppModel's record loop skips it).
    @Test func liveSessionOutranksItsStaleRecord() {
        let dir = "/Users/luke/dev/x"
        let r = DiscoveryMerge.resolve(projects: [], liveCandidates: [candidate("u", cwd: dir)],
                                       managedUUIDs: [], managedPaths: [],
                                       recordUUIDs: ["u"])
        #expect(r.liveUUIDs.contains("u"))
        #expect(r.live.map(\.uuid) == ["u"])
    }

    /// Duplicate registry files for the same UUID produce a single live row.
    @Test func duplicateLiveUUIDDeduped() {
        let dir = "/Users/luke/dev/x"
        let live = [candidate("u", cwd: dir, pid: 1), candidate("u", cwd: dir, pid: 2)]
        let r = DiscoveryMerge.resolve(projects: [], liveCandidates: live,
                                       managedUUIDs: [], managedPaths: [], recordUUIDs: [])
        #expect(r.live.count == 1)
    }

    /// A live candidate with no sessionId (process-table fallback shape) is not
    /// a discovered row — discovery needs the durable UUID key.
    @Test func candidateWithoutUUIDIgnored() {
        let r = DiscoveryMerge.resolve(
            projects: [],
            liveCandidates: [UnmanagedClaudeFinder.Candidate(pid: 5, sessionId: nil, cwd: "/x")],
            managedUUIDs: [], managedPaths: [], recordUUIDs: [])
        #expect(r.live.isEmpty)
    }
}
