import Foundation
import Testing

/// Keeper selection among same-UUID duplicate windows must never pick a DEAD
/// window when a live one exists. Regression pins for the multi-live branch of
/// `chooseKeeper`: with two+ live windows, newest-wins is restricted to the live
/// subset so a newer dead window can't win and orphan the live ones.
@MainActor
@Suite struct ReconcileKeeperTests {

    /// {live @5, live @8, dead @12}: the dead window is the newest by ordinal, but
    /// the keeper must be a LIVE window — the newest live one (@8), never @12.
    @Test func keeperPrefersNewestLiveOverNewerDead() {
        let live5 = SessionEngine.DedupCandidate(windowId: "@5", hasLiveClaude: true, order: 5)
        let live8 = SessionEngine.DedupCandidate(windowId: "@8", hasLiveClaude: true, order: 8)
        let dead12 = SessionEngine.DedupCandidate(windowId: "@12", hasLiveClaude: false, order: 12)

        // The keeper is a live window, never the newer dead one.
        let keeper = SessionEngine.chooseKeeper([live5, live8, dead12])
        #expect(keeper?.hasLiveClaude == true)
        #expect(keeper?.windowId != "@12")
        // Specifically the newest LIVE window.
        #expect(keeper?.windowId == "@8")

        // Order-independent: input ordering must not change the choice.
        #expect(SessionEngine.chooseKeeper([dead12, live8, live5])?.windowId == "@8")
        #expect(SessionEngine.chooseKeeper([live8, dead12, live5])?.windowId == "@8")
    }

    /// A zero-live group still returns the newest window by ordinal (the all-dead
    /// fallback): {dead @4, dead @9, dead @12} -> @12.
    @Test func keeperKeepsNewestWhenNoneLive() {
        let dead4 = SessionEngine.DedupCandidate(windowId: "@4", hasLiveClaude: false, order: 4)
        let dead9 = SessionEngine.DedupCandidate(windowId: "@9", hasLiveClaude: false, order: 9)
        let dead12 = SessionEngine.DedupCandidate(windowId: "@12", hasLiveClaude: false, order: 12)
        #expect(SessionEngine.chooseKeeper([dead4, dead9, dead12])?.windowId == "@12")
        #expect(SessionEngine.chooseKeeper([dead12, dead4, dead9])?.windowId == "@12")
    }
}
