import Foundation
import Testing

/// Login-prompt and remote-control plan-restriction detection
/// (docs/CCORN_SPEC.md section 8). The login fixture is SYNTHETIC: the probe
/// machine was authenticated (runtime findings: Claude Max OAuth), so no real
/// unauthenticated frame could be captured. It is modeled on the 2.1.x login
/// picker, whose option list ("❯ 1.", "Enter to confirm") is exactly what
/// used to mislabel an unauthenticated session as Waiting.
@Suite struct AuthStateTests {

    let detector = StateDetector()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func classifyFresh(_ pane: String) -> SessionState {
        detector.classifyPane(pane: pane, lastPaneHash: nil, lastHashChange: nil,
                              staleThreshold: 600, now: t0).state
    }

    // MARK: NeedsAuth classification

    /// THE section-8 mislabel: the login picker renders the same option-list
    /// chrome as a permission prompt ("❯ 1.", "Enter to confirm"), so the
    /// Waiting patterns match it, but it must classify NeedsAuth, because
    /// "Claude needs your input" is the wrong message for "sign in first".
    @Test func loginPickerIsNeedsAuthNotWaiting() {
        let pane = Fixtures.paneText("needs-auth-login.txt")
        #expect(detector.isWaiting(pane: pane))      // the old (wrong) match still fires…
        #expect(classifyFresh(pane) == .needsAuth)   // …but NeedsAuth preempts it
    }

    /// The invalid-credential error frames also mean sign-in, and the CLI's
    /// own line is surfaced for the alert (spec: never a hard-coded string).
    @Test func invalidCredentialErrorIsNeedsAuthWithNotice() {
        let pane = "⏺ Working on it\n │ Invalid API key · Please run /login │\n"
        #expect(classifyFresh(pane) == .needsAuth)
        #expect(detector.authNotice(pane: pane) == "Invalid API key · Please run /login")
    }

    /// REAL invalid-key error render, captured on 2.1.172 by the preflight
    /// harness (runtime findings P3): an approved-but-invalid env key fails on
    /// the first send with "Invalid API key · Fix external API key". The
    /// "Please run /login" suffix of older versions is gone; the "Invalid API
    /// key" phrase is what must keep matching.
    @Test func realInvalidKeyErrorFrameIsNeedsAuth() {
        let pane = Fixtures.paneText("needs-auth-invalid-key-2172.txt")
        #expect(classifyFresh(pane) == .needsAuth)
        #expect(detector.authNotice(pane: pane)?.contains("Invalid API key") == true)
    }

    /// REAL signed-out login screen (fresh CLAUDE_CONFIG_DIR first run),
    /// captured on 2.1.172 by the preflight harness (runtime findings P4),
    /// the live counterpart of the modeled needs-auth-login fixture.
    @Test func realFreshLoginScreenIsNeedsAuth() {
        let pane = Fixtures.paneText("needs-auth-fresh-login-2172.txt")
        #expect(classifyFresh(pane) == .needsAuth)
    }

    @Test func expiredOAuthTokenIsNeedsAuth() {
        let pane = "OAuth token expired · Please run /login"
        #expect(classifyFresh(pane) == .needsAuth)
    }

    /// A freshly rendered login screen (pane changed since last poll) reads
    /// NeedsAuth immediately, not Working; same precedence rule as Waiting.
    @Test func freshlyRenderedLoginScreenIsNeedsAuthNotWorking() {
        let pane = Fixtures.paneText("needs-auth-login.txt")
        let state = detector.classifyPane(pane: pane,
                                          lastPaneHash: "previous-frame-hash",
                                          lastHashChange: t0,
                                          staleThreshold: 600,
                                          now: t0.addingTimeInterval(3)).state
        #expect(state == .needsAuth)
    }

    /// Live activity preempts auth text: login-ish phrases streamed mid-turn
    /// (Claude quoting an error, writing docs about /login) must not flag a
    /// busy session as blocked.
    @Test func liveActivityPreemptsAuthText() {
        let pane = Fixtures.paneText("working-midtask.txt")
            + "\n⏺ The error was: Invalid API key · Please run /login\n"
        #expect(classifyFresh(pane) == .working)
    }

    /// Ordinary auth-adjacent conversation text must not trip the detector.
    @Test func authAdjacentProseIsNotNeedsAuth() {
        let pane = Fixtures.paneText("running-idle.txt")
            + "\n⏺ The login flow is broken; authentication fails for SSO users.\n"
        #expect(detector.authNotice(pane: pane) == nil)
        #expect(classifyFresh(pane) == .running)
    }

    /// detect() end to end: alive pid + login screen -> NeedsAuth, with the
    /// CLI's line carried on the result for the alert/tooltip.
    @Test func detectCarriesAuthNotice() {
        let input = DetectionInput(windowId: "@1", pid: getpid())
        let panes = StubPanes(pane: Fixtures.paneText("needs-auth-login.txt"), shellPID: nil)
        let result = detector.detect(input: input, panes: panes, transcript: nil,
                                     staleThreshold: 600, now: t0)
        #expect(result.state == .needsAuth)
        #expect(result.authNotice?.contains("Select login method") == true)
    }

    // MARK: Remote-control plan restriction

    /// A pane line reporting that remote control failed for plan reasons is
    /// captured verbatim; the stable `Remote Control active` footer never trips it.
    @Test func rcPlanFailureLineIsCaptured() {
        let pane = Fixtures.paneText("running-idle.txt")
            + "\n Remote Control is not available on your plan. Upgrade to enable it.\n"
        let notice = detector.rcPlanNotice(pane: pane)
        #expect(notice == "Remote Control is not available on your plan. Upgrade to enable it.")
    }

    @Test func rcActiveFooterIsNotAPlanFailure() {
        let pane = Fixtures.paneText("running-idle.txt")
        #expect(pane.contains(StateDetector.remoteControlMarker))
        #expect(detector.rcPlanNotice(pane: pane) == nil)
    }

    /// Plain prose mentioning remote control without a failure word stays clean.
    @Test func rcProseWithoutFailureWordIsNotAPlanFailure() {
        let pane = "⏺ Remote Control lets you drive the session from your phone.\n"
        #expect(detector.rcPlanNotice(pane: pane) == nil)
    }

    // MARK: Definitive vs transient RC failure

    /// A genuine plan/account limitation classifies definitive, the kind that
    /// earns the account verdict (local fallback + the one-time plan modal).
    @Test func definitivePlanLineIsDefinitive() {
        let pane = "⏺ ok\n Remote Control requires a Pro, Max, Team, or Enterprise plan.\n"
        let failure = detector.rcFailure(pane: pane)
        #expect(failure?.kind == .definitive)
        #expect(failure?.message.contains("requires") == true)
    }

    /// THE overstated case: "Remote Control failed to connect because the remote
    /// credentials fetch failed" is transient/ambiguous (a fetch hiccup, maybe
    /// network), NOT a plan limit, so it must classify transient and never fire
    /// the definitive account modal.
    @Test func credentialsFetchFailureIsTransientNotDefinitive() {
        let pane = "⏺ ok\n Remote Control failed to connect because the remote credentials fetch failed.\n"
        #expect(detector.rcFailure(pane: pane)?.kind == .transient)
    }

    /// A line carrying both a transient and a definitive word reads as the
    /// definitive limitation it names (definitive is checked first).
    @Test func definitiveOutranksTransientOnSameLine() {
        let pane = "⏺ ok\n Remote Control failed: not available on your plan.\n"
        #expect(detector.rcFailure(pane: pane)?.kind == .definitive)
    }

    /// A failure line scrolled up into history (above the last rule line) is not
    /// read as current; the same line inside the live region is.
    @Test func rcFailureIgnoresScrollbackAboveLiveRegion() {
        let rule = String(repeating: "─", count: 60)
        let scrollbackOnly =
            "Remote Control requires an upgrade.\n" + rule + "\n❯ \n" + rule + "\n ? for shortcuts\n"
        #expect(detector.rcFailure(pane: scrollbackOnly) == nil)

        let inLiveRegion = rule + "\n❯ \n" + rule + "\n Remote Control requires an upgrade.\n"
        #expect(detector.rcFailure(pane: inLiveRegion)?.kind == .definitive)
    }

    /// detect() reads a definitive failure line present in the LIVE region
    /// regardless of the remote-control-active value (FIX A): the read is scoped
    /// to `livePromptRegion`, which already excludes stale scrollback, so a
    /// failure that is current must surface even when RC reads active. What keeps
    /// a stale/lingering signal from re-asserting the account verdict is no
    /// longer the read gate — it is `reconcileRCAccountCapability` keying on the
    /// FRESH RC signal (`remoteControlActiveFresh`), exercised below.
    @Test func detectReadsLiveFailureLineEvenWhenRemoteControlActive() {
        let pane = "claude\n? for shortcuts\n Remote Control requires a Pro or Max plan.\n"
        let input = DetectionInput(windowId: "@1", pid: getpid())   // alive
        let panes = StubPanes(pane: pane)

        let down = detector.detect(input: input, panes: panes, transcript: nil,
                                   staleThreshold: 600, now: t0, bridgeForPid: { _ in nil })
        #expect(!down.remoteControlActive)
        #expect(!down.remoteControlActiveFresh)
        #expect(down.rcFailureKind == .definitive)
        #expect(down.rcPlanNotice?.contains("requires a Pro or Max plan") == true)

        // RC active via the registry bridge: BOTH the sticky and the fresh
        // signals read active, yet the live failure line is still read (FIX A),
        // because it is current, not lingering scrollback.
        let up = detector.detect(input: input, panes: panes, transcript: nil,
                                 staleThreshold: 600, now: t0, bridgeForPid: { _ in "session_x" })
        #expect(up.remoteControlActive)
        #expect(up.remoteControlActiveFresh)
        #expect(up.rcFailureKind == .definitive)
        #expect(up.rcPlanNotice?.contains("requires a Pro or Max plan") == true)
    }

    // MARK: Aggregate severity

    /// needsAuth tops the ladder now that the recoverable `ended` mark no
    /// longer sits above it: blocked-on-sign-in outranks the degraded
    /// no-remote condition, blocked-on-input, and the recoverable ended mark.
    @Test func needsAuthAggregateSeverity() {
        #expect(StatusPresentation.aggregate([.running, .waiting, .needsAuth]) == .needsAuth)
        #expect(StatusPresentation.aggregate([.needsAuth, .ended]) == .needsAuth)
        #expect(StatusPresentation.aggregate([.stale, .needsAuth]) == .needsAuth)
        #expect(StatusPresentation.aggregate([.noRemote, .needsAuth]) == .needsAuth)
    }

    /// needsAuth counts as an alive state (a claude process is showing the
    /// login screen) for kill/archive gating.
    @Test func needsAuthIsAlive() {
        #expect(SessionState.needsAuth.isAliveState)
        #expect(!SessionState.dead.isAliveState)
        #expect(!SessionState.unmanaged.isAliveState)
    }
}
