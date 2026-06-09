import Foundation

/// Result of attempting to start/resume a session.
enum StartResult {
    case started(windowId: String, pid: Int32)
    case windowCreatedNoProcess(windowId: String)   // window made, claude child never appeared
    case failed(String)
}

/// Top-level non-UI engine. Owns the tmux session, starts/resumes/terminates
/// Claude Code sessions, tracks live PIDs, and reconciles with existing tmux
/// windows on launch. UI layers (later milestones) observe `liveSessions`.
final class SessionEngine {
    let tmux = TmuxController()
    let discovery = SessionDiscovery()
    let detector = StateDetector()
    let store = SessionStore()
    let runner = CommandRunner.shared

    private(set) var settings: CCornSettings
    /// Keyed by tmux window id.
    private(set) var liveSessions: [String: LiveSession] = [:]

    init(settings: CCornSettings? = nil) {
        self.settings = settings ?? SessionStore.shared.loadSettings()
    }

    // MARK: - Dependency checks

    struct Dependencies {
        let tmuxPath: String?
        let claudePath: String?
        let brewPath: String?
        let claudeVersion: String?
        var tmuxInstalled: Bool { tmuxPath != nil }
        var claudeInstalled: Bool { claudePath != nil }
    }

    func checkDependencies() -> Dependencies {
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

    /// Start a brand-new session in `directory` with the given title. The session
    /// UUID is not known until Claude lazily writes its transcript, so the
    /// @ccorn_id tag is bound later (during discovery/reconciliation). Returns the
    /// window id and the captured claude PID.
    func startNewSession(directory: String, title: String) -> StartResult {
        guard tmux.ensureSession() else { return .failed("could not create tmux session") }
        let name = tmux.uniqueWindowName(from: title)
        guard let windowId = tmux.newWindow(name: name, cwd: directory) else {
            return .failed("could not create tmux window")
        }
        // Title is the only remote handle (no per-session URL exists), so set it
        // at launch via the name argument.
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        tmux.sendCommand(windowId: windowId, "claude --rc \"\(escapedTitle)\"")
        return finishStart(windowId: windowId)
    }

    /// Resume an existing session by UUID in its project directory.
    func resumeSession(uuid: String, directory: String, title: String?) -> StartResult {
        guard tmux.ensureSession() else { return .failed("could not create tmux session") }
        let name = tmux.uniqueWindowName(from: title ?? uuid)
        guard let windowId = tmux.newWindow(name: name, cwd: directory) else {
            return .failed("could not create tmux window")
        }
        tmux.setCcornId(windowId: windowId, uuid: uuid)
        tmux.sendCommand(windowId: windowId, "claude --resume \(uuid) --rc")
        let result = finishStart(windowId: windowId)
        if case .started = result {
            let record = SessionRecord(uuid: uuid, path: directory, title: title ?? uuid)
            store.upsert(record)
        }
        return result
    }

    /// Poll for the claude child of the window's pane shell (up to 5s) and bind a
    /// LiveSession on success.
    private func finishStart(windowId: String) -> StartResult {
        // Poll up to 5s; node installs can be slow to spawn.
        for _ in 0..<25 {
            usleep(200_000) // 200ms
            guard let shellPID = tmux.panePID(windowId: windowId) else { continue }
            if let claudePID = ProcessControl.findClaude(belowShell: shellPID) {
                let live = LiveSession(
                    record: SessionRecord(uuid: "", path: "", title: ""),
                    windowId: windowId,
                    pid: claudePID,
                    state: .running
                )
                liveSessions[windowId] = live
                return .started(windowId: windowId, pid: claudePID)
            }
        }
        return .windowCreatedNoProcess(windowId: windowId)
    }

    /// Find the UUID of the session running in `directory` by choosing the
    /// most-recently-modified transcript (filename == UUID). nil if none yet.
    func mostRecentUUID(inDirectory directory: String) -> String? {
        let target = SessionDiscovery.canonicalize(directory)
        let project = discovery.discoverAll().first {
            guard let p = $0.resolvedPath else { return false }
            return p == target
        }
        return project?.mostRecentSession?.uuid
    }

    // MARK: - Terminate

    /// Canonical termination routine: kill the window, then SIGTERM/SIGKILL the
    /// tracked PID if still alive. Run off the main thread (can block ~5s).
    func terminate(windowId: String) {
        let live = liveSessions[windowId]
        tmux.killWindow(windowId: windowId)
        if let pid = live?.pid {
            ProcessControl.terminate(pid: pid)
        }
        live?.state = .stopped
        live?.pid = nil
        liveSessions[windowId] = nil
    }

    /// Terminate an unmanaged process (no tmux window) directly.
    func terminateUnmanaged(pid: Int32) {
        ProcessControl.terminate(pid: pid)
    }

    // MARK: - Discovery

    func discoverProjects() -> [DiscoveredProject] {
        discovery.discover(watchDirectories: settings.watchDirectories)
    }

    func discoverAllProjects() -> [DiscoveredProject] {
        discovery.discoverAll()
    }

    // MARK: - State refresh

    /// Re-detect state for one live session, resolving its transcript for the RC
    /// bridge-session fallback.
    func refreshState(windowId: String, now: Date = Date()) {
        guard let live = liveSessions[windowId] else { return }
        let transcriptPath = transcriptPath(for: live)
        detector.detect(live: live, tmux: tmux,
                        transcriptPath: transcriptPath,
                        staleThreshold: settings.staleThresholdSeconds,
                        now: now)
    }

    func refreshAll(now: Date = Date()) {
        for windowId in liveSessions.keys {
            refreshState(windowId: windowId, now: now)
        }
    }

    private func transcriptPath(for live: LiveSession) -> String? {
        let uuid = live.ccornTag ?? live.record.uuid
        guard !uuid.isEmpty else { return nil }
        // Locate the transcript by UUID across discovered projects.
        for project in discovery.discoverAll() {
            if let s = project.sessions.first(where: { $0.uuid == uuid }) {
                return s.transcriptPath
            }
        }
        return nil
    }

    // MARK: - Launch reconciliation

    /// Rebuild live state from existing `ccorn` windows. Previous-run PIDs are
    /// meaningless, so re-derive each from the pane shell; re-read the @ccorn_id
    /// tag; re-detect state from a fresh capture. (docs/CCORN_SPEC.md "Launch
    /// Reconciliation".)
    @discardableResult
    func reconcile(now: Date = Date()) -> [LiveSession] {
        liveSessions.removeAll()
        guard tmux.hasSession() else { return [] }

        let persisted = store.loadRecords()
        for window in tmux.listWindows() {
            let claudePID = window.panePID.flatMap { ProcessControl.findClaude(belowShell: $0) }
            let uuid = window.ccornId ?? ""
            let record = persisted.first(where: { $0.uuid == uuid })
                ?? SessionRecord(uuid: uuid, path: "", title: window.name)
            let live = LiveSession(
                record: record,
                windowId: window.windowId,
                ccornTag: window.ccornId,
                pid: claudePID,
                state: claudePID == nil ? .dead : .running
            )
            liveSessions[window.windowId] = live
            refreshState(windowId: window.windowId, now: now)
        }
        return Array(liveSessions.values)
    }
}
