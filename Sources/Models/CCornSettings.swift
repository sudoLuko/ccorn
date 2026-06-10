import Foundation

/// A user-named collection of sessions (the Apple Books collections pattern).
/// One level, no nesting. DEFINITIONS (id, name; order = array position) live
/// in `CCornSettings.groups`; MEMBERSHIP lives on each `SessionRecord`
/// (`groupIDs`), keyed by the session uuid, so it follows the record store's
/// prune and retention lifecycle.
struct SessionGroup: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var name: String

    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    /// Assignment gate: membership keys on the session UUID, and a brand-new
    /// session has none until its first transcript binds — no uuid, no
    /// Groups control (the same family as Restart gating on a missing path).
    static func canAssign(uuid: String) -> Bool {
        !uuid.isEmpty
    }

    /// Placeholder name for "+ New Group" / the menu's "New Group…":
    /// "New Group", then "New Group 2", "New Group 3", … against the
    /// existing names.
    static func defaultName(existing: [SessionGroup]) -> String {
        let base = "New Group"
        if !existing.contains(where: { $0.name == base }) { return base }
        var n = 2
        while existing.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }
}

/// User settings that scope and tune the engine. Persisted as JSON alongside
/// the session records. Watch directories are a *filter* on discovery, not the
/// discovery source (that is always `~/.claude/projects/`).
struct CCornSettings: Codable, Equatable {
    /// Directories whose projects CCorn surfaces. Compared against transcript
    /// `cwd` values after both sides are symlink-resolved.
    var watchDirectories: [String]
    /// Idle threshold (seconds) after which an otherwise-Running session is Stale.
    var staleThresholdSeconds: TimeInterval
    /// Auto-restart dead sessions on launch.
    var autoRestartOnLaunch: Bool
    /// Onboarding has been completed; never show it again (flow 6.1).
    var onboardingComplete: Bool
    /// User-defined group definitions, in sidebar order. Membership lives on
    /// the session records (`SessionRecord.groupIDs`), not here.
    var groups: [SessionGroup]

    static let `default` = CCornSettings(
        watchDirectories: [],
        staleThresholdSeconds: 3600,
        autoRestartOnLaunch: false,
        onboardingComplete: false
    )

    init(watchDirectories: [String],
         staleThresholdSeconds: TimeInterval,
         autoRestartOnLaunch: Bool,
         onboardingComplete: Bool = false,
         groups: [SessionGroup] = []) {
        self.watchDirectories = watchDirectories
        self.staleThresholdSeconds = staleThresholdSeconds
        self.autoRestartOnLaunch = autoRestartOnLaunch
        self.onboardingComplete = onboardingComplete
        self.groups = groups
    }

    /// Every field decodes with a default so a settings.json written by an
    /// older build never fails wholesale (which would silently reset the user
    /// to `.default` and re-run onboarding).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchDirectories = try c.decodeIfPresent([String].self, forKey: .watchDirectories)
            ?? Self.default.watchDirectories
        staleThresholdSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .staleThresholdSeconds)
            ?? Self.default.staleThresholdSeconds
        autoRestartOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoRestartOnLaunch)
            ?? Self.default.autoRestartOnLaunch
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete)
            ?? Self.default.onboardingComplete
        groups = try c.decodeIfPresent([SessionGroup].self, forKey: .groups)
            ?? Self.default.groups
    }
}
