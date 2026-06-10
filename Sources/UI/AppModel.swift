import AppKit
import Combine
import SwiftUI

/// UI-facing coordinator over the milestone-1 engine. Owns the 3s state poll,
/// the FSEvents-driven discovery refresh, and the row models both the popover
/// and the main window render. Read-only on engine data in milestone 2 — the
/// only actions are Open in Browser / Open in Terminal / Copy Session ID.
@MainActor
final class AppModel: ObservableObject {
    let engine: SessionEngine

    /// All rows, sorted by last active (most recent first).
    @Published private(set) var rows: [SessionRow] = []
    /// True once the first discovery pass has completed — gates the empty state
    /// ("watch directories have been scanned but no sessions found").
    @Published private(set) var hasScanned = false
    /// Main-window list selection (row id).
    @Published var selection: String?

    /// Set by the AppDelegate so popover/empty-state actions can reach the
    /// window layer without the model importing it.
    var openMainWindow: (() -> Void)?
    var closePopover: (() -> Void)?

    private var unmanagedProjects: [DiscoveredProject] = []
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

    init(engine: SessionEngine) {
        self.engine = engine
    }

    /// The popover header's aggregate dot: worst active state across all rows,
    /// nil (empty/outline dot) when no session has an active color.
    var aggregateState: SessionState? {
        SessionState.aggregate(rows.map(\.state))
    }

    // MARK: - Lifecycle

    /// Reconcile with existing tmux windows, run discovery, then poll states
    /// every 3 seconds. Discovery re-runs only on FSEvents from
    /// `~/.claude/projects/`, never on the poll.
    func start() {
        guard pollTask == nil else { return }

        watcher = DirectoryWatcher(path: engine.discovery.projectsRoot.path) { [weak self] in
            Task { await self?.runDiscovery() }
        }

        pollTask = Task { [weak self] in
            await self?.engine.reconcile()
            await self?.runDiscovery()
            while !Task.isCancelled {
                guard let self else { return }
                await self.engine.refreshAll()
                self.rebuildRows()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        watcher = nil
    }

    // MARK: - Discovery

    private func runDiscovery() async {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let discovery = engine.discovery
        let watchDirs = engine.settings.watchDirectories
        let metaCache = self.metaCache
        // Managed sessions' titles also come from their transcripts — snapshot
        // the uuids on the main actor before hopping off.
        let managedUUIDs = engine.liveSessions.values.map(\.sessionUUID).filter { !$0.isEmpty }
        let (projects, index, meta) = await Task.detached {
            () -> ([DiscoveredProject], [String: DiscoveredSession], [String: TranscriptMeta]) in
            let projects = discovery.discover(watchDirectories: watchDirs)
            let index = discovery.transcriptIndex()
            var wanted = Set(managedUUIDs)
            for project in projects {
                if let uuid = project.mostRecentSession?.uuid { wanted.insert(uuid) }
            }
            var meta: [String: TranscriptMeta] = [:]
            for uuid in wanted {
                if let transcript = index[uuid] {
                    meta[uuid] = metaCache.meta(for: transcript)
                }
            }
            return (projects, index, meta)
        }.value
        guard generation == discoveryGeneration else { return } // superseded
        unmanagedProjects = projects
        transcriptIndex = index
        metaByUUID = meta
        if !hasScanned { hasScanned = true }
        rebuildRows()
    }

    // MARK: - Rows

    /// Rebuild the immutable row models from engine state + discovery results.
    /// A discovered project is unmanaged only when no live window matches it by
    /// path or by session UUID (docs/CCORN_SPEC.md section 4, Unmanaged).
    private func rebuildRows() {
        var built: [SessionRow] = []
        var managedPaths = Set<String>()
        var managedUUIDs = Set<String>()

        for (windowId, live) in engine.liveSessions {
            let uuid = live.sessionUUID
            if !uuid.isEmpty { managedUUIDs.insert(uuid) }
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
                lastActive: lastActive
            ))
        }

        for project in unmanagedProjects {
            guard let path = project.resolvedPath else { continue }
            guard !managedPaths.contains(path) else { continue }
            guard !project.sessions.contains(where: { managedUUIDs.contains($0.uuid) }) else { continue }
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
        // Publish only on real change: the 3s tick must not re-render an
        // unchanged popover + main window for the lifetime of the app.
        if built != rows { rows = built }
        if let selection, !built.contains(where: { $0.id == selection }) {
            self.selection = nil
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

    // MARK: - Actions (milestone 2: read-only set)

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
}
