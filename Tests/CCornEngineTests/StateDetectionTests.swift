import Foundation
import Testing

/// A canned PaneSource so detect() runs against captured fixtures without ever
/// touching a real tmux server (a real `@N` target could resolve against the
/// developer's own sessions).
struct StubPanes: PaneSource {
    var pane: String = ""
    var shellPID: Int32? = nil
    func capturePane(windowId: String) -> String { pane }
    func panePID(windowId: String) -> Int32? { shellPID }
}

/// State detection driven by REAL captured `tmux capture-pane` frames from live
/// `claude --rc` sessions (2.1.169 and 2.1.170, see Fixtures/panes/*). Each
/// fixture exercises one branch of the classifier; time-dependent cases use an
/// injected clock.
@Suite struct StateDetectionTests {

    let detector = StateDetector()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// First-observation classify: no previous pane hash.
    private func classifyFresh(_ pane: String, now: Date? = nil) -> SessionState {
        detector.classifyPane(pane: pane, lastPaneHash: nil, lastHashChange: nil,
                              staleThreshold: 600, now: now ?? t0).state
    }

    // MARK: Working — live activity only

    /// True mid-task frame: live spinner/status line plus the `esc to interrupt`
    /// hint -> Working. (2.1.169/2.1.170 render `·✢✳✶✻✽` status glyphs, not the
    /// braille spinner the spec assumed; the esc-to-interrupt hint is the live
    /// signal, runtime findings T1/T5.)
    @Test func midTaskFixtureIsWorking() {
        let pane = Fixtures.paneText("working-midtask.txt")
        #expect(pane.contains("esc to interrupt"))
        #expect(detector.showsLiveActivity(pane: pane))
        #expect(classifyFresh(pane) == .working)
    }

    /// THE 3a regression: finished-but-idle frames keep `Bash(` tool markers and
    /// `✻ <verb>ed for Ns` glyph lines on screen after the turn ends, so a
    /// marker-based classifier would read them as Working forever. They must be
    /// Running — both on first observation and once the hash has settled.
    @Test(arguments: ["idle-finished.txt", "idle-finished-2170.txt"])
    func finishedButIdleIsNotWorking(fixture: String) {
        let pane = Fixtures.paneText(fixture)
        #expect(pane.contains("Bash("))                  // the misleading leftovers
        #expect(!pane.contains("esc to interrupt"))      // but no live activity
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(classifyFresh(pane) == .running)

        // Settled hash (the steady state under the 3s poll): still Running.
        let settled = detector.classifyPane(pane: pane,
                                            lastPaneHash: StateDetector.sha256(pane),
                                            lastHashChange: t0,
                                            staleThreshold: 600,
                                            now: t0.addingTimeInterval(9))
        #expect(settled.state == .running)
    }

    /// A pane that changed since the previous poll means something is rendering
    /// -> Working, and the stale clock resets to now.
    @Test func changedPaneIsWorking() {
        let pane = Fixtures.paneText("idle-finished.txt")
        let now = t0.addingTimeInterval(3)
        let verdict = detector.classifyPane(pane: pane,
                                            lastPaneHash: "a-different-old-hash",
                                            lastHashChange: t0,
                                            staleThreshold: 600,
                                            now: now)
        #expect(verdict.state == .working)
        #expect(verdict.hashChange == now)
    }

    // MARK: Waiting

    /// Permission/confirmation frame (the "trust this folder" prompt with
    /// `❯ 1. Yes…`) -> Waiting, and live-activity must NOT preempt it.
    @Test func permissionPromptFixtureIsWaiting() {
        let pane = Fixtures.paneText("waiting-permission.txt")
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .waiting)
    }

    /// REAL first-run trust prompt captured on 2.1.172 by the preflight
    /// harness (runtime findings P2): the wording moved to "Quick safety
    /// check: … ❯ 1. Yes, I trust this folder", and it must keep classifying
    /// Waiting via the option-picker chrome, not any version-pinned literal.
    @Test func trustPrompt2172FixtureIsWaiting() {
        let pane = Fixtures.paneText("waiting-trust-2172.txt")
        #expect(detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .waiting)
    }

    /// A confirmation prompt that just rendered (pane changed) is Waiting
    /// immediately — the prompt outranks the pane-changed Working signal.
    @Test func freshlyRenderedPromptIsWaitingNotWorking() {
        let pane = Fixtures.paneText("waiting-permission.txt")
        let state = detector.classifyPane(pane: pane,
                                          lastPaneHash: "previous-frame-hash",
                                          lastHashChange: t0,
                                          staleThreshold: 600,
                                          now: t0.addingTimeInterval(3)).state
        #expect(state == .waiting)
    }

    /// The 3b regression: "approve" must be word-bounded. "approved"/"approval"
    /// in ordinary conversation output must NOT flag Waiting; a real
    /// confirmation prompt still must.
    @Test func waitingRequiresWordBoundaries() {
        #expect(!detector.isWaiting(pane: "⏺ The PR was approved and merged."))
        #expect(!detector.isWaiting(pane: "Waiting on approval from CI."))
        #expect(detector.isWaiting(pane: "Approve this tool call?"))
        #expect(detector.isWaiting(pane: "Do you want to proceed?"))
    }

    /// An idle frame containing approval-ish words stays Running end to end.
    @Test func idleFrameWithApprovedWordStaysRunning() {
        let pane = Fixtures.paneText("running-idle.txt")
            + "\n⏺ The change was approved; approval recorded.\n"
        #expect(classifyFresh(pane) == .running)
    }

    // MARK: Running / remote control

    /// Idle frame showing the `Remote Control active` footer -> Running, and the
    /// remote-control signal is detected from the footer alone.
    @Test func idleRemoteControlFixtureIsRunning() {
        let pane = Fixtures.paneText("running-idle.txt")
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(!detector.isWaiting(pane: pane))
        #expect(pane.contains(StateDetector.remoteControlMarker))
        #expect(classifyFresh(pane) == .running)
    }

    // MARK: Stale (injected clock)

    /// An unchanged pane hash older than the stale threshold promotes Running -> Stale.
    @Test func unchangedHashPastThresholdIsStale() {
        let pane = Fixtures.paneText("running-idle.txt")
        let verdict = detector.classifyPane(pane: pane,
                                            lastPaneHash: StateDetector.sha256(pane),
                                            lastHashChange: t0,
                                            staleThreshold: 600,
                                            now: t0.addingTimeInterval(700))
        #expect(verdict.state == .stale)
        // The hash didn't change, so the last-change timestamp must NOT advance.
        #expect(verdict.hashChange == t0)
    }

    /// Just under the threshold stays Running.
    @Test func unchangedHashUnderThresholdStaysRunning() {
        let pane = Fixtures.paneText("running-idle.txt")
        let state = detector.classifyPane(pane: pane,
                                          lastPaneHash: StateDetector.sha256(pane),
                                          lastHashChange: t0,
                                          staleThreshold: 600,
                                          now: t0.addingTimeInterval(599)).state
        #expect(state == .running)
    }

    // MARK: Dead / spawn grace (detect-level, stubbed panes)

    /// Spawn a process and reap it so its PID is guaranteed dead but was real.
    private func reapedPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    /// The exited-window frame STILL contains stale `Bash(` / `Remote Control
    /// active` markers. The classifier no longer mistakes it for Working — but
    /// pane content alone still reads as a healthy Running session, which is
    /// exactly why Dead must be decided from PID liveness, never from the pane
    /// (runtime findings T2).
    @Test func exitedPaneStillMisleadsByContent() {
        let pane = Fixtures.paneText("dead-exited.txt")
        #expect(pane.contains("Bash("))
        #expect(pane.contains(StateDetector.remoteControlMarker))
        #expect(classifyFresh(pane) == .running) // plausible-but-wrong without the PID check
    }

    /// A tracked-but-dead pid, no claude child re-derivable, and no young pane
    /// shell -> Dead, without reading the (misleading) pane. Remote control is
    /// forced off.
    @Test func deadPidOverridesMisleadingPane() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        let panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellPID: nil)
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state == .dead)
        #expect(result.remoteControlActive == false)
        #expect(result.pid == nil)
    }

    /// The case reconcile produces for an existing window whose claude exited:
    /// pid == nil but a live windowId whose shell is long past the spawn grace.
    /// detect must re-derive (finding nothing) and report Dead from PID/window
    /// presence, never from the stale pane markers.
    @Test func goneClaudeWithLiveWindowIsDeadNotPaneClassified() {
        // A reaped pid as the "pane shell": it has no children to re-derive from
        // and no start time, so no grace applies.
        let input = DetectionInput(windowId: "@1", pid: nil)
        let panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellPID: reapedPID())
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state == .dead)
        #expect(result.remoteControlActive == false)
    }

    /// Item 4: a freshly created window whose shell just started but has no
    /// claude child yet is "still spawning" -> Running (grace), NOT Dead; once
    /// the grace window has elapsed it becomes Dead.
    @Test func youngPaneShellGetsSpawnGrace() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["60"]
        try shell.run()
        defer { shell.terminate() }

        let input = DetectionInput(windowId: "@1", pid: nil)
        let panes = StubPanes(pane: "", shellPID: shell.processIdentifier)

        // Within the grace window: still spawning.
        let spawning = detector.detect(input: input, panes: panes, transcript: nil,
                                       staleThreshold: 600, now: Date())
        #expect(spawning.state == .running)
        #expect(spawning.pid == nil)

        // Same shell, but past the grace window (clock injected): Dead.
        let expired = detector.detect(input: input, panes: panes, transcript: nil,
                                      staleThreshold: 600,
                                      now: Date().addingTimeInterval(30))
        #expect(expired.state == .dead)
    }

    /// Item 4: detect re-derives a missing pid by finding the claude child of
    /// the pane shell (argv match among the shell's descendants only). The
    /// "claude" here is a sleep exec'd with argv[0] = claude under a real parent.
    @Test func detectRederivesPidFromPaneShell() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // The subshell execs sleep with argv[0] "claude", giving the parent zsh
        // exactly one claude-looking child — the shape findClaude matches on.
        shell.arguments = ["-c", "(exec -a claude /bin/sleep 30) & wait"]
        try shell.run()
        defer { shell.terminate() }

        // Give the subshell a moment to fork+exec.
        var derived: Int32?
        for _ in 0..<20 {
            usleep(100_000)
            derived = ProcessControl.findClaude(belowShell: shell.processIdentifier)
            if derived != nil { break }
        }
        let childPID = try #require(derived)
        defer { kill(childPID, SIGKILL) }

        let input = DetectionInput(windowId: "@1", pid: nil)
        let panes = StubPanes(pane: Fixtures.paneText("running-idle.txt"),
                              shellPID: shell.processIdentifier)
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.pid == childPID)
        #expect(result.state == .running)
        #expect(result.remoteControlActive) // footer marker in the idle fixture
    }

    /// Alive pid + mid-task fixture flows through detect end to end as Working.
    @Test func detectClassifiesAliveSessionFromPane() {
        let input = DetectionInput(windowId: "@1", pid: getpid()) // guaranteed alive
        let panes = StubPanes(pane: Fixtures.paneText("working-midtask.txt"), shellPID: nil)
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state == .working)
        #expect(result.pid == getpid())
    }

    // MARK: Bridge-session cache

    /// The cache must only re-read the transcript when its mtime changes: a
    /// stale-mtime call returns the cached (even if outdated) answer, proving no
    /// re-read happened; a new mtime picks up the appended record; a positive
    /// answer is sticky after that.
    @Test func bridgeSessionCacheReadsOnlyOnMtimeChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccorn-rc-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path

        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)

        var cache = BridgeSessionCache()
        let noTranscript = cache.hasBridgeSession(path: nil, mtime: nil)
        #expect(!noTranscript)

        try #"{"type":"mode","sessionId":"x"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        let beforeBridge = cache.hasBridgeSession(path: path, mtime: t1)
        #expect(!beforeBridge)

        // Append the bridge record but present the OLD mtime: the cached negative
        // must come back untouched — the file is not re-read.
        let bridged = #"{"type":"mode","sessionId":"x"}"# + "\n"
            + #"{"type":"bridge-session","sessionId":"x","bridgeSessionId":"b"}"#
        try bridged.write(toFile: path, atomically: true, encoding: .utf8)
        let staleMtime = cache.hasBridgeSession(path: path, mtime: t1)
        #expect(!staleMtime)

        // New mtime: re-read, record found.
        let freshMtime = cache.hasBridgeSession(path: path, mtime: t2)
        #expect(freshMtime)

        // Positive answers are sticky — even if the file disappears.
        try FileManager.default.removeItem(atPath: path)
        let afterDelete = cache.hasBridgeSession(path: path, mtime: t2)
        #expect(afterDelete)
    }

    /// detect's remote-control signal falls back to the transcript when the pane
    /// has no footer marker, resolved via the indexed transcript ref.
    @Test func detectUsesBridgeSessionFallbackWhenPaneLacksMarker() {
        let transcript = DiscoveredSession(uuid: Fixtures.transcriptUUID,
                                           transcriptPath: Fixtures.transcriptPath,
                                           modified: Date(timeIntervalSince1970: 1))
        let input = DetectionInput(windowId: "@1", pid: getpid())
        // The waiting fixture's trust prompt has no "Remote Control active" footer.
        let panes = StubPanes(pane: Fixtures.paneText("waiting-permission.txt"), shellPID: nil)
        let result = detector.detect(input: input, panes: panes, transcript: transcript,
                                     staleThreshold: 600, now: t0)
        #expect(result.remoteControlActive) // bridge-session record in the real fixture transcript
        #expect(result.state == .waiting)
    }
}
