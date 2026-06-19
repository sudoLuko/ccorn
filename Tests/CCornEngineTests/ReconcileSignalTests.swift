import Foundation
import Testing

/// The two reconcile-only signals added by the M2 fixes: telling a died claude
/// session from a window that never ran claude, and binding an adopted window
/// to its session via Claude's per-pid registry file.
@Suite struct ReconcileSignalTests {

    let detector = StateDetector()

    /// Every captured claude frame (live, idle, waiting, or exited) must count
    /// as claude evidence, so a died session is kept as a Dead row.
    @Test(arguments: ["dead-exited.txt", "idle-finished.txt", "idle-finished-2170.txt",
                      "running-idle.txt", "waiting-permission.txt", "working-midtask.txt"])
    func capturedClaudeFramesShowEvidence(fixture: String) {
        #expect(detector.showsClaudeEvidence(pane: Fixtures.paneText(fixture)))
    }

    /// A bare shell pane (the default window `tmux new-session` spawns, which
    /// automatic-rename labels "zsh") has no claude trace and must be excluded
    /// from reconciliation. Mirrors the live pane captured from such a window.
    @Test func bareShellPaneShowsNoEvidence() {
        let pane = "dev@host ccorn %\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"
        #expect(!detector.showsClaudeEvidence(pane: pane))
        #expect(!detector.showsClaudeEvidence(pane: ""))
    }

    /// `~/.claude/sessions/<pid>.json` (verified 2.1.170): sessionId + cwd for a
    /// live claude pid. Shape from a real capture.
    @Test func registryParsesPerPidSessionFile() throws {
        let fm = FileManager.default
        let claudeDir = fm.temporaryDirectory
            .appendingPathComponent("ccorn-registry-\(UUID().uuidString)")
        let sessions = claudeDir.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: claudeDir) }

        // Real record shape captured live from ~/.claude/sessions/73228.json.
        let json = #"{"pid":73228,"sessionId":"b86e6357-72c3-4aa8-935b-75ef27ce282a","# +
            #""cwd":"/Users/you/dev","startedAt":1781044823158,"version":"2.1.170","# +
            #""kind":"interactive","entrypoint":"cli","status":"idle"}"#
        try json.write(to: sessions.appendingPathComponent("73228.json"),
                       atomically: true, encoding: .utf8)

        let info = try #require(ClaudeSessionRegistry.info(forPid: 73228, claudeDir: claudeDir))
        #expect(info.sessionId == "b86e6357-72c3-4aa8-935b-75ef27ce282a")
        #expect(info.cwd == "/Users/you/dev")

        // No file for the pid -> nil.
        #expect(ClaudeSessionRegistry.info(forPid: 1, claudeDir: claudeDir) == nil)

        // A record without a usable sessionId -> nil.
        try #"{"pid":99,"sessionId":""}"#
            .write(to: sessions.appendingPathComponent("99.json"),
                   atomically: true, encoding: .utf8)
        #expect(ClaudeSessionRegistry.info(forPid: 99, claudeDir: claudeDir) == nil)
    }
}

/// One-window/one-row-per-@ccorn_id invariant: the pure keeper choice the engine
/// reconcile uses to dedupe duplicate same-UUID tmux windows, and the pure UI
/// backstop that guarantees one managed row per UUID even if the engine slips.
/// The static helpers live on the main-actor-isolated `SessionEngine`, so the
/// suite runs on the main actor.
@MainActor
@Suite struct RowDedupTests {

    // MARK: Engine keeper selection

    /// Two windows for one UUID, one with a live claude and one without: keep the
    /// live one regardless of which is newer.
    @Test func keeperKeepsTheLiveWindow() {
        let dead = SessionEngine.DedupCandidate(windowId: "@9", hasLiveClaude: false, order: 9)
        let live = SessionEngine.DedupCandidate(windowId: "@3", hasLiveClaude: true, order: 3)
        #expect(SessionEngine.chooseKeeper([dead, live])?.windowId == "@3")
        #expect(SessionEngine.chooseKeeper([live, dead])?.windowId == "@3")
    }

    /// Both windows dead (an orphan left next to its dead replacement): keep the
    /// most-recently-created (largest window-id ordinal).
    @Test func keeperKeepsNewestWhenBothDead() {
        let old = SessionEngine.DedupCandidate(windowId: "@4", hasLiveClaude: false, order: 4)
        let new = SessionEngine.DedupCandidate(windowId: "@11", hasLiveClaude: false, order: 11)
        #expect(SessionEngine.chooseKeeper([old, new])?.windowId == "@11")
        #expect(SessionEngine.chooseKeeper([new, old])?.windowId == "@11")
    }

    /// A single window is always its own keeper: the normal, common case is a
    /// no-op (no reap, one row).
    @Test func keeperSingleWindowUnchanged() {
        let only = SessionEngine.DedupCandidate(windowId: "@2", hasLiveClaude: true, order: 2)
        #expect(SessionEngine.chooseKeeper([only])?.windowId == "@2")
        let onlyDead = SessionEngine.DedupCandidate(windowId: "@5", hasLiveClaude: false, order: 5)
        #expect(SessionEngine.chooseKeeper([onlyDead])?.windowId == "@5")
    }

    /// Pathological "two live windows for one UUID": with no single live winner
    /// the choice falls back to newest, so the keeper is still deterministic
    /// (the engine never auto-kills the loser; it logs and drops it).
    @Test func keeperBreaksTwoLiveTieByNewest() {
        let liveOld = SessionEngine.DedupCandidate(windowId: "@6", hasLiveClaude: true, order: 6)
        let liveNew = SessionEngine.DedupCandidate(windowId: "@8", hasLiveClaude: true, order: 8)
        #expect(SessionEngine.chooseKeeper([liveOld, liveNew])?.windowId == "@8")
    }

    @Test func windowOrdinalParsesAtN() {
        #expect(SessionEngine.windowOrdinal("@12") == 12)
        #expect(SessionEngine.windowOrdinal("@0") == 0)
        #expect(SessionEngine.windowOrdinal("bogus") == -1)
    }

    // MARK: UI managed-row dedup backstop

    /// Two managed windows carrying the same non-empty UUID collapse to a single
    /// row, and the survivor is the deterministic keeper (live pid first), not
    /// whichever the dict happened to yield first.
    @Test func uiDedupCollapsesSameUUIDToOneRow() {
        let result = SessionEngine.dedupeManagedRowWindows([
            (windowId: "@7", uuid: "uuid-A", hasLivePid: false),
            (windowId: "@3", uuid: "uuid-A", hasLivePid: true),
        ])
        #expect(result.survivors == ["@3"])
        #expect(result.collapsed == ["@7"])
    }

    /// Both dead duplicates: survivor is the newest window; order of the input
    /// does not change the outcome (determinism, not dict order).
    @Test func uiDedupKeepsNewestWhenNoLivePid() {
        let a = SessionEngine.dedupeManagedRowWindows([
            (windowId: "@10", uuid: "uuid-B", hasLivePid: false),
            (windowId: "@4", uuid: "uuid-B", hasLivePid: false),
        ])
        let b = SessionEngine.dedupeManagedRowWindows([
            (windowId: "@4", uuid: "uuid-B", hasLivePid: false),
            (windowId: "@10", uuid: "uuid-B", hasLivePid: false),
        ])
        #expect(a.survivors == ["@10"])
        #expect(b.survivors == ["@10"])
        #expect(a.collapsed == ["@4"])
    }

    /// Two empty-UUID (unbound) managed sessions are genuinely distinct: both
    /// kept, nothing collapsed.
    @Test func uiDedupKeepsBothEmptyUUIDWindows() {
        let result = SessionEngine.dedupeManagedRowWindows([
            (windowId: "@1", uuid: "", hasLivePid: true),
            (windowId: "@2", uuid: "", hasLivePid: true),
        ])
        #expect(result.survivors == ["@1", "@2"])
        #expect(result.collapsed.isEmpty)
    }

    /// The normal case — one window per UUID — is a no-op: every window survives,
    /// nothing collapsed.
    @Test func uiDedupNormalCaseIsNoOp() {
        let result = SessionEngine.dedupeManagedRowWindows([
            (windowId: "@1", uuid: "uuid-A", hasLivePid: true),
            (windowId: "@2", uuid: "uuid-B", hasLivePid: false),
            (windowId: "@3", uuid: "", hasLivePid: true),
        ])
        #expect(result.survivors == ["@1", "@2", "@3"])
        #expect(result.collapsed.isEmpty)
    }
}
