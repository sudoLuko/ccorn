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

    static let `default` = CCornSettings(
        watchDirectories: [],
        staleThresholdSeconds: 600,
        autoRestartOnLaunch: false
    )
}
