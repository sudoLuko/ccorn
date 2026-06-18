import Combine
import Foundation

/// Result of attempting to start/resume a session.
enum StartResult: Sendable {
    case started(windowId: String, pid: Int32)
    /// The window was created but no claude child appeared within the spawn
    /// timeout. The orphan window has already been killed; the id is purely
    /// informational. The final captured pane is carried so the failure alert
    /// can mine it for a more specific cause (e.g. a signed-out login prompt)
    /// instead of always blaming a missing install.
    case windowCreatedNoProcess(windowId: String, pane: String)
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

    @Published private(set) var settings: CCornSettings
    /// Keyed by tmux window id.
    @Published private(set) var liveSessions: [String: LiveSession] = [:]

    init(settings: CCornSettings? = nil) {
        self.settings = settings ?? SessionStore.shared.loadSettings()
    }

    /// Apply + persist new settings. The poll picks up the stale threshold on
    /// its next tick; re-running discovery for new watch dirs is the caller's
    /// concern (AppModel).
    func updateSettings(_ newSettings: CCornSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        let store = self.store
        Task.detached { store.saveSettings(newSettings) }
    }

    /// Push the current mouse-mode preference onto the live `ccorn` session so a
    /// Settings toggle takes effect immediately for already-running sessions
    /// (ensureSession only re-applies it on the next start/resume). Scoped to
    /// the session, never the tmux global; see `TmuxController.setMouseMode`.
    /// No-op when the session does not exist yet; the first start/resume creates
    /// it with the current value.
    func applyMouseMode() {
        let tmux = self.tmux
        let enabled = settings.mouseMode
        Task.detached {
            guard tmux.hasSession() else { return }
            tmux.setMouseMode(enabled)
        }
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
    /// project folder name, the convention for CCorn-started sessions: it is
    /// passed as a REAL session title via `--rc "<title>"`, so it syncs to
    /// claude.ai/mobile and disambiguates two sessions in the same folder
    /// (M3's new-session UI may override it). The session UUID is bound right
    /// here via the claude child's registry file and the record is persisted
    /// immediately: the `--rc` title exists nowhere locally (runtime findings
    /// F2), so a record that survives relaunch is the only thing keeping the
    /// displayed name in sync with what claude.ai/mobile shows. Returns the
    /// window id and the captured claude PID.
    func startNewSession(directory: String, title userTitle: String? = nil,
                         config: SessionLaunchConfig? = nil) async -> StartResult {
        // `label` names the tmux window and the `--rc` handle, which both need a
        // non-empty string. The persisted title is the user's chosen name, or
        // empty so the row falls through to Claude's AI title (as resume does):
        // persisting the basename here would pin every session to its folder
        // name and shadow the AI title forever.
        let label = userTitle ?? URL(fileURLWithPath: directory).lastPathComponent
        let storedTitle = userTitle ?? ""
        // A new session inherits the user's configured default unless the New
        // Session sheet passed an explicit per-session override. `effective…`,
        // not the raw default, so a known-RC-unavailable account still launches
        // local even on this no-override path (e.g. the "start new here" retry).
        let cfg = config ?? settings.effectiveDefaultConfig
        let mouse = settings.mouseMode
        let tmux = self.tmux
        let store = self.store

        struct Launch: Sendable {
            let result: StartResult
            let uuid: String?
        }

        let launch = await Task.detached { () -> Launch in
            let session = tmux.ensureSession(mouseMode: mouse)
            guard session.ok else {
                return Launch(result: .failed(Self.tmuxSessionFailureMessage(stderr: session.stderr)), uuid: nil)
            }
            let name = tmux.uniqueWindowName(from: label)
            guard let windowId = tmux.newWindow(name: name, cwd: directory) else {
                return Launch(result: .failed("could not create tmux window"), uuid: nil)
            }
            // A freshly created session comes with a bare default window; kill
            // it now that a real window exists, or it lingers as a never-ran-
            // claude "zsh" window.
            if let stray = session.strayDefaultWindowId {
                tmux.killWindow(windowId: stray)
            }
            // Title is the remote handle the user finds the session by when the
            // per-session deep link isn't available (the registry bridge id can
            // lag a live bridge), so set it at launch. `tmux send-keys` TYPES
            // this string into the pane's interactive shell, which then
            // evaluates it; so the title must be POSIX
            // single-quoted. Double-quote escaping is insufficient: inside double
            // quotes zsh still performs `$(...)`, backtick, and `$VAR` expansion, so a
            // title like `$(rm -rf ~)` would execute. Single quotes make it inert.
            tmux.sendCommand(windowId: windowId,
                             Self.claudeCommand(base: Self.claudeBase(remoteControl: cfg.remoteControl,
                                                                      newTitle: label),
                                                config: cfg))
            let outcome = await Self.awaitClaudeChild(windowId: windowId, tmux: tmux)
            guard case let .started(_, pid) = outcome else {
                return Launch(result: outcome, uuid: nil)
            }
            // Bind + persist now. The registry file is written by the claude
            // process itself right at session start (verified, F3), but give it
            // a moment to appear after the spawn.
            var uuid: String?
            for _ in 0..<10 {
                if let info = ClaudeSessionRegistry.info(forPid: pid) {
                    uuid = info.sessionId
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
            if let uuid {
                tmux.setCcornId(windowId: windowId, uuid: uuid)
                store.upsert(SessionRecord(uuid: uuid, path: directory, title: storedTitle,
                                           launchConfig: cfg))
            }
            // No uuid (registry never appeared): fall back to the old behavior:
            // reconcile binds it on the next launch, though the title is then
            // only as durable as this process.
            return Launch(result: outcome, uuid: uuid)
        }.value

        if case let .started(windowId, pid) = launch.result {
            let live = LiveSession(
                record: SessionRecord(uuid: launch.uuid ?? "", path: directory,
                                      title: storedTitle, launchConfig: cfg),
                windowId: windowId,
                ccornTag: launch.uuid,
                pid: pid,
                state: .running
            )
            liveSessions[windowId] = live
        }
        return launch.result
    }

    /// Resume an existing session by UUID in its project directory. When no
    /// explicit title is given the record keeps an empty title (or its persisted
    /// one); `claude --resume` retains the session's existing title, so the row
    /// falls back to the transcript's ai-title rather than a fabricated name.
    func resumeSession(uuid: String, directory: String, title: String? = nil,
                       config: SessionLaunchConfig? = nil) async -> StartResult {
        let tmux = self.tmux
        let store = self.store
        let mouse = settings.mouseMode
        let windowName = title ?? URL(fileURLWithPath: directory).lastPathComponent
        // `config` is the launch posture to re-apply (the flags do NOT survive
        // --resume): restart passes the session's stored config; adopt/import
        // pass nil for a plain resume. Preserve a persisted title/archived flag
        // unless explicitly retitled, and carry over groupIDs + the stored
        // config; `upsert` replaces the whole record, so anything not re-set
        // here would be dropped.
        let record = await Task.detached { () -> SessionRecord in
            let existing = store.loadRecords().first { $0.uuid == uuid }
            return SessionRecord(uuid: uuid, path: directory,
                                 title: title ?? existing?.title ?? "",
                                 archived: existing?.archived ?? false,
                                 groupIDs: existing?.groupIDs ?? [],
                                 launchConfig: config ?? existing?.launchConfig)
        }.value
        let result = await Task.detached { () -> StartResult in
            let session = tmux.ensureSession(mouseMode: mouse)
            guard session.ok else { return .failed(Self.tmuxSessionFailureMessage(stderr: session.stderr)) }
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
            // A session created as local resumes local (its stored config says
            // so); adopt/import pass nil config → resume remote, as before.
            tmux.sendCommand(windowId: windowId,
                             Self.claudeCommand(base: Self.claudeBase(remoteControl: config?.remoteControl ?? true,
                                                                      resumeUUID: uuid),
                                                config: config))
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

    /// The base `claude` invocation (before the config's flag tokens) for a new
    /// or resumed session. `--rc` (and, for a new session, the title it carries
    /// as the remote handle) appears ONLY when `remoteControl` is true; a local
    /// session omits it entirely, so no bridge ever comes up. `resumeUUID` set =
    /// restart (`--resume <uuid>`); otherwise a new session with `newTitle`. The
    /// uuid/title are single-quoted because the whole string is typed into and
    /// evaluated by the pane's interactive shell. Internal (not private) so the
    /// local-vs-remote branch is unit-testable.
    nonisolated static func claudeBase(remoteControl: Bool,
                                       newTitle: String = "",
                                       resumeUUID: String? = nil) -> String {
        if let resumeUUID {
            let base = "claude --resume \(TmuxController.shellQuote(resumeUUID))"
            return remoteControl ? "\(base) --rc" : base
        }
        return remoteControl ? "claude --rc \(TmuxController.shellQuote(newTitle))" : "claude"
    }

    /// Assemble the `claude` command typed into a pane: the base invocation
    /// (from `claudeBase`, already quoted) plus the launch config's flag tokens,
    /// each token shell-quoted because the whole string is evaluated by the
    /// pane's interactive shell. Quoting a bare `--flag` is harmless; quoting a
    /// value (model alias, path, extra-arg) is what keeps shell metacharacters
    /// in it inert. nil config → base only.
    private nonisolated static func claudeCommand(base: String,
                                                  config: SessionLaunchConfig?) -> String {
        let flags = (config?.claudeFlagTokens() ?? []).map(TmuxController.shellQuote)
        return ([base] + flags).joined(separator: " ")
    }

    /// Message for a failed `tmux new-session`. Surfaces tmux's own stderr (so
    /// the user sees the real reason, not a bare "could not create") and a
    /// concrete recovery step: a stale tmux server left by another install or an
    /// earlier crash is the usual first-run cause, and `tmux kill-server` clears
    /// it. Plain prose, since this lands in an alert body, not a terminal.
    private nonisolated static func tmuxSessionFailureMessage(stderr: String?) -> String {
        var lines = ["Could not create the tmux session that runs Claude Code."]
        let detail = stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty {
            lines.append("tmux reported: \(detail)")
        }
        lines.append("This usually means a stale tmux server is running. Open a terminal, run “tmux kill-server”, then try again.")
        return lines.joined(separator: "\n\n")
    }

    /// Poll for the claude child of the window's pane shell (up to 5s; node
    /// installs can be slow to spawn). On failure the orphan window is killed
    /// rather than left behind.
    private nonisolated static func awaitClaudeChild(windowId: String,
                                                     tmux: TmuxController) async -> StartResult {
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard let shellPID = tmux.panePID(windowId: windowId) else { continue }
            if case .found(let claudePID) = ProcessControl.findClaude(belowShell: shellPID) {
                return .started(windowId: windowId, pid: claudePID)
            }
        }
        // No child: claude may have exited immediately on a fatal launch error
        // (e.g. bypass refused under root). Capture the pane before tearing the
        // window down so the alert can lead with the CLI's own line instead of
        // the generic "no process appeared".
        let finalPane = tmux.capturePane(windowId: windowId)
        tmux.killWindow(windowId: windowId)
        if let fatal = StateDetector().launchFatalError(pane: finalPane) {
            return .failed(fatal)
        }
        return .windowCreatedNoProcess(windowId: windowId, pane: finalPane)
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

    /// Kill a managed session (flow 6.6): learn its identity if still unknown
    /// (last chance: the registry file goes stale once the process dies), and
    /// persist the record so the row survives as Stopped, then run the
    /// canonical kill-window → SIGTERM → SIGKILL routine. Returns the session
    /// UUID ("" when it never became known; nothing persists, the row simply
    /// disappears: there is nothing to resume).
    ///
    /// `archived` folds the archived flag into that same identity-persisting
    /// merge (default false: Stop leaves the flag untouched). Setting it here,
    /// before `terminate` drops the window from `liveSessions`, means the store
    /// already reads archived by the time any rebuild can observe the gone
    /// window, so the record routes straight to Archived instead of flashing as
    /// a Stopped row in All Sessions (flow 6.9).
    @discardableResult
    func killSession(windowId: String, archived: Bool = false) async -> String {
        var uuid = ""
        if let live = liveSessions[windowId] {
            uuid = live.sessionUUID
            let pid = live.pid
            if uuid.isEmpty, let pid {
                uuid = await Task.detached {
                    ClaudeSessionRegistry.info(forPid: pid)?.sessionId ?? ""
                }.value
            }
            if !uuid.isEmpty {
                let record = live.record
                let store = self.store
                let frozen = uuid
                await Task.detached {
                    store.mergeRecord(uuid: frozen,
                                      path: record.path.isEmpty ? nil : record.path,
                                      title: record.title.isEmpty ? nil : record.title,
                                      archived: archived ? true : nil)
                }.value
            }
        }
        await terminate(windowId: windowId)
        return uuid
    }

    /// Restart a dead or stopped session (flow 6.7): tear down any window still
    /// holding the session first; a crashed claude leaves its window and shell
    /// behind, and resuming next to it would orphan a dead window plus create a
    /// `-2` duplicate. Then `claude --resume <uuid> --rc` in a fresh window.
    func restartSession(uuid: String, directory: String,
                        replacingWindowId: String? = nil) async -> StartResult {
        var doomed = Set<String>()
        if let replacingWindowId { doomed.insert(replacingWindowId) }
        for (windowId, live) in liveSessions where live.sessionUUID == uuid {
            doomed.insert(windowId)
        }
        for windowId in doomed { liveSessions[windowId] = nil }
        let tmux = self.tmux
        let store = self.store
        // The session's stored launch flags, to re-apply on the fresh process
        // (they don't survive --resume). nil for sessions CCorn didn't start;
        // those resume plainly, not under the global default.
        let storedConfig = await Task.detached { () -> SessionLaunchConfig? in
            store.loadRecords().first { $0.uuid == uuid }?.launchConfig
        }.value
        await Task.detached {
            for windowId in doomed { tmux.killWindow(windowId: windowId) }
            // A window tagged with this uuid from a previous run, unknown to
            // liveSessions (e.g. reconcile skipped it mid-kill).
            if let lingering = tmux.window(forCcornId: uuid) {
                tmux.killWindow(windowId: lingering.windowId)
            }
        }.value
        return await resumeSession(uuid: uuid, directory: directory, config: storedConfig)
    }

    /// Import an unmanaged session (flows 6.2 / 6.10): SIGTERM → 5s → SIGKILL
    /// the external claude process running the session (if any: matched by
    /// session UUID via the pid registry, else by working directory), then
    /// resume it under CCorn with remote control on.
    func importSession(uuid: String, directory: String) async -> StartResult {
        await Task.detached {
            if let external = UnmanagedClaudeFinder.find(inDirectory: directory,
                                                         sessionId: uuid) {
                await ProcessControl.terminate(pid: external.pid)
            }
        }.value
        return await resumeSession(uuid: uuid, directory: directory)
    }

    /// True if an unmanaged session is mid-task right now: a live external
    /// `claude` process for this session AND transcript writes in the last two
    /// minutes. The import wait-for-idle guard (flows 6.2 / 6.10) polls this so
    /// the takeover's SIGTERM → resume doesn't cut off an in-flight turn. A
    /// quiet transcript or a gone process reads as idle (nothing to interrupt).
    func isExternalSessionWorking(uuid: String, directory: String) async -> Bool {
        let discovery = self.discovery
        return await Task.detached {
            guard UnmanagedClaudeFinder.find(inDirectory: directory, sessionId: uuid) != nil else {
                return false
            }
            guard let transcript = discovery.transcriptIndex()[uuid] else { return false }
            return Date().timeIntervalSince(transcript.modified) < 120
        }.value
    }

    // MARK: - Rename

    enum RenameResult: Sendable, Equatable {
        case ok
        case failed(String)
    }

    /// Rename (flow 6.8). A live session gets Claude's native `/rename`, typed
    /// into the TUI, NOT shell-quoted: the pane's foreground process is the
    /// claude TUI, not a shell, so quotes would become part of the name. The
    /// pane is then watched ~3s for an error render (e.g. a duplicate name);
    /// only new text that wasn't visible before the rename counts. On success
    /// the tmux window name follows and the title is persisted as the display
    /// title. Dead/stopped sessions have no claude to tell; the title is
    /// persisted locally only (it becomes the `--rc`-style explicit title).
    func renameSession(windowId: String?, uuid: String, to newName: String) async -> RenameResult {
        let live = windowId.flatMap { liveSessions[$0] }
        // needsAuth is deliberately NOT in this list: its pane shows the login
        // screen, so typed `/rename` would go nowhere; persist locally only.
        let isLive = live.map { [.running, .working, .waiting, .stale].contains($0.state) } ?? false
        let tmux = self.tmux

        let result: RenameResult = await Task.detached {
            if let windowId, isLive {
                let before = tmux.capturePane(windowId: windowId)
                tmux.sendCommand(windowId: windowId, "/rename \(newName)")
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 6 × 500ms = 3s
                    let after = tmux.capturePane(windowId: windowId)
                    if let error = Self.renameError(before: before, after: after) {
                        return .failed(error)
                    }
                }
            }
            if let windowId {
                tmux.renameWindow(windowId: windowId, to: tmux.uniqueWindowName(from: newName))
            }
            return .ok
        }.value

        if result == .ok {
            live?.record.title = newName
            if !uuid.isEmpty {
                let store = self.store
                Task.detached { store.mergeRecord(uuid: uuid, title: newName) }
            }
        }
        return result
    }

    /// Error text newly rendered since the rename was sent, if any. Matches
    /// only rename-shaped failures; generic words like "error" would
    /// false-positive on session content that happens to stream in the window.
    nonisolated static func renameError(before: String, after: String) -> String? {
        let markers = ["already taken", "already exists", "unknown command", "rename failed"]
        let beforeLines = Set(before.split(whereSeparator: \.isNewline))
        for line in after.split(whereSeparator: \.isNewline) where !beforeLines.contains(line) {
            let lowered = line.lowercased()
            if markers.contains(where: { lowered.contains($0) }) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Archive

    /// Archive (flow 6.9): a running session is killed first (the caller has
    /// already confirmed), with the archived flag folded into the kill's own
    /// identity merge (`archived: true`) so the record is flagged *before* the
    /// window leaves `liveSessions`; a rebuild during the SIGTERM wait then
    /// routes it straight to Archived instead of flashing as a Stopped row in
    /// All Sessions. The trailing merge is the fallback for an already-stopped
    /// record (no live window to kill) or a uuid learned only at kill time.
    func archiveSession(uuid: String, windowId: String?) async {
        var uuid = uuid
        if let windowId, liveSessions[windowId] != nil {
            let killed = await killSession(windowId: windowId, archived: true)
            if uuid.isEmpty { uuid = killed }
        }
        guard !uuid.isEmpty else { return }
        let store = self.store
        let frozen = uuid
        await Task.detached { store.mergeRecord(uuid: frozen, archived: true) }.value
    }

    /// Unarchive: the session reappears in All Sessions as Stopped (flow 6.9).
    func unarchiveSession(uuid: String) async {
        guard !uuid.isEmpty else { return }
        let store = self.store
        await Task.detached { store.mergeRecord(uuid: uuid, archived: false) }.value
    }

    // MARK: - Remove from CCorn (untrack)

    /// "Remove from CCorn": forget a session entirely. Unlike Stop/Archive this
    /// keeps NO record; it tears down any live window via `terminate` (which,
    /// unlike `killSession`, persists nothing), drops the persisted record from
    /// both All Sessions and Archived, and adds the UUID to the ignore-list so
    /// discovery never re-surfaces it (sticky even if the conversation is later
    /// resumed from the terminal). The Claude transcript on disk is never
    /// touched: `claude --resume <uuid>` from a terminal still works. A live
    /// session is identified before its window goes (the registry file goes
    /// stale once the process dies), mirroring `killSession`.
    func removeFromCCorn(uuid: String, windowId: String?) async {
        var uuid = uuid
        if let windowId, let live = liveSessions[windowId] {
            if uuid.isEmpty, let pid = live.pid {
                uuid = await Task.detached {
                    ClaudeSessionRegistry.info(forPid: pid)?.sessionId ?? ""
                }.value
            }
            await terminate(windowId: windowId)
        }
        guard !uuid.isEmpty else { return }
        ignoreSessionUUID(uuid)
        let store = self.store
        let frozen = uuid
        await Task.detached { store.removeRecord(uuid: frozen) }.value
    }

    /// Add a UUID to the persisted ignore-list (deduped), through the same
    /// settings write everything else uses so it survives relaunch.
    private func ignoreSessionUUID(_ uuid: String) {
        guard !uuid.isEmpty, !settings.ignoredSessionUUIDs.contains(uuid) else { return }
        var updated = settings
        updated.ignoredSessionUUIDs.append(uuid)
        updateSettings(updated)
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

    /// One refresh cycle over every live session, the hot poll path. Each
    /// session resolves its transcript with an O(1) lookup into `index`, and the
    /// bridge-session check inside `detect` is mtime-cached per session. All of
    /// it runs off-main; results are applied back on the main actor.
    ///
    /// `index` is the caller's already-built uuid -> transcript index (the UI
    /// keeps one, refreshed by FSEvents-driven discovery). Passing it keeps the
    /// hot path off the filesystem entirely; a fast adaptive poll must not
    /// re-enumerate the projects root on every tick. When nil, the index is
    /// enumerated here (the one-off / launch callers that hold no cache).
    func refreshAll(index: [String: DiscoveredSession]? = nil, now: Date = Date()) async {
        await bindUnknownIdentities()
        await refresh(jobs: detectionJobs(), index: index, now: now)
    }

    /// Bind live sessions whose UUID is still unknown. startNewSession binds at
    /// spawn when it can, but a trust prompt in a new directory delays claude's
    /// registry write past that window (verified live); so this retries on
    /// every refresh tick until the file appears, then tags the window and
    /// persists the record exactly once. Costs one small JSON read per still-
    /// unbound session and nothing when all sessions are bound.
    private func bindUnknownIdentities() async {
        struct Job: Sendable {
            let windowId: String
            let pid: Int32
        }
        let jobs: [Job] = liveSessions.compactMap { windowId, live in
            guard live.sessionUUID.isEmpty, let pid = live.pid else { return nil }
            return Job(windowId: windowId, pid: pid)
        }
        guard !jobs.isEmpty else { return }

        let tmux = self.tmux
        let found = await Task.detached { () -> [String: ClaudeSessionRegistry.Info] in
            var out: [String: ClaudeSessionRegistry.Info] = [:]
            for job in jobs {
                if let info = ClaudeSessionRegistry.info(forPid: job.pid) {
                    tmux.setCcornId(windowId: job.windowId, uuid: info.sessionId)
                    out[job.windowId] = info
                }
            }
            return out
        }.value
        guard !found.isEmpty else { return }

        let store = self.store
        for (windowId, info) in found {
            guard let live = liveSessions[windowId], live.sessionUUID.isEmpty else { continue }
            // Registry files linger for dead pids; a recycled pid could pair
            // our claude with a stale file describing a different session.
            // The cwd is the cheap incarnation check: when both sides are
            // known and disagree, leave the session unbound for this tick.
            if let cwd = info.cwd, !live.record.path.isEmpty,
               SessionDiscovery.canonicalize(cwd) != live.record.path {
                continue
            }
            live.ccornTag = info.sessionId
            let path = live.record.path.isEmpty
                ? info.cwd.map(SessionDiscovery.canonicalize) ?? ""
                : live.record.path
            // Carry the in-memory record's launch config (set by startNewSession
            // even when the uuid bound too late to persist at spawn) and any
            // groupIDs; upsert replaces the whole record, so they'd be lost.
            let record = SessionRecord(uuid: info.sessionId, path: path,
                                       title: live.record.title,
                                       archived: live.record.archived,
                                       groupIDs: live.record.groupIDs,
                                       launchConfig: live.record.launchConfig)
            live.record = record
            Task.detached { store.upsert(record) }
        }
    }

    /// Re-detect state for one live session. A one-off (not the hot path), so it
    /// enumerates the transcript index itself rather than taking a cached one.
    func refreshState(windowId: String, now: Date = Date()) async {
        await refresh(jobs: detectionJobs().filter { $0.windowId == windowId },
                      index: nil, now: now)
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

    private func refresh(jobs: [DetectionJob],
                         index providedIndex: [String: DiscoveredSession]?,
                         now: Date) async {
        guard !jobs.isEmpty else { return }
        let tmux = self.tmux
        let detector = self.detector
        let discovery = self.discovery
        let staleThreshold = settings.staleThresholdSeconds

        let results = await Task.detached { () -> [String: DetectionResult] in
            // The caller's cached index keeps the hot path off the filesystem;
            // only the one-off / launch callers (nil) enumerate here.
            let index = providedIndex ?? discovery.transcriptIndex()
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

    /// Push the per-session terminal status bars. `desired` is windowId ->
    /// rendered `@ccorn_status` content (built by the UI coordinator from the
    /// same row data the screens use, so the bar and the GUI never drift). Only
    /// windows whose content changed since the last push are written, diffed
    /// against each `LiveSession.lastPushedStatusBar`; the changed set is sent
    /// off-main in one batched tmux invocation. A no-op when nothing changed,
    /// which is the common case on an idle tick.
    func syncStatusBars(_ desired: [String: String]) {
        var changes: [(windowId: String, value: String)] = []
        for (windowId, value) in desired {
            guard let live = liveSessions[windowId] else { continue }
            if live.lastPushedStatusBar != value {
                live.lastPushedStatusBar = value
                changes.append((windowId, value))
            }
        }
        guard !changes.isEmpty else { return }
        let tmux = self.tmux
        Task.detached { tmux.setWindowStatusBars(changes) }
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
    /// window tag and persisted, so a later relaunch, when the process may be
    /// gone, still knows the session and its last directory. Windows that show
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
            // Reap "Open in Terminal" view sessions left by a crashed terminal
            // before enumerating windows; destroy-unattached covers the normal
            // close, this is the launch backstop (a view never holds a window
            // the managed session doesn't, so this can't drop a real session).
            tmux.killStrayViewSessions()
            guard tmux.hasSession() else { return [] }
            let persisted = store.loadRecords()
            let index = discovery.transcriptIndex()
            return tmux.listWindows().compactMap { window -> Reconciled? in
                var uuid = window.ccornId ?? ""
                var claudePID: Int32?
                var registryCwd: String?
                // Seed the pid only on a determined .found; .absent/.unknown
                // leave it nil and let detect() re-derive (where the
                // determined-absent-vs-unknown distinction decides Dead vs hold).
                if let shellPID = window.panePID,
                   case .found(let pid) = ProcessControl.findClaude(belowShell: shellPID) {
                    claudePID = pid
                }
                if uuid.isEmpty, let pid = claudePID,
                   let info = ClaudeSessionRegistry.info(forPid: pid) {
                    uuid = info.sessionId
                    registryCwd = info.cwd
                    tmux.setCcornId(windowId: window.windowId, uuid: uuid)
                }

                // No claude identity, no claude process, no @ccorn_managed
                // marker, no claude trace in the pane: this window never ran
                // claude, not a session. (The marker is what keeps a dead
                // CCorn-created session adopted even after its claude text
                // scrolled out of the visible frame or the user ran `clear`.)
                if uuid.isEmpty, claudePID == nil, !window.managed,
                   !detector.showsClaudeEvidence(pane: tmux.capturePane(windowId: window.windowId)) {
                    return nil
                }

                // Adopted windows get the same name-pinning as windows we
                // create: without it automatic-rename tracks the foreground
                // process and a dead claude pane reads as "zsh". The sibling
                // roster is hidden on adopted windows too, so a reconciled
                // fleet shows the per-session bar, not the window list. Only for
                // windows we actually adopt; a rejected bystander window
                // keeps its tmux options untouched.
                tmux.disableRenaming(windowId: window.windowId)
                tmux.hideSiblingRoster(windowId: window.windowId)

                let known = persisted.first { !uuid.isEmpty && $0.uuid == uuid }
                // Title stays empty for unknown records, NEVER the live tmux
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
                                   ccornTag: item.record.uuid.isEmpty ? nil : item.record.uuid,
                                   adopted: true)
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
