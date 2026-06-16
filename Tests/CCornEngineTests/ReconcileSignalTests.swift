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
