import Foundation
import Testing

/// Milestone-3 pure logic: settings decode tolerance, rename error detection,
/// record merging, and the unmanaged-process registry filter.
@Suite struct M3LogicTests {

    // MARK: - CCornSettings decode tolerance

    /// A settings.json written by an older build (no onboardingComplete) must
    /// decode with the user's values intact — a wholesale decode failure would
    /// silently reset to defaults and re-run onboarding.
    @Test func oldSettingsDecodeWithDefaults() throws {
        let old = #"{"watchDirectories":["/Users/x/dev"],"staleThresholdSeconds":600,"autoRestartOnLaunch":true}"#
        let settings = try JSONDecoder().decode(CCornSettings.self, from: Data(old.utf8))
        #expect(settings.watchDirectories == ["/Users/x/dev"])
        #expect(settings.staleThresholdSeconds == 600)
        #expect(settings.autoRestartOnLaunch)
        #expect(!settings.onboardingComplete)
    }

    @Test func emptySettingsDecodeToDefaults() throws {
        let settings = try JSONDecoder().decode(CCornSettings.self, from: Data("{}".utf8))
        #expect(settings == .default)
    }

    @Test func settingsRoundTrip() throws {
        var settings = CCornSettings.default
        settings.watchDirectories = ["/tmp/a"]
        settings.onboardingComplete = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CCornSettings.self, from: data)
        #expect(decoded == settings)
    }

    // MARK: - Rename error detection (flow 6.8)

    @Test func renameErrorDetectsNewErrorLine() {
        let before = "╭───╮\n> /rename foo\n╰───╯"
        let after = before + "\nThat name is already taken"
        let error = SessionEngine.renameError(before: before, after: after)
        #expect(error == "That name is already taken")
    }

    /// Error-shaped text that was already on screen before the rename must not
    /// fail the rename — only NEW lines count.
    @Test func renameErrorIgnoresPreexistingErrorText() {
        let before = "old output: name already exists\n> idle"
        let after = before + "\nRenamed session"
        #expect(SessionEngine.renameError(before: before, after: after) == nil)
    }

    /// Unrelated streamed content (even containing the word "error") must not
    /// flag — only the rename-shaped phrases count.
    @Test func renameErrorIgnoresUnrelatedNewContent() {
        let before = "> working"
        let after = before + "\n⏺ Bash(grep error main.swift)\ncompile error in module X"
        #expect(SessionEngine.renameError(before: before, after: after) == nil)
    }

    @Test func renameErrorNilWhenUnchanged() {
        let pane = "> idle\n? for shortcuts"
        #expect(SessionEngine.renameError(before: pane, after: pane) == nil)
    }

    // MARK: - SessionStore.mergeRecord

    private func temporaryStore() throws -> (SessionStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccorn-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionStore(supportDir: dir), dir)
    }

    @Test func mergeRecordCreatesWhenAbsent() throws {
        let (store, dir) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.mergeRecord(uuid: "u1", path: "/tmp/p", title: "T")
        let records = store.loadRecords()
        #expect(records.count == 1)
        #expect(records[0].uuid == "u1")
        #expect(records[0].path == "/tmp/p")
        #expect(records[0].title == "T")
        #expect(!records[0].archived)
    }

    /// nil parameters leave existing fields untouched — a caller that only
    /// knows part of a session's identity can't clobber the rest.
    @Test func mergeRecordPartialUpdateKeepsOtherFields() throws {
        let (store, dir) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.mergeRecord(uuid: "u1", path: "/tmp/p", title: "Title")
        store.mergeRecord(uuid: "u1", archived: true)
        store.mergeRecord(uuid: "u1", title: "Renamed")
        let records = store.loadRecords()
        #expect(records.count == 1)
        #expect(records[0].path == "/tmp/p")
        #expect(records[0].title == "Renamed")
        #expect(records[0].archived)
    }

    @Test func mergeRecordIgnoresEmptyUUID() throws {
        let (store, dir) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.mergeRecord(uuid: "", title: "ghost")
        #expect(store.loadRecords().isEmpty)
    }

    // MARK: - UnmanagedClaudeFinder registry filtering

    /// Registry files for dead pids linger (RUNTIME_FINDINGS F3) — they must
    /// never produce a candidate.
    @Test func registryRejectsDeadPidFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccorn-claude-\(UUID().uuidString)")
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 99_999_999 is far above macOS's pid range — guaranteed dead.
        let stale = #"{"pid":99999999,"sessionId":"abc","cwd":"/tmp/x"}"#
        try Data(stale.utf8).write(to: sessions.appendingPathComponent("99999999.json"))
        // Non-numeric names are ignored outright.
        try Data(stale.utf8).write(to: sessions.appendingPathComponent("notes.json"))

        #expect(UnmanagedClaudeFinder.registryCandidates(claudeDir: dir).isEmpty)
        #expect(UnmanagedClaudeFinder.find(inDirectory: "/tmp/x", sessionId: "abc",
                                           claudeDir: dir)?.sessionId != "abc")
    }
}
