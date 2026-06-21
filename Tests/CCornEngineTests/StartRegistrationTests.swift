import Foundation
import Testing

/// Pins the pure failure-branch / pid-backfill decision that `startNewSession`
/// and `resumeSession` apply to the `liveSessions` entry they register the moment
/// the tmux window is created (and tagged with `@ccorn_id`). Registering on
/// creation, not on the child watch, is what fixes the persistent "Take over"
/// label: a slow-but-successful `claude --resume … --rc` (node start, RC
/// handshake, a transient probe miss in the GUI exec environment) could time out
/// `awaitClaudeChild` even when claude is genuinely alive, leaving the live
/// tagged window absent from `liveSessions` so the row stayed `.unmanaged` for
/// the whole session. `liveSessionMutation` is the pure half of that flow.
@Suite struct StartRegistrationTests {

    /// A slow-but-successful start: the entry was pre-registered at window
    /// creation; the child watch then confirms `.started` for THAT window. The
    /// confirmed pid is backfilled onto the existing entry (no second entry).
    @Test func slowSuccessBackfillsPidOntoTheExistingEntry() {
        let windowId = "@7"
        let outcome = StartResult.started(windowId: windowId, pid: 4242)
        #expect(SessionEngine.liveSessionMutation(for: outcome, windowId: windowId)
                == .backfillPid(4242))
    }

    /// A genuine no-process result (claude truly failed to start). awaitClaudeChild
    /// has already killed the orphan window, so the optimistic entry MUST be
    /// removed — otherwise a dead window lingers as a managed row. Same for any
    /// outright failure.
    @Test func genuineNoProcessRemovesTheEntry() {
        let windowId = "@7"
        #expect(SessionEngine.liveSessionMutation(
            for: .windowCreatedNoProcess(windowId: windowId, pane: "boom"),
            windowId: windowId) == .remove)
        #expect(SessionEngine.liveSessionMutation(
            for: .failed("nope"), windowId: windowId) == .remove)
    }

    /// Defensive: a `.started` outcome carrying a different window id than the one
    /// we registered (it never should) must NOT backfill the wrong window. No
    /// mutation, so a stale outcome can't corrupt an unrelated entry.
    @Test func startedForADifferentWindowIsIgnored() {
        #expect(SessionEngine.liveSessionMutation(
            for: .started(windowId: "@9", pid: 11), windowId: "@7") == SessionEngine.LiveSessionMutation.none)
    }
}
