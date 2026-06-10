import Foundation

/// The session states (docs/CCORN_SPEC.md section 4, plus `needsAuth` from
/// section 8: a login-needed session is blocked on authentication, not on a
/// normal input prompt, so it must not surface as Waiting).
enum SessionState: String, Codable {
    case running    // alive, remote control active, healthy idle
    case working    // Claude actively executing mid-task
    case waiting    // waiting for user input / approval
    case needsAuth  // showing a login prompt — blocked until the user signs in
    case stale      // idle past the user-defined threshold
    case dead       // process died unexpectedly (tracked PID gone)
    case stopped    // manually killed by the user (set by CCorn, not detected)
    case unmanaged  // discovered but not imported into CCorn
}

extension SessionState {
    /// Severity rank for the menu-bar aggregate dot (higher = worse), per
    /// docs/CCORN_SPEC.md section 5.2: dead > waiting > stale > working > running.
    /// Waiting outranks Stale because a waiting session is blocked on the user;
    /// needsAuth outranks Waiting because nothing at all runs until sign-in.
    /// `stopped` and `unmanaged` carry no active color and rank `nil`.
    var aggregateSeverity: Int? {
        switch self {
        case .dead:      return 6
        case .needsAuth: return 5
        case .waiting:   return 4
        case .stale:     return 3
        case .working:   return 2
        case .running:   return 1
        case .stopped, .unmanaged: return nil
        }
    }

    /// True for the states where a claude process is alive in the window
    /// (everything that can be killed/archived-with-confirmation).
    var isAliveState: Bool {
        switch self {
        case .running, .working, .waiting, .needsAuth, .stale: return true
        case .dead, .stopped, .unmanaged: return false
        }
    }

    /// The worst (highest-severity) active state across sessions, or `nil` when no
    /// session has an active color (all stopped/unmanaged or the list is empty) —
    /// the caller then shows the empty/outline dot.
    static func aggregate(_ states: [SessionState]) -> SessionState? {
        states
            .filter { $0.aggregateSeverity != nil }
            .max { ($0.aggregateSeverity ?? 0) < ($1.aggregateSeverity ?? 0) }
    }
}
