import Foundation

/// What an import-sheet discovery row can honestly say about an *unmanaged*
/// session before CCorn adopts it.
///
/// CCorn does not own an unmanaged session's tmux window, so it has no pane to
/// read (the managed-row state model in `StateDetector`/`StatusPresentation`
/// has no analogue here). That means working vs waiting vs idle-at-the-prompt
/// is genuinely unknowable: a session blocked at an edit-approval prompt looks,
/// from the outside, exactly like one mid-task. The one fact we can establish
/// is whether a live external `claude` process exists (`UnmanagedClaudeFinder`,
/// via `ImportFlowModel.probe`). So a discovery row claims liveness only: a
/// live session is "Active", a dormant one (a transcript on disk with no
/// process) makes no claim at all.
///
/// This replaces the old "Working"/"Idle" badge, which keyed on a 120s
/// transcript-mtime timer and so labeled a session paused on a permission
/// prompt "Working" or "Idle" purely by how recently it was reached, claiming
/// an activity state CCorn never had. (The conservative `live && recent` check
/// still lives at *import* time as the wait-for-idle guard, where erring toward
/// caution before a SIGTERM only costs a confirmation; it is not a status.)
enum ImportRowLiveness: Equatable, Sendable {
    /// A live external `claude` process is running for this session.
    case active
    /// Transcript on disk only; no live process (imports with no kill step).
    case dormant

    init(isLive: Bool) { self = isLive ? .active : .dormant }

    /// The trailing caption the row shows, or `nil` for a dormant row, which
    /// makes no claim. Never an activity word ("Working"/"Idle"): liveness is
    /// the only thing knowable pre-adoption.
    var tagText: String? {
        switch self {
        case .active: return "Active"
        case .dormant: return nil
        }
    }
}
