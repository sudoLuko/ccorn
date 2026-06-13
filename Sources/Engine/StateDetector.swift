import Foundation
import CryptoKit

/// The two tmux reads a detection pass needs. `TmuxController` is the live
/// implementation; tests substitute a stub so the classifier and the
/// dead/grace/re-derive logic run against captured fixtures without a tmux server.
protocol PaneSource: Sendable {
    func capturePane(windowId: String) -> String
    func panePID(windowId: String) -> Int32?
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
    var rcCache: BridgeSessionCache

    init(windowId: String?,
         pid: Int32?,
         lastPaneHash: String? = nil,
         lastHashChange: Date? = nil,
         rcCache: BridgeSessionCache = BridgeSessionCache()) {
        self.windowId = windowId
        self.pid = pid
        self.lastPaneHash = lastPaneHash
        self.lastHashChange = lastHashChange
        self.rcCache = rcCache
    }
}

/// What a detection pass decided; applied back to the LiveSession on the main actor.
struct DetectionResult: Sendable {
    var state: SessionState
    var pid: Int32?
    var remoteControlActive: Bool
    var lastPaneHash: String?
    var lastHashChange: Date?
    var rcCache: BridgeSessionCache
    /// The CLI's own auth-error line when the pane shows a login prompt
    /// (docs/CCORN_SPEC.md section 8: surface the CLI's text, not a canned string).
    var authNotice: String?
    /// The CLI's own line when remote control failed for plan/credential
    /// reasons (section 8's plan-restriction alert).
    var rcPlanNotice: String?
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
    /// transient bring-up/recovery handshake — remote control is engaging, not
    /// failed, so they must read as engaged and never trip "No remote";
    /// `failed` is the genuine failure (alongside the verbose
    /// "Remote Control … {disabled,unavailable,…}" messages, see `rcPlanNotice`).
    static let remoteControlMarker = "Remote Control active"          // ≤ 2.1.171
    static let rcChipActive = "/rc active"                            // ≥ 2.1.172
    static let rcChipConnecting = ["/rc connecting", "/rc reconnecting"]
    static let rcChipFailed = "/rc failed"

    /// Rendered ONLY while Claude is actively executing (verified on 2.1.169 and
    /// 2.1.170): the `esc to interrupt` hint accompanies the live spinner/status
    /// line and disappears the moment the turn finishes. Tool-call markers like
    /// `Bash(` and the `✻ <verb>ed for Ns` glyph lines persist in finished-but-idle
    /// frames, so they must NOT be used as a Working signal (runtime findings T5).
    static let liveActivityMarker = "esc to interrupt"

    /// Braille spinner frames older/newer renderers may use. Dead on
    /// 2.1.169/2.1.170 (which cycle `·✢✳✶✻✽` instead, glyphs that also persist
    /// after finish) — kept only as a forward-compat fallback; it cannot
    /// false-positive on current versions because braille never renders.
    static let spinnerChars = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// Permission / confirmation phrases that mean Claude is waiting on the user.
    /// Anchored to real prompt renders (the trust dialog, tool-permission and
    /// plan-mode prompts); the persistent `>` input box is NOT a Waiting signal —
    /// it is present even when idle. Single risky words (e.g. "approve") are
    /// matched with word boundaries via `waitingWordPattern`, never as bare
    /// substrings — "approved"/"approval" in ordinary output must not flag Waiting.
    static let waitingPhrases = [
        "Would you like", "Do you want", "Please confirm",
        "Allow this", "Enter to confirm",
        "(y/n)", "[y/N]", "❯ 1.", "1. Yes",
    ]

    /// Word-bounded regex for confirmation verbs that are too short to match as
    /// substrings. `\b` keeps "approved"/"approval" from matching.
    static let waitingWordPattern = #"\bapprove\b"#

    /// Login-prompt phrases (docs/CCORN_SPEC.md section 8, "User not
    /// authenticated"). Anchored to whole UI/error renders — the login picker,
    /// the OAuth flow, and the invalid-credential errors — never a bare
    /// "/login", which could appear in ordinary conversation text. A session
    /// matching one of these is blocked on sign-in, which is a different
    /// problem than Waiting (needs input): it gets its own state so the row
    /// and the notification say "sign in", not "Claude needs your input".
    static let authPhrases = [
        "Select login method",
        "Please run /login",
        "Invalid API key",
        "OAuth token expired",
        "OAuth token revoked",
        "Paste code here if prompted",
        "use the url below to sign in",
        "Press Enter to open your browser and sign in",
    ]

    /// Remote-control plan/credential failure phrases (section 8's
    /// plan-restriction alert). Matched as a pane *line* containing
    /// "remote control" plus a failure word, so the stable footer string
    /// `Remote Control active` can never trip it.
    static let rcPlanFailureWords = [
        "not available", "not supported", "requires", "unavailable",
        "upgrade", "not enabled", "not yet enabled", "disabled by", "failed",
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

    /// True when the footer reports remote control *engaged* — connected, or in
    /// the transient connecting/reconnecting handshake. Matches both the
    /// pre-2.1.172 `Remote Control active` literal and the 2.1.172+ `/rc` chip,
    /// so detection is version-robust. `/rc failed` and an absent chip are
    /// deliberately excluded — that is the no-remote case, decided elsewhere.
    /// This is a *positive* signal only: its absence does not prove RC is down
    /// (the footer can lag in an un-repainted idle TUI), which is why `detect`
    /// ORs it with the registry/transcript bridge signals rather than treating
    /// a miss as failure.
    func showsRemoteControlEngaged(pane: String) -> Bool {
        if pane.contains(Self.remoteControlMarker) { return true }
        if pane.contains(Self.rcChipActive) { return true }
        return Self.rcChipConnecting.contains { pane.contains($0) }
    }

    /// True when a pane shows any trace of ever having hosted Claude Code.
    /// Used by launch reconciliation to tell a died claude session from a bare
    /// shell window — e.g. the default window `tmux new-session` spawns, which
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

    func isWaiting(pane: String) -> Bool {
        if Self.waitingPhrases.contains(where: { pane.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return pane.range(of: Self.waitingWordPattern,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The CLI's auth-error/login line if the pane shows a login prompt, nil
    /// otherwise. Returns the matched line (trimmed of TUI box-drawing and
    /// whitespace) so the alert can surface Claude Code's own words.
    func authNotice(pane: String) -> String? {
        for line in pane.split(whereSeparator: \.isNewline) {
            if let phrase = Self.authPhrases.first(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                let cleaned = Self.cleanTUILine(line)
                return cleaned.isEmpty ? phrase : cleaned
            }
        }
        return nil
    }

    /// The CLI's remote-control failure line, if the pane reports that remote
    /// control could not be enabled for plan/credential reasons.
    func rcPlanNotice(pane: String) -> String? {
        for line in pane.split(whereSeparator: \.isNewline) {
            guard line.localizedCaseInsensitiveContains("remote control"),
                  !line.contains(Self.remoteControlMarker) else { continue }
            if Self.rcPlanFailureWords.contains(where: {
                line.localizedCaseInsensitiveContains($0)
            }) {
                return Self.cleanTUILine(line)
            }
        }
        return nil
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

    // MARK: - Detection

    /// One detection pass. Pure with respect to shared state: reads tmux/process
    /// facts through `panes`/ProcessControl, never mutates the store — the caller
    /// applies the returned result on the main actor.
    ///
    /// Dead is decided from PID liveness, never from pane content: an exited
    /// window keeps stale `Bash(` / `Remote Control active` markers
    /// (runtime findings T2). When the tracked pid is missing or gone, the pid is
    /// re-derived from the pane's shell (claude may have just spawned, or been
    /// restarted manually in the window); only if no claude child exists — and the
    /// pane shell is older than the spawn grace window — is the session Dead.
    func detect(input: DetectionInput,
                panes: PaneSource,
                transcript: DiscoveredSession?,
                staleThreshold: TimeInterval,
                spawnGrace: TimeInterval = StateDetector.spawnGraceSeconds,
                now: Date = Date(),
                bridgeForPid: @Sendable (Int32) -> String? = StateDetector.registryBridge)
                -> DetectionResult {

        var result = DetectionResult(state: .stopped,
                                     pid: input.pid,
                                     remoteControlActive: false,
                                     lastPaneHash: input.lastPaneHash,
                                     lastHashChange: input.lastHashChange,
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
            // match among the shell's descendants only — never a global scan).
            if let shellPID = panes.panePID(windowId: windowId) {
                livePID = ProcessControl.findClaude(belowShell: shellPID)
                if livePID == nil,
                   let shellStart = ProcessControl.startTime(pid: shellPID),
                   now.timeIntervalSince(shellStart) < spawnGrace {
                    // The window's shell only just started: claude is still
                    // spawning, not dead. Report Running and let the next tick
                    // (or grace expiry) settle it.
                    result.state = .running
                    result.pid = nil
                    return result
                }
            }
            if livePID == nil {
                result.state = .dead
                result.pid = nil
                return result
            }
        }
        result.pid = livePID

        let pane = panes.capturePane(windowId: windowId)
        // Remote-control-active is the OR of three positive signals, most
        // reliable first; absence of all three is "not up", never asserted from
        // any one miss. The footer (version-robust: old literal or `/rc` chip)
        // is the CLI's own self-report; the registry bridge handle and the
        // transcript `bridge-session` record are version-independent positives
        // that cover a footer that hasn't repainted yet. `||` short-circuits, so
        // an engaged footer skips the registry read and transcript I/O entirely.
        result.remoteControlActive = showsRemoteControlEngaged(pane: pane)
            || livePID.flatMap(bridgeForPid) != nil
            || result.rcCache.hasBridgeSession(path: transcript?.transcriptPath,
                                               mtime: transcript?.modified)
        result.rcPlanNotice = rcPlanNotice(pane: pane)

        let verdict = classifyPane(pane: pane,
                                   lastPaneHash: input.lastPaneHash,
                                   lastHashChange: input.lastHashChange,
                                   staleThreshold: staleThreshold,
                                   now: now)
        result.state = verdict.state
        result.lastPaneHash = verdict.hash
        result.lastHashChange = verdict.hashChange
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
                      staleThreshold: TimeInterval,
                      now: Date) -> (state: SessionState, hash: String, hashChange: Date) {
        let hash = Self.sha256(pane)
        let hashChange = (hash != lastPaneHash) ? now : (lastHashChange ?? now)
        let changedSinceLastPoll = (lastPaneHash != nil && hash != lastPaneHash)

        if showsLiveActivity(pane: pane) { return (.working, hash, hashChange) }
        if authNotice(pane: pane) != nil { return (.needsAuth, hash, hashChange) }
        if isWaiting(pane: pane) { return (.waiting, hash, hashChange) }
        if changedSinceLastPoll { return (.working, hash, hashChange) }

        // Idle: Running, promoted to Stale if the pane hasn't changed past threshold.
        let state: SessionState =
            now.timeIntervalSince(hashChange) >= staleThreshold ? .stale : .running
        return (state, hash, hashChange)
    }
}
