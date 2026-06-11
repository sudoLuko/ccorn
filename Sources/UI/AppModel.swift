import AppKit
import Combine
import SwiftUI

/// UI-facing coordinator over the engine. Owns the 3s state poll, the
/// FSEvents-driven discovery refresh, and the row models every screen renders.
/// Milestone 3: also owns the full action surface — new session, kill,
/// restart, archive, import, rename — plus onboarding completion, the
/// first-run import flow, state-transition notifications, and auto-restart.
@MainActor
final class AppModel: ObservableObject {
    let engine: SessionEngine

    /// All Sessions rows, sorted by last active (most recent first).
    @Published private(set) var rows: [SessionRow] = []
    /// Archived view rows, same sort.
    @Published private(set) var archivedRows: [SessionRow] = []
    /// True once the first discovery pass has completed — gates the empty state
    /// ("watch directories have been scanned but no sessions found").
    @Published private(set) var hasScanned = false
    /// Main-window list selection (row id).
    @Published var selection: String?
    /// Sidebar navigation (All Sessions / Archived) — model-owned so actions
    /// (and verification) can switch views.
    @Published var sidebarNav: SidebarNav = .allSessions

    /// Inline rename state (docs/CCORN_SPEC.md 5.8): the row being edited and
    /// the inline error shown under it ("That name is already taken").
    @Published var renamingRowId: String?
    @Published var renameError: String?
    /// A commit is in flight (the 3s pane error-watch); the field locks.
    @Published var renameInFlight = false

    /// User-defined groups (docs/CCORN_SPEC.md 5.11), mirrored from
    /// settings so the sidebar re-renders on every mutation. Definitions
    /// live in settings; membership lives on the session records.
    @Published private(set) var groups: [SessionGroup] = []
    /// Inline group-name editing in the sidebar — the session-rename
    /// pattern. `editingGroupIsNew` marks a group just created by
    /// "+ New Group": escape (or an empty commit) then removes it instead of
    /// reverting the name.
    @Published var editingGroupId: String?
    private var editingGroupIsNew = false

    /// Non-nil while the first-run import sheet is up (set after onboarding's
    /// scan when unmanaged sessions were found).
    @Published var importFlow: ImportFlowModel?

    /// Surface visibility, published by the window controllers (the popover's
    /// show/close, the main window's occlusion changes). Both surfaces keep
    /// their SwiftUI trees alive while hidden, so the row marks gate their
    /// repeatForever motion on these via Theme's rowMotionEnabled environment
    /// key — a hidden tree otherwise re-renders every frame, forever.
    @Published var popoverOnScreen = false
    @Published var mainWindowOnScreen = false

    /// Set by the AppDelegate so popover/empty-state actions can reach the
    /// window layer without the model importing it.
    var openMainWindow: (() -> Void)?
    var closePopover: (() -> Void)?
    var closeOnboarding: (() -> Void)?
    #if DEBUG
    /// Debug-only (screenshot staging): show the popover on command.
    var openPopover: (() -> Void)?
    #endif

    private var unmanagedProjects: [DiscoveredProject] = []
    /// Persisted session records, mirrored from the store on every discovery
    /// pass and after every mutation. Source of the Stopped/Archived rows.
    private var records: [SessionRecord] = []
    /// uuid -> transcript (path + mtime), refreshed with discovery; provides the
    /// "last active" timestamp for managed sessions.
    private var transcriptIndex: [String: DiscoveredSession] = [:]
    /// uuid -> transcript meta (ai-title + cwd) for every row's uuid, resolved
    /// during discovery (FSEvents fires on transcript writes, so titles stay
    /// fresh); the 3s poll only reads this cache.
    private var metaByUUID: [String: TranscriptMeta] = [:]
    private let metaCache = TranscriptMetaCache()
    private var pollTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    /// Orders overlapping discovery passes: a pass only applies its snapshot if
    /// no newer pass started while it ran, so a slow early pass can never
    /// overwrite fresher results.
    private var discoveryGeneration = 0
    /// Last seen state per session (keyed by uuid, else row id) — the edge
    /// detector behind Waiting/Dead notifications. First observation of a
    /// session records silently; only a real change can notify.
    private var stateMemory: [String: SessionState] = [:]
    /// Rows that already showed their one-shot section-8 alert (login needed /
    /// remote-control plan restriction), so a persisting pane can't re-alert
    /// every poll tick. Pruned alongside `stateMemory`.
    private var authAlerted = Set<String>()
    private var rcPlanAlerted = Set<String>()

    init(engine: SessionEngine) {
        self.engine = engine
        self.groups = engine.settings.groups
    }

    /// The popover header's aggregate mark: worst presentation across all
    /// rows (same per-row resolution the lists use, so a broken-tier worst
    /// shows the warning symbol), nil (empty/outline dot) when no session has
    /// an active color.
    var aggregatePresentation: StatusPresentation? {
        StatusPresentation.aggregate(rows.map(\.presentation))
    }

    /// Sessions CCorn manages (live windows + stopped records) — the primary
    /// content everywhere. Sorted by last active, like `rows`.
    var managedRows: [SessionRow] {
        rows.filter { $0.kind != .unmanaged }
    }

    /// Sessions discovered on the system but not managed — ambient, secondary.
    var unmanagedRows: [SessionRow] {
        rows.filter { $0.kind == .unmanaged }
    }

    var onboardingNeeded: Bool { !engine.settings.onboardingComplete }

    // MARK: - Lifecycle

    /// Reconcile with existing tmux windows, run discovery, auto-restart if
    /// enabled, then poll states every 3 seconds. Discovery re-runs only on
    /// FSEvents from `~/.claude/projects/`, never on the poll.
    func start() {
        guard pollTask == nil else { return }

        watcher = DirectoryWatcher(path: engine.discovery.projectsRoot.path) { [weak self] in
            Task { await self?.runDiscovery() }
        }

        pollTask = Task { [weak self] in
            #if DEBUG
            DebugLife.adjust("poll-loops", by: 1, note: "poll loop entered")
            defer { DebugLife.adjust("poll-loops", by: -1, note: "poll loop exited") }
            #endif
            await self?.initialSync()
            while !Task.isCancelled {
                guard let self else { return }
                await self.engine.refreshAll()
                self.rebuildRows()
                #if DEBUG
                self.logDebugTick()
                #endif
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    #if DEBUG
    /// Shakedown tick line: structural-invariant gauges + resident memory,
    /// emitted once per poll tick.
    private func logDebugTick() {
        let snap = DebugLife.snapshot()
        let mem = DebugLife.memoryBytes()
        DebugLife.event("tick live=\(engine.liveSessions.count)"
            + " liveObjs=\(snap["live-session-objects"] ?? 0)"
            + " pollLoops=\(snap["poll-loops"] ?? 0)"
            + " streams=\(snap["fsevents-streams"] ?? 0)"
            + " records=\(snap["store-records"] ?? -1)"
            + " storeWrites=\(snap["store-writes"] ?? 0)"
            + " stateMem=\(stateMemory.count)"
            + " notifKeys=\(NotificationManager.shared.firedKeys.count)"
            + " footprintMB=\(mem.footprint / 1_048_576)"
            + " rssMB=\(mem.resident / 1_048_576)")
    }
    #endif

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        watcher = nil
    }

    private func initialSync() async {
        pruneMissingWatchDirectories()
        await engine.reconcile()
        await pruneOrphanedRecords()
        await runDiscovery()
        if engine.settings.autoRestartOnLaunch {
            await autoRestartStoppedAndDead()
        }
    }

    /// Retention (launch only): a record whose transcript is gone and which has
    /// no live window cannot be resumed — `claude --resume` would have nothing
    /// to resume — so it is dropped instead of lingering as a dead Stopped row.
    private func pruneOrphanedRecords() async {
        let keep = Set(engine.liveSessions.values.map(\.sessionUUID).filter { !$0.isEmpty })
        let store = engine.store
        let discovery = engine.discovery
        await Task.detached {
            let index = discovery.transcriptIndex()
            // An empty index almost certainly means the projects root was
            // unreadable, not that every transcript vanished — pruning on it
            // would wipe every record. Skip; next launch retries.
            guard !index.isEmpty else { return }
            store.pruneRecords(withoutTranscriptIn: Set(index.keys), keeping: keep)
            // Retention on what survives: archived records inactive past the
            // age limit go, then the total is capped — the store must not
            // grow unbounded across months of sessions.
            store.applyRetention(transcriptMtimes: index.mapValues(\.modified), keeping: keep)
        }.value
    }

    /// Section 8: a watch directory that no longer exists is skipped on scan
    /// and removed from the settings list. Launch-time only, so a briefly
    /// unmounted volume isn't forgotten mid-session.
    private func pruneMissingWatchDirectories() {
        var settings = engine.settings
        let existing = settings.watchDirectories.filter {
            FileManager.default.fileExists(atPath: SessionDiscovery.expandTilde($0))
        }
        guard existing.count != settings.watchDirectories.count else { return }
        settings.watchDirectories = existing
        engine.updateSettings(settings)
    }

    // MARK: - Onboarding (flows 6.1 / 6.2)

    /// Called by the onboarding screen's "Start Scanning": persist the watch
    /// directories, mark onboarding done, arm notifications, start the engine,
    /// open the main window, and put up the import sheet if the scan found
    /// unmanaged sessions.
    func completeOnboarding(directories: [String]) {
        var settings = engine.settings
        settings.watchDirectories = directories
        settings.onboardingComplete = true
        engine.updateSettings(settings)
        NotificationManager.shared.requestPermission()
        Task {
            start()
            while !hasScanned {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            closeOnboarding?()
            openMainWindow?()
            presentImportSheetIfNeeded()
        }
    }

    /// First-run import sheet (5.4): only when the scan surfaced unmanaged
    /// sessions. Probes each candidate off-main for a live external process
    /// and recent transcript activity (the Working/Idle badge).
    func presentImportSheetIfNeeded() {
        let candidates = rows.filter { $0.state == .unmanaged && !$0.uuid.isEmpty }
        guard !candidates.isEmpty else { return }
        Task {
            let probed = await ImportFlowModel.probe(candidates: candidates,
                                                     transcriptIndex: transcriptIndex)
            guard !probed.isEmpty else { return }
            importFlow = ImportFlowModel(items: probed, model: self)
        }
    }

    // MARK: - Discovery

    private func runDiscovery() async {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let discovery = engine.discovery
        let store = engine.store
        let watchDirs = engine.settings.watchDirectories
        let metaCache = self.metaCache
        // Managed sessions' titles also come from their transcripts — snapshot
        // the uuids on the main actor before hopping off.
        let managedUUIDs = engine.liveSessions.values.map(\.sessionUUID).filter { !$0.isEmpty }
        let (projects, index, meta, loadedRecords) = await Task.detached {
            () -> ([DiscoveredProject], [String: DiscoveredSession],
                   [String: TranscriptMeta], [SessionRecord]) in
            let projects = discovery.discover(watchDirectories: watchDirs)
            let index = discovery.transcriptIndex()
            // Drop meta-cache entries for transcripts that no longer exist,
            // or the cache grows monotonically across session churn.
            metaCache.retain(paths: Set(index.values.map(\.transcriptPath)))
            let records = store.loadRecords()
            var wanted = Set(managedUUIDs)
            for project in projects {
                if let uuid = project.mostRecentSession?.uuid { wanted.insert(uuid) }
            }
            for record in records { wanted.insert(record.uuid) }
            var meta: [String: TranscriptMeta] = [:]
            for uuid in wanted {
                if let transcript = index[uuid] {
                    meta[uuid] = metaCache.meta(for: transcript)
                }
            }
            return (projects, index, meta, records)
        }.value
        guard generation == discoveryGeneration else { return } // superseded
        unmanagedProjects = projects
        transcriptIndex = index
        metaByUUID = meta
        records = loadedRecords
        if !hasScanned { hasScanned = true }
        rebuildRows()
    }

    /// Reload records + states after a mutating action so the UI reflects it
    /// immediately rather than on the next FSEvents/poll tick.
    private func refreshAfterMutation() async {
        let store = engine.store
        records = await Task.detached { store.loadRecords() }.value
        await engine.refreshAll()
        rebuildRows()
        await runDiscovery()
    }

    // MARK: - Rows

    /// Rebuild the immutable row models from engine state + records +
    /// discovery results. Precedence per project: a live managed window wins;
    /// a persisted record renders as Stopped (or in Archived); only a project
    /// with no window and no record at all is Unmanaged (docs/CCORN_SPEC.md
    /// section 4).
    private func rebuildRows() {
        var built: [SessionRow] = []
        var archived: [SessionRow] = []
        var managedPaths = Set<String>()
        var managedUUIDs = Set<String>()
        let recordUUIDs = Set(records.map(\.uuid))
        // Group membership for managed rows: their record is skipped below
        // (the live window is the row), so look its membership up by uuid.
        let groupsByUUID = Dictionary(records.map { ($0.uuid, $0.groupIDs) },
                                      uniquingKeysWith: { first, _ in first })
        let now = Date()

        var adoptedIds = Set<String>()
        for (windowId, live) in engine.liveSessions {
            let uuid = live.sessionUUID
            if !uuid.isEmpty { managedUUIDs.insert(uuid) }
            if live.adopted { adoptedIds.insert(windowId) }
            let meta = uuid.isEmpty ? nil : metaByUUID[uuid]
            // A managed row must always resolve a directory: the record path
            // (set at start/resume/reconcile), else the transcript's cwd.
            let path = live.record.path.isEmpty
                ? (meta?.cwd).map(SessionDiscovery.canonicalize) ?? ""
                : live.record.path
            if !path.isEmpty {
                managedPaths.insert(SessionDiscovery.canonicalize(path))
            }
            // Prefer the transcript mtime (real Claude activity) over the pane
            // hash-change time; fall back for sessions with no transcript yet.
            let lastActive = transcriptIndex[uuid]?.modified ?? live.lastHashChange
            built.append(SessionRow(
                id: windowId,
                kind: .managed(windowId: windowId),
                title: Self.displayTitle(explicit: live.record.title,
                                         aiTitle: meta?.title, path: path),
                uuid: uuid,
                path: path,
                state: live.state,
                remoteControlActive: live.remoteControlActive,
                rcGraceExpired: now.timeIntervalSince(live.startedAt) > 30,
                lastActive: lastActive,
                authNotice: live.authNotice,
                rcPlanNotice: live.rcPlanNotice,
                groupIDs: uuid.isEmpty ? [] : (groupsByUUID[uuid] ?? [])
            ))
        }

        // Persisted records with no live window: Stopped rows (or Archived).
        // A record whose uuid is currently managed is the same session — skip.
        for record in records where !managedUUIDs.contains(record.uuid) {
            let row = SessionRow(
                id: "record:\(record.uuid)",
                kind: .record,
                title: Self.displayTitle(explicit: record.title,
                                         aiTitle: metaByUUID[record.uuid]?.title,
                                         path: record.path),
                uuid: record.uuid,
                path: record.path,
                state: .stopped,
                remoteControlActive: false,
                archived: record.archived,
                lastActive: transcriptIndex[record.uuid]?.modified,
                groupIDs: record.groupIDs
            )
            if record.archived {
                archived.append(row)
            } else {
                built.append(row)
            }
        }

        for project in unmanagedProjects {
            guard let path = project.resolvedPath else { continue }
            guard !managedPaths.contains(path) else { continue }
            // Any session of this project that CCorn already knows — live or
            // recorded — means the project is represented; not unmanaged.
            guard !project.sessions.contains(where: {
                managedUUIDs.contains($0.uuid) || recordUUIDs.contains($0.uuid)
            }) else { continue }
            let uuid = project.mostRecentSession?.uuid ?? ""
            built.append(SessionRow(
                id: "unmanaged:\(project.encodedKey)",
                kind: .unmanaged,
                title: Self.displayTitle(explicit: "",
                                         aiTitle: uuid.isEmpty ? nil : metaByUUID[uuid]?.title,
                                         path: path),
                uuid: uuid,
                path: path,
                state: .unmanaged,
                remoteControlActive: false,
                lastActive: project.mostRecentSession?.modified
            ))
        }

        built.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        archived.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }

        emitStateTransitions(built, adoptedIds: adoptedIds)

        // Publish only on real change: the 3s tick must not re-render an
        // unchanged popover + main window for the lifetime of the app.
        if built != rows { rows = built }
        if archived != archivedRows { archivedRows = archived }
        if let selection,
           !built.contains(where: { $0.id == selection }),
           !archived.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if let renamingRowId,
           !built.contains(where: { $0.id == renamingRowId }),
           !archived.contains(where: { $0.id == renamingRowId }) {
            cancelRename()
        }
    }

    /// Notification edges (5.10): fire only when a watched session
    /// *transitions into* Waiting, Dead, or Sign-in required. Keyed by row id
    /// (the stable window id for managed rows — uuid binding mid-run must not
    /// break continuity). A session CCorn started this run gets a Running
    /// baseline, so a spawn that lands directly on a trust/permission/login
    /// prompt still notifies; an adopted (reconciled) or record row is first
    /// recorded silently — whatever state it is first seen in is not a
    /// transition CCorn watched. Also hosts the section-8 one-shot alerts.
    private func emitStateTransitions(_ rows: [SessionRow], adoptedIds: Set<String>) {
        for row in rows where row.kind != .unmanaged {
            presentRCPlanAlertIfNeeded(row)
            let baseline: SessionState? =
                (row.isManaged && !adoptedIds.contains(row.id)) ? .running : nil
            let previous = stateMemory[row.id] ?? baseline
            stateMemory[row.id] = row.state
            guard let previous, previous != row.state else { continue }
            if row.state == .needsAuth {
                if !presentAuthAlertIfNeeded(row) {
                    NotificationManager.shared.notify(sessionKey: row.id,
                                                      title: row.title,
                                                      state: row.state)
                }
            } else if row.state == .waiting || row.state == .dead {
                NotificationManager.shared.notify(sessionKey: row.id,
                                                  title: row.title,
                                                  state: row.state)
            }
        }
        // Drop memory for rows that no longer exist (killed windows, pruned
        // records): window ids are monotonic, so without this the map grows
        // for the lifetime of the app. A vanished row that ever returns is
        // re-observed silently first — exactly the adopted-row rule.
        if stateMemory.count > rows.count {
            let liveIds = Set(rows.map(\.id))
            stateMemory = stateMemory.filter { liveIds.contains($0.key) }
            authAlerted = authAlerted.filter { liveIds.contains($0) }
            rcPlanAlerted = rcPlanAlerted.filter { liveIds.contains($0) }
        }
    }

    // MARK: - Section-8 auth alerts

    /// "User not authenticated" (section 8): a login prompt right after a
    /// CCorn-initiated start gets a modal alert — direct feedback to the
    /// user's own action, leading with the CLI's error text. A session that
    /// drifts into the login screen later (token expiry in a set-and-forget
    /// background session) must NOT steal focus: it gets the notification +
    /// the row's key indicator instead. Returns true when the alert was shown.
    @discardableResult
    private func presentAuthAlertIfNeeded(_ row: SessionRow) -> Bool {
        guard row.isManaged, !row.rcGraceExpired,
              !authAlerted.contains(row.id) else { return false }
        authAlerted.insert(row.id)
        let content = Self.authAlertContent(notice: row.authNotice)
        // Deferred a turn: this runs inside rebuildRows on the poll path, and
        // the rows must publish before a modal can block the main actor.
        Task { Alerts.sheetOrModal(title: content.title, message: content.message) }
        return true
    }

    /// Section-8 copy: lead with the CLI's own error text when captured.
    static func authAlertContent(notice: String?) -> (title: String, message: String) {
        var lines = ["Run claude in this project and use /login (or claude auth login), and make sure ANTHROPIC_API_KEY is unset."]
        if let notice, !notice.isEmpty {
            lines.insert("Claude Code says: “\(notice)”", at: 0)
        }
        return ("Authenticate Claude Code first", lines.joined(separator: "\n\n"))
    }

    /// Remote-control plan restriction (section 8): the pane reported that
    /// remote control could not be enabled for plan/credential reasons. Once
    /// per session, same start-feedback gate as the auth alert.
    private func presentRCPlanAlertIfNeeded(_ row: SessionRow) {
        guard let notice = row.rcPlanNotice, row.isManaged, !row.rcGraceExpired,
              !rcPlanAlerted.contains(row.id) else { return }
        rcPlanAlerted.insert(row.id)
        Task {
            Alerts.sheetOrModal(
                title: "Remote Control isn't available on this account",
                message: "Claude Code says: “\(notice)”\n\nRemote Control is available on Pro, Max, Team, and Enterprise plans (Team/Enterprise need an admin to enable it); API keys and inference-only tokens are not supported.")
        }
    }

    /// Display-name chain: the title CCorn set explicitly (a real `--rc` title
    /// that syncs to claude.ai) > the transcript's ai-title (what
    /// `claude --resume` and claude.ai show for sessions CCorn didn't title) >
    /// the directory basename. Never a tmux window name — those track the
    /// foreground process.
    private static func displayTitle(explicit: String, aiTitle: String?, path: String) -> String {
        if !explicit.isEmpty { return explicit }
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        if !path.isEmpty, !basename.isEmpty { return basename }
        return "Session"
    }

    // MARK: - Read-only actions

    /// No per-session URL exists (RUNTIME_FINDINGS C1): open the claude.ai/code
    /// session list; the user finds the session by its title.
    func openInBrowser(_ row: SessionRow) {
        guard let url = URL(string: "https://claude.ai/code") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open Terminal attached to the session's tmux window (flow 6.5). Targets
    /// the stable `@N` window id — rename-proof, and verified to parse as an
    /// attach target on tmux 3.6.
    func openInTerminal(_ row: SessionRow) {
        guard let windowId = row.windowId else { return }
        let runner = engine.runner
        Task.detached {
            let attach = "tmux attach -t 'ccorn:\(windowId)'"
            let script = """
            tell application "Terminal"
                do script "\(attach)"
                activate
            end tell
            """
            runner.run("osascript", ["-e", script])
        }
    }

    func copySessionID(_ row: SessionRow) {
        guard !row.uuid.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.uuid, forType: .string)
    }

    // MARK: - New session (flow 6.3)

    func newSession() {
        closePopover?()
        // The popover is reachable before onboarding completes; the app is
        // not usable until a watch directory exists (5.3) — route there.
        guard !onboardingNeeded else {
            openMainWindow?()
            return
        }
        guard let directory = Alerts.pickFolder(prompt: "Start Session") else { return }
        let canonical = SessionDiscovery.canonicalize(directory)
        let aliveHere = rows.contains {
            $0.isManaged && $0.path == canonical && $0.state.isAliveState
        }
        if aliveHere {
            guard Alerts.confirm(title: "This directory already has an active session",
                                 message: "Start another session in \(canonical)?",
                                 action: "Start Anyway") else { return }
        }
        Task {
            let result = await engine.startNewSession(directory: directory)
            handleStartResult(result, verb: "start")
            await refreshAfterMutation()
        }
    }

    /// Empty-state "Add Directory": grow the watch list directly.
    func addWatchDirectory() {
        guard let directory = Alerts.pickFolder(prompt: "Watch Directory") else { return }
        var settings = engine.settings
        guard !settings.watchDirectories.contains(directory) else { return } // silently ignore dup
        settings.watchDirectories.append(directory)
        engine.updateSettings(settings)
        Task { await runDiscovery() }
    }

    /// Settings changed (watch dirs / threshold / toggles): persist + rescan.
    func applySettings(_ settings: CCornSettings) {
        engine.updateSettings(settings)
        Task { await runDiscovery() }
    }

    // MARK: - Kill (flow 6.6)

    func killSession(_ row: SessionRow) {
        guard let windowId = row.windowId else { return }
        guard Alerts.confirmKill(name: row.title) else { return }
        Task {
            await engine.killSession(windowId: windowId)
            await refreshAfterMutation()
        }
    }

    // MARK: - Restart (flow 6.7)

    func restartSession(_ row: SessionRow) {
        Task {
            guard !row.path.isEmpty,
                  FileManager.default.fileExists(atPath: row.path) else {
                Alerts.info(title: "The project directory no longer exists.")
                return
            }
            // The transcript must still exist or `claude --resume` has nothing
            // to resume (section 8: "Session ID not found in JSONL files").
            let discovery = engine.discovery
            let uuid = row.uuid
            let hasTranscript = await Task.detached {
                !uuid.isEmpty && discovery.transcriptIndex()[uuid] != nil
            }.value
            guard hasTranscript else {
                if Alerts.confirm(title: "Couldn't find session data.",
                                  message: "Start a new session in this directory instead?",
                                  action: "Start New Session") {
                    // Tear the dead window down first or it lingers next to
                    // the replacement as an orphaned Dead row.
                    if let windowId = row.windowId {
                        await engine.terminate(windowId: windowId)
                    }
                    let result = await engine.startNewSession(directory: row.path)
                    handleStartResult(result, verb: "start")
                    await refreshAfterMutation()
                }
                return
            }
            let result = await engine.restartSession(uuid: uuid,
                                                     directory: row.path,
                                                     replacingWindowId: row.windowId)
            handleStartResult(result, verb: "restart")
            await refreshAfterMutation()
        }
    }

    // MARK: - Archive / unarchive (flow 6.9)

    func archiveSession(_ row: SessionRow) {
        if row.state.isAliveState {
            guard Alerts.confirm(title: "This session is still running.",
                                 message: "Archive and stop it?",
                                 action: "Archive") else { return }
        }
        Task {
            await engine.archiveSession(uuid: row.uuid, windowId: row.windowId)
            await refreshAfterMutation()
        }
    }

    func unarchiveSession(_ row: SessionRow) {
        Task {
            await engine.unarchiveSession(uuid: row.uuid)
            await refreshAfterMutation()
        }
    }

    // MARK: - Import single unmanaged session (flow 6.10)

    func importSession(_ row: SessionRow) {
        guard !row.uuid.isEmpty, !row.path.isEmpty else { return }
        guard Alerts.confirm(
            title: "Import this session?",
            message: "CCorn will take over this session. Your existing terminal window will stop working.",
            action: "Import") else { return }
        Task {
            let result = await engine.importSession(uuid: row.uuid, directory: row.path)
            handleStartResult(result, verb: "import")
            await refreshAfterMutation()
        }
    }

    /// Import sheet dismissed (Skip for Now / Close).
    func importFlowFinished() {
        importFlow = nil
        Task { await refreshAfterMutation() }
    }

    /// The sequential import finished (sheet still up on "All done"): refresh
    /// rows behind the sheet so the main window already shows the imported
    /// sessions with correct dots.
    func importDidMutateSessions() {
        Task { await refreshAfterMutation() }
    }

    // MARK: - Rename (flow 6.8)

    func beginRename(_ row: SessionRow) {
        renamingRowId = row.id
        renameError = nil
        renameInFlight = false
    }

    func cancelRename() {
        renamingRowId = nil
        renameError = nil
        renameInFlight = false
    }

    /// Enter: empty or unchanged cancels; otherwise `/rename` + window rename +
    /// persist, with the inline duplicate-name error path (5.8).
    func commitRename(_ row: SessionRow, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != row.title else {
            cancelRename()
            return
        }
        renameInFlight = true
        renameError = nil
        Task {
            let result = await engine.renameSession(windowId: row.windowId,
                                                    uuid: row.uuid,
                                                    to: trimmed)
            renameInFlight = false
            switch result {
            case .ok:
                cancelRename()
                await refreshAfterMutation()
            case .failed:
                renameError = "That name is already taken"
            }
        }
    }

    // MARK: - Groups (docs/CCORN_SPEC.md 5.11)

    /// Rows for a group view: record-backed (never unmanaged), non-archived
    /// rows whose record carries the group id — same derivation family as
    /// `managedRows`/`archivedRows`, same shared sort. Archived members keep
    /// their membership but surface only in the Archived view.
    func groupRows(id: String) -> [SessionRow] {
        rows.filter { $0.kind != .unmanaged && $0.groupIDs.contains(id) }
    }

    /// Persist the (ordered) group definitions to settings and republish.
    private func saveGroups(_ updated: [SessionGroup]) {
        groups = updated
        var settings = engine.settings
        settings.groups = updated
        engine.updateSettings(settings)
    }

    @discardableResult
    func createGroup(named name: String) -> SessionGroup {
        let group = SessionGroup(name: name)
        saveGroups(groups + [group])
        return group
    }

    /// "+ New Group" in the sidebar: create with a placeholder name and open
    /// the inline editor on it (Books pattern). Escape or an empty commit
    /// removes the placeholder again.
    func beginNewGroup() {
        let group = createGroup(named: SessionGroup.defaultName(existing: groups))
        editingGroupId = group.id
        editingGroupIsNew = true
    }

    func beginGroupRename(_ id: String) {
        editingGroupId = id
        editingGroupIsNew = false
    }

    /// Enter in the inline editor: a real name commits; an empty name cancels
    /// (removing a just-created placeholder, reverting an existing group).
    func commitGroupName(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelGroupEdit()
            return
        }
        editingGroupId = nil
        editingGroupIsNew = false
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        var updated = groups
        updated[idx].name = trimmed
        saveGroups(updated)
    }

    /// Escape: a just-created placeholder group vanishes (it has no members
    /// yet); an existing group keeps its old name.
    func cancelGroupEdit() {
        if editingGroupIsNew, let id = editingGroupId {
            saveGroups(groups.filter { $0.id != id })
        }
        editingGroupId = nil
        editingGroupIsNew = false
    }

    /// Delete a group: the definition goes, every record's membership is
    /// cleared of the id — sessions themselves are NEVER deleted or archived.
    func deleteGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        guard Alerts.confirm(
            title: "Delete “\(group.name)”?",
            message: "Sessions in this group are not deleted; they just leave the group.",
            action: "Delete") else { return }
        performGroupDelete(id)
    }

    /// Confirmation-free core of deleteGroup (the debug channel calls this
    /// directly — modals cannot be scripted, same split as kill).
    func performGroupDelete(_ id: String) {
        saveGroups(groups.filter { $0.id != id })
        if sidebarNav == .group(id) { sidebarNav = .allSessions }
        if editingGroupId == id {
            editingGroupId = nil
            editingGroupIsNew = false
        }
        let store = engine.store
        Task {
            await Task.detached { store.removeGroupID(id) }.value
            await refreshAfterMutation()
        }
    }

    /// Toggle a session's membership (the Groups submenu checkmark items —
    /// one control adds, removes, and shows membership inline).
    func toggleGroupMembership(_ row: SessionRow, groupId: String) {
        var ids = row.groupIDs
        if ids.contains(groupId) {
            ids.removeAll { $0 == groupId }
        } else {
            ids.append(groupId)
        }
        setGroupIDs(ids, for: row)
    }

    /// Direct removal, surfaced in the menu while a group view is active.
    func removeFromGroup(_ row: SessionRow, groupId: String) {
        guard row.groupIDs.contains(groupId) else { return }
        setGroupIDs(row.groupIDs.filter { $0 != groupId }, for: row)
    }

    /// "New Group…" in a session's menu: create and assign in one step, then
    /// open the sidebar's inline editor for naming. Not flagged as new:
    /// escape keeps the group (it already has a member).
    func createGroupAndAssign(_ row: SessionRow) {
        guard SessionGroup.canAssign(uuid: row.uuid) else { return }
        let group = createGroup(named: SessionGroup.defaultName(existing: groups))
        setGroupIDs(row.groupIDs + [group.id], for: row)
        editingGroupId = group.id
        editingGroupIsNew = false
    }

    /// Membership writes merge into the record by uuid, exactly like the
    /// archived flag (created if absent; nil fields untouched — the title is
    /// deliberately not passed, or a derived display title would be promoted
    /// to an explicit one). Gated on a bound uuid: a brand-new session has
    /// none until its transcript binds.
    private func setGroupIDs(_ ids: [String], for row: SessionRow) {
        guard SessionGroup.canAssign(uuid: row.uuid) else { return }
        let store = engine.store
        let uuid = row.uuid
        let path = row.path.isEmpty ? nil : row.path
        Task {
            await Task.detached {
                store.mergeRecord(uuid: uuid, path: path, groupIDs: ids)
            }.value
            await refreshAfterMutation()
        }
    }

    // MARK: - Auto-restart on launch (flow 6.11)

    /// Sequentially restart every stopped/dead session: dead live windows
    /// first, then stopped records. Sessions whose directory or transcript is
    /// gone are skipped silently (they surface their alerts when restarted
    /// manually instead — a launch must not open a stack of modals).
    private func autoRestartStoppedAndDead() async {
        let discovery = engine.discovery
        let index = await Task.detached { discovery.transcriptIndex() }.value

        let dead = engine.liveSessions.filter { $0.value.state == .dead }
        for (windowId, live) in dead {
            let uuid = live.sessionUUID
            let path = live.record.path
            guard !uuid.isEmpty, index[uuid] != nil,
                  !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
            _ = await engine.restartSession(uuid: uuid, directory: path,
                                            replacingWindowId: windowId)
            rebuildRows()
        }

        let liveUUIDs = Set(engine.liveSessions.values.map(\.sessionUUID))
        for record in records where !record.archived && !liveUUIDs.contains(record.uuid) {
            guard index[record.uuid] != nil,
                  !record.path.isEmpty,
                  FileManager.default.fileExists(atPath: record.path) else { continue }
            _ = await engine.restartSession(uuid: record.uuid, directory: record.path)
            rebuildRows()
        }
        await refreshAfterMutation()
    }

    #if DEBUG
    /// Verification hook (DebugCommandChannel): reload records + rows after a
    /// scripted engine mutation, same path the real actions use.
    func debugRefresh() async {
        await refreshAfterMutation()
    }

    /// Screenshot staging (DebugCommandChannel `seed`): stop the live poll and
    /// FSEvents watcher, then replace the published rows wholesale with a
    /// curated set. Pure presentation — the engine, store, and tmux session
    /// are never touched, and nothing restarts the poll afterwards. Seeded
    /// groups replace only the PUBLISHED list; settings are not written.
    func debugSeed(rows: [SessionRow], archived: [SessionRow],
                   groups: [SessionGroup]? = nil) {
        stop()
        hasScanned = true
        self.rows = rows
        self.archivedRows = archived
        if let groups {
            self.groups = groups
        }
    }
    #endif

    // MARK: - Result handling

    private func handleStartResult(_ result: StartResult, verb: String) {
        switch result {
        case .started:
            break
        case .windowCreatedNoProcess:
            Alerts.info(title: "Claude Code didn't \(verb)",
                        message: "No claude process appeared. Make sure Claude Code is installed and authenticated (run `claude` in a terminal; use /login if prompted).")
        case let .failed(reason):
            Alerts.info(title: "Could not \(verb) the session", message: reason)
        }
    }
}
