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
}
