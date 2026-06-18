import Foundation

/// The session states (docs/CCORN_SPEC.md section 4, plus `needsAuth` from
/// section 8: a login-needed session is blocked on authentication, not on a
/// normal input prompt, so it must not surface as Waiting).
enum SessionState: String, Codable {
    case running    // alive, remote control active, healthy idle
    case working    // Claude actively executing mid-task
    case waiting    // waiting for user input / approval
    case needsAuth  // showing a login prompt, blocked until the user signs in
    case stale      // idle past the user-defined threshold
    case dead       // process died unexpectedly (tracked PID gone)
    case stopped    // manually killed by the user (set by CCorn, not detected)
    case unmanaged  // discovered but not imported into CCorn
}

extension SessionState {
    /// True for the states where a claude process is alive in the window
    /// (everything that can be killed/archived-with-confirmation).
    var isAliveState: Bool {
        switch self {
        case .running, .working, .waiting, .needsAuth, .stale: return true
        case .dead, .stopped, .unmanaged: return false
        }
    }
}

/// The one status mark a row shows: exactly one, always. Routine lifecycle
/// states render as a colored dot; broken states that need the user replace
/// the dot with the single warning symbol (exclamationmark.triangle.fill).
/// Shape says routine-vs-broken, the symbol's color says severity (amber
/// recoverable, red terminal), and the short word after the title names the
/// specific problem. Never a dot and a symbol together.
enum StatusPresentation: String, Equatable {
    // Routine tier: colored dot.
    case running
    case working
    case waiting
    case stale
    case stopped
    case unmanaged
    // Broken tier: the one exclamation symbol.
    case noRemote   // alive, but remote control never came up past the grace
    case needsAuth  // login screen: sign-in is the root cause
    case crashed    // process died unexpectedly

    /// Resolve a session's detected state plus its remote-control condition
    /// to the mark the row shows. An otherwise-alive session whose remote
    /// control is not active past the 30s activation grace (exactly the old
    /// warning-overlay condition, docs/CCORN_SPEC.md §8) resolves to
    /// `.noRemote` regardless of the underlying activity; the activity moves
    /// to the tooltip. Exclusions are unchanged: needsAuth wins (sign-in is
    /// the root cause, missing remote control just its consequence), and
    /// dead/stopped/unmanaged keep their own presentations.
    ///
    /// `remoteControlRequested` is the session's intent: a session the user
    /// launched as local (`--rc` omitted) never has remote control and never
    /// should, so the no-remote mark is suppressed for it entirely, leaving the
    /// routine presentation. Defaults true: every session not started as local
    /// is expected to be remote, the historical behavior.
    static func resolve(state: SessionState,
                        remoteControlActive: Bool,
                        rcGraceExpired: Bool,
                        remoteControlRequested: Bool = true) -> StatusPresentation {
        let routine: StatusPresentation
        switch state {
        case .running: routine = .running
        case .working: routine = .working
        case .waiting: routine = .waiting
        case .stale: routine = .stale
        case .needsAuth: return .needsAuth
        case .dead: return .crashed
        case .stopped: return .stopped
        case .unmanaged: return .unmanaged
        }
        guard remoteControlRequested else { return routine }
        return (!remoteControlActive && rcGraceExpired) ? .noRemote : routine
    }

    /// True for the broken tier: the states that render the symbol.
    var isBroken: Bool {
        switch self {
        case .noRemote, .needsAuth, .crashed: return true
        case .running, .working, .waiting, .stale, .stopped, .unmanaged: return false
        }
    }

    /// The popover's triage tier: true when the session needs the user, the
    /// broken trio plus waiting (blocked on input). The calm states (running,
    /// working, stale, stopped) collapse behind the popover's quiet
    /// disclosure; unmanaged is ambient and belongs to neither tier.
    var needsAttention: Bool {
        switch self {
        case .waiting, .noRemote, .needsAuth, .crashed: return true
        case .running, .working, .stale, .stopped, .unmanaged: return false
        }
    }

    /// Severity rank for the menu-bar aggregate mark (higher = worse). The
    /// broken tier tops the ladder (crashed (terminal) > sign-in > no-remote,
    /// degraded, slotted next to sign-in) so a broken-tier worst shows the
    /// symbol in the header, not a dot. Below it: waiting (blocked on the user)
    /// tops the routine tier, then `working` — an actively running task is the
    /// most informative routine state, so a fleet with anything working reads
    /// as working (blue) rather than the grey stale dot. `stale` still outranks
    /// a plain healthy `running` so idle-too-long surfaces over healthy idle.
    /// `stopped` and `unmanaged` carry no active color and rank `nil`.
    var aggregateSeverity: Int? {
        switch self {
        case .crashed:   return 7
        case .needsAuth: return 6
        case .noRemote:  return 5
        case .waiting:   return 4
        case .working:   return 3
        case .stale:     return 2
        case .running:   return 1
        case .stopped, .unmanaged: return nil
        }
    }

    /// The worst (highest-severity) presentation across sessions, or `nil`
    /// when nothing has an active color (all stopped/unmanaged or the list is
    /// empty); the caller then shows the empty/outline dot.
    static func aggregate(_ presentations: [StatusPresentation]) -> StatusPresentation? {
        presentations
            .filter { $0.aggregateSeverity != nil }
            .max { ($0.aggregateSeverity ?? 0) < ($1.aggregateSeverity ?? 0) }
    }

    /// Tooltip / accessibility name.
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .working: return "Working"
        case .waiting: return "Waiting for input"
        case .stale: return "Stale"
        case .stopped: return "Stopped"
        case .unmanaged: return "Not managed by CCorn"
        case .noRemote: return "Remote control not active"
        case .needsAuth: return "Sign-in required"
        case .crashed: return "Crashed"
        }
    }

    /// Short word after the title (a text label, not a glyph) for the
    /// states that need the user. The routine states stay mark-only; their
    /// word lives in the tooltip.
    var attentionLabel: String? {
        switch self {
        case .waiting: return "Needs input"
        case .needsAuth: return "Sign in"
        case .noRemote: return "No remote"
        case .crashed: return "Crashed"
        case .running, .working, .stale, .stopped, .unmanaged: return nil
        }
    }

    /// One-line gloss for the Settings status legend: the words behind a mark
    /// for the color-only states a first-time user would otherwise have to
    /// hover to learn. The mark and color stay sourced from `StatusMark`, so
    /// the legend can never drift from what a row actually shows.
    var legendDescription: String {
        switch self {
        case .running: return "Alive and idle, ready for input"
        case .working: return "Claude is actively running a task"
        case .waiting: return "Paused for your input or approval"
        case .stale: return "Idle past the stale threshold"
        case .stopped: return "You stopped this session"
        case .unmanaged: return "Discovered, but not imported into CCorn"
        case .needsAuth: return "Blocked on a sign-in prompt"
        case .noRemote: return "Remote control never came up, so there is no phone access"
        case .crashed: return "The process exited unexpectedly"
        }
    }

    /// The nine marks in legend order (the six routine dots, then the broken
    /// trio) for the Settings legend to render with the real `StatusMark`.
    static let legendOrder: [StatusPresentation] = [
        .running, .working, .waiting, .stale, .stopped, .unmanaged,
        .needsAuth, .noRemote, .crashed,
    ]
}
