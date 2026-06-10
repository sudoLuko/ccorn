import Foundation
import Testing

/// Discovery / JSONL parsing driven by a REAL Claude Code 2.1.169 transcript
/// (Fixtures/projects/-private-tmp-ccorn-fix-probe/<uuid>.jsonl) plus a sibling
/// `memory/` dir that must be ignored.
///
/// Serialized because the suite materializes the transcript's real cwd on disk:
/// Foundation's `resolvingSymlinksInPath` only normalizes `/private/tmp/x` → the
/// shorter `/tmp/x` form when the leaf actually exists, so the project dir must be
/// present for canonicalization (and watch-dir matching) to be deterministic —
/// exactly the state a live project is in.
@Suite(.serialized) final class DiscoveryTests {

    /// The cwd recorded in the fixture transcript.
    static let cwdDir = "/private/tmp/ccorn-fix-probe"
    /// Its canonical (symlink-normalized) form, which is what discovery reports.
    static let cwdCanonical = "/tmp/ccorn-fix-probe"

    init() throws {
        try FileManager.default.createDirectory(atPath: Self.cwdDir, withIntermediateDirectories: true)
    }
    deinit {
        try? FileManager.default.removeItem(atPath: Self.cwdDir)
    }

    private var discovery: SessionDiscovery {
        SessionDiscovery(projectsRoot: Fixtures.projectsRoot)
    }

    @Test func discoversProjectFromRealTranscript() throws {
        let all = discovery.discoverAll()
        #expect(all.count == 1)
        let project = try #require(all.first)
        // Opaque, lossy directory key — never decoded.
        #expect(project.encodedKey == "-private-tmp-ccorn-fix-probe")
        // Real path resolved from the transcript `cwd`, not from the dir name.
        #expect(project.resolvedPath == Self.cwdCanonical)
    }

    @Test func extractsSessionIdAndFilenameMatches() throws {
        let project = try #require(discovery.discoverAll().first)
        let session = try #require(project.sessions.first)
        // The JSONL filename (sans extension) IS the session UUID.
        #expect(session.uuid == Fixtures.transcriptUUID)

        // Cross-check against the `sessionId` field inside the transcript.
        let line1 = Fixtures.firstLine(ofFileAt: Fixtures.transcriptPath)
        let obj = try JSONSerialization.jsonObject(with: Data(line1.utf8)) as? [String: Any]
        #expect(obj?["sessionId"] as? String == session.uuid)
    }

    @Test func firstCwdSkipsLine1MetadataRecord() {
        // Line 1 is a metadata record (`type: mode`) with NO cwd...
        let line1 = Fixtures.firstLine(ofFileAt: Fixtures.transcriptPath)
        #expect(!line1.contains("\"cwd\""))
        // ...so firstCwd must scan past it to a later record that carries cwd.
        let cwd = SessionDiscovery.firstCwd(inTranscript: Fixtures.transcriptPath)
        #expect(cwd == "/private/tmp/ccorn-fix-probe")
    }

    @Test func detectsBridgeSessionRecord() {
        #expect(SessionDiscovery.transcriptHasBridgeSession(path: Fixtures.transcriptPath))
        // Sanity: a path with no bridge-session record returns false.
        #expect(!SessionDiscovery.transcriptHasBridgeSession(path: "/nonexistent/none.jsonl"))
    }

    @Test func ignoresMemorySiblingDirectory() throws {
        let project = try #require(discovery.discoverAll().first)
        // Only the *.jsonl is a session; the memory/ sibling holds notes.md.
        #expect(project.sessions.count == 1)
        #expect(project.sessions.allSatisfy { $0.transcriptPath.hasSuffix(".jsonl") })
        #expect(!project.sessions.contains { $0.transcriptPath.contains("/memory/") })
    }

    @Test func watchDirFilterMatchesViaSymlinkResolvedCwd() {
        // cwd is /private/tmp/...; the watch dir is given as the /tmp symlink.
        // Canonicalization must make them match so the project is kept.
        let kept = discovery.discover(watchDirectories: ["/tmp"])
        #expect(kept.count == 1)
        #expect(kept.first?.resolvedPath == Self.cwdCanonical)

        // A real watch dir that doesn't contain the cwd keeps nothing.
        #expect(discovery.discover(watchDirectories: ["/usr"]).isEmpty)
        // A non-existent watch dir is skipped silently -> nothing kept.
        #expect(discovery.discover(watchDirectories: ["/Users/nobody/does-not-exist"]).isEmpty)
    }

    /// The refresh hot path's single-enumeration index: uuid -> transcript ref,
    /// with the right path and a real mtime, without reading any transcript.
    @Test func transcriptIndexMapsUUIDToTranscript() throws {
        let index = discovery.transcriptIndex()
        #expect(index.count == 1)
        let entry = try #require(index[Fixtures.transcriptUUID])
        #expect(entry.transcriptPath == Fixtures.transcriptPath)
        #expect(entry.modified > .distantPast)
    }
}

/// Session-title extraction (M2 fixes): the display name comes from the LAST
/// `ai-title` record — `{"type":"ai-title","aiTitle":...}` — which Claude
/// re-appends as the session progresses, so the final one is current.
@Suite struct TranscriptTitleTests {

    /// The real fixture transcript carries the title Claude generated for it.
    @Test func readsTitleFromRealTranscript() {
        let title = SessionDiscovery.lastAITitle(inTranscript: Fixtures.transcriptPath)
        #expect(title == "Run sleep command and echo completion")
        let meta = SessionDiscovery.meta(inTranscript: Fixtures.transcriptPath)
        #expect(meta.title == "Run sleep command and echo completion")
        #expect(meta.cwd == "/private/tmp/ccorn-fix-probe")
    }

    @Test func lastTitleWinsAndMissingTitleIsNil() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ccorn-title-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let twoTitles = dir.appendingPathComponent("two.jsonl")
        try (#"{"type":"ai-title","aiTitle":"stale title","sessionId":"x"}"# + "\n"
            + #"{"type":"user","cwd":"/tmp","sessionId":"x"}"# + "\n"
            + #"{"type":"ai-title","aiTitle":"current title","sessionId":"x"}"#)
            .write(to: twoTitles, atomically: true, encoding: .utf8)
        #expect(SessionDiscovery.lastAITitle(inTranscript: twoTitles.path) == "current title")

        // No ai-title record at all (such transcripts exist) -> nil, and the
        // caller falls back to the directory basename.
        let untitled = dir.appendingPathComponent("untitled.jsonl")
        try #"{"type":"user","cwd":"/tmp","sessionId":"y"}"#
            .write(to: untitled, atomically: true, encoding: .utf8)
        #expect(SessionDiscovery.lastAITitle(inTranscript: untitled.path) == nil)
        #expect(SessionDiscovery.lastAITitle(inTranscript: "/nonexistent/no.jsonl") == nil)
    }

    /// The cache re-reads a transcript only when its mtime changes.
    @Test func metaCacheKeyedByMtime() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ccorn-metacache-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")

        func write(title: String, mtime: Date) throws {
            try #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"z"}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }

        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        let cache = TranscriptMetaCache()

        try write(title: "first", mtime: t1)
        let ref1 = DiscoveredSession(uuid: "z", transcriptPath: file.path, modified: t1)
        #expect(cache.meta(for: ref1).title == "first")

        // Same recorded mtime -> cached result, file not re-read.
        try write(title: "second", mtime: t1)
        #expect(cache.meta(for: ref1).title == "first")

        // mtime moved -> re-read.
        try write(title: "second", mtime: t2)
        let ref2 = DiscoveredSession(uuid: "z", transcriptPath: file.path, modified: t2)
        #expect(cache.meta(for: ref2).title == "second")
    }
}

/// Discovery behaviors that need a synthetic projects tree (path-collision
/// dedup), built under a unique temp root per test.
@Suite struct DiscoveryDedupTests {

    /// Two encoded project dirs whose transcripts resolve to the SAME cwd: the
    /// dedup winner must be deterministic — the most recently modified project —
    /// regardless of directory enumeration order.
    @Test func dedupPicksMostRecentlyModifiedProject() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ccorn-dedup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let cwd = "/tmp/ccorn-dedup-probe"   // need not exist: canonicalize is existence-independent now
        func makeProject(encoded: String, uuid: String, modified: Date) throws {
            let dir = root.appendingPathComponent(encoded)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(uuid).jsonl")
            let lines = #"{"type":"mode","sessionId":"\#(uuid)"}"# + "\n"
                + #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(uuid)"}"#
            try lines.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }

        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        try makeProject(encoded: "-tmp-ccorn-dedup-probe",
                        uuid: "11111111-1111-1111-1111-111111111111", modified: newer)
        try makeProject(encoded: "-private-tmp-ccorn-dedup-probe",
                        uuid: "22222222-2222-2222-2222-222222222222", modified: older)

        let discovery = SessionDiscovery(projectsRoot: root)
        let kept = discovery.discover(watchDirectories: ["/tmp"])
        #expect(kept.count == 1)
        #expect(kept.first?.encodedKey == "-tmp-ccorn-dedup-probe") // the newer one

        // Flip recency: the OTHER project must now win — proof the choice is
        // driven by mtime, not enumeration order.
        let newest = Date(timeIntervalSince1970: 3_000_000)
        let otherTranscript = root
            .appendingPathComponent("-private-tmp-ccorn-dedup-probe")
            .appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl")
        try fm.setAttributes([.modificationDate: newest], ofItemAtPath: otherTranscript.path)
        let rekept = discovery.discover(watchDirectories: ["/tmp"])
        #expect(rekept.count == 1)
        #expect(rekept.first?.encodedKey == "-private-tmp-ccorn-dedup-probe")
    }
}
