import Foundation
import Testing

/// State detection driven by REAL captured `tmux capture-pane` frames from live
/// `claude --rc` 2.1.169 sessions (see Fixtures/panes/*). Each fixture exercises
/// one branch of the classifier; the stale case uses an injected clock.
@Suite struct StateDetectionTests {

    let detector = StateDetector()

    private func makeLive(pid: Int32? = nil,
                          windowId: String? = "@1",
                          lastHash: String? = nil,
                          lastChange: Date? = nil) -> LiveSession {
        let record = SessionRecord(uuid: "test-uuid", path: "/tmp/x", title: "Test")
        let live = LiveSession(record: record, windowId: windowId, pid: pid)
        live.lastPaneHash = lastHash
        live.lastHashChange = lastChange
        return live
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Working

    /// Mid-task frame containing a real `Bash(...)` tool call -> Working.
    /// (Runtime finding: 2.1.169 renders `✽`/`✻` thinking glyphs, NOT the braille
    /// spinner the spec lists, so the tool-call markers are the live Working signal.)
    @Test func midTaskFixtureIsWorking() {
        let pane = Fixtures.paneText("working-midtask.txt")
        #expect(pane.contains("Bash("))
        #expect(detector.isWorking(pane: pane))
        let state = detector.classifyPane(pane: pane, live: makeLive(), staleThreshold: 600, now: t0)
        #expect(state == .working)
    }

    // MARK: Waiting

    /// Permission/confirmation frame (the "trust this folder" prompt with
    /// `❯ 1. Yes…`) -> Waiting, and Working must NOT preempt it.
    @Test func permissionPromptFixtureIsWaiting() {
        let pane = Fixtures.paneText("waiting-permission.txt")
        #expect(!detector.isWorking(pane: pane))
        #expect(detector.isWaiting(pane: pane))
        let state = detector.classifyPane(pane: pane, live: makeLive(), staleThreshold: 600, now: t0)
        #expect(state == .waiting)
    }

    // MARK: Running

    /// Idle frame showing the `Remote Control active` footer -> Running, and the
    /// remote-control signal is detected from the footer (no transcript needed).
    @Test func idleRemoteControlFixtureIsRunning() {
        let pane = Fixtures.paneText("running-idle.txt")
        #expect(!detector.isWorking(pane: pane))
        #expect(!detector.isWaiting(pane: pane))
        #expect(detector.remoteControlActive(pane: pane, transcriptPath: nil))
        // Fresh session: hash change stamped at `now`, so elapsed 0 < threshold.
        let state = detector.classifyPane(pane: pane, live: makeLive(), staleThreshold: 600, now: t0)
        #expect(state == .running)
    }

    // MARK: Stale (injected clock)

    /// An unchanged pane hash older than the stale threshold promotes Running -> Stale.
    @Test func unchangedHashPastThresholdIsStale() {
        let pane = Fixtures.paneText("running-idle.txt")
        let live = makeLive(lastHash: StateDetector.sha256(pane), lastChange: t0)
        let now = t0.addingTimeInterval(700) // > 600s threshold, same pane
        let state = detector.classifyPane(pane: pane, live: live, staleThreshold: 600, now: now)
        #expect(state == .stale)
        // The hash didn't change, so the last-change timestamp must NOT advance.
        #expect(live.lastHashChange == t0)
    }

    /// Just under the threshold stays Running.
    @Test func unchangedHashUnderThresholdStaysRunning() {
        let pane = Fixtures.paneText("running-idle.txt")
        let live = makeLive(lastHash: StateDetector.sha256(pane), lastChange: t0)
        let now = t0.addingTimeInterval(599)
        let state = detector.classifyPane(pane: pane, live: live, staleThreshold: 600, now: now)
        #expect(state == .running)
    }

    /// A changed pane resets the stale clock to `now` (so it can't be stale).
    @Test func changedPaneResetsStaleClock() {
        let pane = Fixtures.paneText("running-idle.txt")
        let live = makeLive(lastHash: "a-different-old-hash", lastChange: t0)
        let now = t0.addingTimeInterval(10_000)
        let state = detector.classifyPane(pane: pane, live: live, staleThreshold: 600, now: now)
        #expect(state == .running)
        #expect(live.lastHashChange == now)
    }

    // MARK: Dead (PID precedence over misleading pane)

    /// Spawn a process and reap it so its PID is guaranteed dead but was real.
    private func reapedPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    /// The exited-window frame STILL contains stale `Bash(` / `Remote Control
    /// active` markers, so a pane-only classifier wrongly says Working...
    @Test func exitedPaneStillLooksWorkingByContent() {
        let pane = Fixtures.paneText("dead-exited.txt")
        #expect(pane.contains("Bash("))
        let naive = detector.classifyPane(pane: pane, live: makeLive(), staleThreshold: 600, now: t0)
        #expect(naive == .working) // exactly why pane content must not decide Dead
    }

    /// ...but `detect()` checks PID liveness first and reports Dead, never reading
    /// the pane. Remote-control is forced off for a dead session.
    @Test func deadPidOverridesMisleadingPane() {
        let live = makeLive(pid: reapedPID(), windowId: "@1")
        detector.detect(live: live,
                        tmux: TmuxController(),
                        transcriptPath: nil,
                        staleThreshold: 600,
                        now: t0)
        #expect(live.state == .dead)
        #expect(live.remoteControlActive == false)
    }
}
