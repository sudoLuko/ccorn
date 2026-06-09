import Foundation

/// Immutable row model the UI renders. Rebuilt by `AppModel` after every poll
/// tick and discovery pass from the engine's live sessions plus discovered
/// unmanaged projects — views never reach into engine state directly.
struct SessionRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Lives in a tmux window CCorn tracks; the id is the stable `@N` window id.
        case managed(windowId: String)
        /// Discovered under `~/.claude/projects/` with no matching ccorn window.
        case unmanaged
    }

    let id: String
    let kind: Kind
    let title: String
    /// Claude session UUID; may be empty for a brand-new managed session whose
    /// transcript hasn't been written yet.
    let uuid: String
    /// Resolved project path ("" when unknown).
    let path: String
    let state: SessionState
    let remoteControlActive: Bool
    let lastActive: Date?

    var isManaged: Bool {
        if case .managed = kind { return true }
        return false
    }

    var windowId: String? {
        if case let .managed(windowId) = kind { return windowId }
        return nil
    }

    /// Alive states get the warning indicator when remote control is not
    /// active (docs/CCORN_SPEC.md section 4, "Warning indicator visual").
    var needsAttention: Bool {
        switch state {
        case .running, .working, .waiting, .stale: return !remoteControlActive
        case .dead, .stopped, .unmanaged: return false
        }
    }

    /// Home-relative display form of `path` ("~/dev/ccorn").
    var displayPath: String {
        path.isEmpty ? "—" : (path as NSString).abbreviatingWithTildeInPath
    }
}
