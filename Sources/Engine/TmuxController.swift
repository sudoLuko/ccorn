import Foundation

/// One window inside the `ccorn` tmux session.
struct TmuxWindow: Sendable {
    let windowId: String   // stable `@N` id, the only reliable target
    let name: String       // display/attach label only, never a key
    let ccornId: String?   // our @ccorn_id tag (the Claude session UUID), if set
    let panePID: Int32?    // the pane's shell pid
    /// The pane's working directory, the project path fallback for windows
    /// with no persisted record (a previous run's startNewSession windows).
    let panePath: String?
    /// True when the window carries the @ccorn_managed marker set at creation.
    /// Durable "CCorn created this for a claude session" signal; unlike pane
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
    /// window exists; a session whose last window dies is destroyed by tmux,
    /// so it cannot be killed any earlier.
    struct EnsureSessionResult: Sendable {
        let ok: Bool
        let strayDefaultWindowId: String?
        /// tmux's own stderr from a failed `new-session`, so the caller can tell
        /// the user *why* it failed (a stale/incompatible server, a socket
        /// permission issue) instead of a bare "could not create". nil on success.
        var stderr: String? = nil
    }

    /// Create the `ccorn` session if it does not already exist. Never recreate.
    /// `mouseMode` is applied on every ensure (creation or confirmation) so a
    /// session set up before the preference changed still picks up the current
    /// value. See `setMouseMode` for why it is scoped to this session.
    @discardableResult
    func ensureSession(mouseMode: Bool) -> EnsureSessionResult {
        if hasSession() {
            scrubNestedSessionMarkers()
            setMouseMode(mouseMode)
            return EnsureSessionResult(ok: true, strayDefaultWindowId: nil)
        }
        let r = tmux([
            "new-session", "-d", "-s", Self.sessionName,
            "-P", "-F", "#{window_id}",
        ])
        guard r.ok else { return EnsureSessionResult(ok: false, strayDefaultWindowId: nil, stderr: r.stderr) }
        scrubNestedSessionMarkers()
        setMouseMode(mouseMode)
        let id = r.trimmedOut
        return EnsureSessionResult(ok: true, strayDefaultWindowId: id.isEmpty ? nil : id)
    }

    /// Set tmux mouse mode on the `ccorn` SESSION only (no `-g`). A session
    /// option overrides the server-global value for this session alone, so a
    /// user's own `set -g mouse …` for their other tmux sessions is left
    /// intact. With mouse on the scroll wheel scrolls the pane; with it off the
    /// wheel falls back to arrow keys in a full-screen TUI and native terminal
    /// text selection is simpler. The grouped "view" sessions used by Open in
    /// Terminal do NOT inherit this (they carry their own session options), so
    /// `attachViewCommand` sets it on each view too.
    func setMouseMode(_ enabled: Bool) {
        tmux(["set-option", "-t", Self.sessionName, "mouse", enabled ? "on" : "off"])
        installCopyModeSelectBindings()
        installCopyModeExitBindings()
        installCopyModeBanner()
        installStatusLine()
    }

    /// Rebind mouse-release in copy-mode so dragging to select text COPIES to the
    /// macOS clipboard without cancelling copy-mode. Two problems with the stock
    /// `MouseDragEnd1Pane` → `copy-pipe-and-cancel` are fixed here:
    ///
    /// 1. `-and-cancel` exits copy-mode, which snaps the pane back to the live
    ///    bottom position on every release, the "jump to the bottom" the moment
    ///    you let go of a selection. `copy-pipe-no-clear` leaves copy-mode
    ///    untouched, so the scroll position holds; the user returns to the live
    ///    view with `q`/Escape on their own timing.
    /// 2. The selection never reached the system clipboard. CCorn attaches through
    ///    Terminal.app, which does not honor the OSC 52 clipboard escape that
    ///    tmux's default `set-clipboard` path relies on, so a stock copy silently
    ///    went nowhere. Piping the selection to `pbcopy` writes the macOS
    ///    pasteboard directly, independent of the terminal's OSC 52 support.
    ///
    /// Only reachable with `mouse` on (a drag is what enters copy-mode), so it
    /// pairs with `setMouseMode`.
    ///
    /// Key tables are SERVER-GLOBAL; unlike the `mouse` session option there is
    /// no per-session key table, and in Release CCorn shares the user's default
    /// tmux server. So the binding is guarded to fire only inside CCorn's own
    /// sessions: `#{m:ccorn*,#{session_name}}` matches `ccorn` and the
    /// `ccorn-view-*` view sessions and falls through to the stock
    /// `copy-pipe-and-cancel` everywhere else, leaving the user's other tmux work
    /// on tmux's default copy behavior, the same restraint `setMouseMode` shows
    /// by never touching their `set -g mouse`. Both the emacs (`copy-mode`) and
    /// vi (`copy-mode-vi`) tables are rebound since `mode-keys` selects the live one.
    private func installCopyModeSelectBindings() {
        for table in ["copy-mode", "copy-mode-vi"] {
            tmux([
                "bind-key", "-T", table, "MouseDragEnd1Pane",
                "if-shell", "-F", "#{m:ccorn*,#{session_name}}",
                "send-keys -X copy-pipe-no-clear pbcopy",
                "send-keys -X copy-pipe-and-cancel",
            ])
        }
    }

    /// Bind Escape to leave copy-mode, so a user who scrolled up with the mouse
    /// can exit the same way `q` does (a drag enters copy-mode, but Escape is the
    /// instinctive way out). `q` is untouched and keeps its stock `cancel`, so it
    /// still exits; this only ADDS Escape alongside it.
    ///
    /// Key tables are SERVER-GLOBAL (in Release CCorn shares the user's default
    /// tmux server), so the bind is gated exactly like the MouseDragEnd1Pane
    /// rebind above: `if-shell -F "#{m:ccorn*,#{session_name}}"` cancels copy-mode
    /// only inside CCorn's own sessions (`ccorn` and the `ccorn-view-*` views) and
    /// falls through to the table's STOCK Escape everywhere else, so the user's
    /// other tmux sessions keep their default copy-mode Escape (`cancel` in the
    /// emacs table, `clear-selection` in the vi table). Both tables are bound
    /// since `mode-keys` selects the live one. The same restraint and the same
    /// residual tradeoff as the select rebind: a user who has REbound Escape in
    /// copy-mode globally gets the stock behavior restored in the else branch,
    /// not their own custom binding.
    private func installCopyModeExitBindings() {
        // Per-table stock Escape, restored in the non-CCorn else branch: the
        // emacs copy-mode cancels, the vi copy-mode clears the selection.
        let tables: [(table: String, stockEscape: String)] = [
            ("copy-mode", "send-keys -X cancel"),
            ("copy-mode-vi", "send-keys -X clear-selection"),
        ]
        for (table, stockEscape) in tables {
            tmux([
                "bind-key", "-T", table, "Escape",
                "if-shell", "-F", "#{m:ccorn*,#{session_name}}",
                "send-keys -X cancel",
                stockEscape,
            ])
        }
    }

    /// A CCorn-namespaced GLOBAL user option stashing the status-right the session
    /// would otherwise show, so the banner's non-copy-mode branch can reproduce
    /// it. Global, not session-scoped, for two reasons: the grouped `ccorn-view-*`
    /// sessions do not inherit a base session's user options, and a global `@`
    /// stash lets them reference it without re-embedding the quote-laden default
    /// status-right (which contains `"`) into `attachViewCommand`'s osascript
    /// path. A `@`-prefixed user option is inert storage; it changes no tmux
    /// behavior for the user's other sessions.
    private static let savedStatusRightOption = "@ccorn_status_right_saved"

    /// The `status-right` format that flips to a loud banner while a pane is in
    /// copy-mode and restores the normal status-right otherwise. The bright bar
    /// (black text on amber) appears the moment `#{pane_in_mode}` is true and
    /// vanishes on exit. The non-copy-mode branch re-expands the stashed default
    /// with `#{T:...}` so its own formats and clock still render. Style runs are
    /// split into separate `#[...]` directives on purpose: a single
    /// `#[bg=...,fg=...]` carries a comma that tmux would misread as the
    /// conditional's true/false separator. Shared verbatim by the session
    /// (`installCopyModeBanner`) and each view (`attachViewCommand`); it contains
    /// no quote so it embeds safely single-quoted in the attach command.
    static let copyModeStatusRight =
        "#{?pane_in_mode,"
        + "#[bg=colour214]#[fg=colour16] COPY MODE: q or esc to exit #[default]"
        + ",#{T:\(savedStatusRightOption)}}"

    /// Install the copy-mode banner on the `ccorn` SESSION. `status-right` is a
    /// session option (like `mouse`), so it is scoped to CCorn's session and
    /// every window in it, current and future, and never touches the user's other
    /// tmux sessions. The default status-right is captured from the GLOBAL value
    /// (which CCorn never writes, so re-applying on every ensure is idempotent)
    /// and stashed for the non-copy-mode branch to reproduce. The grouped view
    /// sessions carry their own session options, so `attachViewCommand` sets the
    /// same `status-right` on each view too, the same way it re-applies `mouse`.
    private func installCopyModeBanner() {
        let saved = tmux(["show-options", "-gv", "status-right"]).trimmedOut
        tmux(["set-option", "-g", Self.savedStatusRightOption, saved])
        tmux(["set-option", "-t", Self.sessionName, "status-right", Self.copyModeStatusRight])
        // status-right is only repainted on tmux's `status-interval` tick (15s by
        // default), so the banner would lag a mouse selection or clear late. A
        // session-scoped `pane-mode-changed` hook forces an immediate status
        // refresh the moment a pane enters or leaves copy-mode, so the banner
        // appears and disappears live. Set (not appended) on CCorn's own session,
        // so re-applying on every ensure stays idempotent and never accumulates;
        // the user's other sessions keep their own (global) hooks. Views carry
        // their own hooks, so `attachViewCommand` sets the same one per view.
        tmux(["set-hook", "-t", Self.sessionName, "pane-mode-changed", "refresh-client -S"])
    }

    /// The `status-left` format every CCorn session uses: it expands each
    /// window's `@ccorn_status` user option (set per window by
    /// `setWindowStatusBars`). `#{@ccorn_status}` inserts the value verbatim and
    /// the status drawer then interprets the `#[...]` styles inside it, so the
    /// per-window content carries its own color. Plain `#{@ccorn_status}` (not
    /// `#{T:…}`): the value must NOT be re-expanded as a format, or a `#` in a
    /// session title would be read as a format introducer; titles are instead
    /// escaped for the drawer in `StatusBarFormat`.
    static let statusLeftFormat = "#{@ccorn_status}"

    /// Install CCorn's per-session status line on the `ccorn` SESSION (and, via
    /// `attachViewCommand`, on each view). These are session options, scoped to
    /// CCorn's sessions and never touching the user's other tmux work, exactly
    /// like `mouse` and the copy-mode `status-right`.
    ///
    /// The current session's own state takes the left, read from each window's
    /// `@ccorn_status` option (`statusLeftFormat`). `status-left-length` is
    /// raised because the default (10) would clip the content to nothing; the
    /// terminal width still bounds what is drawn. `status-interval` is shortened
    /// to 5s so every attached client (CCorn runs one per session) repaints its
    /// bar within a few seconds even when it is not the client a
    /// `refresh-client -S` targets; a status repaint is a local terminal redraw,
    /// not a process spawn, so the shorter tick is cheap.
    ///
    /// The sibling roster is hidden separately, per window (`hideSiblingRoster`):
    /// `window-status-current-format` is resolved from the window, not the
    /// session, so a session-level blank is ignored for the current window.
    private func installStatusLine() {
        let s = Self.sessionName
        tmux(["set-option", "-t", s, "status-left", Self.statusLeftFormat])
        tmux(["set-option", "-t", s, "status-left-length", "200"])
        tmux(["set-option", "-t", s, "status-interval", "5"])
    }

    /// A `claude` that inherits CLAUDE_CODE_CHILD_SESSION runs as a nested
    /// child session and skips ALL local session persistence: no pid
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
            // target-WINDOW: when a managed window is itself named "ccorn" (a
            // project whose basename equals the session name, e.g. CCorn run on
            // its own repo) tmux resolves the bare name to THAT window and
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
        hideSiblingRoster(windowId: id)
        // Durable marker: this window exists for a claude session, even if the
        // claude text later scrolls out of the visible pane frame.
        tmux(["set-option", "-w", "-t", id, "@ccorn_managed", "1"])
        return id
    }

    /// Pin a window's name. Without this, tmux's automatic-rename tracks the
    /// foreground process (a window whose claude exited reads as "zsh"), and
    /// allow-rename lets pane escape sequences rewrite it. Applied to every
    /// window CCorn creates and every existing window it adopts on reconcile.
    /// (Display names come from session titles; the live tmux window name is
    /// never shown either way.)
    func disableRenaming(windowId: String) {
        tmux(["set-option", "-w", "-t", windowId, "automatic-rename", "off"])
        tmux(["set-option", "-w", "-t", windowId, "allow-rename", "off"])
    }

    /// Blank this window's entry in the status-line window list, so a terminal
    /// attached to one session does not see a roster of every sibling session
    /// (the per-session bar lives in `status-left`; the list is just noise
    /// here). Set as WINDOW options, not session options: tmux resolves
    /// `window-status-current-format` from the window for the current window, so
    /// a session-level blank is silently ignored and the default `0:name`
    /// reappears (verified on tmux 3.6). Because window options are shared by
    /// every session that lists the window, this one set also covers the grouped
    /// `ccorn-view-*` sessions "Open in Terminal" attaches to. Applied to every
    /// window CCorn creates and adopts, alongside `disableRenaming`.
    func hideSiblingRoster(windowId: String) {
        tmux(["set-option", "-w", "-t", windowId, "window-status-format", ""])
        tmux(["set-option", "-w", "-t", windowId, "window-status-current-format", ""])
    }

    /// Send a command to a window's pane. The key is sent as a *separate* `Enter`
    /// argument; never an embedded `\n` in the command string (CLAUDE.md rule).
    func sendCommand(windowId: String, _ command: String) {
        tmux(["send-keys", "-t", windowId, command, "Enter"])
    }

    /// Capture the *visible frame* of a pane. No `-S`: Claude Code is a
    /// full-screen TUI on the alternate screen, which keeps no per-app
    /// scrollback, so `-S -<n>` would read stale pre-launch output. `-J` rejoins
    /// wrapped lines so pattern matching sees whole strings.
    ///
    /// `target` is any tmux target: a stable window id (`@N`), which resolves to
    /// the window's *active* pane, or a specific pane id (`%N`). State detection
    /// passes a freshly-resolved pane id when it found the pane running claude,
    /// so a split window with the non-claude pane active does not blind capture;
    /// it falls back to the window id (active-pane) target otherwise. The `-p -J`
    /// flags are identical for either target.
    func capturePane(windowId target: String) -> String {
        tmux(["capture-pane", "-t", target, "-p", "-J"]).stdout
    }

    /// One `(paneId, shellPID)` pair per pane in the window. `%N` is the stable
    /// pane id (a valid `capture-pane`/`send-keys` target, like the window id);
    /// `#{pane_pid}` is each pane's shell pid, exactly the pid
    /// `ProcessControl.findClaude(belowShell:)` walks. State detection uses this
    /// to follow the pane actually running `claude` after a split, instead of
    /// capturing whatever pane is active. A non-zero exit (no server, a killed
    /// window, a timeout kill) yields an empty list, which detection treats as
    /// "could not enumerate" and degrades to the window-target capture, never to
    /// a worse state. Pure parser split out so the format contract is unit-tested
    /// without a tmux server.
    static func parsePaneList(from r: CommandResult) -> [(paneId: String, shellPID: Int32)] {
        guard r.ok else { return [] }
        var out: [(paneId: String, shellPID: Int32)] = []
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let cols = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard cols.count == 2,
                  !cols[0].isEmpty,
                  let pid = Int32(cols[1].trimmingCharacters(in: .whitespaces)) else { continue }
            out.append((paneId: cols[0], shellPID: pid))
        }
        return out
    }

    func listPanes(windowId: String) -> [(paneId: String, shellPID: Int32)] {
        Self.parsePaneList(from: tmux(["list-panes", "-t", windowId, "-F", "#{pane_id} #{pane_pid}"]))
    }

    /// Kill a window by id (sends SIGHUP to the pane's processes).
    func killWindow(windowId: String) {
        tmux(["kill-window", "-t", windowId])
    }

    func renameWindow(windowId: String, to name: String) {
        tmux(["rename-window", "-t", windowId, name])
    }

    /// The pane's shell pid (the parent under which the `claude` child lives),
    /// distinguishing a determined answer from a tmux that could not answer.
    /// `list-panes` exits 0 with `#{pane_pid}` when the window exists; ANY
    /// non-zero exit (no server running, a killed window, a 127 launch failure,
    /// or a `CommandRunner` timeout kill) means tmux could not tell us, so the
    /// result is `.unknown` rather than a false "no shell". `StateDetector` must
    /// never read `.unknown` as a crashed session. Pure classifier split out so
    /// the exit-code contract is unit-tested without a tmux server.
    static func panePIDProbe(from r: CommandResult) -> PanePIDProbe {
        guard r.ok else { return .unknown }
        if let pid = r.stdout
            .split(whereSeparator: { $0 == "\n" })
            .first
            .flatMap({ Int32($0.trimmingCharacters(in: .whitespaces)) }) {
            return .pid(pid)
        }
        return .unknown                          // succeeded but no pid: treat as undetermined
    }

    func panePIDProbe(windowId: String) -> PanePIDProbe {
        Self.panePIDProbe(from: tmux(["list-panes", "-t", windowId, "-F", "#{pane_pid}"]))
    }

    /// The pane's shell pid, or nil when it can't be read. Convenience over
    /// `panePIDProbe` for callers that retry on nil regardless of why (the spawn
    /// watch); detection uses `panePIDProbe` to tell a tool failure from absence.
    func panePID(windowId: String) -> Int32? {
        if case .pid(let pid) = panePIDProbe(windowId: windowId) { return pid }
        return nil
    }

    // MARK: @ccorn_id tag

    /// Tag a window with the Claude session UUID so reconciliation and rename can
    /// resolve windows robustly (independent of the display name). `-w` scopes the
    /// option to the window.
    func setCcornId(windowId: String, uuid: String) {
        tmux(["set-option", "-w", "-t", windowId, "@ccorn_id", uuid])
    }

    // MARK: @ccorn_status (per-session bar content)

    /// Write the per-window status-bar content into each changed window's
    /// `@ccorn_status` option (read back by `statusLeftFormat`), then force one
    /// status repaint so the change shows immediately on the focused client
    /// rather than waiting for the next `status-interval` tick. The caller
    /// passes only windows whose content changed (it diffs against
    /// `LiveSession.lastPushedStatusBar`), so a steady fleet writes nothing.
    ///
    /// The whole batch is one tmux invocation: commands are separated by a
    /// literal `;` argument, which works because `CommandRunner` execs tmux with
    /// an argv array (no shell), so the `;` reaches tmux as a command separator
    /// rather than being eaten by a shell.
    func setWindowStatusBars(_ changes: [(windowId: String, value: String)]) {
        guard !changes.isEmpty else { return }
        var args: [String] = []
        for (windowId, value) in changes {
            if !args.isEmpty { args.append(";") }
            args += ["set-option", "-w", "-t", windowId, StatusBarFormat.windowOption, value]
        }
        args += [";", "refresh-client", "-S"]
        tmux(args)
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
    /// in-string escapes, so both are backslash-escaped; backslash first, or the
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
    /// the safe name is chosen up front; the window is born correct, with no
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
    /// creates, one per attached terminal. A view shares `ccorn`'s window list
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
    /// NOT inherit the leader's current window; it lands on window 0, so the
    /// select is required). `destroy-unattached on` reaps the view the moment
    /// the terminal closes; it MUST be set with the client already attached
    /// (set on a *detached* session, tmux destroys it immediately), which is why
    /// it rides in this attaching command rather than being pre-set. Honors the
    /// debug socket+session overrides so a shakedown attach lands on the isolated
    /// server, not the user's real `ccorn`. tmux's command separator is a
    /// single-quoted `';'`; the shell hands tmux a literal `;`, avoiding
    /// backslash escaping inside the osascript `do script` string.
    ///
    /// `mouseMode` is set on the VIEW session, not just `ccorn`: a grouped
    /// session shares the window list but carries its own session options, so
    /// it does not inherit the base session's `mouse` value; the terminal the
    /// user actually attaches to is the view, so the option must land here for
    /// the scroll wheel to behave as configured. The copy-mode banner is set on
    /// the view for the same reason: `status-right` is a session option, the user
    /// attaches to the view, so the banner must land here to be visible. Its
    /// non-copy-mode branch resolves the GLOBAL `@ccorn_status_right_saved` stash
    /// (set by `installCopyModeBanner` before any attach), so it needs nothing
    /// else on the view; single-quoted because it carries spaces, `#{...}`, and
    /// `[]`, none of which the shell must touch, and it holds no quote of its own.
    /// The `pane-mode-changed` hook rides along for the same reason the base
    /// session sets it: without it the banner would only repaint on the status
    /// tick, not the instant the selection enters copy-mode.
    func attachViewCommand(windowId: String, mouseMode: Bool) -> String {
        let view = Self.uniqueViewSessionName(forWindowId: windowId, taken: Set(sessionNames()))
        let socket = Self.socketName.map { "-L \($0) " } ?? ""
        return "tmux \(socket)new-session -t \(Self.sessionName) -s \(view)"
            + " ';' set-option -t \(view) destroy-unattached on"
            + " ';' set-option -t \(view) mouse \(mouseMode ? "on" : "off")"
            + " ';' set-option -t \(view) status-right '\(Self.copyModeStatusRight)'"
            + " ';' set-hook -t \(view) pane-mode-changed 'refresh-client -S'"
            // CCorn's per-session bar (installStatusLine): set on the view for
            // the same reason as status-right above, since a view carries its
            // own session options and the user attaches to the view. status-left
            // resolves the window's @ccorn_status; single-quoted because it holds
            // `#{}` the shell must not touch. The sibling roster is blanked by
            // per-window options (hideSiblingRoster) the view inherits through
            // the shared windows, so nothing window-list-related is set here.
            + " ';' set-option -t \(view) status-left '\(Self.statusLeftFormat)'"
            + " ';' set-option -t \(view) status-left-length 200"
            + " ';' set-option -t \(view) status-interval 5"
            + " ';' select-window -t '\(view):\(windowId)'"
    }

    /// Reap view sessions orphaned by a crashed terminal, the backstop to
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
    /// for that view is byte-for-byte Terminal's `tty of tab`; so a live client
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
