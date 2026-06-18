import AppKit
import Combine
import SwiftUI

/// Window-appearance override the user picks in Settings ▸ Appearance: follow
/// the system, or force the whole app light/dark. Mapped to the `NSAppearance`
/// handed to `NSApp.appearance` (nil follows the system). `String`-backed so it
/// persists in UserDefaults as a stable token; `CaseIterable` drives the picker.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    /// The override to assign to `NSApp.appearance`: nil follows the system, the
    /// named appearances force light/dark. Mirrors the debug `appearance` command
    /// (DebugCommandChannel) so scripted and user overrides resolve identically.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Picker label.
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// UI-facing coordinator over the engine. Owns the 3s state poll, the
/// FSEvents-driven discovery refresh, and the row models every screen renders.
/// Milestone 3: also owns the full action surface (new session, stop,
/// restart, archive, import, rename) plus onboarding completion, the
/// first-run import flow, state-transition notifications, and auto-restart.
@MainActor
final class AppModel: ObservableObject {
    let engine: SessionEngine

    /// All Sessions rows, sorted by last active (most recent first).
    @Published private(set) var rows: [SessionRow] = []
    /// Archived view rows, same sort.
    @Published private(set) var archivedRows: [SessionRow] = []
    /// True once the first discovery pass has completed; gates the empty state
    /// ("watch directories have been scanned but no sessions found").
    @Published private(set) var hasScanned = false
    /// Main-window list selection (row id).
    @Published var selection: String?
    /// Sidebar navigation (All Sessions / Archived), model-owned so actions
    /// (and verification) can switch views.
    @Published var sidebarNav: SidebarNav = .allSessions
    /// Main-window sidebar visibility, model-owned so the titlebar toggle,
    /// the View menu (⌘⌃S), and verification all drive the same state, and
    /// persisted so the choice survives relaunch. Recovery from a persisted
    /// hidden launch is the always-visible titlebar toggle, never amnesia.
    @Published var sidebarVisible: Bool {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarVisibleKey) }
    }
    private static let sidebarVisibleKey = "sidebarVisible"

    /// Window-appearance override (Settings ▸ Appearance): force the whole app
    /// light or dark, or follow the system. Model-owned + persisted like
    /// `sidebarVisible`, so the launch hook and the Settings picker drive one
    /// source of truth and the choice survives relaunch. The `didSet` applies it
    /// immediately via `NSApp.appearance` (see `applyAppearance`), which cascades
    /// to every window EXCEPT the menu-bar popover, deliberately fixed dark
    /// (PopoverPanel sets its own appearance).
    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
            applyAppearance()
        }
    }
    private static let appearanceModeKey = "appearanceMode"

    /// Hidden-until-⌘F name filter (docs/CCORN_SPEC.md 5.1). `searchActive`
    /// swaps the title-bar corn for a focused search field; `searchQuery`
    /// narrows the visible list by session name (case-insensitive substring),
    /// scoped to whichever sidebar view is shown. Both are model-owned so the
    /// ⌘F command, the title-bar field, and the list filter share one source of
    /// truth. Escape clears the query and lowers `searchActive`, restoring the
    /// corn. Not persisted: a freshly shown window always opens un-searched.
    @Published var searchActive = false
    @Published var searchQuery = ""

    /// Inline rename state (docs/CCORN_SPEC.md 5.8): the row being edited and
    /// the inline error shown under it ("That name is already taken").
    @Published var renamingRowId: String?
    @Published var renameError: String?
    /// A commit is in flight (the 3s pane error-watch); the field locks.
    @Published var renameInFlight = false

    /// Session uuids with a restart in flight; dedupes rapid clicks on a
    /// stopped row (restartSession), which would otherwise spawn duplicate
    /// windows in the gap before the next refresh re-derives the live window.
    private var restartingUUIDs: Set<String> = []

    /// Session uuids with an import (adopt) in flight; dedupes rapid clicks on
    /// an unmanaged row (importSession), which would otherwise kill + resume the
    /// same session twice and leave a duplicate window. Held across the
    /// wait-for-idle poll, so a second click is ignored until the first settles.
    private var importingUUIDs: Set<String> = []

    /// Session uuids with an archive in flight; held from the moment the user
    /// confirms until the post-mutation refresh lands. While set, `rebuildRows`
    /// treats the uuid as already-archived, so the gap between the kill (the
    /// window leaving `liveSessions`) and the persisted `archived` flag can't
    /// publish the session as a transient top-of-list Stopped row in All
    /// Sessions: the row simply leaves its current position and reappears in
    /// Archived. Cleared on every exit path (defer), so a failed or cancelled
    /// archive never strands the session invisible in both views.
    private var archivingUUIDs: Set<String> = []

    /// UUIDs whose Stop is in flight. Like `archivingUUIDs`, this spans the gap
    /// between the kill (the window leaving `liveSessions`) and the discovery
    /// refresh that drops the dead process from the cached `liveUnmanaged`.
    /// Without it, a poll/FSEvents rebuild in that gap still sees the just-killed
    /// process as a live registry candidate but no longer as managed, so it
    /// reclassifies the session as a live *unmanaged* row — a different list
    /// section — and the row leaves the managed list and animates back in as
    /// Stopped. Held, the session keeps rendering as its own Stopped record in
    /// place. Cleared on every exit path (defer).
    private var stoppingUUIDs: Set<String> = []

    /// User-defined groups (docs/CCORN_SPEC.md 5.11), mirrored from
    /// settings so the sidebar re-renders on every mutation. Definitions
    /// live in settings; membership lives on the session records.
    @Published private(set) var groups: [SessionGroup] = []
    /// Inline group-name editing in the sidebar; the session-rename
    /// pattern. `editingGroupIsNew` marks a group just created by
    /// "+ New Group": escape (or an empty commit) then removes it instead of
    /// reverting the name.
    @Published var editingGroupId: String?
    private var editingGroupIsNew = false

    /// Non-nil while the first-run import sheet is up (set after onboarding's
    /// scan when unmanaged sessions were found).
    @Published var importFlow: ImportFlowModel?

    /// Non-nil while the New Session sheet is up (flow 6.3). Presented on the
    /// main window via `.sheet(item:)`, the same hosting as the import sheet.
    @Published var newSessionFlow: NewSessionFlowModel?

    /// Surface visibility, published by the window controllers (the popover's
    /// show/close, the main window's occlusion changes). Both surfaces keep
    /// their SwiftUI trees alive while hidden, so the row marks gate their
    /// repeatForever motion on these via Theme's rowMotionEnabled environment
    /// key; a hidden tree otherwise re-renders every frame, forever.
    @Published var popoverOnScreen = false
    @Published var mainWindowOnScreen = false

    /// Set by the AppDelegate so popover/empty-state actions can reach the
    /// window layer without the model importing it.
    var openMainWindow: (() -> Void)?
    var closePopover: (() -> Void)?
    var closeOnboarding: (() -> Void)?
    /// Re-applies the "keep window in front" preference to the live main
    /// window after a settings change, without the model reaching into the
    /// window layer (wired by AppDelegate to MainWindowController).
    var applyWindowLevel: (() -> Void)?
    #if DEBUG
    /// Debug-only (screenshot staging): show the popover on command.
    var openPopover: (() -> Void)?
    #endif

    private var unmanagedProjects: [DiscoveredProject] = []
    /// Live external (non-CCorn) Claude sessions, registry-derived and scoped to
    /// the watch dirs on each discovery pass. Each becomes its own UUID-keyed
    /// discovered row, so two sessions sharing a directory never collapse into
    /// one flipping row (see DiscoveryMerge).
    private var liveUnmanaged: [UnmanagedClaudeFinder.Candidate] = []
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
    /// Last seen state per session (keyed by uuid, else row id), the edge
    /// detector behind Waiting/Dead notifications. First observation of a
    /// session records silently; only a real change can notify.
    private var stateMemory: [String: SessionState] = [:]
    /// Rows that already showed their one-shot section-8 sign-in alert, so a
    /// persisting login pane can't re-alert every poll tick. Pruned alongside
    /// `stateMemory`. (The remote-control plan modal is gated once per *account*
    /// by `settings.rcKnownUnavailable`, not per row; see
    /// `reconcileRCAccountCapability`.)
    private var authAlerted = Set<String>()

    init(engine: SessionEngine) {
        self.engine = engine
        self.groups = engine.settings.groups
        self.sidebarVisible =
            UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true
        self.appearanceMode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: Self.appearanceModeKey) ?? "")
            ?? .system
        // Not applied here: the initial assignment doesn't fire `didSet`, and
        // NSApp isn't ready this early; AppDelegate calls `applyAppearance` once
        // on launch.
    }

    /// Apply the persisted appearance override to the whole app. nil follows the
    /// system; `.aqua`/`.darkAqua` force light/dark. The central place appearance
    /// is applied: called once on launch (AppDelegate) and on every change (the
    /// `appearanceMode` didSet). The fixed-dark popover overrides this for itself
    /// (PopoverPanel.swift), so it stays dark under any forced mode.
    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    /// Toggle the main-window sidebar (titlebar button, View menu, ⌘⌃S).
    /// Animated so collapse/expand is a clean slide, never a sliver.
    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarVisible.toggle()
        }
    }

    /// Reveal the ⌘F name filter: show the title-bar field, which focuses
    /// itself (the corn/field swap is SwiftUI-observed off `searchActive`).
    /// Idempotent, so a second ⌘F while the field is already up is a harmless
    /// no-op rather than a reset.
    func beginSearch() {
        searchActive = true
    }

    /// Dismiss the filter (Escape, or a fresh window show): clear the query,
    /// hide the field, and restore the corn. Safe to call when not searching.
    func endSearch() {
        searchQuery = ""
        searchActive = false
    }

    /// The popover header's aggregate mark: worst presentation across all
    /// rows (same per-row resolution the lists use, so a broken-tier worst
    /// shows the warning symbol), nil (empty/outline dot) when no session has
    /// an active color.
    var aggregatePresentation: StatusPresentation? {
        StatusPresentation.aggregate(rows.map(\.presentation))
    }

    /// Sessions CCorn manages (live windows + stopped records); the primary
    /// content everywhere. Sorted by last active, like `rows`.
    var managedRows: [SessionRow] {
        rows.filter { $0.kind != .unmanaged }
    }

    /// Sessions discovered on the system but not managed; ambient, secondary.
    var unmanagedRows: [SessionRow] {
        rows.filter { $0.kind == .unmanaged }
    }

    var onboardingNeeded: Bool { !engine.settings.onboardingComplete }

    // MARK: - Lifecycle

    /// Reconcile with existing tmux windows, run discovery, auto-restart if
    /// enabled, then poll states on the adaptive cadence (`nextPollNanos`).
    /// Discovery re-runs only on FSEvents from `~/.claude/projects/`, never on
    /// the poll.
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
                // Pass the cached transcript index so the hot path never
                // re-walks the projects root; see refreshAll(index:).
                await self.engine.refreshAll(index: self.transcriptIndex)
                self.rebuildRows()
                #if DEBUG
                self.logDebugTick()
                #endif
                try? await Task.sleep(nanoseconds: self.nextPollNanos())
            }
        }
    }

    /// Adaptive poll cadence. The working->active flip's latency only matters
    /// when the user is actually looking at a list, so fast polling is gated on
    /// window visibility (the same on-screen signal that gates row motion):
    ///
    ///   - a session is Working AND a window is on screen -> 0.75s, so the flip
    ///     to active lands sub-second instead of riding the 3s tick;
    ///   - a window is on screen but nothing is Working -> 3s (keep the list
    ///     fresh enough to notice work *starting*);
    ///   - no window on screen but something is Working -> 5s, so the
    ///     working->waiting transition (the one that fires the needs-input
    ///     notification, our headline feature) is still caught promptly while
    ///     CCorn runs in the background;
    ///   - no window on screen and nothing is Working -> 30s, clawing back
    ///     wakeups when nobody is watching. An idle session cannot reach a
    ///     notified state without first Working (which pulls us back to the 5s
    ///     cadence), so slowing the fully-idle background case delays nothing
    ///     the user can perceive.
    private func nextPollNanos() -> UInt64 {
        let watching = popoverOnScreen || mainWindowOnScreen
        let anyWorking = engine.liveSessions.values.contains { $0.state == .working }
        if watching {
            return anyWorking ? 750_000_000 : 3_000_000_000
        }
        return anyWorking ? 5_000_000_000 : 30_000_000_000
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
    /// no live window cannot be resumed (`claude --resume` would have nothing
    /// to resume), so it is dropped instead of lingering as a dead Stopped row.
    private func pruneOrphanedRecords() async {
        let keep = Set(engine.liveSessions.values.map(\.sessionUUID).filter { !$0.isEmpty })
        let store = engine.store
        let discovery = engine.discovery
        await Task.detached {
            let index = discovery.transcriptIndex()
            // An empty index almost certainly means the projects root was
            // unreadable, not that every transcript vanished; pruning on it
            // would wipe every record. Skip; next launch retries.
            guard !index.isEmpty else { return }
            store.pruneRecords(withoutTranscriptIn: Set(index.keys), keeping: keep)
            // Retention on what survives: archived records inactive past the
            // age limit go, then the total is capped; the store must not
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
        // Managed sessions' titles also come from their transcripts; snapshot
        // the uuids on the main actor before hopping off.
        let managedUUIDs = engine.liveSessions.values.map(\.sessionUUID).filter { !$0.isEmpty }
        let (projects, live, index, meta, loadedRecords) = await Task.detached {
            () -> ([DiscoveredProject], [UnmanagedClaudeFinder.Candidate],
                   [String: DiscoveredSession], [String: TranscriptMeta], [SessionRecord]) in
            let projects = discovery.discover(watchDirectories: watchDirs)
            // Live external sessions, scoped to the watch dirs (registry cwds are
            // already canonical). This is the per-session liveness signal that
            // makes the discovered surface session-granular instead of
            // directory-granular.
            let watch = watchDirs
                .map { SessionDiscovery.canonicalize(SessionDiscovery.expandTilde($0)) }
                .filter { FileManager.default.fileExists(atPath: $0) }
            let live = UnmanagedClaudeFinder.registryCandidates().filter { candidate in
                watch.contains { SessionDiscovery.isPath(candidate.cwd, inside: $0) }
            }
            let index = discovery.transcriptIndex()
            // Drop meta-cache entries for transcripts that no longer exist,
            // or the cache grows monotonically across session churn.
            metaCache.retain(paths: Set(index.values.map(\.transcriptPath)))
            let records = store.loadRecords()
            var wanted = Set(managedUUIDs)
            for project in projects {
                if let uuid = project.mostRecentSession?.uuid { wanted.insert(uuid) }
            }
            for candidate in live {
                if let uuid = candidate.sessionId { wanted.insert(uuid) }
            }
            for record in records { wanted.insert(record.uuid) }
            var meta: [String: TranscriptMeta] = [:]
            for uuid in wanted {
                if let transcript = index[uuid] {
                    meta[uuid] = metaCache.meta(for: transcript)
                }
            }
            return (projects, live, index, meta, records)
        }.value
        guard generation == discoveryGeneration else { return } // superseded
        unmanagedProjects = projects
        liveUnmanaged = live
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

    /// Sort key for a Stopped/Archived record row. The list sorts by transcript
    /// mtime, but `claude`'s shutdown write bumps that mtime when CCorn stops a
    /// session, which would shoot the Stopped row to the top. Once a record
    /// carries a pinned pre-shutdown `lastActivity`, keep using it; a genuine
    /// later interaction (e.g. resumed in a terminal) pushes the on-disk mtime
    /// past the post-shutdown `activityBaselineMtime` and wins.
    ///
    /// The nil-baseline case must also yield the pin, not the raw mtime: stop
    /// persists `lastActivity` *before* `terminate` and the settled
    /// `activityBaselineMtime` only after, so there is a brief window where the
    /// reloaded record has the pin but no baseline yet — and the FSEvents the
    /// shutdown write fires drives a rebuild inside it. Returning the raw
    /// (already-bumped) mtime there is exactly what made the row jump to the top
    /// and then animate back once the baseline landed. A record with no pin at
    /// all (old records, never stopped under this build) still degrades to the
    /// raw mtime.
    private static func recordLastActive(_ record: SessionRecord, mtime: Date?) -> Date? {
        guard let pin = record.lastActivity else { return mtime }
        if let mtime, let baseline = record.activityBaselineMtime, mtime > baseline {
            return mtime   // genuine interaction after the stop
        }
        return pin
    }

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
        // Sessions the user removed from CCorn: skipped on every rebuild so an
        // untracked session never re-surfaces: neither as a Stopped/Archived
        // record row, a live external row, nor a dormant-directory summary,
        // even after the conversation is resumed from the terminal. Read live
        // from settings (updated the instant a removal commits), so this holds
        // on the immediate post-mutation rebuild too, before discovery re-runs.
        let ignored = Set(engine.settings.ignoredSessionUUIDs)
        // Group membership for managed rows: their record is skipped below
        // (the live window is the row), so look its membership up by uuid.
        let groupsByUUID = Dictionary(records.map { ($0.uuid, $0.groupIDs) },
                                      uniquingKeysWith: { first, _ in first })
        let now = Date()

        var adoptedIds = Set<String>()
        // windowId -> the terminal status-bar content for each live session,
        // built from the same resolved row fields the screens render, then
        // handed to the engine to push (diffed) into each window's tmux option.
        var statusBars: [String: String] = [:]
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
            let row = SessionRow(
                id: windowId,
                kind: .managed(windowId: windowId),
                title: Self.displayTitle(explicit: live.record.title,
                                         aiTitle: meta?.title, path: path),
                uuid: uuid,
                path: path,
                state: live.state,
                remoteControlActive: live.remoteControlActive,
                // A session CCorn started as local (launchConfig says so) is
                // never flagged "no remote"; adopted/reconciled rows carry no
                // config (nil) and stay remote-expected.
                remoteControlRequested: live.record.launchConfig?.remoteControl ?? true,
                bridgeSessionId: live.bridgeSessionId,
                rcGraceExpired: now.timeIntervalSince(live.startedAt) > 30,
                lastActive: lastActive,
                authNotice: live.authNotice,
                rcPlanNotice: live.rcPlanNotice,
                groupIDs: uuid.isEmpty ? [] : (groupsByUUID[uuid] ?? []),
                // The runtime pane signal (covers mid-session escalation and
                // adopted sessions), OR a launch posture that starts in active
                // bypass. allowBypass alone does NOT count; it only arms bypass.
                isBypass: live.bypassActive
                    || live.record.launchConfig?.permissionMode == .bypass
            )
            built.append(row)
            // Terminal status bar for this session's tmux window, from the same
            // resolved row fields so it can never disagree with the GUI.
            statusBars[windowId] = StatusBarFormat.windowStatus(
                title: row.title,
                state: row.state,
                permissionMode: live.record.launchConfig?.permissionMode,
                isBypass: row.isBypass,
                remoteControlRequested: row.remoteControlRequested,
                remoteControlActive: row.remoteControlActive,
                rcGraceExpired: row.rcGraceExpired,
                idleSeconds: lastActive.map { now.timeIntervalSince($0) })
        }
        engine.syncStatusBars(statusBars)

        // Discovered (unmanaged) surface, resolved session-granular: live
        // external sessions become individual UUID-keyed rows; fully-dormant
        // directories collapse to one summary row. A running session outranks a
        // stale Stopped record for the same UUID.
        let discovered = DiscoveryMerge.resolve(
            projects: unmanagedProjects,
            liveCandidates: liveUnmanaged,
            managedUUIDs: managedUUIDs,
            managedPaths: managedPaths,
            recordUUIDs: recordUUIDs)

        // A Stop/Archive in flight: keep rendering the session as its own
        // (stopped/archived) record, never as a live-unmanaged row, for the
        // whole kill→refresh window even while the stale `liveUnmanaged` still
        // lists the just-killed process (see `stoppingUUIDs`/`archivingUUIDs`).
        let inFlightKill = stoppingUUIDs.union(archivingUUIDs)

        // Persisted records with no live window: Stopped rows (or Archived). A
        // record whose uuid is currently managed (or running externally right
        // now) is the same session, surfaced elsewhere; skip it here — unless a
        // kill is in flight, where the "running externally" reading is the stale
        // discovery signal for the very process we just killed.
        for record in records
        where !managedUUIDs.contains(record.uuid)
            && (!discovered.liveUUIDs.contains(record.uuid)
                || inFlightKill.contains(record.uuid))
            && !ignored.contains(record.uuid) {
            // An archive in flight counts as already-archived even before its
            // flag persists: during the kill's SIGTERM wait the window has left
            // liveSessions but the store still reads archived == false, and
            // without this the record would surface as a transient Stopped row
            // at the top of All Sessions before the flag lands (see
            // `archivingUUIDs`).
            let isArchived = record.archived || archivingUUIDs.contains(record.uuid)
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
                // Carry the launched posture so a stopped local session keeps
                // its "Local" tag (and stays excluded from no-remote).
                remoteControlRequested: record.launchConfig?.remoteControl ?? true,
                archived: isArchived,
                lastActive: Self.recordLastActive(
                    record, mtime: transcriptIndex[record.uuid]?.modified),
                groupIDs: record.groupIDs
            )
            if isArchived {
                archived.append(row)
            } else {
                built.append(row)
            }
        }

        // Live external sessions: one stable row each, keyed by UUID. Two
        // sessions sharing a directory are two distinct rows: no directory
        // collapse, no most-recent flip. A removed (ignored) UUID stays hidden
        // even once its conversation is resumed externally.
        for session in discovered.live
        where !ignored.contains(session.uuid)
            && !inFlightKill.contains(session.uuid) {
            built.append(SessionRow(
                id: "unmanaged:session:\(session.uuid)",
                kind: .unmanaged,
                title: Self.displayTitle(explicit: "",
                                         aiTitle: metaByUUID[session.uuid]?.title,
                                         path: session.path),
                uuid: session.uuid,
                path: session.path,
                state: .unmanaged,
                remoteControlActive: false,
                lastActive: transcriptIndex[session.uuid]?.modified
            ))
        }

        // Fully-dormant directories: one summary row each (the most-recent
        // session as representative). Stable; no live process is writing them.
        let projectsByKey = Dictionary(unmanagedProjects.map { ($0.encodedKey, $0) },
                                       uniquingKeysWith: { first, _ in first })
        for key in discovered.dormantDirKeys {
            guard let project = projectsByKey[key],
                  let path = project.resolvedPath else { continue }
            let uuid = project.mostRecentSession?.uuid ?? ""
            // Once a removed session's record is gone, its directory would
            // otherwise re-collapse to a dormant summary keyed by that same
            // UUID; skip it so the removal stays sticky.
            if ignored.contains(uuid) { continue }
            built.append(SessionRow(
                id: "unmanaged:dir:\(project.encodedKey)",
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
    /// (the stable window id for managed rows; uuid binding mid-run must not
    /// break continuity). A session CCorn started this run gets a Running
    /// baseline, so a spawn that lands directly on a trust/permission/login
    /// prompt still notifies; an adopted (reconciled) or record row is first
    /// recorded silently; whatever state it is first seen in is not a
    /// transition CCorn watched. Also hosts the section-8 one-shot alerts.
    private func emitStateTransitions(_ rows: [SessionRow], adoptedIds: Set<String>) {
        reconcileRCAccountCapability()
        for row in rows where row.kind != .unmanaged {
            let baseline: SessionState? =
                (row.isManaged && !adoptedIds.contains(row.id)) ? .running : nil
            let previous = stateMemory[row.id] ?? baseline
            stateMemory[row.id] = row.state
            guard let previous, previous != row.state else { continue }
            if row.state == .needsAuth {
                if !presentAuthAlertIfNeeded(row) {
                    NotificationManager.shared.notify(sessionKey: row.id,
                                                      title: row.title,
                                                      state: row.state,
                                                      bridgeSessionId: row.bridgeSessionId)
                }
            } else if row.state == .waiting || row.state == .dead {
                NotificationManager.shared.notify(sessionKey: row.id,
                                                  title: row.title,
                                                  state: row.state,
                                                  bridgeSessionId: row.bridgeSessionId)
            }
        }
        // Drop memory for rows that no longer exist (killed windows, pruned
        // records): window ids are monotonic, so without this the map grows
        // for the lifetime of the app. A vanished row that ever returns is
        // re-observed silently first, exactly the adopted-row rule.
        if stateMemory.count > rows.count {
            let liveIds = Set(rows.map(\.id))
            stateMemory = stateMemory.filter { liveIds.contains($0.key) }
            authAlerted = authAlerted.filter { liveIds.contains($0) }
        }
    }

    // MARK: - Section-8 auth alerts

    /// "User not authenticated" (section 8): a login prompt right after a
    /// CCorn-initiated start gets a modal alert: direct feedback to the
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
        var lines = ["Run claude in this project and use /login; make sure ANTHROPIC_API_KEY is unset."]
        if let notice, !notice.isEmpty {
            lines.insert("Claude Code says: “\(notice)”", at: 0)
        }
        return ("Authenticate Claude Code first", lines.joined(separator: "\n\n"))
    }

    /// Remote-control account capability (section 8). CCorn launches with `--rc`
    /// by default, so an account that genuinely cannot use remote control would
    /// otherwise fail (and re-alert) on every session. This reconciles the
    /// learned `settings.rcKnownUnavailable` flag against the live sessions each
    /// poll:
    ///
    ///  - RC active on *any* managed session proves the account is capable:
    ///    clear a prior verdict, which lets the user's stored remote/local
    ///    preference drive `effectiveDefaultConfig` again. Not grace-gated: RC
    ///    can link at any time, and this is what makes the flag reversible (the
    ///    user can re-opt a session into remote; once it connects, the lock
    ///    lifts).
    ///  - Otherwise the first *definitive* account/plan failure within a
    ///    session's start grace earns the verdict: set the flag so
    ///    `effectiveDefaultConfig` forces local (preference untouched) and later
    ///    sessions stop passing `--rc`, and show the plan modal, but only
    ///    once per account (the flag gates it), so already-running peers that
    ///    also failed don't re-fire it. A *transient* failure never reaches here
    ///    (its kind is `.transient`); it surfaces only as the row's soft
    ///    No-remote signal and may reconnect on its own.
    private func reconcileRCAccountCapability() {
        let sessions = engine.liveSessions.values
        let now = Date()

        if sessions.contains(where: { $0.remoteControlActive }) {
            if engine.settings.rcKnownUnavailable {
                var updated = engine.settings
                updated.rcKnownUnavailable = false
                engine.updateSettings(updated)
            }
            return
        }

        guard !engine.settings.rcKnownUnavailable,
              let failed = sessions.first(where: {
                  $0.rcFailureKind == .definitive
                      && !$0.remoteControlActive
                      && now.timeIntervalSince($0.startedAt) <= 30
              })
        else { return }

        let notice = failed.rcPlanNotice
        var updated = engine.settings
        updated.rcKnownUnavailable = true
        engine.updateSettings(updated)
        // Deferred a turn: this runs inside rebuildRows on the poll path, and
        // the rows must publish before a modal can block the main actor.
        Task {
            Alerts.sheetOrModal(
                title: "Remote Control isn't available on this account",
                message: Self.rcPlanAlertMessage(notice: notice))
        }
    }

    /// Section-8 plan-modal copy: lead with the CLI's own line when captured,
    /// then the plan requirements, then what CCorn now does (fall back to local,
    /// reversibly).
    static func rcPlanAlertMessage(notice: String?) -> String {
        var lines = [
            "Remote Control needs a Pro, Max, Team, or Enterprise plan.",
            "New sessions start locally, but you can still pick Remote; CCorn switches back once one connects.",
        ]
        if let notice, !notice.isEmpty {
            lines.insert("Claude Code says: “\(notice)”", at: 0)
        }
        return lines.joined(separator: "\n\n")
    }

    /// Display-name chain: the title CCorn set explicitly (a real `--rc` title
    /// that syncs to claude.ai) > the transcript's ai-title (what
    /// `claude --resume` and claude.ai show for sessions CCorn didn't title) >
    /// the directory basename. Never a tmux window name; those track the
    /// foreground process.
    private static func displayTitle(explicit: String, aiTitle: String?, path: String) -> String {
        if !explicit.isEmpty { return explicit }
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        if !path.isEmpty, !basename.isEmpty { return basename }
        return "Session"
    }

    // MARK: - Read-only actions

    /// The row-click handoff (flow 6.4): popover single-click and main-window
    /// double-click both land here and route via `SessionRow.openAction` (the
    /// pure, unit-tested decision). The explicit, RC-gated "Open in Browser" /
    /// "Open in Terminal" menu items remain the way to force either destination.
    func openSession(_ row: SessionRow) {
        switch row.openAction(clickAction: engine.settings.clickAction) {
        case .terminal: openInTerminal(row)
        case .browser: openInBrowser(row)
        case .restartThenAttach: restartSession(row, attachInTerminal: true)
        case .adoptThenAttach: importSession(row, attachInTerminal: true)
        }
    }

    /// Open the session in the browser. When the remote-control bridge handle
    /// is known, deep-link straight to the session
    /// (`claude.ai/code/<session_…>`, verified to equal the URL Claude Code
    /// prints); otherwise fall back to the claude.ai/code list, where the user
    /// finds the session by its title. The handle is a positive-only signal
    /// (the registry file can lag a live bridge), so the portal fallback is
    /// normal, not an error.
    func openInBrowser(_ row: SessionRow) {
        NSWorkspace.shared.open(Self.browserURL(bridgeSessionId: row.bridgeSessionId))
    }

    /// The claude.ai destination for a remote-control bridge handle: the
    /// per-session deep link when the handle is present and usable, else the
    /// claude.ai/code portal. Pure and `nonisolated` so the notification-tap
    /// handler (which runs off the main actor) builds the identical URL.
    nonisolated static func browserURL(bridgeSessionId: String?) -> URL {
        if let id = bridgeSessionId,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "https://claude.ai/code/\(encoded)") {
            return url
        }
        return URL(string: "https://claude.ai/code")!
    }

    /// Open Terminal attached to the session's tmux window (flow 6.5). Targets
    /// the stable `@N` window id, rename-proof, and verified to parse as an
    /// attach target on tmux 3.6.
    func openInTerminal(_ row: SessionRow) {
        guard let windowId = row.windowId else { return }
        attachTerminal(windowId: windowId, title: row.title)
    }

    /// Open a Terminal window attached to a tmux window id. Shared by the
    /// direct attach (live row) and the restart-then-attach path (stopped row,
    /// where the id is only known once the resume returns a started window).
    /// Attaches through a per-terminal grouped "view" session, NOT the shared
    /// `ccorn` session directly: current window and active pane are session
    /// level, so two terminals on one session mirror each other's window
    /// switching and share keystrokes. A grouped view gives each terminal its
    /// own current window + active pane. See `TmuxController.attachViewCommand`,
    /// which builds the command and honors the debug socket+session overrides so
    /// a shakedown attach lands on the isolated server, not the user's real one.
    private func attachTerminal(windowId: String, title: String? = nil) {
        let runner = engine.runner
        let tmux = engine.tmux
        let mouse = engine.settings.mouseMode
        Task.detached {
            // One terminal per session: if a terminal is already open for this
            // window (a live `ccorn-view-<id>` client), raise and focus it
            // instead of stacking a second window on the session. The lookup is
            // live tmux state, so a terminal the user has since closed leaves no
            // client and we fall through to opening a fresh one. A restart/import
            // attaches to a *new* window id with no view yet, so it also opens
            // fresh; no special-casing needed.
            if let tty = tmux.viewClientTTY(forWindowId: windowId),
               AppModel.raiseTerminal(tty: tty, runner: runner) {
                return
            }
            let attach = tmux.attachViewCommand(windowId: windowId, mouseMode: mouse)
            // Title the fresh tab with the session's chosen name. Without a custom
            // title Terminal labels the window after the command it ran (the long
            // grouped-attach string), so set the same name the rest of CCorn shows.
            // `do script` returns the new tab; its `custom title` overrides both
            // Terminal's command-line default and any later tmux title escape. Only
            // the fresh-open path needs it: the raise path above reuses a tab that
            // was titled when it first opened. The title is user data → AppleScript-
            // quoted; empty/absent falls back to Terminal's default (no title line).
            let titleLine: String
            if let title, !title.isEmpty {
                titleLine = "\n    set custom title of newTab to \(TmuxController.appleScriptQuote(title))"
            } else {
                titleLine = ""
            }
            let script = """
            tell application "Terminal"
                set newTab to do script "\(attach)"\(titleLine)
                activate
            end tell
            """
            runner.run("osascript", ["-e", script])
        }
    }

    /// Raise + focus the Terminal window whose tab tty matches (the one already
    /// open for this session); returns whether it was found. The recipe is
    /// load-bearing and verified live: resolve the window id first and address
    /// `window id <id>`: setting `frontmost`/`index` on the `repeat`-loop window
    /// reference silently no-ops when other Terminal windows are open, so it
    /// surfaces the wrong window. `set index … to 1` is what reorders it to the
    /// front (`set frontmost` alone does not). A false return (no Terminal tab
    /// carries this tty; the user closed it after the tmux query) tells the
    /// caller to open a fresh window instead. `tty` is `/dev/ttysNN`, so it is
    /// safe to interpolate. `nonisolated static` so it runs on the detached task
    /// without hopping to the main actor (it touches no AppModel state).
    nonisolated private static func raiseTerminal(tty: String, runner: CommandRunner) -> Bool {
        let script = """
        tell application "Terminal"
            set theId to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set theId to id of w
                        exit repeat
                    end if
                end repeat
                if theId is not missing value then exit repeat
            end repeat
            if theId is missing value then return "notfound"
            if miniaturized of window id theId then set miniaturized of window id theId to false
            set index of window id theId to 1
            set frontmost of window id theId to true
            activate
        end tell
        return "raised"
        """
        return runner.run("osascript", ["-e", script]).trimmedOut == "raised"
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
        // not usable until a watch directory exists (5.3); route there.
        guard !onboardingNeeded else {
            openMainWindow?()
            return
        }
        guard let directory = Alerts.pickFolder(prompt: "Choose Folder") else { return }
        let canonical = SessionDiscovery.canonicalize(directory)
        // Multiple sessions per directory is a normal, expected workflow; no
        // blocking "already has an active session" confirm. The sheet surfaces a
        // passive count of any sessions already alive here (activeSessionCount);
        // Start Session proceeds directly.
        //
        // The name + launch-flag override are gathered in the New Session sheet,
        // seeded from the global default (inherit → override). The sheet attaches
        // to the main window, so make sure it is open (from the popover it may not
        // be) before presenting.
        openMainWindow?()
        newSessionFlow = NewSessionFlowModel(directory: canonical,
                                             defaultConfig: engine.settings.effectiveDefaultConfig,
                                             model: self)
    }

    /// Count of managed sessions already alive in `directory` (a canonical
    /// path). Drives the New Session sheet's passive heads-up line; it is
    /// awareness only, never a gate; multiple sessions per directory is normal.
    func activeSessionCount(in directory: String) -> Int {
        rows.filter { $0.isManaged && $0.path == directory && $0.state.isAliveState }.count
    }

    /// New Session sheet committed (flow 6.3): dismiss it, then start the session
    /// with the chosen title + launch config. A blank title falls through to
    /// Claude's AI session title (it keeps updating); a typed name sticks.
    func startConfiguredSession(directory: String, title: String?, config: SessionLaunchConfig) {
        newSessionFlow = nil
        Task {
            let result = await engine.startNewSession(directory: directory, title: title, config: config)
            handleStartResult(result, verb: "start")
            await refreshAfterMutation()
        }
    }

    /// New Session sheet cancelled.
    func dismissNewSession() {
        newSessionFlow = nil
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
    /// applyWindowLevel covers the "keep window in front" toggle taking effect
    /// immediately on the live window; applyMouseMode pushes the scroll-wheel
    /// preference onto the running `ccorn` session so it takes effect at once
    /// for existing sessions (both no-ops for the other settings).
    func applySettings(_ settings: CCornSettings) {
        engine.updateSettings(settings)
        applyWindowLevel?()
        engine.applyMouseMode()
        Task { await runDiscovery() }
    }

    // MARK: - Stop (flow 6.6)

    /// Stop a managed session: confirm, then run the engine-side kill
    /// (`engine.killSession`: SIGKILL the process and tmux window) and persist
    /// a Stopped record so the row survives as Stopped, restartable. The UI
    /// verb is "Stop" because the outcome is a parked, recoverable session, not
    /// a deleted one; the engine keeps the literal "kill" name for the
    /// mechanism it performs.
    func stopSession(_ row: SessionRow) {
        guard let windowId = row.windowId else { return }
        guard Alerts.confirmStop(name: row.title) else { return }
        // Pin the row to its Stopped record for the whole kill→refresh window so
        // it never flickers through a live-unmanaged row (see `stoppingUUIDs`).
        // An empty (still-binding) uuid simply skips the guard, like archive.
        let uuid = row.uuid
        if !uuid.isEmpty { stoppingUUIDs.insert(uuid) }
        Task {
            defer { if !uuid.isEmpty { stoppingUUIDs.remove(uuid) } }
            await engine.killSession(windowId: windowId)
            await refreshAfterMutation()
        }
    }

    // MARK: - Restart (flow 6.7)

    /// Restart a stopped/dead session (flow 6.7). `attachInTerminal` is set by
    /// the row-click handoff (openSession) when the click action is Terminal:
    /// a stopped row has no window to attach to, so it is resumed first and the
    /// fresh window opened in Terminal. The context-menu "Restart Session"
    /// leaves it false; restart only, no terminal.
    func restartSession(_ row: SessionRow, attachInTerminal: Bool = false) {
        let uuid = row.uuid
        // Dedupe rapid clicks: the row keeps showing no window until the next
        // refresh, so a second click would otherwise spawn a second window.
        guard restartingUUIDs.insert(uuid).inserted else { return }
        Task {
            defer { restartingUUIDs.remove(uuid) }
            guard !row.path.isEmpty,
                  FileManager.default.fileExists(atPath: row.path) else {
                Alerts.info(title: "The project directory no longer exists.")
                return
            }
            // The transcript must still exist or `claude --resume` has nothing
            // to resume (section 8: "Session ID not found in JSONL files").
            let discovery = engine.discovery
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
                    if attachInTerminal { attachIfStarted(result) }
                    await refreshAfterMutation()
                }
                return
            }
            let result = await engine.restartSession(uuid: uuid,
                                                     directory: row.path,
                                                     replacingWindowId: row.windowId)
            handleStartResult(result, verb: "restart")
            if attachInTerminal { attachIfStarted(result, title: row.title) }
            await refreshAfterMutation()
        }
    }

    /// Attach Terminal to a just-started window (the restart-then-attach tail
    /// of openSession). Only `.started` carries a live window;
    /// `.windowCreatedNoProcess`/`.failed` surface through handleStartResult.
    /// `title` names the fresh Terminal tab (the resumed/imported session's
    /// chosen name); nil when a brand-new session was started in place, which
    /// has no chosen name yet.
    private func attachIfStarted(_ result: StartResult, title: String? = nil) {
        if case let .started(windowId, _) = result {
            attachTerminal(windowId: windowId, title: title)
        }
    }

    // MARK: - Archive / unarchive (flow 6.9)

    func archiveSession(_ row: SessionRow) {
        if row.state.isAliveState {
            guard Alerts.confirm(title: "This session is still running.",
                                 message: "Archive and stop it?",
                                 action: "Archive") else { return }
        }
        // Arm the transient-suppression guard only after the user confirms, and
        // clear it on every exit path: rebuildRows routes this uuid to Archived
        // for the whole kill→flag→refresh window, so All Sessions never sees the
        // intermediate Stopped row. A bound uuid is required for the guard to
        // match a record; an empty (still-binding) uuid simply skips it.
        let uuid = row.uuid
        archivingUUIDs.insert(uuid)
        Task {
            defer { archivingUUIDs.remove(uuid) }
            await engine.archiveSession(uuid: uuid, windowId: row.windowId)
            await refreshAfterMutation()
        }
    }

    func unarchiveSession(_ row: SessionRow) {
        Task {
            await engine.unarchiveSession(uuid: row.uuid)
            await refreshAfterMutation()
        }
    }

    // MARK: - Remove from CCorn (untrack)

    /// "Remove from CCorn": stop tracking this session entirely. A light,
    /// reassuring confirm (this is not destructive: the conversation is
    /// untouched), then one mutation in the engine: stop any live window, drop
    /// the record from both All Sessions and Archived, and add the UUID to the
    /// ignore-list so discovery never re-surfaces it. CCorn never touches the
    /// Claude transcript on disk; the user can still resume it with
    /// `claude --resume` from the terminal. Offered everywhere Archive is (live
    /// and dead rows), on archived rows, and on unmanaged rows the user wants to
    /// stop seeing.
    func removeFromCCorn(_ row: SessionRow) {
        // isAliveState covers a session whose claude process is still up
        // (running/working/waiting/needsAuth/stale); only those need the
        // "stop it first" wording. Dead/stopped/unmanaged just leave the list.
        let lead = row.state.isAliveState
            ? "This stops the session and removes it from your list. "
            : "This removes the session from your list. "
        guard Alerts.confirm(
            title: "Remove “\(row.title)” from CCorn?",
            message: lead + "Your conversation stays on disk and can be resumed anytime.",
            action: "Remove") else { return }
        let uuid = row.uuid
        let windowId = row.windowId
        Task {
            await engine.removeFromCCorn(uuid: uuid, windowId: windowId)
            await refreshAfterMutation()
        }
    }

    // MARK: - Import single unmanaged session (flow 6.10)

    /// Adopt an unmanaged session: take it over (SIGTERM the external claude →
    /// resume under CCorn). `attachInTerminal`, set by the row-click handoff
    /// (openSession) and the unmanaged menu's "Open in Terminal", opens the
    /// fresh managed window in Terminal once it exists. If Claude is mid-task we
    /// offer to wait it out first, so the takeover doesn't cut off active work
    /// (same guard as the first-run import sheet, flow 6.2).
    func importSession(_ row: SessionRow, attachInTerminal: Bool = false) {
        guard !row.uuid.isEmpty, !row.path.isEmpty else { return }
        let uuid = row.uuid
        // Dedupe rapid clicks: the row stays Unmanaged until the next refresh,
        // so a second click would otherwise kick off a second kill + resume.
        guard !importingUUIDs.contains(uuid) else { return }
        guard Alerts.confirmDestructive(
            title: "Take over this session?",
            message: "Your existing terminal session will stop, but no work is lost. CCorn resumes the conversation where it left off.",
            action: "Take Over") else { return }
        importingUUIDs.insert(uuid)
        let path = row.path
        Task {
            defer { importingUUIDs.remove(uuid) }
            // Wait for idle: if Claude is mid-task, hold off (polling) until the
            // session goes quiet, unless the user chooses to import anyway.
            if await engine.isExternalSessionWorking(uuid: uuid, directory: path) {
                let wait = Alerts.choice(
                    title: "Claude is mid-task in \(row.title)",
                    message: "Taking over now may interrupt active work.",
                    primary: "Wait for Idle",
                    secondary: "Take Over Anyway")
                if wait {
                    while await engine.isExternalSessionWorking(uuid: uuid, directory: path) {
                        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                    }
                }
            }
            let result = await engine.importSession(uuid: uuid, directory: path)
            handleStartResult(result, verb: "import")
            if attachInTerminal { attachIfStarted(result, title: row.title) }
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
    /// rows whose record carries the group id, same derivation family as
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
    /// cleared of the id; sessions themselves are NEVER deleted or archived.
    func deleteGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        guard Alerts.confirm(
            title: "Delete “\(group.name)”?",
            message: "Sessions in this group are not deleted; they just leave the group.",
            action: "Delete") else { return }
        performGroupDelete(id)
    }

    /// Confirmation-free core of deleteGroup (the debug channel calls this
    /// directly: modals cannot be scripted, same split as kill).
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

    /// Toggle a session's membership (the Groups submenu checkmark items:
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
    /// archived flag (created if absent; nil fields untouched: the title is
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
    /// manually instead: a launch must not open a stack of modals).
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
    /// curated set. Pure presentation: the engine, store, and tmux session
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
        case let .windowCreatedNoProcess(_, pane):
            // No child appeared, but the pane may say why. A signed-out first
            // session prints the login prompt and exits before any child shows,
            // so mine the captured pane for that signal (same recognition the
            // root/sudo fatal line uses) and lead with the sign-in fix rather
            // than implying Claude Code may not be installed.
            if let notice = engine.detector.authNotice(pane: pane) {
                let content = Self.authAlertContent(notice: notice)
                Alerts.info(title: content.title, message: content.message)
            } else {
                Alerts.info(title: "Claude Code didn't \(verb)",
                            message: "No claude process started. Either Claude Code isn't installed, or it's installed but not signed in. In a terminal, run “claude” to confirm it launches, then “/login” to sign in, and try again.")
            }
        case let .failed(reason):
            Alerts.info(title: "Could not \(verb) the session", message: reason)
        }
    }
}
