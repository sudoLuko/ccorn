import Foundation
import Testing

/// User-defined groups (docs/CCORN_SPEC.md 5.11): definitions persist in
/// settings (field-by-field-defaulting decode), membership merges onto
/// records keyed by the session uuid (the archived-flag pattern) and
/// inherits the record store's lifecycle.
@Suite struct GroupsTests {

    private func scratchStore() -> SessionStore {
        SessionStore(supportDir: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccorn-groups-tests-\(UUID().uuidString)",
                                    isDirectory: true))
    }

    // MARK: Membership persistence (uuid-keyed, archived-flag pattern)

    @Test func membershipMergesOntoRecordKeyedByUUID() {
        let store = scratchStore()
        store.mergeRecord(uuid: "u1", path: "/p", groupIDs: ["g1", "g2"])
        let record = store.loadRecords().first { $0.uuid == "u1" }
        #expect(record?.groupIDs == ["g1", "g2"])
        // The merge creates the record if absent, same as the archived flag.
        #expect(record?.path == "/p")
    }

    @Test func nilMembershipLeavesExistingMembershipUntouched() {
        let store = scratchStore()
        store.mergeRecord(uuid: "u1", groupIDs: ["g1"])
        // A later merge that only knows about archived must not clobber it.
        store.mergeRecord(uuid: "u1", archived: true)
        let record = store.loadRecords().first { $0.uuid == "u1" }
        #expect(record?.groupIDs == ["g1"])
        #expect(record?.archived == true)
    }

    @Test func membershipSurvivesArchiveAndUnarchive() {
        let store = scratchStore()
        store.mergeRecord(uuid: "u1", groupIDs: ["g1"])
        store.mergeRecord(uuid: "u1", archived: true)
        store.mergeRecord(uuid: "u1", archived: false)
        #expect(store.loadRecords().first { $0.uuid == "u1" }?.groupIDs == ["g1"])
    }

    /// An empty uuid never creates a record (mergeRecord's guard), the
    /// storage-level backstop behind the UI's bound-uuid gating.
    @Test func emptyUUIDNeverCreatesARecord() {
        let store = scratchStore()
        store.mergeRecord(uuid: "", groupIDs: ["g1"])
        #expect(store.loadRecords().isEmpty)
    }

    // MARK: Backward-compatible decoding

    @Test func recordsWrittenByOlderBuildsDecodeWithEmptyMembership() throws {
        let old = #"[{"uuid":"u1","path":"/p","title":"t","archived":true}]"#
        let records = try JSONDecoder().decode([SessionRecord].self, from: Data(old.utf8))
        #expect(records.count == 1)
        #expect(records[0].groupIDs.isEmpty)
        #expect(records[0].archived)
    }

    @Test func groupDefinitionsPersistInSettings() throws {
        // Old settings without groups decode to [] (never a wholesale reset).
        let old = #"{"watchDirectories":["/x"],"staleThresholdSeconds":600,"autoRestartOnLaunch":false,"onboardingComplete":true}"#
        let settings = try JSONDecoder().decode(CCornSettings.self, from: Data(old.utf8))
        #expect(settings.groups.isEmpty)
        #expect(settings.onboardingComplete)

        // Round trip with definitions, order preserved (order = array position).
        var updated = settings
        updated.groups = [SessionGroup(id: "g2", name: "Infra"),
                          SessionGroup(id: "g1", name: "Client work")]
        let decoded = try JSONDecoder().decode(CCornSettings.self,
                                               from: JSONEncoder().encode(updated))
        #expect(decoded.groups == updated.groups)
        #expect(decoded.groups.map(\.id) == ["g2", "g1"])
    }

    // MARK: Delete keeps sessions

    @Test func deletingAGroupClearsMembershipButKeepsRecords() {
        let store = scratchStore()
        store.mergeRecord(uuid: "u1", path: "/a", groupIDs: ["g1"])
        store.mergeRecord(uuid: "u2", path: "/b", groupIDs: ["g1", "g2"])
        store.mergeRecord(uuid: "u3", path: "/c", archived: true)

        store.removeGroupID("g1")

        let records = store.loadRecords()
        #expect(records.count == 3) // every session survives
        #expect(records.first { $0.uuid == "u1" }?.groupIDs == [])
        #expect(records.first { $0.uuid == "u2" }?.groupIDs == ["g2"])
        #expect(records.first { $0.uuid == "u3" }?.archived == true) // untouched
    }

    // MARK: Bound-uuid gating

    @Test func assignmentGatesOnABoundUUID() {
        #expect(!SessionGroup.canAssign(uuid: ""))
        #expect(SessionGroup.canAssign(uuid: "aaaaaaaa-0000-4000-8000-000000000001"))
    }

    // MARK: Group filter semantics

    /// The record-level rule behind AppModel.groupRows: members of the group,
    /// excluding archived (they keep membership but surface in Archived only).
    @Test func groupFilterSelectsNonArchivedMembers() {
        let records = [
            SessionRecord(uuid: "u1", path: "", title: "", groupIDs: ["g1"]),
            SessionRecord(uuid: "u2", path: "", title: "", archived: true, groupIDs: ["g1"]),
            SessionRecord(uuid: "u3", path: "", title: "", groupIDs: ["g2"]),
            SessionRecord(uuid: "u4", path: "", title: "", groupIDs: ["g2", "g1"]),
        ]
        let members = records.filter { $0.groupIDs.contains("g1") && !$0.archived }
        #expect(members.map(\.uuid) == ["u1", "u4"])
    }

    // MARK: New-session-into-active-group seeding

    /// The pure mapping behind AppModel.activeGroupIDsForNewSession: a group
    /// view seeds the new session into that group, every other view seeds none.
    /// This is what makes a session started while a group is open appear in the
    /// group the user is looking at instead of vanishing to All Sessions.
    @Test func activeGroupViewSeedsNewSessionMembership() {
        #expect(SidebarNav.group("x").groupIDsForNewSession == ["x"])
        #expect(SidebarNav.allSessions.groupIDsForNewSession == [])
        #expect(SidebarNav.archived.groupIDsForNewSession == [])
    }

    // MARK: Placeholder naming

    @Test func defaultGroupNameDedupes() {
        #expect(SessionGroup.defaultName(existing: []) == "New Group")
        let one = [SessionGroup(name: "New Group")]
        #expect(SessionGroup.defaultName(existing: one) == "New Group 2")
        let two = one + [SessionGroup(name: "New Group 2")]
        #expect(SessionGroup.defaultName(existing: two) == "New Group 3")
    }
}
