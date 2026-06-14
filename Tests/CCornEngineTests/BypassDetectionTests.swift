import Foundation
import Testing

/// The active-bypass pane signal that drives the row's bypass marker. Matched on
/// the core phrase so the leading glyph (`⏵`) and spacing can vary across CLI
/// versions; reflects ACTUAL runtime bypass, including a session escalated into
/// bypass mid-session.
@Suite struct BypassDetectionTests {

    let detector = StateDetector()

    @Test func detectsTheBypassFooterWithGlyphAndSpacing() {
        #expect(detector.showsBypass(pane: "⏵ bypass permissions on"))
        #expect(detector.showsBypass(pane: "  ⏵⏵ bypass permissions on (shift+tab to cycle)"))
        // Case-insensitive, so a renderer that capitalizes still matches.
        #expect(detector.showsBypass(pane: "Bypass Permissions On"))
    }

    @Test func ignoresPanesWithoutActiveBypass() {
        #expect(!detector.showsBypass(pane: "⏵⏵ accept edits on"))
        #expect(!detector.showsBypass(pane: "normal session, ? for shortcuts"))
        // The word "bypass" alone, not the active footer, must not trip it.
        #expect(!detector.showsBypass(pane: "You can bypass this with --dangerously-skip-permissions"))
    }

    /// detect() carries the signal into the result. A live pid (the test
    /// process's own) skips the pane-shell re-derive, so no pgrep is needed.
    @Test func detectSetsBypassActiveFromPane() {
        let stub = StubPanes(pane: "claude\n⏵ bypass permissions on\n? for shortcuts")
        let result = detector.detect(
            input: DetectionInput(windowId: "@1",
                                  pid: ProcessInfo.processInfo.processIdentifier),
            panes: stub,
            transcript: nil,
            staleThreshold: 600,
            now: Date(timeIntervalSince1970: 1_000_000),
            bridgeForPid: { _ in nil })
        #expect(result.bypassActive)
    }

    // MARK: Root refusal

    @Test func recognizesTheBypassRootRefusalLine() {
        let pane = "│ --dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons │"
        let line = detector.launchFatalError(pane: pane)
        #expect(line != nil)
        #expect(line?.contains("cannot be used with root") == true)
        // Box-drawing chrome is stripped.
        #expect(line?.hasPrefix("│") == false)
    }

    @Test func ordinaryPaneHasNoLaunchFatalError() {
        #expect(detector.launchFatalError(pane: "claude\n? for shortcuts") == nil)
    }

    @Test func rootDropsBypassModesFromTheSelectableList() {
        let asRoot = CCPermissionMode.selectable(isRoot: true)
        #expect(!asRoot.contains(.bypass))
        #expect(!asRoot.contains(.allowBypass))
        #expect(asRoot.contains(.auto))
        // Non-root offers everything.
        #expect(CCPermissionMode.selectable(isRoot: false) == CCPermissionMode.allCases)
    }

    @Test func detectLeavesBypassFalseForOrdinarySessions() {
        let stub = StubPanes(pane: "claude\n? for shortcuts")
        let result = detector.detect(
            input: DetectionInput(windowId: "@1",
                                  pid: ProcessInfo.processInfo.processIdentifier),
            panes: stub,
            transcript: nil,
            staleThreshold: 600,
            now: Date(timeIntervalSince1970: 1_000_000),
            bridgeForPid: { _ in nil })
        #expect(!result.bypassActive)
    }
}
