import Foundation

/// Immutable row model the UI renders. Rebuilt by `AppModel` after every poll
/// tick and discovery pass from the engine's live sessions, persisted records,
/// and discovered unmanaged projects; views never reach into engine state
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
    /// Whether this session was launched to use remote control (`--rc`). False
    /// for a session the user created as local; it has no remote control by
    /// design, so it must never resolve to the no-remote mark. Defaults true:
    /// records/unmanaged/adopted rows have no local intent and stay remote-expected.
    let remoteControlRequested: Bool
    /// Remote-control bridge handle (`session_…`) when known; the
    /// `claude.ai/code/<id>` per-session URL segment the browser handoff opens.
    /// nil for rows with no live bridge (stopped/unmanaged, or RC not yet up);
    /// the handoff falls back to the claude.ai/code portal then.
    let bridgeSessionId: String?
    /// True once the session is old enough that missing remote control is a
    /// problem, not just still-activating (30s grace; docs/CCORN_SPEC.md §8).
    let rcGraceExpired: Bool
    let archived: Bool
    let lastActive: Date?
    /// CLI-authored lines from detection: the login-prompt error for a
    /// needsAuth row, and the remote-control plan-restriction failure
    /// (docs/CCORN_SPEC.md §8). Drive tooltips and the one-shot alerts.
    let authNotice: String?
    let rcPlanNotice: String?
    /// User-group membership, mirrored from the session's record (keyed by
    /// uuid there, never by this row's id, which differs across managed/
    /// stopped/unmanaged and changes on stop). Always [] for unmanaged rows.
    let groupIDs: [String]
    /// True when the session is running with permissions bypassed; drives the
    /// row's bypass marker. Only set for live managed rows (the detector pane
    /// signal, or a launch config of `.bypass`); never for stopped/unmanaged.
    let isBypass: Bool

    init(id: String,
         kind: Kind,
         title: String,
         uuid: String,
         path: String,
         state: SessionState,
         remoteControlActive: Bool,
         remoteControlRequested: Bool = true,
         bridgeSessionId: String? = nil,
         rcGraceExpired: Bool = true,
         archived: Bool = false,
         lastActive: Date?,
         authNotice: String? = nil,
         rcPlanNotice: String? = nil,
         groupIDs: [String] = [],
         isBypass: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.uuid = uuid
        self.path = path
        self.state = state
        self.remoteControlActive = remoteControlActive
        self.remoteControlRequested = remoteControlRequested
        self.bridgeSessionId = bridgeSessionId
        self.rcGraceExpired = rcGraceExpired
        self.archived = archived
        self.lastActive = lastActive
        self.authNotice = authNotice
        self.rcPlanNotice = rcPlanNotice
        self.groupIDs = groupIDs
        self.isBypass = isBypass
    }

    var isManaged: Bool {
        if case .managed = kind { return true }
        return false
    }

    /// Launched without remote control (`--rc`): a local-only session with no
    /// browser/phone access and no per-session URL. Drives the row's quiet
    /// "Local" tag. The inverse of `remoteControlRequested`, which defaults true,
    /// so unmanaged/adopted rows (unknown posture) are never tagged local.
    var isLocal: Bool { !remoteControlRequested }

    var windowId: String? {
        if case let .managed(windowId) = kind { return windowId }
        return nil
    }

    /// Identity for the SwiftUI list/animation, kept stable across a session's
    /// managed→record transition (Stop): a live row's `id` is its tmux window id
    /// but the resulting Stopped row's `id` is `record:<uuid>`, so keying the
    /// list on `id` makes Stop read as a remove+insert and the row animates out
    /// then back in. The session uuid is the durable identity, so the row stays
    /// put and updates in place. Falls back to the (unique) `id` for a brand-new
    /// managed row whose uuid hasn't bound yet; that one row re-keys once on
    /// bind, which `id`/`stateMemory` continue to key on `id` to avoid (see
    /// `AppModel.emitStateTransitions`). This is display identity only.
    var listID: String { uuid.isEmpty ? id : uuid }

    /// The one status mark this row shows (review item 1: one mark per row).
    /// Folds the remote-control condition (alive but RC inactive past the
    /// 30s activation grace, the old warning-overlay rule) into the mark as
    /// No remote; needsAuth/dead/stopped/unmanaged keep their own
    /// presentations.
    var presentation: StatusPresentation {
        StatusPresentation.resolve(state: state,
                                   remoteControlActive: remoteControlActive,
                                   rcGraceExpired: rcGraceExpired,
                                   remoteControlRequested: remoteControlRequested)
    }

    /// Tooltip for the status mark. No remote keeps its existing text (the
    /// CLI's captured plan-restriction line when there is one, else the
    /// generic reason) with the underlying activity appended (the mark no
    /// longer shows it). Sign-in leads with the CLI's own login line.
    var statusTooltip: String {
        switch presentation {
        case .noRemote:
            let reason = rcPlanNotice ?? "Remote control is not active on this session"
            let activity = StatusPresentation.resolve(state: state,
                                                      remoteControlActive: true,
                                                      rcGraceExpired: false)
            return "\(reason) (session is \(activity.displayName.lowercased()))"
        case .needsAuth:
            return authNotice ?? "Claude Code is not signed in"
        default:
            return presentation.displayName
        }
    }

    /// Home-relative display form of `path` ("~/dev/ccorn").
    var displayPath: String {
        path.isEmpty ? "—" : (path as NSString).abbreviatingWithTildeInPath
    }
}

extension SessionRow {
    /// What the row-click handoff resolves to (flow 6.4). Row-intrinsic and
    /// pure (depends only on the row and the user's click-action preference)
    /// so it is unit-testable without AppModel's GUI/tmux side effects.
    enum OpenAction: Equatable {
        /// Attach to this row's live tmux window.
        case terminal
        /// Hand off to the browser: the per-session deep link when this row's
        /// bridge handle is known, else the claude.ai/code portal (see
        /// `AppModel.openInBrowser`).
        case browser
        /// No live window: restart (resume) the session, then attach Terminal.
        case restartThenAttach
        /// An unmanaged discovery: import (adopt) the session under CCorn, then
        /// attach Terminal to the fresh managed window (flow 6.4 / 6.10).
        case adoptThenAttach
    }

    /// Browser mode hands off to the browser (per-session deep link or portal,
    /// resolved in `AppModel.openInBrowser`). Terminal mode:
    ///  - live window → attach to it (no remote control needed);
    ///  - stopped session (a record, not archived) → restart and attach to the
    ///    fresh window (the Restart preconditions still gate this downstream);
    ///  - unmanaged discovery (uuid + path known) → import it, then attach to
    ///    the fresh window (the import confirm + wait-for-idle gate it downstream);
    ///  - anything else with no window (archived, identity not yet surfaced) → browser.
    func openAction(clickAction: SessionClickAction) -> OpenAction {
        guard clickAction == .terminal else { return .browser }
        if windowId != nil { return .terminal }
        if case .record = kind, !archived { return .restartThenAttach }
        if case .unmanaged = kind, !uuid.isEmpty, !path.isEmpty { return .adoptThenAttach }
        return .browser
    }
}
