import Foundation
import Testing

/// The registry-bind uniqueness guard (`canBindRegistryUUID`). A window's
/// `@ccorn_id` is bound from the (non-authoritative) Claude session registry; a
/// recycled pid or a stale file for one of several sessions sharing a directory
/// can return a sibling's id. Binding it onto a second window mints a duplicate
/// `@ccorn_id`, which breaks one-window-per-session and the one-terminal-per-
/// session raise. The guard refuses any id already claimed by another live window.
@MainActor
@Suite struct BindGuardTests {

    /// A fresh id no live window holds is bindable.
    @Test func bindsFreshUUID() {
        #expect(SessionEngine.canBindRegistryUUID("a", claimed: ["b", "c"]))
        #expect(SessionEngine.canBindRegistryUUID("a", claimed: []))
    }

    /// An id another live window already holds is refused (the duplicate vector).
    @Test func refusesClaimedUUID() {
        #expect(!SessionEngine.canBindRegistryUUID("b", claimed: ["b", "c"]))
    }

    /// An empty id is never bindable (an unbound window stays unbound).
    @Test func refusesEmptyUUID() {
        #expect(!SessionEngine.canBindRegistryUUID("", claimed: []))
        #expect(!SessionEngine.canBindRegistryUUID("", claimed: ["b"]))
    }

    /// Same-pass collision: two windows in one bind pass resolve to the same id
    /// (the same-directory mis-bind). Claiming each accepted id as we go means the
    /// second is refused, so the pass binds the id to exactly one window. This is
    /// the loop discipline both the poll bind and the launch reconcile follow.
    @Test func samePassCollisionBindsOnlyOnce() {
        // Two unbound windows, both handed UUID "x" by a stale registry.
        let proposed = [(windowId: "@10", uuid: "x"), (windowId: "@23", uuid: "x")]
        var claimed = Set<String>()   // no live window holds anything yet
        var bound: [String] = []
        for w in proposed where SessionEngine.canBindRegistryUUID(w.uuid, claimed: claimed) {
            claimed.insert(w.uuid)
            bound.append(w.windowId)
        }
        #expect(bound == ["@10"])     // only the first; the second is refused
        #expect(claimed == ["x"])
    }

    /// A window whose id is already owned by a live window is refused even though
    /// it is the only candidate this pass (the exact transpose-session bug: an
    /// untagged window resolving to a uuid the live resumed window already holds).
    @Test func refusesUUIDOwnedByExistingLiveWindow() {
        let liveUUIDs: Set<String> = ["0cf6995c"]   // held by the live resumed window
        #expect(!SessionEngine.canBindRegistryUUID("0cf6995c", claimed: liveUUIDs))
    }
}
