import Foundation

/// The seven session states (docs/CCORN_SPEC.md section 4).
enum SessionState: String, Codable {
    case running    // alive, remote control active, healthy idle
    case working    // Claude actively executing mid-task
    case waiting    // waiting for user input / approval
    case stale      // idle past the user-defined threshold
    case dead       // process died unexpectedly (tracked PID gone)
    case stopped    // manually killed by the user (set by CCorn, not detected)
    case unmanaged  // discovered but not imported into CCorn
}
