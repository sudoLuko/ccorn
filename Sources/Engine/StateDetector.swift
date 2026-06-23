import Foundation
import CryptoKit

/// A pane-pid lookup resolves three ways: it ANSWERS with the shell pid, it
/// answers that the window is GONE (a determined absence), or it FAILS TO ANSWER.
///
///   * `.pid`     - tmux ran and reported the pane shell.
///   * `.absent`  - tmux ran and the target is gone: the window was killed out
///     from under CCorn, or the whole server died. A DETERMINED absence, so the
///     session is Dead. (tmux exits 1 for "can't find window"/"no server".)
///   * `.unknown` - tmux could NOT answer (a 127 launch failure, a timeout kill,
///     or a server hiccup): liveness is undetermined. Detection must not read it
///     as "no shell" and flip the session to crashed; it holds non-dead and lets
///     the next poll retry.
///
/// The `.absent`/`.unknown` split is load-bearing: it is what lets a vanished
/// window flip to Dead while a transient tool failure still holds Running (a
/// genuine claude crash, by contrast, leaves the pane SHELL alive, so it
/// surfaces as `.pid` + a determined-empty `pgrep`, never as a tmux probe here).
enum PanePIDProbe: Sendable, Equatable {
    case pid(Int32)
    case absent
    case unknown
}

/// The tmux reads a detection pass needs. `TmuxController` is the live
/// implementation; tests substitute a stub so the classifier and the
/// dead/grace/re-derive logic run against captured fixtures without a tmux server.
protocol PaneSource: Sendable {
    /// Capture a pane's visible frame. `target` is a window id (active pane) or a
    /// freshly-resolved pane id (the pane actually running claude after a split).
    func capturePane(windowId target: String) -> String
    func panePIDProbe(windowId: String) -> PanePIDProbe
    /// `(paneId, shellPID)` per pane in the window, so detection can follow the
    /// pane running `claude` instead of the active one. An empty list means the
    /// enumeration failed (or, degenerate, no panes); detection then keeps the
    /// window-target capture, never a worse state.
    func listPanes(windowId: String) -> [(paneId: String, shellPID: Int32)]
}

extension TmuxController: PaneSource {}

/// Snapshot of a LiveSession's detection-relevant fields, read on the main actor
/// and passed by value so the detector can run off-main without touching shared
/// mutable state.
struct DetectionInput: Sendable {
    var windowId: String?
    var pid: Int32?
    var lastPaneHash: String?
    var lastHashChange: Date?
    /// Whether the previous pass saw the live-activity marker. Lets `classifyPane`
    /// recognise the marker present->absent edge (a finished turn) and flip
    /// straight to Running, instead of the change-fallback holding Working for
    /// one more poll. Defaults false so first observations and marker-less
    /// renderers behave exactly as before.
    var wasShowingLiveActivity: Bool
    var rcCache: BridgeSessionCache

    init(windowId: String?,
         pid: Int32?,
         lastPaneHash: String? = nil,
         lastHashChange: Date? = nil,
         wasShowingLiveActivity: Bool = false,
         rcCache: BridgeSessionCache = BridgeSessionCache()) {
        self.windowId = windowId
        self.pid = pid
        self.lastPaneHash = lastPaneHash
        self.lastHashChange = lastHashChange
        self.wasShowingLiveActivity = wasShowingLiveActivity
        self.rcCache = rcCache
    }
}

/// Whether a captured remote-control failure names a genuine account/plan
/// limitation (RC truly unsupported for this auth: an API key, an
/// inference-only token, or a plan that lacks it) or a transient/ambiguous
/// failure (a credentials-fetch hiccup, a network blip, a timeout) that may
/// clear on its own. Only `.definitive` earns the account verdict: the modal
/// and the local fallback; `.transient` stays a soft No-remote signal
/// (docs/CCORN_SPEC.md section 8).
enum RCFailureKind: Sendable, Equatable {
    case definitive
    case transient
}

/// What a detection pass decided; applied back to the LiveSession on the main actor.
struct DetectionResult: Sendable {
    var state: SessionState
    var pid: Int32?
    var remoteControlActive: Bool
    /// The "fresh" remote-control-active signal: the live footer/chip OR the
    /// registry bridge handle, WITHOUT the sticky transcript `bridge-session`
    /// leg of `remoteControlActive`. The transcript leg is sticky-positive for
    /// the whole run (records never disappear), which is correct for keeping a
    /// healthy idle session off the No-remote path but wrong for the
    /// account-capability verdict, which must react to RC being up *right now*.
    /// `reconcileRCAccountCapability` reads this; the no-remote presentation
    /// path keeps reading the sticky `remoteControlActive` above. Defaults false
    /// so a `DetectionResult` built without it behaves as "not freshly up".
    var remoteControlActiveFresh: Bool = false
    var lastPaneHash: String?
    var lastHashChange: Date?
    /// Whether this pass saw the live-activity marker, carried back so the next
    /// pass can detect the present->absent edge (see `DetectionInput`).
    var wasShowingLiveActivity: Bool
    var rcCache: BridgeSessionCache
    /// The CLI's own auth-error line when the pane shows a login prompt
    /// (docs/CCORN_SPEC.md section 8: surface the CLI's text, not a canned string).
    var authNotice: String?
    /// The CLI's own line when remote control failed for plan/credential
    /// reasons (section 8's plan-restriction alert).
    var rcPlanNotice: String?
    /// The kind of that failure (`.definitive` account/plan limitation vs
    /// `.transient` recoverable hiccup), nil when none was seen. Only set when
    /// remote control is not currently up (see `detect`), so a failure line that
    /// lingers in the pane after RC reconnected never re-asserts a verdict.
    var rcFailureKind: RCFailureKind?
    /// True when the pane footer reports permissions are being bypassed right
    /// now: a session launched with `--dangerously-skip-permissions` or one the
    /// user escalated into bypass mid-session (Shift+Tab). Drives the row's
    /// bypass marker; reflects ACTUAL runtime state, not just the launch flag.
    var bypassActive: Bool = false
    /// The remote-control bridge handle from the process session registry: a
    /// `session_…` id equal to the `claude.ai/code/<id>` per-session URL
    /// segment (verified against the URLs Claude Code prints). nil until the
    /// bridge links, or while the registry file lags a live bridge
    /// (positive-only, like the RC signal it feeds). NOT the transcript
    /// `bridge-session` record's id, which is a `cse_…` in a different
    /// namespace that is not URL-valid; never build the deep link from that
    /// one. Drives the per-session "Open in Browser" handoff.
    var bridgeSessionId: String?
}

/// Caches the bridge-session transcript check so the 3s refresh hot path does
/// not re-read the transcript every tick. A transcript is append-only, so a
/// positive result is sticky for its path; a negative result is re-checked only
/// when the (path, mtime) pair changes.
struct BridgeSessionCache: Sendable, Equatable {
    private var path: String?
    private var mtime: Date?
    private var hasBridge = false

    init() {}

    /// True if the transcript at `path` contains a `bridge-session` record,
    /// reading the file only when the cached answer can't still be valid.
    mutating func hasBridgeSession(path: String?, mtime: Date?) -> Bool {
        guard let path else { return false }
        if path == self.path {
            if hasBridge { return true }                  // sticky: records never disappear
            if mtime == self.mtime { return hasBridge }   // unchanged file, cached negative
        }
        self.path = path
        self.mtime = mtime
        hasBridge = SessionDiscovery.transcriptHasBridgeSession(path: path)
        return hasBridge
    }
}

/// Detects a session's state from a `tmux capture-pane` snapshot, PID liveness,
/// and the remote-control signal. See docs/CCORN_SPEC.md section 4 and
/// runtime findings T1/T2/T5.
///
/// Precedence for a managed session:
///   1. no live `claude` pid (after re-deriving from the pane shell) -> Dead,
///      unless the pane shell itself is younger than the spawn grace window
///      (still spawning) -> Running.
///   2. pane shows the live-activity hint or a spinner frame -> Working
///   3. pane shows a permission/confirmation prompt -> Waiting
///   4. pane changed since the previous poll -> Working (something is rendering)
///   5. otherwise -> Running, unless the pane hash has been unchanged longer
///      than the stale threshold, in which case -> Stale.
///
/// Remote-control-active is reported separately (it drives the row's warning
/// indicator); it does not change the Working/Waiting/Running dot.
struct StateDetector: Sendable {

    /// The footer remote-control indicators, across CLI versions. Claude Code
    /// 2.1.169–2.1.171 printed the literal `Remote Control active` (runtime
    /// findings C2); 2.1.172 removed it and 2.1.173 replaced the footer with a
    /// short `/rc <state>` chip (verified live: the old literal has zero
    /// occurrences in the 2.1.173 binary). `remoteControlMarker` is kept for the
    /// older versions and as the `claude-evidence` / plan-notice anchor; the
    /// chip vocabulary below covers 2.1.172+.
    ///
    /// Chip states: `active` is connected; `connecting`/`reconnecting` are the
    /// transient bring-up/recovery handshake; remote control is engaging, not
    /// failed, so they must read as engaged and never trip "No remote";
    /// `failed` is the genuine failure (alongside the verbose
    /// "Remote Control … {disabled,unavailable,…}" messages, see `rcPlanNotice`).
    static let remoteControlMarker = "Remote Control active"          // ≤ 2.1.171
    static let rcChipActive = "/rc active"                            // ≥ 2.1.172
    static let rcChipConnecting = ["/rc connecting", "/rc reconnecting"]
    static let rcChipFailed = "/rc failed"

    /// Active-bypass footer: a session running with permission checks skipped,
    /// launched with `--dangerously-skip-permissions`, or escalated into bypass
    /// mid-session via Shift+Tab (the `--allow-dangerously-skip-permissions`
    /// path). Claude renders a status-bar line like `⏵ bypass permissions on`;
    /// matched on the core phrase, case-insensitively, so the leading glyph and
    /// spacing can vary across CLI versions without breaking detection.
    static let bypassMarker = "bypass permissions on"

    /// Rendered ONLY while Claude is actively executing (verified on 2.1.169 and
    /// 2.1.170): the `esc to interrupt` hint accompanies the live spinner/status
    /// line and disappears the moment the turn finishes. Tool-call markers like
    /// `Bash(` and the `✻ <verb>ed for Ns` glyph lines persist in finished-but-idle
    /// frames, so they must NOT be used as a Working signal (runtime findings T5).
    static let liveActivityMarker = "esc to interrupt"

    /// Braille spinner frames older/newer renderers may use. Dead on
    /// 2.1.169/2.1.170 (which cycle `·✢✳✶✻✽` instead, glyphs that also persist
    /// after finish). Kept only as a forward-compat fallback; it cannot
    /// false-positive on current versions because braille never renders.
    static let spinnerChars = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// Structural prompt affordances that only the live confirmation UI renders:
    /// the affirmative option of an approval picker (`1. Yes …`) or the
    /// `Enter to confirm` hint. These are the chrome of the trust dialog,
    /// tool-permission, and plan-mode prompts (see the `waiting-*`/`needs-auth-*`
    /// fixtures); every real approval prompt renders at least one of them
    /// alongside its question.
    ///
    /// Deliberately NOT here: the bare cursor glyph + index `❯ 1.`. It is not an
    /// approval affordance, only "the cursor is on the first list item", and it
    /// renders identically in a *settings* picker like `/model` when the user
    /// arrows up to item 1 ("❯ 1. Default …"), which is a configuration menu, not
    /// a prompt for input. Matching it false-flagged the `/model` picker as
    /// Waiting (the `slash-model-picker-item1-2181` fixture). A real approval
    /// prompt always also carries an explicit affordance ("1. Yes" / "Enter to
    /// confirm"), so dropping the bare glyph costs no real detection while
    /// removing the settings-picker collision. `isWaiting` additionally refuses
    /// any region that carries a settings-commit footer (see `settingsMenuPhrases`).
    ///
    /// Also deliberately NOT here: the synthetic `(y/n)` / `[y/N]` tokens. No real
    /// captured 2.1.x frame renders either in a *live* approval region — every
    /// real prompt uses the numbered `1. Yes` picker — so they only ever matched
    /// prose that the user (or Claude) typed into scrollback, pure false-positive
    /// risk with no true-positive coverage to back them.
    ///
    /// Deliberately NOT here either: natural-language phrasings like "Do you want…",
    /// "Would you like…", or "Approve …". They read identically in ordinary
    /// assistant prose that lingers in an idle scrollback frame ("Do you want to
    /// rename a session to …?"), so matching them as bare substrings false-flagged
    /// finished, idle sessions as needs-input (the `idle-conversational-*`
    /// fixture). Because a genuine prompt always carries the structural chrome
    /// above, dropping the prose costs no real detection. The persistent `>`
    /// input box is likewise not a signal; it is present even when idle.
    static let waitingPhrases = [
        "1. Yes", "Enter to confirm",
    ]

    /// Settings-commit footers that mark the live region as a *settings* menu (a
    /// configuration picker the user opened, e.g. `/model`), not a prompt Claude
    /// is blocked on. A genuine approval prompt commits with `Enter to confirm`
    /// or a numbered choice; a settings menu commits a default with this chrome.
    /// When the live region carries one of these, `isWaiting` is suppressed even
    /// if some affordance phrase incidentally matches, so arrowing the `/model`
    /// cursor onto an item that happens to read "1. …" never reads as needs-input
    /// (the `slash-model-picker-item1-2181` fixture).
    static let settingsMenuPhrases = [
        "Enter to set as default",
        "to use this session only",
    ]

    /// Auth signals come in two tiers because they live in the pane differently
    /// (docs/CCORN_SPEC.md section 8, "User not authenticated").
    ///
    /// `authLoginChrome` is the live login UI: the picker, the OAuth/browser
    /// flow, the paste-code prompt. These render ONLY while sign-in is actively
    /// blocking — they replace the input box, they don't scroll up into history
    /// as a finished turn — so a match anywhere in the pane is a genuine block,
    /// no supersession check needed.
    static let authLoginChrome = [
        "Select login method",
        "Paste code here if prompted",
        "use the url below to sign in",
        "Press Enter to open your browser and sign in",
    ]

    /// `authErrorResult` is the OTHER kind: an error printed as a *tool result*
    /// for a turn (the `⎿ Invalid API key` result line, an OAuth-token failure,
    /// a "Please run /login" nudge). Unlike the login chrome, an error result
    /// scrolls up into history once the turn is done and lingers there. So a
    /// match alone is NOT proof the session is still blocked: a session that
    /// errored, then ran a SUCCESSFUL turn, keeps the stale phrase in
    /// scrollback (the `recovered-auth-in-scrollback-2181` fixture).
    ///
    /// The distinguishing signal (validated against both poles, the recovered
    /// and the genuinely-blocked fixtures): an error-result phrase forces
    /// needsAuth only when it is NOT superseded — i.e. no `⏺` assistant-response
    /// bullet line (`authResponseBullet`) appears at a line index AFTER the last
    /// error-result line. A successful turn always emits a `⏺` response, so
    /// `⏺` after the error means the session recovered; no `⏺` after it (the
    /// turn errored without producing a response) means it is still blocked.
    /// A re-errored turn keeps reading blocked: the newest error becomes the
    /// last error line and its turn's `⏺` sits above it, not after it. The
    /// `✻ <verb>ed for Ns` glyph renders after an *errored* turn too, so it is
    /// NOT a usable supersession signal; only `⏺` is.
    static let authErrorResult = [
        "Invalid API key",
        "OAuth token expired",
        "OAuth token revoked",
        "Please run /login",
    ]

    /// The assistant-response bullet (U+23FA), printed at the head of a
    /// completed assistant turn's output. Its presence on a line AFTER the last
    /// error-result line is what marks an auth error as superseded (see
    /// `authErrorResult`).
    static let authResponseBullet: Character = "⏺"

    /// Fatal launch errors that make `claude` exit immediately, leaving no child
    /// process; so the spawn watch times out and would otherwise report the
    /// generic "no claude process appeared". The clearest case is the bypass root
    /// refusal (`--dangerously-skip-permissions cannot be used with root/sudo
    /// privileges …`). Matched loosely so version wording can drift.
    static let launchFatalPhrases = [
        "cannot be used with root",
        "cannot be used with sudo",
    ]

    /// The CLI's own fatal-launch line if the pane shows one (e.g. the bypass
    /// root refusal), nil otherwise; so the failed-start alert can lead with
    /// Claude Code's words instead of a generic message.
    func launchFatalError(pane: String) -> String? {
        for line in pane.split(whereSeparator: \.isNewline) {
            if Self.launchFatalPhrases.contains(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                return Self.cleanTUILine(line)
            }
        }
        return nil
    }

    /// Definitive account/plan limitations: remote control is genuinely
    /// unsupported for this authentication (an API key or inference-only token,
    /// or a plan/org policy that lacks it). A pane line pairing "remote control"
    /// with one of these is the account verdict; it fires the one-time plan
    /// modal and flips new sessions to local. Checked before the transient set,
    /// so a line carrying both ("…failed: not available on your plan") is read
    /// as the definitive limitation it names.
    static let rcPlanDefinitiveWords = [
        "not available", "not supported", "requires", "upgrade",
        "inference-only", "inference only", "api key",
        "not enabled", "not yet enabled", "disabled by",
    ]

    /// Transient or ambiguous failures: a credentials-fetch hiccup, a network
    /// blip, a timeout, a handshake that didn't complete. These can clear on
    /// their own (short drops reconnect, docs/CCORN_SPEC.md section 2), so they
    /// must NOT assert an account limitation; they surface only as the soft
    /// No-remote signal. Note `unavailable` is transient on purpose; the
    /// definitive phrasing is the two-word "not available", caught above.
    static let rcPlanTransientWords = [
        "failed", "fetch failed", "unavailable", "timed out", "timeout",
        "network", "could not connect", "couldn't connect", "reconnect",
        "try again",
    ]

    /// How long a freshly created window may sit without a `claude` child before
    /// it is reported Dead instead of "still spawning" (node installs can take
    /// several seconds to exec).
    static let spawnGraceSeconds: TimeInterval = 10

    // MARK: - Signals

    /// True when the pane shows Claude actively executing *right now*: the
    /// `esc to interrupt` hint (2.1.169/2.1.170) or a braille spinner frame
    /// (forward-compat). Deliberately ignores tool-call markers, which persist
    /// after the call finishes (runtime findings T5).
    func showsLiveActivity(pane: String) -> Bool {
        if pane.contains(Self.liveActivityMarker) { return true }
        return pane.contains(where: { Self.spinnerChars.contains($0) })
    }

    /// True when the footer reports remote control *engaged*: connected, or in
    /// the transient connecting/reconnecting handshake. Matches both the
    /// pre-2.1.172 `Remote Control active` literal and the 2.1.172+ `/rc` chip,
    /// so detection is version-robust. `/rc failed` and an absent chip are
    /// deliberately excluded; that is the no-remote case, decided elsewhere.
    /// This is a *positive* signal only: its absence does not prove RC is down
    /// (the footer can lag in an un-repainted idle TUI), which is why `detect`
    /// ORs it with the registry/transcript bridge signals rather than treating
    /// a miss as failure.
    func showsRemoteControlEngaged(pane: String) -> Bool {
        if pane.contains(Self.remoteControlMarker) { return true }
        if pane.contains(Self.rcChipActive) { return true }
        return Self.rcChipConnecting.contains { pane.contains($0) }
    }

    /// True when the pane footer reports permissions are currently bypassed.
    func showsBypass(pane: String) -> Bool {
        pane.localizedCaseInsensitiveContains(Self.bypassMarker)
    }

    /// True when a pane shows any trace of ever having hosted Claude Code.
    /// Used by launch reconciliation to tell a died claude session from a bare
    /// shell window, e.g. the default window `tmux new-session` spawns, which
    /// automatic-rename labels "zsh". Generous on purpose: a stale TUI frame
    /// (runtime findings T2), a clean-exit `claude --resume` hint, or a typed
    /// `claude` command all count; only a pane with no claude trace at all is
    /// treated as never-ran-claude.
    func showsClaudeEvidence(pane: String) -> Bool {
        if pane.contains("claude") { return true }   // typed command / resume hint / paths
        if pane.contains("Claude") { return true }   // TUI brand text
        if pane.contains(Self.remoteControlMarker) { return true }
        if pane.contains(Self.liveActivityMarker) { return true }
        if pane.contains("? for shortcuts") { return true }
        return false
    }

    /// A captured-frame line is a horizontal rule (an input-box border or the top
    /// of a prompt dialog) when it is mostly box-drawing horizontals. The 20-char
    /// floor sits well above any incidental `─` run in conversation text yet below
    /// the width of every real border.
    private static func isRuleLine(_ line: Substring) -> Bool {
        line.filter { $0 == "─" || $0 == "━" }.count >= 20
    }

    /// The bottom "live UI" region of a captured frame: the suffix from the last
    /// horizontal-rule line onward. A confirmation prompt replaces the input box
    /// and renders as the bottom-most rule-delimited block, verified on 2.1.173
    /// for the trust dialog and the tool-permission dialog (see the `waiting-*`
    /// fixtures), so the real prompt chrome lives here, while finished
    /// conversation (a pasted option list, a `(y/n)` written in prose) sits in the
    /// scrollback above. Scoping the Waiting scan to this region keeps that
    /// lingering chrome from flagging an idle session (the
    /// `idle-marker-in-scrollback` fixture). With no rule line at all (a bare
    /// pane, never a real live TUI) it returns the whole pane: conservative, so a
    /// genuine prompt is never missed.
    static func livePromptRegion(_ pane: String) -> String {
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false)
        guard let lastRule = lines.lastIndex(where: { isRuleLine($0) }) else { return pane }
        return lines[lastRule...].joined(separator: "\n")
    }

    func isWaiting(pane: String) -> Bool {
        let region = Self.livePromptRegion(pane)
        // A settings picker (e.g. `/model`) renders its option list inside the
        // live region with a settings-commit footer; it is a configuration menu
        // the user opened, not a prompt Claude is blocked on. Never read one as
        // needs-input, even if an option line happens to read like an affordance.
        if Self.settingsMenuPhrases.contains(where: { region.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        return Self.waitingPhrases.contains { region.localizedCaseInsensitiveContains($0) }
    }

    /// The CLI's auth-error/login line if the pane shows a GENUINE sign-in
    /// block, nil otherwise. Returns the matched line (trimmed of TUI
    /// box-drawing and whitespace) so the alert can surface Claude Code's own
    /// words (the return contract the alert/tooltip relies on is preserved).
    ///
    /// Two tiers, scanned over the WHOLE pane (an error result is in scrollback
    /// by definition, so live-region scoping would miss it):
    ///   * `authLoginChrome` — a live login screen; a match anywhere is a block.
    ///   * `authErrorResult` — an error tool-result; a match blocks ONLY when
    ///     it is not superseded by a later `⏺` assistant-response bullet (a
    ///     successful turn ran after the error, so the session recovered).
    ///
    /// Login chrome wins outright. Otherwise the last error-result line is
    /// compared against the last `⏺` line: a `⏺` at a strictly greater index
    /// means recovered (nil); no later `⏺` means still blocked (the error line).
    /// `classifyPane`/`detect` precedence is unchanged — live activity still
    /// preempts this — so a phrase streamed mid-turn never reaches here.
    func authNotice(pane: String) -> String? {
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false)

        // Live login chrome: a match anywhere is a genuine block, full stop.
        for line in lines {
            if let phrase = Self.authLoginChrome.first(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                let cleaned = Self.cleanTUILine(line)
                return cleaned.isEmpty ? phrase : cleaned
            }
        }

        // Error-result: find the LAST line carrying one, then check whether an
        // `⏺` assistant-response bullet appears on any LATER line (the turn
        // recovered). Track both in one pass over the pane.
        var lastErrorLine: (index: Int, text: Substring, phrase: String)?
        var lastBulletIndex: Int?
        for (index, line) in lines.enumerated() {
            if line.contains(Self.authResponseBullet) {
                lastBulletIndex = index
            }
            if let phrase = Self.authErrorResult.first(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                lastErrorLine = (index, line, phrase)
            }
        }
        guard let error = lastErrorLine else { return nil }
        // Superseded: a response bullet sits AFTER the last error line.
        if let bullet = lastBulletIndex, bullet > error.index { return nil }
        let cleaned = Self.cleanTUILine(error.text)
        return cleaned.isEmpty ? error.phrase : cleaned
    }

    /// The CLI's remote-control failure line plus its kind, if the pane's *live
    /// region* reports that remote control could not be enabled. Scoped to the
    /// live region (not the whole pane) so a stale failure line scrolled up into
    /// history is not read as current; the same `livePromptRegion` scoping the
    /// Waiting scan uses. The stable `Remote Control active` footer never trips
    /// it; a definitive account/plan match outranks a transient one on the same
    /// line.
    func rcFailure(pane: String) -> (message: String, kind: RCFailureKind)? {
        for line in Self.livePromptRegion(pane).split(whereSeparator: \.isNewline) {
            guard line.localizedCaseInsensitiveContains("remote control"),
                  !line.contains(Self.remoteControlMarker) else { continue }
            if Self.rcPlanDefinitiveWords.contains(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                return (Self.cleanTUILine(line), .definitive)
            }
            if Self.rcPlanTransientWords.contains(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                return (Self.cleanTUILine(line), .transient)
            }
        }
        return nil
    }

    /// The CLI's remote-control failure line (either kind), nil when none: the
    /// row tooltip's soft No-remote text. The verdict-bearing kind comes from
    /// `rcFailure`.
    func rcPlanNotice(pane: String) -> String? {
        rcFailure(pane: pane)?.message
    }

    /// Strip TUI chrome (box-drawing borders, prompt glyphs) and surrounding
    /// whitespace from a captured pane line.
    private static func cleanTUILine(_ line: Substring) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "│┃|╭╮╰╯─━❯> \t"))
    }

    /// Default `bridgeForPid` for `detect`: the live remote-control bridge
    /// handle the claude process records in its own session-registry file. A
    /// version-independent positive RC signal (the field predates the footer
    /// string change). Injected by tests so `detect` need not touch `~/.claude`.
    static func registryBridge(pid: Int32) -> String? {
        ClaudeSessionRegistry.info(forPid: pid)?.bridgeSessionId
    }

    static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pane following

    /// Pick the pane whose shell subtree contains the tracked `claude` pid, so a
    /// split window captures the claude pane rather than tmux's active one. Pure:
    /// no Process/tmux I/O. Membership is delegated to `contains`, which the
    /// caller backs with the SAME argv-based `ProcessControl.findClaude` walk
    /// detection already uses (`findClaude(belowShell: shellPID) == .found(pid)`),
    /// so this introduces no second way to identify claude.
    ///
    /// Returns nil and lets the caller fall back to the window-target capture
    /// when: the list is empty (enumeration failed, or one pane — the common
    /// single-pane case, where the window target already is the claude pane);
    /// there is exactly one pane (no split, nothing to follow); or no pane's
    /// subtree contains the pid (the determined-absent / dead path then runs
    /// unchanged on the active pane). The single-pane short-circuit also avoids a
    /// needless subtree walk in the overwhelmingly common case.
    static func selectClaudePane(panes: [(paneId: String, shellPID: Int32)],
                                 claudePID: Int32,
                                 contains: (_ shellPID: Int32, _ claudePID: Int32) -> Bool)
                                 -> String? {
        guard panes.count > 1 else { return nil }
        return panes.first { contains($0.shellPID, claudePID) }?.paneId
    }

    // MARK: - Re-derivation

    /// The outcome of re-deriving the live claude pid for a window whose tracked
    /// pid is gone, decided from the shells of ALL its panes (a split may run
    /// claude in a pane other than the active one). `.undetermined` is the
    /// tool-failure-hardening hold (any probe could not answer); `.stillSpawning`
    /// is a determined-absent-within-grace hold; `.dead` is the determined crash.
    enum Rederivation: Equatable {
        case found(Int32)
        case undetermined
        case stillSpawning
        case dead
    }

    /// Re-derive the live claude pid across a window's panes. Enumerate panes with
    /// `listPanes` and probe EACH pane's shell with the SAME argv-based
    /// `claudeBelowShell` walk the alive path uses, so a split where claude runs
    /// in a non-active pane is not mis-declared Dead. Resolution order, matching
    /// the tool-failure-hardening invariant ("a tool that could not answer holds
    /// non-dead, never crashes"):
    ///
    ///   * any pane shell hosts a claude child            -> `.found` (alive)
    ///   * else any probe is `.unknown`                   -> `.undetermined` (hold)
    ///   * else (every probe determined-absent) any pane
    ///     shell is younger than the spawn grace          -> `.stillSpawning` (hold)
    ///   * else                                           -> `.dead`
    ///
    /// When `listPanes` returns no panes (enumeration failed, or — as the existing
    /// single-pane suites model it — the pre-following codepath), fall back to the
    /// active-pane `panePIDProbe`: a single-pane window's only pane IS the window
    /// target, so the active-pane probe is exactly the right (and unchanged)
    /// answer, and a genuinely failed `panePIDProbe` itself reports `.unknown`,
    /// which maps to `.undetermined` here.
    private func rederiveLivePID(windowId: String,
                                 panes: PaneSource,
                                 now: Date,
                                 spawnGrace: TimeInterval,
                                 claudeBelowShell: (Int32) -> ProcessControl.ClaudeScan)
                                 -> Rederivation {
        let paneShells: [Int32]
        let listed = panes.listPanes(windowId: windowId)
        if listed.isEmpty {
            // No enumeration: fall back to the active-pane shell probe (preserves
            // single-pane behavior exactly), reading its determinacy.
            switch panes.panePIDProbe(windowId: windowId) {
            case .pid(let shellPID):
                paneShells = [shellPID]
            case .absent:
                // The window itself is gone: killed out from under CCorn, or the
                // whole tmux server died. A DETERMINED absence (tmux ran and said
                // so), so the session is Dead. A gone window cannot be mid-spawn,
                // so this bypasses the grace window. This is the case the poll
                // missed before: panePIDProbe lumped a killed window in with a
                // tool failure, so a vanished session held Running forever.
                return .dead
            case .unknown:
                // A tool-failure (127 / timeout / hiccup): absence is unproven, so
                // hold non-dead and let the next poll re-derive.
                return .undetermined
            }
        } else {
            paneShells = listed.map(\.shellPID)
        }

        var sawUnknown = false
        for shellPID in paneShells {
            switch claudeBelowShell(shellPID) {
            case .found(let pid): return .found(pid)
            case .unknown:        sawUnknown = true
            case .absent:         continue
            }
        }
        if sawUnknown { return .undetermined }   // a probe couldn't answer: hold

        // Every pane's shell is determined-absent. Hold only while a pane shell is
        // still inside the spawn grace window (claude may be exec'ing).
        let stillSpawning = paneShells.contains { shellPID in
            if let start = ProcessControl.startTime(pid: shellPID) {
                return now.timeIntervalSince(start) < spawnGrace
            }
            return false
        }
        return stillSpawning ? .stillSpawning : .dead
    }

    // MARK: - Detection

    /// One detection pass. Pure with respect to shared state: reads tmux/process
    /// facts through `panes`/ProcessControl, never mutates the store; the caller
    /// applies the returned result on the main actor.
    ///
    /// Dead is decided from PID liveness, never from pane content: an exited
    /// window keeps stale `Bash(` / `Remote Control active` markers
    /// (runtime findings T2). When the tracked pid is missing or gone, the pid is
    /// re-derived from the pane's shell (claude may have just spawned, or been
    /// restarted manually in the window); only if no claude child exists, and the
    /// pane shell is older than the spawn grace window, is the session Dead.
    ///
    /// Crucially, Dead requires a DETERMINED absence: the tools (tmux for the
    /// pane shell, `pgrep` for its children) actually answered "no process".
    /// When a tool fails to answer (`PanePIDProbe.unknown` /
    /// `ProcessControl.ClaudeScan.unknown` from a server hiccup, a fork/resource
    /// exhaustion launch failure, or a timeout kill) liveness is UNDETERMINED,
    /// and the pass holds the session non-dead (Running) and lets the next poll
    /// re-derive, rather than concluding crashed. This is what stops a transient
    /// global tool failure at launch reconcile from false-flipping every live
    /// session to crashed (and auto-restart from then tearing them down). The
    /// trade-off is bounded and self-correcting: a truly-dead session still
    /// flips to Dead on the next poll once the tools answer.
    ///
    /// `claudeBelowShell` is an injection seam (default: the real
    /// `ProcessControl.findClaude`), mirroring `bridgeForPid`, so the
    /// determined-absent-vs-unknown branches are unit-tested without forcing a
    /// real `pgrep` to fail.
    func detect(input: DetectionInput,
                panes: PaneSource,
                transcript: DiscoveredSession?,
                staleThreshold: TimeInterval,
                spawnGrace: TimeInterval = StateDetector.spawnGraceSeconds,
                now: Date = Date(),
                bridgeForPid: @Sendable (Int32) -> String? = StateDetector.registryBridge,
                claudeBelowShell: @Sendable (Int32) -> ProcessControl.ClaudeScan
                    = { ProcessControl.findClaude(belowShell: $0) })
                -> DetectionResult {

        var result = DetectionResult(state: .stopped,
                                     pid: input.pid,
                                     remoteControlActive: false,
                                     lastPaneHash: input.lastPaneHash,
                                     lastHashChange: input.lastHashChange,
                                     wasShowingLiveActivity: input.wasShowingLiveActivity,
                                     rcCache: input.rcCache)

        var livePID = input.pid.flatMap { ProcessControl.isAlive($0) ? $0 : nil }

        guard let windowId = input.windowId else {
            // No window: a tracked-but-gone pid is Dead; otherwise Stopped.
            result.state = (input.pid != nil && livePID == nil) ? .dead : .stopped
            result.pid = livePID
            return result
        }

        if livePID == nil {
            // Re-derive: find the claude child of the pane's shell (argv/exec-path
            // match among the shell's descendants only, never a global scan).
            // Only a DETERMINED absence (the tools answered) may become Dead; a
            // tool that could not answer holds the session non-dead for this poll.
            //
            // A SPLIT window matters here: pane 0 may be a bare shell while claude
            // runs in a later pane (verified: the alive-path pane-following walk
            // below targets exactly that case). The active-pane probe alone would
            // report `.absent` for the bare pane and, past the spawn grace, declare
            // a session Dead while claude is alive elsewhere — auto-restart then
            // tearing down a live session. So when tmux can enumerate the window's
            // panes, walk EACH pane's shell with the SAME argv-based
            // `claudeBelowShell` the alive path uses, and only conclude the
            // determined absence (Dead-eligible) when NO pane hosts a claude child.
            switch rederiveLivePID(windowId: windowId, panes: panes,
                                   now: now, spawnGrace: spawnGrace,
                                   claudeBelowShell: claudeBelowShell) {
            case .found(let pid):
                livePID = pid
            case .undetermined:
                // A tool could not answer (tmux server down / killed window /
                // launch failure / timeout, or pgrep could not enumerate, or the
                // pane enumeration failed): liveness is UNDETERMINED, not Dead.
                // Hold Running and let the next poll re-derive.
                result.state = .running
                result.pid = nil
                return result
            case .stillSpawning:
                // Determined absence, but a pane shell is younger than the spawn
                // grace window: claude may still be exec'ing (node installs can
                // take several seconds). Hold Running.
                result.state = .running
                result.pid = nil
                return result
            case .dead:
                // Determined: a live pane shell with no claude child in ANY pane,
                // past the grace window. A genuine crash.
                result.state = .dead
                result.pid = nil
                return result
            }
        }
        result.pid = livePID

        // Follow the pane running claude, not tmux's active pane. After a split
        // (the non-claude pane active) a window-target capture returns the wrong
        // pane and the classifier loses the TUI footer it keys on, though the
        // pane-agnostic pid walk keeps the session alive. Re-resolve the pane id
        // every poll from the live pane list (pane ids are runtime state like
        // pids; never persisted): pick the pane whose shell subtree contains the
        // tracked claude pid, reusing the SAME argv-based `claudeBelowShell` walk.
        // Falls back to the window-target capture (today's behavior, exactly)
        // when there is one pane, the enumeration failed, or no pane matches, so
        // a transient `list-panes` failure degrades to today's capture, never to
        // a worse state, and single-pane sessions are untouched.
        let captureTarget = livePID.flatMap { pid in
            Self.selectClaudePane(panes: panes.listPanes(windowId: windowId),
                                  claudePID: pid,
                                  contains: { shellPID, claudePID in
                                      claudeBelowShell(shellPID) == .found(claudePID)
                                  })
        } ?? windowId
        let pane = panes.capturePane(windowId: captureTarget)
        // The registry bridge handle (a `session_…` id) is read up front: its
        // mere presence is one of the remote-control-active signals, AND its
        // value is the `claude.ai/code/<id>` per-session URL segment the browser
        // handoff opens. Reading it every tick (a tiny per-pid JSON file) keeps
        // that id fresh for the on-demand action; cheap for the handful of live
        // sessions this manages.
        let registryBridge = livePID.flatMap(bridgeForPid)
        result.bridgeSessionId = registryBridge
        // Remote-control-active is the OR of three positive signals, most
        // reliable first; absence of all three is "not up", never asserted from
        // any one miss. The footer (version-robust: old literal or `/rc` chip)
        // is the CLI's own self-report; the registry bridge handle and the
        // transcript `bridge-session` record are version-independent positives
        // that cover a footer that hasn't repainted yet. `||` short-circuits, so
        // an engaged footer or a present registry handle skips the transcript I/O.
        // The "fresh" RC-active signal: the live footer/chip plus the registry
        // bridge handle, WITHOUT the sticky transcript `bridge-session` leg. A
        // transcript record is append-only, so the cache's positive is sticky
        // for the whole run (it never disappears, by design, so an idle TUI that
        // stops repainting its `/rc active` chip still reads as connected). That
        // stickiness is what the full `remoteControlActive` OR below relies on to
        // keep a healthy session off the No-remote path — but it is exactly wrong
        // for the account-capability verdict, which must react to RC actually
        // being up *right now*. So compute the fresh OR separately and carry it
        // out for `reconcileRCAccountCapability`; it is NOT used for the
        // StatusPresentation/StatusBar no-remote decision (that stays on the
        // sticky `remoteControlActive`).
        result.remoteControlActiveFresh = showsRemoteControlEngaged(pane: pane)
            || registryBridge != nil
        // Remote-control-active is the OR of three positive signals (the fresh
        // pair above PLUS the sticky transcript leg); absence of all three is
        // "not up", never asserted from any one miss. `||` short-circuits, so an
        // engaged footer or a present registry handle skips the transcript I/O.
        result.remoteControlActive = result.remoteControlActiveFresh
            || result.rcCache.hasBridgeSession(path: transcript?.transcriptPath,
                                               mtime: transcript?.modified)
        // Read a failure line whenever the pane's LIVE region carries one. The
        // read is scoped to `livePromptRegion`, so a stale failure scrolled up
        // into history is already excluded; a failure present in the live region
        // is current and must be surfaced even while `remoteControlActive` is
        // sticky-true from a prior `bridge-session` record (the bug this fixes: a
        // genuine current `/rc failed` / plan-limit line was never read once the
        // sticky leg latched). The account-verdict gate in AppModel keys on the
        // FRESH signal, not on this read, so a lingering line cannot re-assert a
        // verdict on its own.
        if let failure = rcFailure(pane: pane) {
            result.rcPlanNotice = failure.message
            result.rcFailureKind = failure.kind
        }
        result.bypassActive = showsBypass(pane: pane)

        let verdict = classifyPane(pane: pane,
                                   lastPaneHash: input.lastPaneHash,
                                   lastHashChange: input.lastHashChange,
                                   wasShowingLiveActivity: input.wasShowingLiveActivity,
                                   staleThreshold: staleThreshold,
                                   now: now)
        result.state = verdict.state
        result.lastPaneHash = verdict.hash
        result.lastHashChange = verdict.hashChange
        result.wasShowingLiveActivity = showsLiveActivity(pane: pane)
        if verdict.state == .needsAuth {
            result.authNotice = authNotice(pane: pane)
        }
        return result
    }

    /// Pure classification of a windowed, alive session from its captured pane.
    /// No process or tmux I/O, so tests drive it directly with captured-frame
    /// fixtures. Returns the new stale-tracking values alongside the state.
    ///
    /// Precedence: live activity > NeedsAuth > Waiting > pane-changed >
    /// (Stale | Running). The live-activity hint outranks everything so
    /// prompt-like text streamed mid-turn ("Would you like…", a pasted login
    /// error) doesn't flag a busy session as blocked; NeedsAuth outranks
    /// Waiting because the login screen renders option pickers ("❯ 1.",
    /// "Enter to confirm") that would otherwise mislabel it as needs-input
    /// (section 8); pane-changed ranks below both so a freshly rendered prompt
    /// reads correctly immediately, not Working. A first observation (no
    /// previous hash) does not count as a change.
    func classifyPane(pane: String,
                      lastPaneHash: String?,
                      lastHashChange: Date?,
                      wasShowingLiveActivity: Bool = false,
                      staleThreshold: TimeInterval,
                      now: Date) -> (state: SessionState, hash: String, hashChange: Date) {
        let hash = Self.sha256(pane)
        let hashChange = (hash != lastPaneHash) ? now : (lastHashChange ?? now)
        let changedSinceLastPoll = (lastPaneHash != nil && hash != lastPaneHash)
        let liveNow = showsLiveActivity(pane: pane)

        if liveNow { return (.working, hash, hashChange) }
        if authNotice(pane: pane) != nil { return (.needsAuth, hash, hashChange) }
        if isWaiting(pane: pane) { return (.waiting, hash, hashChange) }
        // Change-fallback (covers marker-less renderers): a changed pane reads as
        // Working, EXCEPT on the live-activity present->absent edge. There the
        // turn just finished (the marker "disappears the moment the turn
        // finishes"), and the change is only the final render settling, so flip
        // straight to the idle classification below instead of costing one more
        // poll. When the marker was never involved (wasShowingLiveActivity ==
        // false), this is unchanged from before.
        if changedSinceLastPoll && !wasShowingLiveActivity { return (.working, hash, hashChange) }

        // Idle: Running, promoted to Stale if the pane hasn't changed past threshold.
        let state: SessionState =
            now.timeIntervalSince(hashChange) >= staleThreshold ? .stale : .running
        return (state, hash, hashChange)
    }
}
