import Foundation
import Testing

/// Pane-following: state detection must capture the pane actually running
/// `claude`, not tmux's *active* pane. After a split with the non-claude pane
/// active, a window-target `capture-pane` returns the wrong pane and the
/// classifier loses the TUI footer it keys on (the tracked pid is unaffected, so
/// the session stays alive but goes blind on every text signal). These pin both
/// the pure selection step and the detection-level behavior through the
/// `PaneSource` fake.
///
/// The selection reuses the SAME argv-based `ProcessControl.findClaude` walk
/// detection already uses (no second way to identify claude); here the
/// membership predicate is stubbed so the pure function and the detect() seam
/// are exercised without spawning tmux/pgrep.
@Suite struct PaneFollowingTests {

    let detector = StateDetector()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Pure selection: StateDetector.selectClaudePane

    /// A single pane is the common case: nothing to follow, so the selection
    /// returns nil and the caller keeps the window-target capture. Also avoids a
    /// needless subtree walk every poll.
    @Test func singlePaneSelectsNilSoCallerFallsBackToWindowTarget() {
        let panes: [(paneId: String, shellPID: Int32)] = [(paneId: "%0", shellPID: 100)]
        let picked = StateDetector.selectClaudePane(
            panes: panes,
            claudePID: 999,
            contains: { _, _ in true })   // even a "yes" predicate is bypassed for one pane
        #expect(picked == nil)
    }

    /// An empty list (enumeration failed) selects nil -> window-target fallback.
    @Test func emptyPaneListSelectsNil() {
        let empty: [(paneId: String, shellPID: Int32)] = []
        let picked = StateDetector.selectClaudePane(
            panes: empty,
            claudePID: 999,
            contains: { _, _ in true })
        #expect(picked == nil)
    }

    /// Two panes, the claude pid living under the SECOND (inactive) pane's shell:
    /// the selection returns that pane's id, so capture follows claude instead of
    /// the active pane. Membership is the argv-based check, here stubbed to match
    /// only the claude pane's shell.
    @Test func splitSelectsThePaneWhoseSubtreeHoldsClaude() {
        let panes: [(paneId: String, shellPID: Int32)] =
            [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]
        let picked = StateDetector.selectClaudePane(
            panes: panes,
            claudePID: 4242,
            contains: { shellPID, claudePID in shellPID == 200 && claudePID == 4242 })
        #expect(picked == "%1")
    }

    /// Two panes but neither subtree holds the claude pid (it lives in a pane not
    /// listed, or has just exited): selection returns nil and the caller falls
    /// through to the window-target capture and the unchanged determined-absent /
    /// dead path. Pane-following never invents a "blind" state.
    @Test func noMatchingPaneSelectsNil() {
        let panes: [(paneId: String, shellPID: Int32)] =
            [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]
        let picked = StateDetector.selectClaudePane(
            panes: panes,
            claudePID: 4242,
            contains: { _, _ in false })
        #expect(picked == nil)
    }

    // MARK: - Pure parse: TmuxController.parsePaneList

    /// The `list-panes -F "#{pane_id} #{pane_pid}"` format: one (paneId, shellPID)
    /// pair per line. A non-zero exit (tmux could not enumerate) is an empty list,
    /// which detection treats as "could not follow" and degrades to the
    /// window-target capture, never to a worse state.
    @Test func parsePaneListReadsIdAndPid() {
        let parsed = TmuxController.parsePaneList(from:
            CommandResult(stdout: "%0 100\n%1 200\n%3 4242\n", stderr: "", exitCode: 0))
        #expect(parsed.count == 3)
        #expect(parsed[0].paneId == "%0" && parsed[0].shellPID == 100)
        #expect(parsed[1].paneId == "%1" && parsed[1].shellPID == 200)
        #expect(parsed[2].paneId == "%3" && parsed[2].shellPID == 4242)
    }

    @Test func parsePaneListTreatsToolFailureAsEmpty() {
        #expect(TmuxController.parsePaneList(from:
            CommandResult(stdout: "%0 100\n", stderr: "no server running", exitCode: 1)).isEmpty)
        #expect(TmuxController.parsePaneList(from:
            CommandResult(stdout: "", stderr: "failed to launch tmux", exitCode: 127)).isEmpty)
        // Garbage / partial lines are skipped, not crashed on.
        let mixed = TmuxController.parsePaneList(from:
            CommandResult(stdout: "%0 100\ngarbage\n%1 notapid\n%2 300\n", stderr: "", exitCode: 0))
        #expect(mixed.count == 2)
        #expect(mixed[0].paneId == "%0" && mixed[0].shellPID == 100)
        #expect(mixed[1].paneId == "%2" && mixed[1].shellPID == 300)
    }

    // MARK: - Detection through the PaneSource fake

    /// THE split regression, end to end through detect(): two panes, the ACTIVE
    /// pane is a bare shell (no claude footer), the INACTIVE pane runs claude.
    /// The window-target capture would return the bare active pane (here:
    /// `idle-finished` masquerading as a non-claude frame is overkill; an empty
    /// frame is enough to show the loss of signal), so detection must follow the
    /// claude pane id and classify from ITS frame. The tracked pid is alive
    /// (getpid), and the membership predicate matches only the claude pane's
    /// shell, exactly as the real argv walk would.
    @Test func detectFollowsClaudePaneAfterSplit() {
        let live = getpid()                         // tracked pid is alive
        let claudeFrame = Fixtures.paneText("waiting-trust-2172.txt")   // a real claude footer
        let activeBareFrame = "luke@host ~ % "      // the split-off shell pane

        var panes = StubPanes(pane: activeBareFrame, shellProbe: .pid(100))
        // tmux lists both panes; pane %0 is the active bare shell, %1 runs claude.
        panes.panesList = [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]
        // Per-target captures: the window id resolves to the ACTIVE (bare) pane;
        // the resolved claude pane id (%1) returns the claude frame.
        panes.paneCaptures = ["@1": activeBareFrame, "%1": claudeFrame]

        let input = DetectionInput(windowId: "@1", pid: live)
        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            // The argv walk reports claude under the %1 shell (200) only.
            claudeBelowShell: { shellPID in shellPID == 200 ? .found(live) : .absent })

        // Classified from the CLAUDE pane (a trust prompt = Waiting), not the
        // active bare shell (which would misclassify as Running/Stale).
        #expect(result.state == .waiting)
        #expect(result.pid == live)

        // Control: the SAME inputs but without pane-following (single-pane list)
        // capture the window target -> the bare active pane -> NOT waiting. This
        // is the bug the change fixes.
        var noFollow = StubPanes(pane: activeBareFrame, shellProbe: .pid(100))
        noFollow.paneCaptures = ["@1": activeBareFrame, "%1": claudeFrame]
        // empty panesList -> selection short-circuits, window target used
        let blind = detector.detect(
            input: input, panes: noFollow, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { _ in .found(live) })
        #expect(blind.state != .waiting)            // blind on the active pane, the regression
    }

    /// Single pane (no split): the pane list has one entry, so selection
    /// short-circuits to nil and detect() captures the WINDOW target exactly as
    /// before. Classification is unchanged from today.
    @Test func singlePaneDetectionUsesWindowTargetUnchanged() {
        let live = getpid()
        let claudeFrame = Fixtures.paneText("running-idle.txt")
        var panes = StubPanes(pane: claudeFrame, shellProbe: .pid(100))
        panes.panesList = [(paneId: "%0", shellPID: 100)]   // one pane, nothing to follow
        // Note: no entry for "@1" in paneCaptures, so capturePane(@1) returns `pane`.

        let input = DetectionInput(windowId: "@1", pid: live)
        let result = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { _ in .found(live) })

        // Same verdict as classifying the fixture directly with no pane-following.
        let direct = detector.classifyPane(pane: claudeFrame, lastPaneHash: nil,
                                           lastHashChange: nil, staleThreshold: 600, now: t0)
        #expect(result.state == direct.state)
        #expect(result.state == .running)
        #expect(result.pid == live)
    }

    /// Split, but NO pane subtree holds the claude pid (it just exited, or lives
    /// in a pane tmux didn't list): selection returns nil, detect() falls back to
    /// the window-target capture, and the existing classification runs unchanged.
    /// Pane-following adds no new "blind"/error state; the determined-absent /
    /// dead path is reached exactly as before for the no-match case.
    @Test func splitWithNoClaudeMatchFallsBackToWindowTarget() {
        let live = getpid()
        let windowFrame = Fixtures.paneText("running-idle.txt")
        var panes = StubPanes(pane: windowFrame, shellProbe: .pid(100))
        panes.panesList = [(paneId: "%0", shellPID: 100), (paneId: "%1", shellPID: 200)]
        // Distinct per-pane frames so a wrong selection would change the verdict;
        // the window target ("@1") falls back to `pane` (the window frame).
        panes.paneCaptures = ["%0": "bare-shell-0", "%1": "bare-shell-1"]

        let input = DetectionInput(windowId: "@1", pid: live)
        // No LISTED pane's shell (100 or 200) holds claude -> selection nil ->
        // window-target capture -> classify the window frame, unchanged.
        let noMatch = detector.detect(
            input: input, panes: panes, transcript: nil, staleThreshold: 600, now: t0,
            claudeBelowShell: { shellPID in shellPID == 999 ? .found(live) : .absent })

        let direct = detector.classifyPane(pane: windowFrame, lastPaneHash: nil,
                                           lastHashChange: nil, staleThreshold: 600, now: t0)
        #expect(noMatch.state == direct.state)
        #expect(noMatch.state == .running)
        #expect(noMatch.pid == live)
    }
}
