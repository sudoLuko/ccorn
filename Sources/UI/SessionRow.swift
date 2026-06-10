import Foundation

/// Immutable row model the UI renders. Rebuilt by `AppModel` after every poll
/// tick and discovery pass from the engine's live sessions, persisted records,
/// and discovered unmanaged projects — views never reach into engine state
/// directly.
struct SessionRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Lives in a tmux window CCorn tracks; the id is the stable `@N` window id.
        case managed(windowId: String)
        /// A persisted record with no live window: Stopped (or archived).
        case record
        /// Discovered under `~/.claude/projects/` with no matching ccorn window.
        case unmanaged
    }

    let id: String
    let kind: Kind
    let title: String
    /// Claude session UUID; may be empty for a brand-new managed session whose
    /// registry/transcript hasn't surfaced yet.
    let uuid: String
    /// Resolved project path ("" when unknown).
    let path: String
    let state: SessionState
    let remoteControlActive: Bool
    /// True once the session is old enough that missing remote control is a
    /// problem, not just still-activating (30s grace — docs/CCORN_SPEC.md §8).
    let rcGraceExpired: Bool
    let archived: Bool
    let lastActive: Date?

    init(id: String,
         kind: Kind,
         title: String,
         uuid: String,
         path: String,
         state: SessionState,
         remoteControlActive: Bool,
         rcGraceExpired: Bool = true,
         archived: Bool = false,
         lastActive: Date?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.uuid = uuid
        self.path = path
        self.state = state
        self.remoteControlActive = remoteControlActive
        self.rcGraceExpired = rcGraceExpired
        self.archived = archived
        self.lastActive = lastActive
    }

    var isManaged: Bool {
        if case .managed = kind { return true }
        return false
    }

    var windowId: String? {
        if case let .managed(windowId) = kind { return windowId }
        return nil
    }

    /// Alive states get the warning indicator when remote control has not
    /// come up within the activation grace window (docs/CCORN_SPEC.md
    /// section 4, "Warning indicator visual"; section 8, 30s activation).
    var needsAttention: Bool {
        switch state {
        case .running, .working, .waiting, .stale:
            return !remoteControlActive && rcGraceExpired
        case .dead, .stopped, .unmanaged:
            return false
        }
    }

    /// Home-relative display form of `path` ("~/dev/ccorn").
    var displayPath: String {
        path.isEmpty ? "—" : (path as NSString).abbreviatingWithTildeInPath
    }
}
