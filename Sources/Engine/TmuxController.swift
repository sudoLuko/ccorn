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

    /// Quote a value as an AppleScript string literal for embedding in an
    /// `osascript` program. AppleScript treats backslash and double quote as the
    /// in-string escapes, so both are backslash-escaped — backslash first, or the
    /// escapes added for the quotes would themselves be doubled. Returns the value
    /// wrapped in double quotes, ready to drop into a `tell application` block. Use
    /// for any user-controlled value (a session title) interpolated into a script.
    static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
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

    // MARK: Per-client view sessions (Open in Terminal)

    /// Prefix for the throwaway grouped "view" sessions that "Open in Terminal"
    /// creates — one per attached terminal. A view shares `ccorn`'s window list
    /// but keeps its OWN current window and active pane, so two terminals no
    /// longer mirror each other's window switching or share keystrokes the way
    /// every client attached to one plain session does (both are session-level).
    /// Named distinctly from the managed session so the launch sweep can spot
    /// and reap strays.
    static let viewSessionPrefix = "ccorn-view"

    /// Every session name on the server: the managed `ccorn` plus any live views.
    func sessionNames() -> [String] {
        let r = tmux(["list-sessions", "-F", "#{session_name}"])
        guard r.ok else { return [] }
        return r.stdout
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A view-session name unique among `taken`. Derived from the window id so
    /// `tmux ls` reads back to a window; `-2`, `-3` on collision when several
    /// terminals attach to the same window. The id is digits after `@`, so the
    /// result is already a tmux-safe session token (no `.`/`:`/space to escape).
    static func uniqueViewSessionName(forWindowId windowId: String, taken: Set<String>) -> String {
        let suffix = windowId.replacingOccurrences(of: "@", with: "")
        let base = "\(viewSessionPrefix)-\(suffix)"
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The shell command a Terminal runs to attach to `windowId` through a fresh
    /// grouped view session. `new-session -t <ccorn>` groups onto the shared
    /// window list; `-s <view>` is this terminal's private view; `select-window`
    /// points it at the requested window by stable id (a grouped session does
    /// NOT inherit the leader's current window — it lands on window 0, so the
    /// select is required). `destroy-unattached on` reaps the view the moment
    /// the terminal closes; it MUST be set with the client already attached
    /// (set on a *detached* session, tmux destroys it immediately), which is why
    /// it rides in this attaching command rather than being pre-set. Honors the
    /// debug socket+session overrides so a shakedown attach lands on the isolated
    /// server, not the user's real `ccorn`. tmux's command separator is a
    /// single-quoted `';'` — the shell hands tmux a literal `;`, avoiding
    /// backslash escaping inside the osascript `do script` string.
    func attachViewCommand(windowId: String) -> String {
        let view = Self.uniqueViewSessionName(forWindowId: windowId, taken: Set(sessionNames()))
        let socket = Self.socketName.map { "-L \($0) " } ?? ""
        return "tmux \(socket)new-session -t \(Self.sessionName) -s \(view)"
            + " ';' set-option -t \(view) destroy-unattached on"
            + " ';' select-window -t '\(view):\(windowId)'"
    }

    /// Reap view sessions orphaned by a crashed terminal — the backstop to
    /// `destroy-unattached`, which already covers the normal close. Only
    /// unattached views are killed; one with a live client is in active use.
    /// Killing a view never harms the shared windows (they belong to the group,
    /// kept alive by the managed session). Run from the launch reconcile sweep.
    func killStrayViewSessions() {
        let r = tmux(["list-sessions", "-F", "#{session_name}\t#{session_attached}"])
        guard r.ok else { return }
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2 else { continue }
            let name = cols[0]
            let attached = cols[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix(Self.viewSessionPrefix + "-"), attached == "0" {
                tmux(["kill-session", "-t", name])
            }
        }
    }

    /// The tty of an already-open terminal attached to this window's view, or
    /// nil if none. The join (verified live): a view is named
    /// `ccorn-view-<windowId>` (uniqueViewSessionName), and tmux's `client_tty`
    /// for that view is byte-for-byte Terminal's `tty of tab` — so a live client
    /// on `ccorn-view-<id>` IS the Terminal tab opened for this session. Lets the
    /// attach path raise that terminal instead of stacking a second window on the
    /// session (one terminal per session). A terminal the user has since closed
    /// leaves no client (`destroy-unattached` reaps the view), so a nil here
    /// means "open a fresh one".
    func viewClientTTY(forWindowId windowId: String) -> String? {
        let r = tmux(["list-clients", "-F", "#{client_session}\t#{client_tty}"])
        guard r.ok else { return nil }
        return Self.matchViewClient(windowId: windowId, clientLines: r.stdout)
    }

    /// Pure split of `viewClientTTY`: the tty of the client whose session is this
    /// window's view (`ccorn-view-<suffix>`, or a `-2`/`-3` collision form). The
    /// `-` before the collision number is what stops window `@1`'s base
    /// `ccorn-view-1` from matching window `@10`'s `ccorn-view-10`.
    static func matchViewClient(windowId: String, clientLines: String) -> String? {
        let suffix = windowId.replacingOccurrences(of: "@", with: "")
        let base = "\(viewSessionPrefix)-\(suffix)"
        for line in clientLines.split(whereSeparator: { $0 == "\n" }) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2 else { continue }
            let session = cols[0].trimmingCharacters(in: .whitespaces)
            let tty = cols[1].trimmingCharacters(in: .whitespaces)
            guard session == base || session.hasPrefix(base + "-") else { continue }
            if !tty.isEmpty { return tty }
        }
        return nil
    }
}
