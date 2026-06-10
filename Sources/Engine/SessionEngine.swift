import Combine
import Foundation

/// Result of attempting to start/resume a session.
enum StartResult: Sendable {
    case started(windowId: String, pid: Int32)
    /// The window was created but no claude child appeared within the spawn
    /// timeout. The orphan window has already been killed; the id is purely
    /// informational.
    case windowCreatedNoProcess(windowId: String)
    case failed(String)
}

/// Top-level non-UI engine. Owns the tmux session, starts/resumes/terminates
/// Claude Code sessions, tracks live PIDs, and reconciles with existing tmux
/// windows on launch.
///
/// Concurrency model: the engine (and the `liveSessions` store) is main-actor
/// isolated and observable, so milestone-2 SwiftUI reads and the 3s poll
/// timer's writes can never race. All tmux/process/disk work runs in detached
/// tasks on value snapshots; results hop back to the main actor to be applied.
@MainActor
final class SessionEngine: ObservableObject {
    nonisolated let tmux = TmuxController()
    nonisolated let discovery = SessionDiscovery()
    nonisolated let detector = StateDetector()
    nonisolated let store = SessionStore()
    nonisolated let runner = CommandRunner.shared

    private(set) var settings: CCornSettings
    /// Keyed by tmux window id.
    @Published private(set) var liveSessions: [String: LiveSession] = [:]

    init(settings: CCornSettings? = nil) {
        self.settings = settings ?? SessionStore.shared.loadSettings()
    }

    // MARK: - Dependency checks

    struct Dependencies: Sendable {
        let tmuxPath: String?
        let claudePath: String?
        let brewPath: String?
        let claudeVersion: String?
        var tmuxInstalled: Bool { tmuxPath != nil }
        var claudeInstalled: Bool { claudePath != nil }
    }

    /// Blocking (spawns `which`/`claude --version`); call from a background task.
    nonisolated func checkDependencies() -> Dependencies {
        let tmuxPath = runner.which("tmux")
        let claudePath = runner.which("claude")
        let brewPath = runner.which("brew")
        var version: String?
        if claudePath != nil {
            let r = runner.run("claude", ["--version"])
            version = r.trimmedOut.split(separator: " ").first.map(String.init)
        }
        return Dependencies(tmuxPath: tmuxPath, claudePath: claudePath,
                            brewPath: brewPath, claudeVersion: version)
    }

    // MARK: - Start / resume

    /// Start a brand-new session in `directory`. The title defaults to the
    /// project folder name — the convention for CCorn-started sessions: it is
    /// passed as a REAL session title via `--rc "<title>"`, so it syncs to
    /// claude.ai/mobile and disambiguates two sessions in the same folder
    /// (M3's new-session UI may override it). The session UUID is not known
    /// until Claude lazily writes its transcript, so the @ccorn_id tag is bound
    /// later (during discovery/reconciliation). Returns the window id and the
    /// captured claude PID.
    func startNewSession(directory: String, title: String? = nil) async -> StartResult {
        let title = title ?? URL(fileURLWithPath: directory).lastPathComponent
        let tmux = self.tmux
        let result = await Task.detached { () -> StartResult in
            let session = tmux.ensureSession()
            guard session.ok else { return .failed("could not create tmux session") }
            let name = tmux.uniqueWindowName(from: title)
            guard let windowId = tmux.newWindow(name: name, cwd: directory) else {
                return .failed("could not create tmux window")
            }
            // A freshly created session comes with a bare default window; kill
            // it now that a real window exists, or it lingers as a never-ran-
            // claude "zsh" window.
            if let stray = session.strayDefaultWindowId {
                tmux.killWindow(windowId: stray)
            }
            // Title is the only remote handle (no per-session URL exists), so set it
            // at launch. `tmux send-keys` TYPES this string into the pane's
            // interactive shell, which then evaluates it — so the title must be POSIX
            // single-quoted. Double-quote escaping is insufficient: inside double
            // quotes zsh still performs `$(...)`, backtick, and `$VAR` expansion, so a
            // title like `$(rm -rf ~)` would execute. Single quotes make it inert.
            tmux.sendCommand(windowId: windowId, "claude --rc \(TmuxController.shellQuote(title))")
            return await Self.awaitClaudeChild(windowId: windowId, tmux: tmux)
        }.value

        if case let .started(windowId, pid) = result {
            // uuid stays "" — it is unknown until Claude lazily writes its
            // transcript, and is bound later via the @ccorn_id tag during
            // discovery/reconciliation. Title and path are known now, so keep
            // them on the live record rather than discarding them.
            let live = LiveSession(
                record: SessionRecord(uuid: "", path: directory, title: title),
                windowId: windowId,
                pid: pid,
                state: .running
            )
            liveSessions[windowId] = live
        }
        return result
    }

    /// Resume an existing session by UUID in its project directory. When no
    /// explicit title is given the record keeps an empty title (or its persisted
    /// one) — `claude --resume` retains the session's existing title, so the row
    /// falls back to the transcript's ai-title rather than a fabricated name.
    func resumeSession(uuid: String, directory: String, title: String? = nil) async -> StartResult {
        let tmux = self.tmux
        let store = self.store
        let windowName = title ?? URL(fileURLWithPath: directory).lastPathComponent
        // Preserve a persisted title/archived flag unless explicitly retitled.
        let record = await Task.detached { () -> SessionRecord in
            let existing = store.loadRecords().first { $0.uuid == uuid }
            return SessionRecord(uuid: uuid, path: directory,
                                 title: title ?? existing?.title ?? "",
                                 archived: existing?.archived ?? false)
        }.value
        let result = await Task.detached { () -> StartResult in
            let session = tmux.ensureSession()
            guard session.ok else { return .failed("could not create tmux session") }
            let name = tmux.uniqueWindowName(from: windowName)
            guard let windowId = tmux.newWindow(name: name, cwd: directory) else {
                return .failed("could not create tmux window")
            }
            if let stray = session.strayDefaultWindowId {
                tmux.killWindow(windowId: stray)
            }
            tmux.setCcornId(windowId: windowId, uuid: uuid)
            // Single-quoted for the same reason as the title in startNewSession: this
            // command is typed into and evaluated by the pane's interactive shell.
            tmux.sendCommand(windowId: windowId, "claude --resume \(TmuxController.shellQuote(uuid)) --rc")
            let outcome = await Self.awaitClaudeChild(windowId: windowId, tmux: tmux)
            if case .started = outcome {
                store.upsert(record)
            }
            return outcome
        }.value

        if case let .started(windowId, pid) = result {
            let live = LiveSession(
                record: record,
                windowId: windowId,
                ccornTag: uuid,
                pid: pid,
                state: .running
            )
            liveSessions[windowId] = live
        }
        return result
    }

    /// Poll for the claude child of the window's pane shell (up to 5s; node
    /// installs can be slow to spawn). On failure the orphan window is killed
    /// rather than left behind.
    private nonisolated static func awaitClaudeChild(windowId: String,
                                                     tmux: TmuxController) async -> StartResult {
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard let shellPID = tmux.panePID(windowId: windowId) else { continue }
            if let claudePID = ProcessControl.findClaude(belowShell: shellPID) {
                return .started(windowId: windowId, pid: claudePID)
            }
        }
        tmux.killWindow(windowId: windowId)
        return .windowCreatedNoProcess(windowId: windowId)
    }

    /// Find the UUID of the session running in `directory` by choosing the
    /// most-recently-modified transcript (filename == UUID). nil if none yet.
    /// Blocking (reads transcript heads); call from a background task.
    nonisolated func mostRecentUUID(inDirectory directory: String) -> String? {
        let target = SessionDiscovery.canonicalize(directory)
        let project = discovery.discoverAll().first {
            guard let p = $0.resolvedPath else { return false }
            return p == target
        }
        return project?.mostRecentSession?.uuid
    }

    // MARK: - Terminate

    /// Canonical termination routine: kill the window, then SIGTERM/SIGKILL the
    /// tracked PID if still alive. The store is updated immediately so the poll
    /// cycle never touches a session that is mid-kill.
    func terminate(windowId: String) async {
        let live = liveSessions[windowId]
        let pid = live?.pid
        live?.state = .stopped
        live?.pid = nil
        liveSessions[windowId] = nil

        let tmux = self.tmux
        await Task.detached {
            tmux.killWindow(windowId: windowId)
            if let pid {
                await ProcessControl.terminate(pid: pid)
            }
        }.value
    }

    /// Terminate an unmanaged process (no tmux window) directly.
    nonisolated func terminateUnmanaged(pid: Int32) async {
        await ProcessControl.terminate(pid: pid)
    }

    // MARK: - Discovery

    func discoverProjects() async -> [DiscoveredProject] {
        let discovery = self.discovery
        let watchDirs = settings.watchDirectories
        return await Task.detached {
            discovery.discover(watchDirectories: watchDirs)
        }.value
    }

    /// Blocking (reads transcript heads); call from a background task.
    nonisolated func discoverAllProjects() -> [DiscoveredProject] {
        discovery.discoverAll()
    }

    // MARK: - State refresh

    /// One refresh cycle over every live session — the 3s hot path. The projects
    /// root is enumerated exactly ONCE into a uuid -> transcript index (directory
    /// listings only, no transcript reads); each session then resolves its
    /// transcript with an O(1) lookup, and the bridge-session check inside
    /// `detect` is mtime-cached per session. All of it runs off-main; results
    /// are applied back on the main actor.
    func refreshAll(now: Date = Date()) async {
        await refresh(jobs: detectionJobs(), now: now)
    }

    /// Re-detect state for one live session.
    func refreshState(windowId: String, now: Date = Date()) async {
        await refresh(jobs: detectionJobs().filter { $0.windowId == windowId }, now: now)
    }

    private struct DetectionJob: Sendable {
        let windowId: String
        let uuid: String
        let input: DetectionInput
    }

    private func detectionJobs() -> [DetectionJob] {
        liveSessions.map { windowId, live in
            DetectionJob(windowId: windowId, uuid: live.sessionUUID, input: live.detectionInput())
        }
    }

    private func refresh(jobs: [DetectionJob], now: Date) async {
        guard !jobs.isEmpty else { return }
        let tmux = self.tmux
        let detector = self.detector
        let discovery = self.discovery
        let staleThreshold = settings.staleThresholdSeconds

        let results = await Task.detached { () -> [String: DetectionResult] in
            let index = discovery.transcriptIndex()
            var out: [String: DetectionResult] = [:]
            for job in jobs {
                let transcript = job.uuid.isEmpty ? nil : index[job.uuid]
                out[job.windowId] = detector.detect(input: job.input,
                                                    panes: tmux,
                                                    transcript: transcript,
                                                    staleThreshold: staleThreshold,
                                                    now: now)
            }
            return out
        }.value

        for (windowId, result) in results {
            // The session may have been terminated while the pass ran.
            liveSessions[windowId]?.apply(result)
        }
    }

    // MARK: - Launch reconciliation

    /// Rebuild live state from existing `ccorn` windows. Previous-run PIDs are
    /// meaningless, so the pid is re-derived from each pane shell; the @ccorn_id
    /// tag is re-read; state comes from a fresh capture. One transcript-index
    /// enumeration covers all windows. (docs/CCORN_SPEC.md "Launch Reconciliation".)
    ///
    /// Identity binding: when a window has no @ccorn_id tag but a live claude
    /// child, the child's registry file (`~/.claude/sessions/<pid>.json`)
    /// supplies the session UUID + cwd; the binding is written back to the
    /// window tag and persisted, so a later relaunch — when the process may be
    /// gone — still knows the session and its last directory. Windows that show
    /// no trace of ever running claude (e.g. the bare default window
    /// `tmux new-session` spawns) are not sessions and are skipped.
    @discardableResult
    func reconcile(now: Date = Date()) async -> [LiveSession] {
        let tmux = self.tmux
        let detector = self.detector
        let discovery = self.discovery
        let store = self.store
        let staleThreshold = settings.staleThresholdSeconds

        struct Reconciled: Sendable {
            let window: TmuxWindow
            let record: SessionRecord
            let result: DetectionResult
        }

        let reconciled = await Task.detached { () -> [Reconciled] in
            guard tmux.hasSession() else { return [] }
            let persisted = store.loadRecords()
            let index = discovery.transcriptIndex()
            return tmux.listWindows().compactMap { window -> Reconciled? in
                // Adopted windows get the same name-pinning as windows we
                // create: without it automatic-rename tracks the foreground
                // process and a dead claude pane reads as "zsh".
                tmux.disableRenaming(windowId: window.windowId)

                var uuid = window.ccornId ?? ""
                var claudePID: Int32?
                var registryCwd: String?
                if let shellPID = window.panePID {
                    claudePID = ProcessControl.findClaude(belowShell: shellPID)
                }
                if uuid.isEmpty, let pid = claudePID,
                   let info = ClaudeSessionRegistry.info(forPid: pid) {
                    uuid = info.sessionId
                    registryCwd = info.cwd
                    tmux.setCcornId(windowId: window.windowId, uuid: uuid)
                }

                // No claude identity, no claude process, no claude trace in the
                // pane: this window never ran claude — not a session.
                if uuid.isEmpty, claudePID == nil,
                   !detector.showsClaudeEvidence(pane: tmux.capturePane(windowId: window.windowId)) {
                    return nil
                }

                let known = persisted.first { !uuid.isEmpty && $0.uuid == uuid }
                // Title stays empty for unknown records — NEVER the live tmux
                // window name; the row falls back to ai-title/basename.
                let record = known ?? SessionRecord(
                    uuid: uuid,
                    path: Self.reconciledPath(uuid: uuid, registryCwd: registryCwd,
                                              index: index, panePath: window.panePath),
                    title: ""
                )
                if known == nil, !uuid.isEmpty {
                    store.upsert(record)
                }

                let input = DetectionInput(windowId: window.windowId, pid: claudePID)
                let result = detector.detect(input: input,
                                             panes: tmux,
                                             transcript: uuid.isEmpty ? nil : index[uuid],
                                             staleThreshold: staleThreshold,
                                             now: now)
                return Reconciled(window: window, record: record, result: result)
            }
        }.value

        liveSessions.removeAll()
        for item in reconciled {
            let live = LiveSession(record: item.record,
                                   windowId: item.window.windowId,
                                   ccornTag: item.record.uuid.isEmpty ? nil : item.record.uuid)
            live.apply(item.result)
            liveSessions[item.window.windowId] = live
        }
        return Array(liveSessions.values)
    }

    /// Last-known directory for an adopted window with no persisted record: the
    /// live claude's registry cwd, else the transcript's cwd, else the pane's
    /// working directory (which tracks the shell, so it is the weakest signal).
    private nonisolated static func reconciledPath(uuid: String,
                                                   registryCwd: String?,
                                                   index: [String: DiscoveredSession],
                                                   panePath: String?) -> String {
        if let registryCwd {
            return SessionDiscovery.canonicalize(registryCwd)
        }
        if !uuid.isEmpty, let transcript = index[uuid],
           let cwd = SessionDiscovery.firstCwd(inTranscript: transcript.transcriptPath) {
            return SessionDiscovery.canonicalize(cwd)
        }
        return panePath ?? ""
    }
}
