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
    /// session has none until its first transcript binds: no uuid, no
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

/// What clicking a session row does: popover single-click and main-window
/// double-click both route through it. Terminal is the default: it attaches to
/// the session's own tmux window, so one click lands you *inside* that session.
/// Browser opens claude.ai/code, which is only the session list (no per-session
/// URL exists, runtime finding C1), so the user still has to find it by title.
enum SessionClickAction: String, Codable, CaseIterable {
    case terminal
    case browser
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
    /// What clicking a session row does (popover single-click, main-window
    /// double-click). Defaults to Terminal; the click attaches to the
    /// session's tmux window rather than opening the claude.ai/code list.
    var clickAction: SessionClickAction
    /// The launch flags new sessions inherit (the New Session sheet seeds its
    /// per-session override from this). Safe-but-autonomous (`auto`) by default.
    /// Applies only to sessions CCorn starts fresh, never to adopted ones.
    var defaultLaunchConfig: SessionLaunchConfig
    /// Keep the main window above other apps' windows (raise its level to
    /// `.floating`) so opening a session in Terminal can't bury it. Off by
    /// default; the popover and the activation-policy switch are unaffected
    /// (MainWindowController.applyWindowLevel / updateActivationPolicy).
    var keepWindowInFront: Bool
    /// tmux mouse mode for CCorn's sessions. On (default): the scroll wheel
    /// scrolls the pane. Off: the wheel falls back to arrow keys in a
    /// full-screen TUI, but native terminal text selection is simpler.
    /// Applied as a SESSION option on `ccorn` (and its view sessions), never
    /// the tmux global, so a user's own `set -g mouse` is left untouched
    /// (TmuxController.setMouseMode / applyMouseMode).
    var mouseMode: Bool
    /// Learned: this account cannot use remote control (a session reported a
    /// *definitive* account/plan failure, not a transient credentials-fetch or
    /// network hiccup). Set once, it forces `effectiveDefaultConfig` to local so
    /// new sessions stop passing `--rc` and re-failing, and gates the plan modal
    /// to once per account, without overwriting the user's stored
    /// `defaultLaunchConfig.remoteControl` preference, so flipping it back to
    /// remote restores the user's choice rather than a hardcoded default.
    /// Reversible: a session the user opts back into remote that then connects
    /// clears it, so a one-off bad match never permanently locks a real RC
    /// account into local (AppModel.reconcileRCAccountCapability).
    var rcKnownUnavailable: Bool
    /// Durable Claude session UUIDs the user removed from CCorn ("Remove from
    /// CCorn"): discovery skips them so an untracked session never re-surfaces,
    /// even if its conversation is later resumed from the terminal. Sticky by
    /// design and persisted here (the same store-backed JSON the archived flag
    /// lives in) so a future "manage untracked" surface can read and clear it.
    /// Removing a session only forgets CCorn's own record and remembers the
    /// UUID here; the Claude transcript on disk is never touched.
    var ignoredSessionUUIDs: [String]

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
         groups: [SessionGroup] = [],
         clickAction: SessionClickAction = .terminal,
         defaultLaunchConfig: SessionLaunchConfig = .safeDefault,
         keepWindowInFront: Bool = false,
         mouseMode: Bool = true,
         rcKnownUnavailable: Bool = false,
         ignoredSessionUUIDs: [String] = []) {
        self.watchDirectories = watchDirectories
        self.staleThresholdSeconds = staleThresholdSeconds
        self.autoRestartOnLaunch = autoRestartOnLaunch
        self.onboardingComplete = onboardingComplete
        self.groups = groups
        self.clickAction = clickAction
        self.defaultLaunchConfig = defaultLaunchConfig
        self.keepWindowInFront = keepWindowInFront
        self.mouseMode = mouseMode
        self.rcKnownUnavailable = rcKnownUnavailable
        self.ignoredSessionUUIDs = ignoredSessionUUIDs
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
        clickAction = try c.decodeIfPresent(SessionClickAction.self, forKey: .clickAction)
            ?? Self.default.clickAction
        defaultLaunchConfig = try c.decodeIfPresent(SessionLaunchConfig.self, forKey: .defaultLaunchConfig)
            ?? Self.default.defaultLaunchConfig
        keepWindowInFront = try c.decodeIfPresent(Bool.self, forKey: .keepWindowInFront)
            ?? Self.default.keepWindowInFront
        mouseMode = try c.decodeIfPresent(Bool.self, forKey: .mouseMode)
            ?? Self.default.mouseMode
        rcKnownUnavailable = try c.decodeIfPresent(Bool.self, forKey: .rcKnownUnavailable)
            ?? Self.default.rcKnownUnavailable
        ignoredSessionUUIDs = try c.decodeIfPresent([String].self, forKey: .ignoredSessionUUIDs)
            ?? Self.default.ignoredSessionUUIDs
    }

    /// The launch config a brand-new session actually inherits: the user's
    /// `defaultLaunchConfig` preference, except remote control is forced off
    /// when this account is known to lack it (`rcKnownUnavailable`). The learned
    /// flag wins over the preference (new sessions stop passing `--rc` and
    /// re-failing) but the stored `defaultLaunchConfig.remoteControl` choice is
    /// left untouched, so it takes effect again the moment the account proves
    /// capable and the flag clears. Both the New Session sheet seed and the
    /// engine's no-override fallback read this, not `defaultLaunchConfig`.
    var effectiveDefaultConfig: SessionLaunchConfig {
        var config = defaultLaunchConfig
        if rcKnownUnavailable { config.remoteControl = false }
        return config
    }
}
