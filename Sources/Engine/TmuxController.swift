import Foundation

/// One window inside the `ccorn` tmux session.
struct TmuxWindow: Sendable {
    let windowId: String   // stable `@N` id — the only reliable target
    let name: String       // display/attach label only, never a key
    let ccornId: String?   // our @ccorn_id tag (the Claude session UUID), if set
    let panePID: Int32?    // the pane's shell pid
}

/// All tmux orchestration. Every programmatic command targets the stable window
/// id (`@N`) captured at creation, never the window name (names can contain
/// spaces/dots that break tmux's `session:window.pane` target syntax).
///
/// See docs/CCORN_SPEC.md "Window Naming and Identity" and CLAUDE.md "tmux commands".
struct TmuxController: Sendable {
    static let sessionName = "ccorn"
    private let runner = CommandRunner.shared

    // MARK: Session lifecycle

    /// True if the `ccorn` session exists.
    func hasSession() -> Bool {
        runner.run("tmux", ["has-session", "-t", Self.sessionName]).ok
    }

    /// Create the `ccorn` session if it does not already exist. Never recreate.
    @discardableResult
    func ensureSession() -> Bool {
        if hasSession() { return true }
        return runner.run("tmux", ["new-session", "-d", "-s", Self.sessionName]).ok
    }

    // MARK: Windows

    /// Create a new window and return its stable `@N` id. The name is sanitized
    /// and de-duplicated against existing windows by the caller via `uniqueWindowName`.
    func newWindow(name: String, cwd: String) -> String? {
        let r = runner.run("tmux", [
            "new-window", "-t", Self.sessionName,
            "-n", name, "-c", cwd,
            "-P", "-F", "#{window_id}",
        ])
        guard r.ok else { return nil }
        let id = r.trimmedOut
        return id.isEmpty ? nil : id
    }

    /// Send a command to a window's pane. The key is sent as a *separate* `Enter`
    /// argument — never an embedded `\n` in the command string (CLAUDE.md rule).
    func sendCommand(windowId: String, _ command: String) {
        runner.run("tmux", ["send-keys", "-t", windowId, command, "Enter"])
    }

    /// Capture the *visible frame* of a pane. No `-S`: Claude Code is a
    /// full-screen TUI on the alternate screen, which keeps no per-app
    /// scrollback, so `-S -<n>` would read stale pre-launch output. `-J` rejoins
    /// wrapped lines so pattern matching sees whole strings.
    func capturePane(windowId: String) -> String {
        runner.run("tmux", ["capture-pane", "-t", windowId, "-p", "-J"]).stdout
    }

    /// Kill a window by id (sends SIGHUP to the pane's processes).
    func killWindow(windowId: String) {
        runner.run("tmux", ["kill-window", "-t", windowId])
    }

    func renameWindow(windowId: String, to name: String) {
        runner.run("tmux", ["rename-window", "-t", windowId, name])
    }

    /// The pane's shell pid — the parent under which the `claude` child lives.
    func panePID(windowId: String) -> Int32? {
        let r = runner.run("tmux", ["list-panes", "-t", windowId, "-F", "#{pane_pid}"])
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
        runner.run("tmux", ["set-option", "-w", "-t", windowId, "@ccorn_id", uuid])
    }

    // MARK: Enumeration / reconciliation

    /// All windows in the `ccorn` session, with id, name, @ccorn_id tag, and pane pid.
    func listWindows() -> [TmuxWindow] {
        guard hasSession() else { return [] }
        // Tab-separated so names containing spaces don't break the split.
        let fmt = "#{window_id}\t#{window_name}\t#{@ccorn_id}\t#{pane_pid}"
        let r = runner.run("tmux", ["list-windows", "-t", Self.sessionName, "-F", fmt])
        guard r.ok else { return [] }
        var windows: [TmuxWindow] = []
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 4 else { continue }
            let tag = cols[2].isEmpty ? nil : cols[2]
            let pid = Int32(cols[3].trimmingCharacters(in: .whitespaces))
            windows.append(TmuxWindow(windowId: cols[0], name: cols[1], ccornId: tag, panePID: pid))
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

    /// A sanitized name unique against the current window names; appends -2, -3 on collision.
    func uniqueWindowName(from raw: String) -> String {
        let base = Self.sanitize(raw)
        let existing = Set(listWindows().map { $0.name })
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
