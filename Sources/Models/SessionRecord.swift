import Combine
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
///
/// Main-actor isolated and observable: this is the store SwiftUI reads from in
/// milestone 2, and the poll timer / start / terminate / reconcile paths all
/// mutate it — isolation to the main actor is what makes those writes and the
/// UI reads race-free. (A bare `actor` was rejected deliberately: every SwiftUI
/// read would have to await, which in practice forces mirroring onto a
/// main-actor type anyway.) Detection I/O runs off-main on value snapshots —
/// see `detectionInput()` / `apply(_:)`.
@MainActor
final class LiveSession: ObservableObject {
    /// Mutable: identity binding rewrites it once the session UUID is learned,
    /// and rename updates the title. Persisting it is the engine's job.
    @Published var record: SessionRecord

    /// When CCorn started (or adopted) this session. Drives the 30s grace
    /// before "remote control not active" shows a warning indicator
    /// (docs/CCORN_SPEC.md section 8).
    let startedAt = Date()

    /// True when this session was adopted from an existing tmux window at
    /// launch (reconcile) rather than started by CCorn in this run. Adopted
    /// sessions get no notification baseline: whatever state they are first
    /// seen in is not a transition CCorn watched happen.
    let adopted: Bool

    @Published var windowId: String?
    @Published var ccornTag: String?
    @Published var pid: Int32?
    @Published var state: SessionState
    /// True when the `Remote Control active` footer or a `bridge-session` record
    /// indicates remote control is live. Drives the row's warning indicator.
    @Published var remoteControlActive: Bool

    // Detection bookkeeping (not UI-facing, so not published).
    var lastPaneHash: String?
    var lastHashChange: Date?
    var rcCache = BridgeSessionCache()
    /// CLI-authored auth/plan failure lines from the latest detection pass
    /// (section 8 alerts + row tooltips). Read only during rebuildRows, which
    /// runs after every apply — no need to publish.
    var authNotice: String?
    var rcPlanNotice: String?

    #if DEBUG
    /// Shakedown identity, captured at init (deinit is nonisolated, so it must
    /// not read main-actor state): the window id, else the uuid prefix.
    private nonisolated let debugLabel: String
    #endif

    init(record: SessionRecord,
         windowId: String? = nil,
         ccornTag: String? = nil,
         pid: Int32? = nil,
         state: SessionState = .stopped,
         remoteControlActive: Bool = false,
         adopted: Bool = false) {
        self.record = record
        self.windowId = windowId
        self.ccornTag = ccornTag
        self.pid = pid
        self.state = state
        self.remoteControlActive = remoteControlActive
        self.adopted = adopted
        #if DEBUG
        self.debugLabel = windowId
            ?? (record.uuid.isEmpty ? "unbound" : String(record.uuid.prefix(8)))
        DebugLife.adjust("live-session-objects", by: 1, note: "init LiveSession \(debugLabel)")
        #endif
    }

    #if DEBUG
    deinit {
        DebugLife.adjust("live-session-objects", by: -1, note: "deinit LiveSession \(debugLabel)")
    }
    #endif

    /// The session UUID detection should resolve the transcript by: the tmux
    /// @ccorn_id tag when bound, else the persisted record's UUID ("" for a
    /// brand-new session whose transcript hasn't been written yet).
    var sessionUUID: String { ccornTag ?? record.uuid }

    /// Value snapshot for an off-main detection pass.
    func detectionInput() -> DetectionInput {
        DetectionInput(windowId: windowId,
                       pid: pid,
                       lastPaneHash: lastPaneHash,
                       lastHashChange: lastHashChange,
                       rcCache: rcCache)
    }

    /// Apply a detection result computed off-main back onto main-actor state.
    func apply(_ result: DetectionResult) {
        state = result.state
        pid = result.pid
        remoteControlActive = result.remoteControlActive
        lastPaneHash = result.lastPaneHash
        lastHashChange = result.lastHashChange
        rcCache = result.rcCache
        authNotice = result.authNotice
        rcPlanNotice = result.rcPlanNotice
    }
}
