import Foundation

/// Persisted record for one known session. Identity is the Claude session UUID
/// (the JSONL filename / `sessionId`). Only the fields that must survive
/// relaunch are persisted; PID, live state, window id, and pane hashes are
/// re-derived on every launch (see docs/CCORN_SPEC.md "Session Record").
struct SessionRecord: Codable, Identifiable, Equatable {
    /// Claude session UUID — the stable identity key.
    let uuid: String
    /// Last-known resolved project path (from the transcript `cwd`).
    var path: String
    /// Last-known display title (the Claude session title).
    var title: String
    /// Survives relaunch: whether the user archived this session.
    var archived: Bool

    var id: String { uuid }

    init(uuid: String, path: String, title: String, archived: Bool = false) {
        self.uuid = uuid
        self.path = path
        self.title = title
        self.archived = archived
    }
}

/// Runtime, never-persisted state for a session. Rebuilt on every launch from
/// tmux windows + process inspection + pane capture.
final class LiveSession {
    let record: SessionRecord

    var windowId: String?
    var ccornTag: String?
    var pid: Int32?
    var state: SessionState
    /// True when the `Remote Control active` footer or a `bridge-session` record
    /// indicates remote control is live. Drives the row's warning indicator.
    var remoteControlActive: Bool

    // Stale tracking.
    var lastPaneHash: String?
    var lastHashChange: Date?

    init(record: SessionRecord,
         windowId: String? = nil,
         ccornTag: String? = nil,
         pid: Int32? = nil,
         state: SessionState = .stopped,
         remoteControlActive: Bool = false) {
        self.record = record
        self.windowId = windowId
        self.ccornTag = ccornTag
        self.pid = pid
        self.state = state
        self.remoteControlActive = remoteControlActive
    }
}
