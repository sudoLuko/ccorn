import Foundation

/// Builds the per-window content CCorn pushes into each managed window's
/// `@ccorn_status` tmux option, which the `ccorn` session's `status-left`
/// format reads back (`#{@ccorn_status}`). Because every managed session is a
/// window in the one shared `ccorn` session and `status-left` resolves a window
/// option in the context of the client's current window, each attached terminal
/// shows *its own* session's state instead of the default sibling roster.
///
/// Pure and table-tested: state in, a tmux format string out, no I/O. The one
/// mark per row the app shows (`StatusPresentation`) is the GUI's job; this is
/// its terminal counterpart, and it follows the same restraint: color marks
/// attention only. Calm facts (title, mode, remote/local, idle) render in the
/// status bar's base style; only the states that want the user get a colored
/// chip (amber for the recoverable broken tier, mirroring the GUI; red is
/// reserved for active BYPASS, the one genuinely loud condition).
///
/// tmux format mechanics this relies on (verified against tmux 3.6's
/// `format_draw`): `#{@ccorn_status}` inserts the option value verbatim, then
/// the status drawer interprets `#[...]` style directives in the result and
/// collapses `##` to a single `#`. So CCorn's own style runs are written as a
/// single `#[...]`, while any dynamic text (a title) is escaped `#`->`##`,
/// which both prints a literal `#` and disarms a `#[...]` a title might carry
/// (it becomes the literal text `#[...]`, never an injected style).
enum StatusBarFormat {
    /// tmux 256-color tokens. Amber is the copy-mode banner's `colour214`
    /// (TmuxController.copyModeStatusRight), reused so the bar speaks one
    /// warning color; red is the terminal-severity danger token.
    private static let amberBg = "colour214"
    private static let amberFg = "colour16"
    private static let dangerBg = "colour160"
    private static let dangerFg = "colour231"

    /// Longest title kept before eliding; the bar is width-pressured and the
    /// terminal clips the rest anyway, so a generous cap only bounds the option
    /// value, never the visible width.
    static let maxTitleLength = 48

    /// The tmux user option the status-left format reads. Window-scoped, set per
    /// window by `TmuxController.setWindowStatusBars`, alongside the existing
    /// `@ccorn_id` / `@ccorn_managed` window options.
    static let windowOption = "@ccorn_status"

    /// Escape dynamic text for the status drawer: `#`->`##`. A literal `#` then
    /// renders as one `#`, and a `#[...]` a title happens to contain can no
    /// longer inject a style (it draws as the literal text `#[...]`). The only
    /// metacharacter the drawer acts on is `#`, so this is the whole escape.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "#", with: "##")
    }

    /// A colored "chip": padded text on a solid background, the bar's attention
    /// treatment (the copy-mode banner is the same shape). `#[default]` returns
    /// the following text to the bar's base style.
    private static func chip(_ text: String, bg: String, fg: String) -> String {
        "#[bg=\(bg)]#[fg=\(fg)] \(text) #[default]"
    }

    private static func amberChip(_ text: String) -> String {
        chip(text, bg: amberBg, fg: amberFg)
    }

    private static func dangerChip(_ text: String) -> String {
        chip(text, bg: dangerBg, fg: dangerFg)
    }

    /// Coarse, minute-granular idle label, or nil under a minute. Minute
    /// granularity is deliberate: the displayed value (and therefore the
    /// rewritten option) changes at most once a minute per idle session, which
    /// bounds the bar's write rate to near nothing when nothing is happening.
    static func idleLabel(seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "idle \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "idle \(hours)h" : "idle \(hours)h\(remainder)m"
    }

    /// The calm permission-mode word, or nil when there is nothing useful to
    /// show. `.bypass` returns nil here because active bypass is surfaced by the
    /// loud chip via `isBypass`; the bare launch flag is not shown on its own.
    static func modeLabel(_ mode: CCPermissionMode) -> String? {
        switch mode {
        case .standard:    return "default"
        case .plan:        return "plan"
        case .acceptEdits: return "accept-edits"
        case .auto:        return "auto"
        case .allowBypass: return "allow-bypass"
        case .bypass:      return nil
        }
    }

    /// Build the status-left content for one managed window.
    ///
    /// - `isBypass`: permissions are bypassed *right now* (runtime pane signal
    ///   OR a `.bypass` launch posture), the same fold the GUI row uses; it wins
    ///   the mode slot with a loud red chip — but only for an alive state, since
    ///   a process that has died is no longer bypassing anything.
    /// - The remote slot is suppressed entirely while a session is blocked on
    ///   sign-in (remote control can't be up before authentication, so the
    ///   sign-in chip is the whole story) or once the process is gone (a dead
    ///   session resolves to `ended`, with no separate remote claim), mirroring
    ///   the GUI's "sign-in is the root cause" / early `.ended` precedence.
    static func windowStatus(title: String,
                             state: SessionState,
                             permissionMode: CCPermissionMode?,
                             isBypass: Bool,
                             remoteControlRequested: Bool,
                             remoteControlActive: Bool,
                             rcGraceExpired: Bool,
                             idleSeconds: TimeInterval?) -> String {
        var segments: [String] = []

        // 1. Title (escaped, elided). Falls back to a placeholder so a not-yet-
        //    titled session still reads as something rather than empty.
        let name = title.isEmpty ? "session" : title
        let elided = name.count > maxTitleLength
            ? String(name.prefix(maxTitleLength - 1)) + "\u{2026}"
            : name
        segments.append(escape(elided))

        // 2. Permission mode / bypass. The loud BYPASS chip means "permissions
        //    are bypassed *right now*", which is only true while the process is
        //    executing: a dead bypass session is no longer running anything, so
        //    it shows no mode chip (the `ended` state chip carries it). Gating on
        //    `isAliveState` keeps the red alarm from outliving the process.
        if isBypass, state.isAliveState {
            segments.append(dangerChip("BYPASS"))
        } else if let mode = permissionMode, let label = modeLabel(mode) {
            segments.append(label)
        }

        // 3. Remote control (moot while blocked on sign-in, and moot once the
        //    process is gone). For `.dead`, mirror `StatusPresentation.resolve`,
        //    which returns `.ended` early before any no-remote check: a no-remote
        //    chip on a process that no longer exists asserts remote-control-not-up
        //    for nothing, contradicting the GUI's single `ended` mark. So the
        //    `ended` state chip is the whole story for a dead session too.
        if state != .needsAuth && state != .dead {
            if !remoteControlRequested {
                segments.append("local")
            } else if remoteControlActive || !rcGraceExpired {
                // Within the activation grace, stay optimistic: it was requested
                // and is expected to come up, so don't flash "no remote".
                segments.append("remote")
            } else {
                segments.append(amberChip("no remote"))
            }
        }

        // 4. State / idle. Working and waiting are obvious in the pane the user
        //    is looking at, so the bar just names them; the broken trio gets its
        //    chip; an idle session shows how long it has been quiet.
        switch state {
        case .working:
            segments.append("working")
        case .waiting:
            segments.append("needs input")
        case .needsAuth:
            segments.append(amberChip("sign in"))
        case .dead:
            // The process is gone (clean /exit or crash, indistinguishable to
            // CCorn): a recoverable amber "ended" chip, not a red alarm,
            // mirroring the GUI's `.ended` broken-tier mark.
            segments.append(amberChip("ended"))
        case .running, .stale:
            if let seconds = idleSeconds, let label = idleLabel(seconds: seconds) {
                segments.append(label)
            }
        case .stopped, .unmanaged:
            break   // no live window to label
        }

        return segments.joined(separator: "  ")
    }
}
