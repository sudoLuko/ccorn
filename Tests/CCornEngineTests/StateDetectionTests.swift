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

    // MARK: Working: live activity only

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
    /// Running, both on first observation and once the hash has settled.
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

    /// THE settle-cycle removal: when the previous poll showed live activity and
    /// this one doesn't, the turn just finished and the pane change is only the
    /// final render settling, so it flips to Running on THIS poll, not one
    /// later. Same captured idle frame, same pane change; only the
    /// previous-marker flag differs.
    @Test func markerFallingEdgeFlipsToRunningImmediately() {
        let working = Fixtures.paneText("working-midtask.txt")
        let finished = Fixtures.paneText("idle-finished.txt")
        let now = t0.addingTimeInterval(3)
        #expect(detector.showsLiveActivity(pane: working))
        #expect(!detector.showsLiveActivity(pane: finished))

        // Previous poll saw the marker -> the marker present->absent edge is a
        // finished turn -> Running now, no extra Working cycle.
        let edge = detector.classifyPane(pane: finished,
                                         lastPaneHash: StateDetector.sha256(working),
                                         lastHashChange: t0,
                                         wasShowingLiveActivity: true,
                                         staleThreshold: 600,
                                         now: now)
        #expect(edge.state == .running)

        // The marker-less renderer (previous poll showed no marker): the
        // change-fallback is unchanged, so a changed pane still reads Working.
        let fallback = detector.classifyPane(pane: finished,
                                             lastPaneHash: StateDetector.sha256(working),
                                             lastHashChange: t0,
                                             wasShowingLiveActivity: false,
                                             staleThreshold: 600,
                                             now: now)
        #expect(fallback.state == .working)
    }

    /// detect() carries the current frame's marker state back in the result, so
    /// the next pass can recognise the falling edge. A live frame reports true;
    /// the following idle frame reports false.
    @Test func detectReportsLiveActivityForNextPass() {
        let live = StubPanes(pane: Fixtures.paneText("working-midtask.txt"), shellPID: getpid())
        let liveResult = detector.detect(input: DetectionInput(windowId: "@1", pid: getpid()),
                                         panes: live, transcript: nil,
                                         staleThreshold: 600, now: t0)
        #expect(liveResult.state == .working)
        #expect(liveResult.wasShowingLiveActivity)

        let idle = StubPanes(pane: Fixtures.paneText("idle-finished.txt"), shellPID: getpid())
        let idleResult = detector.detect(
            input: DetectionInput(windowId: "@1", pid: getpid(),
                                  lastPaneHash: StateDetector.sha256(Fixtures.paneText("working-midtask.txt")),
                                  lastHashChange: t0,
                                  wasShowingLiveActivity: true),
            panes: idle, transcript: nil, staleThreshold: 600, now: t0.addingTimeInterval(3))
        #expect(idleResult.state == .running)
        #expect(!idleResult.wasShowingLiveActivity)
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
    /// immediately; the prompt outranks the pane-changed Working signal.
    @Test func freshlyRenderedPromptIsWaitingNotWorking() {
        let pane = Fixtures.paneText("waiting-permission.txt")
        let state = detector.classifyPane(pane: pane,
                                          lastPaneHash: "previous-frame-hash",
                                          lastHashChange: t0,
                                          staleThreshold: 600,
                                          now: t0.addingTimeInterval(3)).state
        #expect(state == .waiting)
    }

    /// THE needs-input false-positive fix: a Waiting verdict requires the
    /// structural prompt chrome (option picker / y-n / "Enter to confirm"), never
    /// natural-language phrasing. Prose like "Do you want to rename…" or
    /// "Approve this tool call?" that lingers in an idle scrollback frame must NOT
    /// flag needs-input; the same question carrying the real prompt chrome still must.
    @Test func waitingRequiresStructuralPrompt() {
        // Prose only, the kind of assistant text that stays on screen when idle.
        #expect(!detector.isWaiting(pane: "⏺ Do you want to rename a session to \"hello world\"?"))
        #expect(!detector.isWaiting(pane: "Do you want to proceed?"))
        #expect(!detector.isWaiting(pane: "Would you like me to continue?"))
        #expect(!detector.isWaiting(pane: "Approve this tool call?"))
        #expect(!detector.isWaiting(pane: "⏺ The PR was approved and merged."))
        #expect(!detector.isWaiting(pane: "Waiting on approval from CI."))
        // The same question rendered with the real prompt chrome -> Waiting.
        #expect(detector.isWaiting(pane: "Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Enter to confirm · Esc to cancel"))
        #expect(detector.isWaiting(pane: "Continue? (y/n)"))
    }

    /// An idle frame containing approval-ish words stays Running end to end.
    @Test func idleFrameWithApprovedWordStaysRunning() {
        let pane = Fixtures.paneText("running-idle.txt")
            + "\n⏺ The change was approved; approval recorded.\n"
        #expect(classifyFresh(pane) == .running)
    }

    /// REAL 2.1.173 idle frame that reproduced the needs-input false positive: a
    /// finished, idle session whose last assistant turn asked "Do you want to
    /// rename a session to "hello world"?…". That prose tripped the old substring
    /// matcher. With Waiting anchored to structural prompt chrome (none here), the
    /// session classifies Running.
    @Test func idleConversationalDoYouWantStaysRunning() {
        let pane = Fixtures.paneText("idle-conversational-doyouwant-2173.txt")
        #expect(pane.contains("Do you want"))            // the prose that used to trip it
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(!detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .running)
    }

    // MARK: Waiting: the structural-marker contract

    /// Every KEPT marker independently means Waiting, both as a raw signal and
    /// end to end through the classifier (embedded in an otherwise-idle frame so
    /// only the marker can be the cause).
    @Test(arguments: ["❯ 1.", "1. Yes", "(y/n)", "[y/N]", "Enter to confirm"])
    func eachStructuralMarkerFlagsWaiting(marker: String) {
        let pane = "⏺ Ran the command.\n \(marker)\n"
        #expect(detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .waiting)
    }

    /// Every DROPPED natural-language phrasing must NOT flag Waiting on its own;
    /// this is the regression that produced the false positive. Each is the exact
    /// prose the old `waitingPhrases`/`approve` rules matched.
    @Test(arguments: [
        "Would you like me to continue?",
        "Do you want to proceed?",
        "Please confirm the details below.",
        "Allow this change to the config?",
        "Approve this tool call?",
        "The PR was approved; approval recorded.",
    ])
    func droppedProsePhrasesDoNotFlagWaiting(prose: String) {
        let pane = "⏺ \(prose)\n"
        #expect(!detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .running)
    }

    /// Markers match case-insensitively (the matcher is
    /// `localizedCaseInsensitiveContains`), so a lowercased render still counts.
    @Test func structuralMarkersAreCaseInsensitive() {
        #expect(detector.isWaiting(pane: "Continue? (Y/N)"))
        #expect(detector.isWaiting(pane: "press enter to confirm"))
    }

    /// Live activity outranks a prompt: an option list streamed mid-turn (Claude
    /// quoting a menu, a tool drawing one) must not block a busy session.
    @Test func liveActivityPreemptsWaitingPrompt() {
        let pane = Fixtures.paneText("working-midtask.txt")
            + "\n ❯ 1. Yes\n   2. No\n Enter to confirm · Esc to cancel\n"
        #expect(detector.showsLiveActivity(pane: pane))
        #expect(classifyFresh(pane) == .working)
    }

    /// Full `detect()` pass on the real false-positive frame: alive pid + idle
    /// conversational pane -> Running, and the `/rc active` chip is still read as
    /// remote-control engaged (the fix touches Waiting only, not RC detection).
    @Test func detectClassifiesConversationalFrameRunningWithRC() {
        let input = DetectionInput(windowId: "@1", pid: getpid())
        let panes = StubPanes(pane: Fixtures.paneText("idle-conversational-doyouwant-2173.txt"),
                              shellPID: nil)
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state == .running)
        #expect(result.remoteControlActive)
    }

    // MARK: Waiting: region scoping (Layer 2)

    /// REAL 2.1.173 tool-permission dialog captured live: `⏺ Bash(…)` / `⎿
    /// Waiting…` scrollback, then a rule, then `❯ 1. Yes / 2. … / 3. No` and
    /// `Esc to cancel · Tab to amend` (note: NOT "Enter to confirm", which is
    /// trust/login-only). It must classify Waiting via the picker chrome.
    @Test func toolPermissionDialog2173IsWaiting() {
        let pane = Fixtures.paneText("waiting-tool-permission-2173.txt")
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .waiting)
    }

    /// REAL 2.1.173 plan-mode (ExitPlanMode) approval, captured live: a prompt
    /// whose structure differs from the others and is the key false-negative
    /// guard. The plan BODY sits in a DASHED-rule (`╌`) box that `isRuleLine`
    /// ignores, and the `❯ 1. Yes…` picker sits below the last SOLID rule, so
    /// region scoping lands on the picker (Waiting) while excluding the plan body
    /// (where prompt-like text could otherwise live). A real "needs input" prompt
    /// must never read calm.
    @Test func planModeApprovalPrompt2173IsWaiting() {
        let pane = Fixtures.paneText("waiting-plan-mode-2173.txt")
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .waiting)
        let region = StateDetector.livePromptRegion(pane)
        #expect(region.contains("❯ 1."))                  // picker is in the live region
        #expect(!region.contains("Here is Claude's plan")) // plan body is excluded
    }

    /// REAL 2.1.173 Write-tool permission, captured live. The file-content diff
    /// sits in a dashed-rule box and the `❯ 1. Yes` picker is below the last solid
    /// rule; both fall in the live region, which is correct: the prompt IS
    /// blocking, and the verdict is Waiting because the picker is real (even with
    /// marker-like text inside the diff).
    @Test func writeFilePermission2173IsWaiting() {
        let pane = Fixtures.paneText("waiting-write-permission-2173.txt")
        #expect(!detector.showsLiveActivity(pane: pane))
        #expect(detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .waiting)
    }

    /// A `/model` selection menu (captured live) is intentionally NOT needs-input:
    /// its cursor sits on the current model (`❯ 5. Opus`), not `❯ 1.`, and it
    /// offers "Enter to set as default", not a confirm/Yes affordance, so no
    /// waiting marker matches and it reads Running. Scope decision: CCorn flags
    /// Claude-blocked approval prompts (trust/permission/plan), not a user-opened
    /// settings menu. Pins that a bare numbered list does not mean Waiting.
    @Test func slashModelPickerIsNotWaiting() {
        let pane = Fixtures.paneText("slash-model-picker-2173.txt")
        #expect(pane.contains("❯ 5. Opus"))       // a picker is on screen…
        #expect(!detector.isWaiting(pane: pane))   // …but a settings menu, not an approval
        #expect(classifyFresh(pane) == .running)
    }

    /// THE Layer-2 win, on a REAL capture: Claude echoed `1. Yes … (y/n)` in its
    /// reply, then went idle (empty input box at the bottom). Whole-frame matching
    /// (Layer 1) would call this Waiting; region scoping reads the idle session it
    /// is, because that chrome is in the scrollback, not the live region.
    @Test func markerInScrollbackAboveInputBoxIsNotWaiting() {
        let pane = Fixtures.paneText("idle-marker-in-scrollback-2173.txt")
        // The chrome really is present in the frame, just not in the live region.
        #expect(pane.contains("1. Yes"))
        #expect(pane.contains("(y/n)"))
        #expect(!detector.isWaiting(pane: pane))
        #expect(classifyFresh(pane) == .running)
    }

    /// `livePromptRegion` keeps the bottom rule-delimited block and drops the
    /// scrollback above it, the mechanism the cases above rely on.
    @Test func livePromptRegionIsTheBottomRuleBlock() {
        let scrollbackChrome = Fixtures.paneText("idle-marker-in-scrollback-2173.txt")
        let region = StateDetector.livePromptRegion(scrollbackChrome)
        #expect(!region.contains("1. Yes"))          // scrollback chrome dropped
        #expect(region.contains("/rc active"))        // bottom footer kept
        // A real prompt's chrome survives because it *is* the bottom block.
        let prompt = Fixtures.paneText("waiting-tool-permission-2173.txt")
        #expect(StateDetector.livePromptRegion(prompt).contains("❯ 1. Yes"))
    }

    /// Fallback: with no rule line (a bare pane that a live TUI never produces)
    /// there is no region to scope to, so detection scans the whole string;
    /// better a rare false positive than a missed prompt.
    @Test func noRuleStructureFallsBackToFullFrame() {
        let bare = "⏺ Ready.\n ❯ 1. Yes\n   2. No\n"
        #expect(StateDetector.livePromptRegion(bare) == bare)
        #expect(detector.isWaiting(pane: bare))
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

    /// REAL 2.1.173 idle frame: the `Remote Control active` footer was removed
    /// at 2.1.172 and replaced with a `/rc active` chip (the old literal has
    /// zero occurrences in the 2.1.173 binary). The frame still classifies
    /// Running, and remote-control-active now reads from the chip, the bug that
    /// made every fresh 2.1.173 session false-alarm "No remote".
    @Test func idleRcActiveChip2173FixtureIsRunning() {
        let pane = Fixtures.paneText("running-rc-active-2173.txt")
        #expect(!pane.contains(StateDetector.remoteControlMarker)) // old literal gone
        #expect(pane.contains(StateDetector.rcChipActive))
        #expect(detector.showsRemoteControlEngaged(pane: pane))
        #expect(classifyFresh(pane) == .running)
    }

    /// The footer RC vocabulary, version-spanning: the pre-2.1.172 literal and
    /// the 2.1.172+ `active`/`connecting`/`reconnecting` chips all read as
    /// engaged (connecting/reconnecting are the bring-up/recovery handshake, not
    /// failure); `/rc failed` and an absent chip read as not engaged, which is
    /// the no-remote case, decided from a positive failure signal, not a miss.
    @Test func remoteControlEngagedSpansVersionsAndTransients() {
        #expect(detector.showsRemoteControlEngaged(pane: "idle · Remote Control active"))
        #expect(detector.showsRemoteControlEngaged(pane: "? for shortcuts        /rc active"))
        #expect(detector.showsRemoteControlEngaged(pane: "? for shortcuts        /rc connecting"))
        #expect(detector.showsRemoteControlEngaged(pane: "? for shortcuts        /rc reconnecting"))
        #expect(!detector.showsRemoteControlEngaged(pane: "? for shortcuts        /rc failed"))
        #expect(!detector.showsRemoteControlEngaged(pane: "? for shortcuts · ← for agents"))
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
    /// active` markers. The classifier no longer mistakes it for Working, but
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
        // exactly one claude-looking child, the shape findClaude matches on.
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
        // must come back untouched; the file is not re-read.
        let bridged = #"{"type":"mode","sessionId":"x"}"# + "\n"
            + #"{"type":"bridge-session","sessionId":"x","bridgeSessionId":"b"}"#
        try bridged.write(toFile: path, atomically: true, encoding: .utf8)
        let staleMtime = cache.hasBridgeSession(path: path, mtime: t1)
        #expect(!staleMtime)

        // New mtime: re-read, record found.
        let freshMtime = cache.hasBridgeSession(path: path, mtime: t2)
        #expect(freshMtime)

        // Positive answers are sticky, even if the file disappears.
        try FileManager.default.removeItem(atPath: path)
        let afterDelete = cache.hasBridgeSession(path: path, mtime: t2)
        #expect(afterDelete)
    }

    /// The version-independent positive: with no RC footer and no transcript
    /// bridge record, a live bridge handle in the process's session registry
    /// still resolves remote-control-active, and its absence (all three signals
    /// missing) leaves RC inactive, never asserted from a single miss. The
    /// registry read is injected so the test never touches `~/.claude`.
    @Test func detectUsesRegistryBridgeWhenFooterAndTranscriptAbsent() {
        let input = DetectionInput(windowId: "@1", pid: getpid()) // alive
        // The waiting fixture has no RC footer; no transcript is passed.
        let panes = StubPanes(pane: Fixtures.paneText("waiting-permission.txt"), shellPID: nil)

        let bridged = detector.detect(input: input, panes: panes, transcript: nil,
                                      staleThreshold: 600, now: t0,
                                      bridgeForPid: { _ in "session_01abc" })
        #expect(bridged.remoteControlActive)
        #expect(bridged.state == .waiting)
        // The handle is also carried out for the per-session browser deep link,
        // not just collapsed into the RC-active bool.
        #expect(bridged.bridgeSessionId == "session_01abc")

        let unbridged = detector.detect(input: input, panes: panes, transcript: nil,
                                        staleThreshold: 600, now: t0,
                                        bridgeForPid: { _ in nil })
        #expect(!unbridged.remoteControlActive)
        #expect(unbridged.bridgeSessionId == nil)
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
