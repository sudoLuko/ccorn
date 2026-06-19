import os

/// Production diagnostic logging. Distinct from the DEBUG-only
/// `studio.ccorn.debug` lifecycle logger (`DebugLifecycle.swift`): this facility
/// ships in Release so a field failure (tmux dead, claude off PATH, a corrupt or
/// unwritable store, an unreadable transcript) leaves a cause record retrievable
/// with Console.app or `log show --predicate 'subsystem == "studio.ccorn"'`.
///
/// One `Logger` per failure domain. `os.Logger` redacts every interpolation as
/// `<private>` by default, which is the correct default here: user paths,
/// session titles, transcript contents and cwd must stay private. Only
/// non-sensitive scalars (exit codes, error codes, counts) are marked
/// `.public`. These are failure-site logs, not a trace, so the hot 3s poll path
/// (capture-pane, pane-pid probe) logs only on a genuine non-zero exit, never on
/// an empty-but-healthy result.
enum Log {
    private static let subsystem = "studio.ccorn"

    /// tmux orchestration: session/window lifecycle, capture, enumeration.
    static let tmux = Logger(subsystem: subsystem, category: "tmux")
    /// External-process execution: PATH resolution, launch and non-zero exits.
    static let process = Logger(subsystem: subsystem, category: "process")
    /// Session discovery: project enumeration and transcript parsing.
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    /// Persisted store: support-dir, records, and settings read/write.
    static let store = Logger(subsystem: subsystem, category: "store")
}
