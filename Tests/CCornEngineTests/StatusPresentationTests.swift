import Foundation
import Testing

/// One mark per row (visual/IA review item 1): resolution of session state +
/// remote-control condition to the single status presentation, the broken
/// tier, and the no-remote severity slot.
@Suite struct StatusPresentationTests {

    private func resolve(_ state: SessionState,
                         rc: Bool,
                         graceExpired: Bool = true) -> StatusPresentation {
        StatusPresentation.resolve(state: state,
                                   remoteControlActive: rc,
                                   rcGraceExpired: graceExpired)
    }

    // MARK: No-remote resolution

    /// The old circled-exclamation overlay condition — alive (running/working/
    /// waiting/stale) with RC inactive past the 30s activation grace — now
    /// resolves the whole row to the no-remote presentation, regardless of
    /// the underlying activity.
    @Test func aliveStatesWithoutRemoteControlResolveToNoRemote() {
        for state: SessionState in [.running, .working, .waiting, .stale] {
            #expect(resolve(state, rc: false) == .noRemote)
        }
    }

    /// Within the activation grace the session is just still starting up:
    /// the routine presentation holds.
    @Test func activationGraceSuppressesNoRemote() {
        #expect(resolve(.running, rc: false, graceExpired: false) == .running)
        #expect(resolve(.working, rc: false, graceExpired: false) == .working)
        #expect(resolve(.waiting, rc: false, graceExpired: false) == .waiting)
        #expect(resolve(.stale, rc: false, graceExpired: false) == .stale)
    }

    @Test func remoteControlActiveKeepsRoutinePresentation() {
        #expect(resolve(.running, rc: true) == .running)
        #expect(resolve(.working, rc: true) == .working)
        #expect(resolve(.waiting, rc: true) == .waiting)
        #expect(resolve(.stale, rc: true) == .stale)
    }

    /// The existing exclusions hold: needsAuth wins over no-remote (sign-in
    /// is the root cause, missing RC just its consequence); dead, stopped,
    /// and unmanaged keep their own presentations.
    @Test func noRemoteExclusions() {
        #expect(resolve(.needsAuth, rc: false) == .needsAuth)
        #expect(resolve(.dead, rc: false) == .crashed)
        #expect(resolve(.stopped, rc: false) == .stopped)
        #expect(resolve(.unmanaged, rc: false) == .unmanaged)
    }

    // MARK: Broken tier

    /// Exactly the three broken states carry the symbol; every routine state
    /// is a dot.
    @Test func brokenTierIsExactlyTheTrio() {
        #expect(StatusPresentation.noRemote.isBroken)
        #expect(StatusPresentation.needsAuth.isBroken)
        #expect(StatusPresentation.crashed.isBroken)
        for routine: StatusPresentation in [.running, .working, .waiting,
                                            .stale, .stopped, .unmanaged] {
            #expect(!routine.isBroken)
        }
    }

    /// Words appear only on waiting, sign-in, no-remote, and crashed.
    @Test func attentionWordsOnlyOnTheFourStates() {
        #expect(StatusPresentation.waiting.attentionLabel == "Needs input")
        #expect(StatusPresentation.needsAuth.attentionLabel == "Sign in")
        #expect(StatusPresentation.noRemote.attentionLabel == "No remote")
        #expect(StatusPresentation.crashed.attentionLabel == "Crashed")
        for silent: StatusPresentation in [.running, .working, .stale,
                                           .stopped, .unmanaged] {
            #expect(silent.attentionLabel == nil)
        }
    }

    // MARK: Severity ranking

    /// No-remote ranks as a degraded condition near sign-in: above the whole
    /// routine ladder, below sign-in, below crashed.
    @Test func noRemoteSeveritySlotSitsBetweenWaitingAndNeedsAuth() {
        #expect(StatusPresentation.aggregate([.noRemote, .waiting]) == .noRemote)
        #expect(StatusPresentation.aggregate([.noRemote, .stale]) == .noRemote)
        #expect(StatusPresentation.aggregate([.noRemote, .working, .running]) == .noRemote)
        #expect(StatusPresentation.aggregate([.noRemote, .needsAuth]) == .needsAuth)
        #expect(StatusPresentation.aggregate([.noRemote, .crashed]) == .crashed)
    }

    /// stopped/unmanaged stay colorless and never become the aggregate.
    @Test func noRemoteAggregatesAboveNonActiveStates() {
        #expect(StatusPresentation.aggregate([.stopped, .unmanaged, .noRemote]) == .noRemote)
    }
}
