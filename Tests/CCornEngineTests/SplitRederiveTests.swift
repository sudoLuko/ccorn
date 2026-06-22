import Foundation
import Testing

/// Re-derivation across a SPLIT window. When the tracked pid is gone, detect()
/// re-derives the live claude pid from the pane shells. The active-pane probe
/// alone is wrong for a split: pane 0 may be a bare shell while claude runs in a
/// later pane, so probing only pane 0 reports `.absent` and — past the spawn
/// grace — falsely declares the session Dead (auto-restart then tears down a
/// LIVE session). These pin that detect() walks EVERY pane's shell and only
/// concludes Dead when NO pane hosts a claude child, while preserving the
/// single-pane and tool-failure-hardening behavior unchanged.
///
/// The membership predicate is the SAME injected argv-based `claudeBelowShell`
/// the alive-path pane-following walk uses (no second way to identify claude);
/// here it is stubbed per shell pid so the split logic runs without spawning
/// tmux/pgrep.
@Suite struct SplitRederiveTests {

    let detector = StateDetector()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Spawn-then-reap so the pid is real-but-dead: `startTime` nil (no grace),
    /// the genuine-crash shape for the determined-absent path.
    private func reapedPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    // MARK: - The split regression (FIX 12)

    /// THE bug: tracked pid gone, two panes, pane 0 a bare shell (no claude),
    /// claude alive under pane 1's shell. The OLD code probed only the active
    /// (pane-0) shell -> `.absent` -> past grace -> Dead, while claude was alive.
    /// detect() must walk both pane shells, find claude under pane 1, and resolve
    /// the session ALIVE (re-derived pid), never Dead.
    @Test func splitRederivesClaudeFromInactivePaneNotDead() {
        let claudePID: Int32 = 4242
        let input = DetectionInput(windowId: "@1", pid: reapedPID())   // tracked pid dead
        var panes = StubPanes(pane: Fixtures.paneText("running-idle.txt"), shellProbe: .pid(100))
        // pane %0 active bare shell (100), pane %1 hosts claude (shell 200).
        panes.panesList = [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]
        panes.paneCaptures = ["%1": Fixtures.paneText("running-idle.txt")]

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            // The argv walk reports claude under the %1 shell (200) only; pane 0 is
            // a determined-absent bare shell.
            claudeBelowShell: { shellPID in shellPID == 200 ? .found(claudePID) : .absent })

        #expect(result.state != .dead)
        #expect(result.pid == claudePID)   // re-derived from the inactive pane
    }

    /// Order independence: claude under the FIRST listed pane resolves alive too
    /// (the walk returns on the first match, not only when it is the later pane).
    @Test func splitRederivesClaudeFromFirstPane() {
        let claudePID: Int32 = 7000
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        var panes = StubPanes(pane: "", shellProbe: .pid(100))
        panes.panesList = [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { shellPID in shellPID == 100 ? .found(claudePID) : .absent })

        #expect(result.state != .dead)
        #expect(result.pid == claudePID)
    }

    // MARK: - Preserve: a genuinely dead split still reaches Dead

    /// No pane hosts claude (both panes' shells determined-absent, neither within
    /// grace): a real crash. The walk concludes the determined absence and the
    /// session reaches Dead, exactly as a single-pane crash does.
    @Test func splitWithNoClaudeInAnyPaneStillFlipsToDead() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        // Reaped shell pids -> startTime nil -> no spawn grace anywhere.
        var panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .pid(reapedPID()))
        panes.panesList = [(paneId: "%0", shellPID: reapedPID()),
                           (paneId: "%1", shellPID: reapedPID())]

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { _ in .absent })   // no claude under any pane shell

        #expect(result.state == .dead)
        #expect(result.pid == nil)
    }

    // MARK: - Preserve: unknown holds non-dead even in a split

    /// A pane probe that could NOT answer (`.unknown`) keeps liveness undetermined
    /// across the whole window: the pass holds non-dead (Running), never Dead,
    /// even though another pane is determined-absent. The tool-failure-hardening
    /// invariant survives the multi-pane walk.
    @Test func splitWithAnUnknownProbeHoldsNonDead() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        var panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .pid(100))
        panes.panesList = [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            // pane 0 determined-absent, pane 1 could not answer.
            claudeBelowShell: { shellPID in shellPID == 200 ? .unknown : .absent })

        #expect(result.state != .dead)
        #expect(result.state == .running)
        #expect(result.pid == nil)         // cleared so the next poll re-derives
    }

    /// Spawn grace is honored across panes: when every pane is determined-absent
    /// but ONE pane shell is younger than the grace window, claude may still be
    /// exec'ing, so the pass holds Running; once the grace elapses, Dead.
    @Test func splitWithinGraceHoldsRunningThenDead() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["60"]
        try shell.run()
        defer { shell.terminate() }

        let input = DetectionInput(windowId: "@1", pid: nil)
        var panes = StubPanes(pane: "", shellProbe: .pid(shell.processIdentifier))
        // pane %0 a reaped (no-grace) shell, pane %1 the fresh sleep shell.
        panes.panesList = [(paneId: "%0", shellPID: reapedPID()),
                           (paneId: "%1", shellPID: shell.processIdentifier)]

        let spawning = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: Date(),
            claudeBelowShell: { _ in .absent })
        #expect(spawning.state == .running)   // a young pane shell is still within grace

        let expired = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600,
            now: Date().addingTimeInterval(30),
            claudeBelowShell: { _ in .absent })
        #expect(expired.state == .dead)
    }

    // MARK: - Preserve: an empty pane list falls back to the active-pane probe

    /// When `list-panes` returns nothing (enumeration failed, or a single-pane
    /// window in the suites that model the pre-following path), re-derivation falls
    /// back to the active-pane `panePIDProbe` exactly as before: a determined
    /// absence still reaches Dead, so single-pane crash detection is unchanged.
    @Test func emptyPaneListFallsBackToActiveProbeAndStillDies() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        // Empty panesList -> active-pane probe path; reaped shell -> no grace.
        let panes = StubPanes(pane: Fixtures.paneText("dead-exited.txt"), shellProbe: .pid(reapedPID()))

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { _ in .absent })

        #expect(result.state == .dead)
        #expect(result.pid == nil)
    }

    /// And the empty-list fallback still resolves a live single-pane session: the
    /// active-pane probe answers `.pid`, the argv walk finds claude, alive.
    @Test func emptyPaneListFallsBackToActiveProbeAndResolvesAlive() {
        let input = DetectionInput(windowId: "@1", pid: nil)
        let panes = StubPanes(pane: Fixtures.paneText("running-idle.txt"), shellProbe: .pid(getpid()))

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { _ in .found(4242) })

        #expect(result.state == .running)
        #expect(result.pid == 4242)
    }

    // MARK: - Pure re-derivation precedence (Rederivation enum)

    /// found > undetermined > stillSpawning > dead, exercised directly through
    /// detect()'s observable verdict for the multi-pane all-absent + unknown mix
    /// is covered above; this pins that a `.found` anywhere wins over a later
    /// `.unknown` (the walk returns on first match, so a found pane short-circuits
    /// the unknown that follows it).
    @Test func foundShortCircuitsALaterUnknown() {
        let input = DetectionInput(windowId: "@1", pid: reapedPID())
        var panes = StubPanes(pane: "", shellProbe: .pid(100))
        panes.panesList = [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]

        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            // pane 0 found, pane 1 unknown: found must win (alive, not held).
            claudeBelowShell: { shellPID in shellPID == 100 ? .found(555) : .unknown })

        #expect(result.pid == 555)
        #expect(result.state != .dead)
    }
}
