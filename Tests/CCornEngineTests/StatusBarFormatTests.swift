import Foundation
import Testing

/// The per-session terminal status bar (`StatusBarFormat`): the escaping the
/// tmux drawer needs, the idle/mode labels, and the segment assembly across the
/// states a managed window can be in. Pure, so these run with no tmux server.
@Suite struct StatusBarFormatTests {

    // Color tokens, kept in sync with StatusBarFormat's private constants so a
    // chip assertion reads clearly.
    private let amberBg = "#[bg=colour214]"
    private let dangerBg = "#[bg=colour160]"

    /// Call with sensible defaults so each test varies only what it exercises.
    private func bar(title: String = "proj",
                     state: SessionState = .running,
                     mode: CCPermissionMode? = .auto,
                     bypass: Bool = false,
                     rcRequested: Bool = true,
                     rcActive: Bool = true,
                     graceExpired: Bool = true,
                     idle: TimeInterval? = nil) -> String {
        StatusBarFormat.windowStatus(title: title,
                                     state: state,
                                     permissionMode: mode,
                                     isBypass: bypass,
                                     remoteControlRequested: rcRequested,
                                     remoteControlActive: rcActive,
                                     rcGraceExpired: graceExpired,
                                     idleSeconds: idle)
    }

    // MARK: Escaping (the only drawer metacharacter is `#`)

    @Test func escapeDoublesHash() {
        #expect(StatusBarFormat.escape("issue #42") == "issue ##42")
        #expect(StatusBarFormat.escape("C#") == "C##")
        #expect(StatusBarFormat.escape("plain title") == "plain title")
    }

    /// A title carrying a `#[...]` cannot inject a style: it is escaped to a
    /// literal `##[...]`, which the drawer renders as the text `#[...]`.
    @Test func escapeNeutralizesStyleInjection() {
        #expect(StatusBarFormat.escape("#[fg=colour201]EVIL") == "##[fg=colour201]EVIL")
    }

    @Test func titleIsEscapedInTheBar() {
        let out = bar(title: "fix #[fg=colour201]bug")
        // The raw single-hash style sequence from the title must not survive.
        #expect(!out.contains("fix #[fg=colour201]bug"))
        #expect(out.contains("fix ##[fg=colour201]bug"))
    }

    // MARK: Idle label (minute granularity bounds the write rate)

    @Test func idleLabelBuckets() {
        #expect(StatusBarFormat.idleLabel(seconds: 0) == nil)
        #expect(StatusBarFormat.idleLabel(seconds: 59) == nil)
        #expect(StatusBarFormat.idleLabel(seconds: 60) == "idle 1m")
        #expect(StatusBarFormat.idleLabel(seconds: 4 * 60 + 30) == "idle 4m")
        #expect(StatusBarFormat.idleLabel(seconds: 59 * 60) == "idle 59m")
        #expect(StatusBarFormat.idleLabel(seconds: 3600) == "idle 1h")
        #expect(StatusBarFormat.idleLabel(seconds: 3600 + 60) == "idle 1h1m")
        #expect(StatusBarFormat.idleLabel(seconds: 2 * 3600) == "idle 2h")
    }

    // MARK: Mode label

    @Test func modeLabels() {
        #expect(StatusBarFormat.modeLabel(.standard) == "default")
        #expect(StatusBarFormat.modeLabel(.plan) == "plan")
        #expect(StatusBarFormat.modeLabel(.acceptEdits) == "accept-edits")
        #expect(StatusBarFormat.modeLabel(.auto) == "auto")
        #expect(StatusBarFormat.modeLabel(.allowBypass) == "allow-bypass")
        // Active bypass owns the loud chip; the bare flag isn't shown on its own.
        #expect(StatusBarFormat.modeLabel(.bypass) == nil)
    }

    // MARK: Permission-mode / bypass slot

    @Test func bypassShowsLoudChipAndNoModeWord() {
        let out = bar(mode: .bypass, bypass: true)
        #expect(out.contains(dangerBg))
        #expect(out.contains("BYPASS"))
        #expect(!out.contains("auto"))
    }

    @Test func calmModeShowsPlainWord() {
        let out = bar(mode: .plan, bypass: false)
        #expect(out.contains("plan"))
        #expect(!out.contains(dangerBg))
    }

    @Test func unknownModeOmitsTheSlot() {
        // Adopted/reconciled sessions carry no launch config.
        let out = bar(title: "x", mode: nil, bypass: false, idle: nil)
        #expect(!out.contains("auto"))
        #expect(!out.contains(dangerBg))
    }

    // MARK: Remote-control slot

    @Test func remoteActiveShowsRemote() {
        #expect(bar(rcActive: true).contains("remote"))
    }

    @Test func localSessionShowsLocalNotNoRemote() {
        let out = bar(rcRequested: false, rcActive: false)
        #expect(out.contains("local"))
        #expect(!out.contains("no remote"))
    }

    @Test func noRemoteShowsAmberChipPastGrace() {
        let out = bar(rcRequested: true, rcActive: false, graceExpired: true)
        #expect(out.contains(amberBg))
        #expect(out.contains("no remote"))
    }

    /// Within the activation grace, stay optimistic: "remote", never a flash of
    /// the no-remote chip.
    @Test func withinGraceStaysOptimistic() {
        let out = bar(rcRequested: true, rcActive: false, graceExpired: false)
        #expect(out.contains("remote"))
        #expect(!out.contains("no remote"))
    }

    // MARK: State / idle slot

    @Test func workingNamesTheStateWithoutIdle() {
        let out = bar(state: .working, idle: 9999)
        #expect(out.contains("working"))
        #expect(!out.contains("idle"))
    }

    @Test func waitingReadsNeedsInput() {
        #expect(bar(state: .waiting).contains("needs input"))
    }

    @Test func deadReadsCrashedRed() {
        let out = bar(state: .dead)
        #expect(out.contains(dangerBg))
        #expect(out.contains("crashed"))
    }

    @Test func idleSurfacesForRunningAndStale() {
        #expect(bar(state: .running, idle: 4 * 60).contains("idle 4m"))
        #expect(bar(state: .stale, idle: 2 * 3600).contains("idle 2h"))
    }

    // MARK: needsAuth precedence (remote slot suppressed)

    @Test func needsAuthShowsSignInAndSuppressesRemoteSlot() {
        let out = bar(state: .needsAuth, rcRequested: true, rcActive: false, graceExpired: true)
        #expect(out.contains(amberBg))
        #expect(out.contains("sign in"))
        // Remote control is moot before authentication: no remote/local/no-remote.
        #expect(!out.contains("no remote"))
        #expect(!out.contains("local"))
        #expect(!out.contains("remote"))
    }

    // MARK: Title fallback and elision

    @Test func emptyTitleFallsBack() {
        #expect(bar(title: "").contains("session"))
    }

    @Test func longTitleIsElided() {
        let long = String(repeating: "a", count: 80)
        let out = bar(title: long)
        #expect(out.contains("\u{2026}"))
        #expect(!out.contains(long))
    }

    // MARK: Whole-bar shape

    @Test func calmRunningSessionReadsTitleModeRemoteIdle() {
        let out = bar(title: "my-api", state: .running, mode: .auto,
                      rcActive: true, idle: 4 * 60)
        #expect(out == "my-api  auto  remote  idle 4m")
    }
}
