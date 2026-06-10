import Foundation

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

    static let `default` = CCornSettings(
        watchDirectories: [],
        staleThresholdSeconds: 3600,
        autoRestartOnLaunch: false,
        onboardingComplete: false
    )

    init(watchDirectories: [String],
         staleThresholdSeconds: TimeInterval,
         autoRestartOnLaunch: Bool,
         onboardingComplete: Bool = false) {
        self.watchDirectories = watchDirectories
        self.staleThresholdSeconds = staleThresholdSeconds
        self.autoRestartOnLaunch = autoRestartOnLaunch
        self.onboardingComplete = onboardingComplete
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
    }
}
