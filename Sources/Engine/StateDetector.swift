import Foundation
import CryptoKit

/// Detects a session's state from a `tmux capture-pane` snapshot, PID liveness,
/// and the remote-control signal. See docs/CCORN_SPEC.md section 4.
///
/// Precedence for a managed session:
///   1. PID gone                       -> Dead
///   2. pane shows tool calls/spinner  -> Working
///   3. pane shows a permission/confirmation prompt -> Waiting
///   4. otherwise                      -> Running, unless the pane hash has been
///      unchanged longer than the stale threshold, in which case -> Stale.
///
/// Remote-control-active is reported separately (it drives the row's warning
/// indicator); it does not change the Working/Waiting/Running dot.
struct StateDetector {

    /// The exact footer literal printed by Claude Code 2.1.169 (RUNTIME_FINDINGS C2).
    static let remoteControlMarker = "Remote Control active"

    /// Tool-invocation markers that indicate Claude is mid-task.
    static let workingMarkers = [
        "Bash(", "Read(", "Write(", "Edit(", "Task(",
        "Grep(", "Glob(", "Update(", "WebFetch(", "WebSearch(", "MultiEdit(",
    ]

    /// Braille spinner frames Claude renders while busy.
    static let spinnerChars = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// Permission / confirmation phrases that mean Claude is waiting on the user.
    /// Note: the persistent `>` input box is NOT used as a Waiting signal — it is
    /// present even when idle (Running), so trailing-`>` matching would misclassify
    /// every healthy session. We key on explicit prompts instead.
    static let waitingPhrases = [
        "Would you like", "Do you want", "Please confirm",
        "Do you want to proceed", "Allow this", "approve",
        "(y/n)", "[y/N]", "❯ 1.", "1. Yes",
    ]

    // MARK: - Signals

    func isWorking(pane: String) -> Bool {
        if pane.contains(where: { Self.spinnerChars.contains($0) }) { return true }
        return Self.workingMarkers.contains { pane.contains($0) }
    }

    func isWaiting(pane: String) -> Bool {
        Self.waitingPhrases.contains { pane.localizedCaseInsensitiveContains($0) }
    }

    func remoteControlActive(pane: String, transcriptPath: String?) -> Bool {
        if pane.contains(Self.remoteControlMarker) { return true }
        if let path = transcriptPath, SessionDiscovery.transcriptHasBridgeSession(path: path) {
            return true
        }
        return false
    }

    static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Detection

    /// Update `live` from a fresh capture and PID check, mutating its stale
    /// tracking in place. `now` is injected for testability / determinism.
    func detect(live: LiveSession,
                tmux: TmuxController,
                transcriptPath: String?,
                staleThreshold: TimeInterval,
                now: Date = Date()) {

        // Dead: tracked PID gone.
        if let pid = live.pid, !ProcessControl.isAlive(pid) {
            live.state = .dead
            live.remoteControlActive = false
            return
        }
        // Dead: a tracked window whose claude pid is gone. This is exactly the
        // state `reconcile` produces for an existing window whose `claude` has
        // exited — the pane shell (and thus the tmux window) is still alive, so
        // there is a windowId, but findClaude returned no pid. Decide it from
        // PID/window presence, never from the pane: an exited window keeps stale
        // `Bash(` / `Remote Control active` markers that would otherwise be read
        // as Working (RUNTIME_FINDINGS T2).
        if live.pid == nil, live.windowId != nil {
            live.state = .dead
            live.remoteControlActive = false
            return
        }
        // No window / no pid and never started -> Stopped (caller decides; default).
        guard let windowId = live.windowId else {
            live.state = .stopped
            return
        }

        let pane = tmux.capturePane(windowId: windowId)
        live.remoteControlActive = remoteControlActive(pane: pane, transcriptPath: transcriptPath)
        live.state = classifyPane(pane: pane, live: live, staleThreshold: staleThreshold, now: now)
    }

    /// Pure classification of a windowed, alive session from its captured pane.
    /// Mutates only `live`'s stale-hash tracking; performs no process or tmux I/O,
    /// so it is driven directly by captured-frame fixtures in tests.
    ///
    /// Precedence: Working > Waiting > (Stale | Running). Dead and Stopped are
    /// decided earlier in `detect` from PID liveness / window presence, never from
    /// pane content — a pane can still show stale Working/Running markers after the
    /// `claude` process has exited.
    func classifyPane(pane: String,
                      live: LiveSession,
                      staleThreshold: TimeInterval,
                      now: Date) -> SessionState {
        // Stale hash bookkeeping (computed for all states; only promotes Running).
        let hash = Self.sha256(pane)
        if hash != live.lastPaneHash {
            live.lastPaneHash = hash
            live.lastHashChange = now
        }

        if isWorking(pane: pane) { return .working }
        if isWaiting(pane: pane) { return .waiting }

        // Idle: Running, promoted to Stale if the pane hasn't changed past threshold.
        let lastChange = live.lastHashChange ?? now
        return now.timeIntervalSince(lastChange) >= staleThreshold ? .stale : .running
    }
}
