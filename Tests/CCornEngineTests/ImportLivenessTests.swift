import Foundation
import Testing

/// The import sheet's honesty contract: a discovered (unmanaged) session has no
/// pane, so the row claims liveness only, never an activity state. Pins
/// `ImportRowLiveness` so the old "Working"/"Idle" overclaim can't creep back.
@Suite struct ImportLivenessTests {

    @Test func liveSessionClaimsActiveOnly() {
        let live = ImportRowLiveness(isLive: true)
        #expect(live == .active)
        #expect(live.tagText == "Active")
    }

    @Test func dormantSessionMakesNoClaim() {
        let dormant = ImportRowLiveness(isLive: false)
        #expect(dormant == .dormant)
        // No process, no claim: a dormant row shows no trailing caption.
        #expect(dormant.tagText == nil)
    }

    /// The regression guard: neither liveness ever produces an activity word.
    /// "Working"/"Idle" implied a state CCorn never had (it keyed on a 120s
    /// transcript-mtime timer), so no liveness may map to either.
    @Test func neverClaimsAnActivityState() {
        for liveness in [ImportRowLiveness.active, .dormant] {
            #expect(liveness.tagText != "Working")
            #expect(liveness.tagText != "Idle")
        }
    }
}
