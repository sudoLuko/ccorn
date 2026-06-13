import Foundation

/// One window inside the `ccorn` tmux session.
struct TmuxWindow: Sendable {
    let windowId: String   // stable `@N` id — the only reliable target
    let name: String       // display/attach label only, never a key
    let ccornId: String?   // our @ccorn_id tag (the Claude session UUID), if set
    let panePID: Int32?    // the pane's shell pid
    /// The pane's working directory — the project path fallback for windows
    /// with no persisted record (a previous run's startNewSession windows).
    let panePath: String?
    /// True when the window carries the @ccorn_managed marker set at creation.
    /// Durable "CCorn created this for a claude session" signal — unlike pane
    /// content, it survives the claude text scrolling away or a `clear`, so
    /// reconcile never drops a dead session for lack of visible evidence.
    let managed: Bool
}

/// All tmux orchestration. Every programmatic command targets the stable window
/// id (`@N`) captured at creation, never the window name (names can contain
/// spaces/dots that break tmux's `session:window.pane` target syntax).
///
/// See docs/CCORN_SPEC.md "Window Naming and Identity" and CLAUDE.md "tmux commands".
struct TmuxController: Sendable {
    #if DEBUG
    /// Shakedown isolation: a debug run can use a scratch tmux session so
    /// churn never touches the user's real `ccorn` windows. Production name
    /// in all other cases.
    static let sessionName =
        ProcessInfo.processInfo.environment["CCORN_DEBUG_TMUX_SESSION"] ?? "ccorn"
    /// Hermetic e2e isolation: point every tmux command at a separate server
    /// socket (`tmux -L <name>`), so even a kill-server in a chaos test
    /// cannot reach the user's default server. Session-name isolation alone
    /// still shares the server; socket isolation shares nothing.
    static let socketName: String? =
        ProcessInfo.processInfo.environment["CCORN_DEBUG_TMUX_SOCKET"]
    #else
    static let sessionName = "ccorn"
    static let socketName: String? = nil
    #endif
    private let runner = CommandRunner.shared

    /// Every tmux invocation funnels through here so the debug socket
    /// override applies to all commands or none.
    @discardableResult
    private func tmux(_ args: [String]) -> CommandResult {
        if let socket = Self.socketName {
            return runner.run("tmux", ["-L", socket] + args)
        }
        return runner.run("tmux", args)
    }

    // MARK: Session lifecycle

    /// True if the `ccorn` session exists.
    func hasSession() -> Bool {
        tmux(["has-session", "-t", Self.sessionName]).ok
    }

    /// Outcome of `ensureSession`. `strayDefaultWindowId` is set only when the
    /// session was created fresh: `new-session` always spawns one bare shell
    /// window alongside it, which would otherwise linger and surface as a
    /// never-ran-claude row (the "zsh" row). The caller kills it once a real
    /// window exists — a session whose last window dies is destroyed by tmux,
    /// so it cannot be killed any earlier.
    struct EnsureSessionResult: Sendable {
        let ok: Bool
        let strayDefaultWindowId: String?
    }

    /// Create the `ccorn` session if it does not already exist. Never recreate.
    @discardableResult
    func ensureSession() -> EnsureSessionResult {
        if hasSession() {
            scrubNestedSessionMarkers()
            return EnsureSessionResult(ok: true, strayDefaultWindowId: nil)
        }
        let r = tmux([
            "new-session", "-d", "-s", Self.sessionName,
            "-P", "-F", "#{window_id}",
        ])
        guard r.ok else { return EnsureSessionResult(ok: false, strayDefaultWindowId: nil) }
        scrubNestedSessionMarkers()
        let id = r.trimmedOut
        return EnsureSessionResult(ok: true, strayDefaultWindowId: id.isEmpty ? nil : id)
    }

    /// A `claude` that inherits CLAUDE_CODE_CHILD_SESSION runs as a nested
    /// child session and skips ALL local session persistence — no pid
    /// registry, no conversation records, `--resume` refuses the session
    /// (runtime findings P8). That breaks identity binding, restart,
    /// and RC detection for every session CCorn spawns. The var can reach our
    /// windows when the tmux server (or CCorn itself, in dev) was started
    /// from inside a Claude Code shell, so mark it for removal from the
    /// session environment; new panes then never inherit it. Runs on every
    /// ensure, covering servers and sessions CCorn did not create.
    private func scrubNestedSessionMarkers() {
        for name in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID"] {
            tmux(["set-environment", "-t", Self.sessionName, "-r", name])
        }
    }

    // MARK: Windows

    /// Create a new window and return its stable `@N` id. The name is sanitized
    /// and de-duplicated against existing windows by the caller via `uniqueWindowName`.
    func newWindow(name: String, cwd: String) -> String? {
        let r = tmux([
            // Trailing ":" (empty window part) targets the SESSION, so tmux
            // creates at the next free index. A bare "-t ccorn" is a
            // target-WINDOW: when a managed window is itself named "ccorn" — a
            // project whose basename equals the session name, e.g. CCorn run on
            // its own repo — tmux resolves the bare name to THAT window and
            // tries to reuse its index, failing with "create window failed:
            // index N in use" and breaking every new session. The colon forces
            // the session interpretation.
            "new-window", "-t", Self.sessionName + ":",
            "-n", name, "-c", cwd,
            "-P", "-F", "#{window_id}",
        ])
        guard r.ok else { return nil }
        let id = r.trimmedOut
        guard !id.isEmpty else { return nil }
        disableRenaming(windowId: id)
        // Durable marker: this window exists for a claude session, even if the
        // claude text later scrolls out of the visible pane frame.
        tmux(["set-option", "-w", "-t", id, "@ccorn_managed", "1"])
        return id
    }

    /// Pin a window's name. Without this, tmux's automatic-rename tracks the
    /// foreground process — a window whose claude exited reads as "zsh" — and
    /// allow-rename lets pane escape sequences rewrite it. Applied to every
    /// window CCorn creates and every existing window it adopts on reconcile.
    /// (Display names come from session titles; the live tmux window name is
    /// never shown either way.)
    func disableRenaming(windowId: String) {
        tmux(["set-option", "-w", "-t", windowId, "automatic-rename", "off"])
        tmux(["set-option", "-w", "-t", windowId, "allow-rename", "off"])
    }

    /// Send a command to a window's pane. The key is sent as a *separate* `Enter`
    /// argument — never an embedded `\n` in the command string (CLAUDE.md rule).
    func sendCommand(windowId: String, _ command: String) {
        tmux(["send-keys", "-t", windowId, command, "Enter"])
    }

    /// Capture the *visible frame* of a pane. No `-S`: Claude Code is a
    /// full-screen TUI on the alternate screen, which keeps no per-app
    /// scrollback, so `-S -<n>` would read stale pre-launch output. `-J` rejoins
    /// wrapped lines so pattern matching sees whole strings.
    func capturePane(windowId: String) -> String {
        tmux(["capture-pane", "-t", windowId, "-p", "-J"]).stdout
    }

    /// Kill a window by id (sends SIGHUP to the pane's processes).
    func killWindow(windowId: String) {
        tmux(["kill-window", "-t", windowId])
    }

    func renameWindow(windowId: String, to name: String) {
        tmux(["rename-window", "-t", windowId, name])
    }

    /// The pane's shell pid — the parent under which the `claude` child lives.
    func panePID(windowId: String) -> Int32? {
        let r = tmux(["list-panes", "-t", windowId, "-F", "#{pane_pid}"])
        return r.stdout
            .split(whereSeparator: { $0 == "\n" })
            .first
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: @ccorn_id tag

    /// Tag a window with the Claude session UUID so reconciliation and rename can
    /// resolve windows robustly (independent of the display name). `-w` scopes the
    /// option to the window.
    func setCcornId(windowId: String, uuid: String) {
        tmux(["set-option", "-w", "-t", windowId, "@ccorn_id", uuid])
    }

    // MARK: Enumeration / reconciliation

    /// All windows in the `ccorn` session, with id, name, @ccorn_id tag, pane
    /// pid, and pane working directory.
    func listWindows() -> [TmuxWindow] {
        guard hasSession() else { return [] }
        // Tab-separated so names containing spaces don't break the split.
        let fmt = "#{window_id}\t#{window_name}\t#{@ccorn_id}\t#{pane_pid}\t#{pane_current_path}\t#{@ccorn_managed}"
        let r = tmux(["list-windows", "-t", Self.sessionName, "-F", fmt])
        guard r.ok else { return [] }
        var windows: [TmuxWindow] = []
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 6 else { continue }
            let tag = cols[2].isEmpty ? nil : cols[2]
            let pid = Int32(cols[3].trimmingCharacters(in: .whitespaces))
            let path = cols[4].isEmpty ? nil : cols[4]
            windows.append(TmuxWindow(windowId: cols[0], name: cols[1], ccornId: tag,
                                      panePID: pid, panePath: path,
                                      managed: cols[5] == "1"))
        }
        return windows
    }

    /// Resolve a window by its @ccorn_id tag.
    func window(forCcornId uuid: String) -> TmuxWindow? {
        listWindows().first { $0.ccornId == uuid }
    }

    // MARK: Name sanitization

    /// Sanitize a folder name into a tmux-safe window name: spaces, dots, colons
    /// and other tmux-significant characters become `-`.
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let collapsed = mapped.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : trimmed
    }

    /// POSIX single-quote a value for embedding in a command line that the pane's
    /// interactive shell evaluates (a `send-keys` payload). Wrapping in single
    /// quotes makes `$(...)`, backticks, `$VAR`, and every other shell
    /// metacharacter inert; an embedded single quote is closed, escaped, and
    /// reopened (`'\''`). Use this for any user/data-controlled value (titles,
    /// uuids) that flows into `sendCommand`.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A sanitized name unique against the current window names; appends -2, -3
    /// on collision. The session name itself is reserved: a window named
    /// identically to the session is a tmux target hazard (see `newWindow`), so
    /// the safe name is chosen up front — the window is born correct, with no
    /// post-creation rename. The display title is separate and unaffected.
    func uniqueWindowName(from raw: String) -> String {
        let base = Self.sanitize(raw)
        let taken = Set(listWindows().map { $0.name }).union([Self.sessionName])
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
