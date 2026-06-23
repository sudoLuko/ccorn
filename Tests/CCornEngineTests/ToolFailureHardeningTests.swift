import Foundation
import Testing

/// Hardening for the launch-reconcile false-crash edge: a transient tool failure
/// (a tmux server hiccup, fork/resource exhaustion giving `CommandRunner` a 127
/// launch failure, or a timeout kill) must never be read as "the process is
/// gone". Crashed (`.dead`) requires a DETERMINED absence: the tools actually
/// answered "no process". These pin that distinction at each layer:
///   1. `ProcessControl.childScan` / `findClaude` — pgrep exit 1 is determined
///      absence; 127 / a signal is `.unknown`.
///   2. `TmuxController.panePIDProbe` — a non-zero `list-panes` is `.unknown`,
///      not a false "no shell".
///   3. `StateDetector.detect` — determined absence -> `.dead` (real crashes
///      still detected); a tool failure -> non-dead (held for the next poll).
///   4. A reconcile-style sweep — a global tool failure flips NO window to
///      `.dead`, and the next re-derive with tools restored resolves each.
@Suite struct ToolFailureHardeningTests {

    let detector = StateDetector()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Spawn a process and reap it so its PID is guaranteed dead but was real:
    /// `pgrep -P <reaped>` answers exit 1 (a determined "no children") and
    /// `startTime` is nil (no spawn grace), the genuine-crash shape.
    private func reapedPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    // MARK: 1. ProcessControl: determined absence vs tool failure

    /// The exit-code contract `childPIDs` relies on: 0 = matches, 1 = ran with
    /// none (DETERMINED absence, dead-eligible), anything else = could not answer
    /// (`.unknown`). This is the crux: a 127 launch failure must NOT collapse to
    /// the same empty list as a real exit-1 "no children".
    @Test func childScanDistinguishesDeterminedAbsenceFromToolFailure() {
        #expect(ProcessControl.childScan(from: CommandResult(stdout: "123\n456\n", stderr: "", exitCode: 0))
                == .children([123, 456]))
        // exit 1: pgrep ran and found nothing -> determined, empty.
        #expect(ProcessControl.childScan(from: CommandResult(stdout: "", stderr: "", exitCode: 1))
                == .children([]))
        // 127: CommandRunner could not launch pgrep -> unknown, NOT empty.
        #expect(ProcessControl.childScan(from: CommandResult(stdout: "", stderr: "failed to launch", exitCode: 127))
                == .unknown)
        // A signal status (timeout SIGTERM/SIGKILL) -> unknown.
        #expect(ProcessControl.childScan(from: CommandResult(stdout: "", stderr: "", exitCode: 143))
                == .unknown)
        #expect(ProcessControl.childScan(from: CommandResult(stdout: "garbage", stderr: "", exitCode: 0))
                == .children([]))   // exit 0 but unparseable -> determined empty
    }

    /// Live integration: a real childless process answers `.absent` (determined),
    /// and a reaped pid likewise answers `.absent` (its `pgrep` exits 1). Neither
    /// is `.unknown`, so a genuinely-gone claude is still dead-eligible.
    @Test func findClaudeReportsDeterminedAbsenceForChildlessProcess() throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["30"]
        try sleep.run()
        defer { sleep.terminate() }
        #expect(ProcessControl.findClaude(belowShell: sleep.processIdentifier) == .absent)
        #expect(ProcessControl.findClaude(belowShell: reapedPID()) == .absent)
    }

    // MARK: 2. TmuxController: panePIDProbe classifier

    /// `list-panes` classifies three ways. exit 0 with a pid -> `.pid`. exit 1 ->
    /// `.absent`: tmux RAN and reported the target gone (it returns 1 for BOTH
    /// "can't find window" — a window killed out from under CCorn — AND "no server
    /// running" — the whole server died), a DETERMINED absence the poll surfaces
    /// as Dead. Any OTHER non-zero (127 launch failure, a timeout-kill signal)
    /// means tmux could not run at all -> `.unknown`, held non-dead.
    ///
    /// The exit-1 -> `.absent` boundary intentionally treats a steady-state
    /// server death as Dead (it is: the window is gone). The false-dead this used
    /// to guard against was at LAUNCH, where auto-restart could tear down a live
    /// session — but launch reconcile rebuilds from `listWindows`/`hasSession`,
    /// never this probe, and a steady-state Dead never auto-restarts, so the
    /// guarantee holds while a vanished window now correctly reads Dead.
    @Test func panePIDProbeClassifiesWindowGoneAbsentToolFailureUnknown() {
        #expect(TmuxController.panePIDProbe(from: CommandResult(stdout: "54321\n", stderr: "", exitCode: 0))
                == .pid(54321))
        // exit 1: tmux ran and the window/server is gone -> determined absence.
        #expect(TmuxController.panePIDProbe(from: CommandResult(stdout: "", stderr: "can't find window @7", exitCode: 1))
                == .absent)
        #expect(TmuxController.panePIDProbe(from: CommandResult(stdout: "", stderr: "no server running", exitCode: 1))
                == .absent)
        // 127 / signal: tmux could not run -> undetermined, held non-dead.
        #expect(TmuxController.panePIDProbe(from: CommandResult(stdout: "", stderr: "failed to launch tmux", exitCode: 127))
                == .unknown)
        #expect(TmuxController.panePIDProbe(from: CommandResult(stdout: "", stderr: "killed", exitCode: 137))
                == .unknown)
        // Succeeded but no parseable pid -> undetermined, not a false absence.
        #expect(TmuxController.panePIDProbe(from: CommandResult(stdout: "\n", stderr: "", exitCode: 0))
                == .unknown)
    }

    // MARK: 3. detect(): the dead verdict requires a determined absence

    /// tmux could not report the pane shell (`.unknown`): liveness is
    /// undetermined, so the session is held non-dead even though the tracked pid
    /// is gone. Previously this branch (panePID nil) fell straight through to
    /// `.dead`, skipping even the spawn grace.
    @Test func panePIDToolFailureHoldsNonDeadNotCrashed() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())   // tracked pid dead
        let panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .unknown)
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state != .dead)
        #expect(result.state == .running)
        #expect(result.pid == nil)        // cleared, so the next poll re-derives
    }

    /// pgrep could not enumerate the shell's children (`.unknown`): also
    /// undetermined, also held non-dead. Injected so the failure is deterministic
    /// (a real `/usr/bin/pgrep` cannot be forced to fail).
    @Test func pgrepToolFailureHoldsNonDeadNotCrashed() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        let panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .pid(getpid()))
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0,
                                     claudeBelowShell: { _ in .unknown })
        #expect(result.state != .dead)
        #expect(result.state == .running)
        #expect(result.pid == nil)
    }

    /// The control case: a DETERMINED absence (the shell answered, pgrep found no
    /// claude, no grace) still flips to `.dead`. Genuine crash detection is
    /// unchanged by the hardening.
    @Test func determinedAbsenceStillFlipsToDead() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        // A reaped shell pid -> startTime nil -> no spawn grace.
        let panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .pid(reapedPID()))
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0,
                                     claudeBelowShell: { _ in .absent })
        #expect(result.state == .dead)
        #expect(result.pid == nil)
    }

    /// The WINDOW itself is gone (`shellProbe == .absent`): an external
    /// `kill-window`, or the whole tmux server died (`kill-server`). tmux ran and
    /// said the target does not exist, a DETERMINED absence, so the session is
    /// Dead, NOT held Running. This is the regression preflight's chaos suite
    /// caught (scenarios C and E): a vanished window had been lumped in with a
    /// transient tool failure and stayed green. A gone window cannot be
    /// mid-spawn, so the grace window is bypassed; `claudeBelowShell` is never
    /// reached (there is no shell to walk).
    @Test func vanishedWindowFlipsToDead() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())   // tracked pid dead
        let panes = StubPanes(pane: "", shellProbe: .absent)           // window/server gone
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state == .dead)
        #expect(result.pid == nil)
    }

    /// A DETERMINED `.found` re-derives the live pid and resolves Running: a live
    /// session is never mislabelled by the new branch structure.
    @Test func determinedFoundResolvesAlive() {
        let input = DetectionInput(windowId: "@1", pid: nil)
        let panes = StubPanes(pane: Fixtures.paneText("running-idle.txt"), shellProbe: .pid(getpid()))
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0,
                                     claudeBelowShell: { _ in .found(4242) })
        #expect(result.state == .running)
        #expect(result.pid == 4242)
    }

    /// Spawn grace is preserved on the determined-absent branch: a shell younger
    /// than the grace window with no claude child yet is still spawning -> Running,
    /// then Dead once the grace elapses. (Confirms the restructure kept the grace
    /// that the panePID-nil branch used to skip.)
    @Test func determinedAbsenceWithinGraceIsRunningThenDead() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["60"]
        try shell.run()
        defer { shell.terminate() }

        let input = DetectionInput(windowId: "@1", pid: nil)
        let panes = StubPanes(pane: "", shellProbe: .pid(shell.processIdentifier))

        let spawning = detector.detect(input: input, panes: panes, transcript: nil,
                                       staleThreshold: 600, now: Date(),
                                       claudeBelowShell: { _ in .absent })
        #expect(spawning.state == .running)

        let expired = detector.detect(input: input, panes: panes, transcript: nil,
                                      staleThreshold: 600, now: Date().addingTimeInterval(30),
                                      claudeBelowShell: { _ in .absent })
        #expect(expired.state == .dead)
    }

    // MARK: 4. reconcile-style sweep: no correlated mass false-crash

    /// The launch-reconcile scenario distilled: detect runs per-window (reconcile
    /// re-derives each), so a GLOBAL tool failure means every window sees
    /// `.unknown`. None may false-flip to `.dead`. Then, with tools restored, the
    /// same windows resolve correctly: live ones to Running, a genuinely crashed
    /// one to Dead. This is the "a pile happens" mechanism, shown closed.
    @Test func globalToolFailureFlipsNoWindowToDeadThenResolvesOnRecovery() {
        let windowIds = ["@1", "@2", "@3", "@4", "@5"]

        // Phase 1: global tmux failure (reconcile's own findClaude seed also
        // returned unknown -> input.pid nil). Every window is undetermined.
        let failing = StubPanes(pane: Fixtures.paneText("running-idle.txt"), shellProbe: .unknown)
        for id in windowIds {
            let r = detector.detect(input: DetectionInput(windowId: id, pid: nil),
                                    panes: failing, transcript: nil,
                                    staleThreshold: 600, now: t0)
            #expect(r.state != .dead)        // no false crash under the outage
        }

        // Phase 2: tools restored. @1..@4 are live (claude re-derived); @5 truly
        // crashed (shell answers, pgrep determined-absent, no grace).
        for id in ["@1", "@2", "@3", "@4"] {
            let live = StubPanes(pane: Fixtures.paneText("running-idle.txt"), shellProbe: .pid(getpid()))
            let r = detector.detect(input: DetectionInput(windowId: id, pid: nil),
                                    panes: live, transcript: nil, staleThreshold: 600, now: t0,
                                    claudeBelowShell: { _ in .found(7000) })
            #expect(r.state == .running)
            #expect(r.pid == 7000)
        }
        let dead = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .pid(reapedPID()))
        let deadResult = detector.detect(input: DetectionInput(windowId: "@5", pid: nil),
                                         panes: dead, transcript: nil, staleThreshold: 600, now: t0,
                                         claudeBelowShell: { _ in .absent })
        #expect(deadResult.state == .dead)   // a real crash still surfaces once tools answer
    }
}
