import Foundation
import Testing

/// Regression proof for the exact-match base-session target. tmux's target
/// matching is PREFIX-based, so a bare `-t ccorn` also resolves to a leftover
/// `ccorn-view-*` grouped session: that made `hasSession()` falsely true (so the
/// base was never rebuilt) and routed new windows/options onto the view. The fix
/// targets the base session by exact name via `TmuxController.sessionTarget`
/// (`=ccorn`). These tests pin both the construction of that target string and
/// the real tmux behavior it depends on.
@Suite struct TmuxSessionTargetTests {

    // MARK: - (a) Pure construction

    /// The exact-match form is `=` + the session name, and it begins with `=`.
    /// Pinning this catches a revert to the bare, prefix-matching target.
    @Test func sessionTargetIsExactMatchForm() {
        #expect(TmuxController.sessionTarget == "=" + TmuxController.sessionName)
        #expect(TmuxController.sessionTarget.hasPrefix("="))
    }

    // MARK: - (b) Real tmux behavior

    /// Resolve a tmux binary on PATH (the build host has tmux at
    /// /opt/homebrew/bin/tmux). Returns nil when tmux is absent so the suite
    /// skips with a reason instead of failing.
    private static func tmuxPath() -> String? {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to PATH resolution via `env`.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux", "-V"]
        let null = FileHandle.nullDevice
        p.standardOutput = null
        p.standardError = null
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return "/usr/bin/env" }
        } catch { return nil }
        return nil
    }

    /// Run `tmux` (or `env tmux`) on a throwaway socket; returns the exit code.
    /// Never touches the user's default server (always `-L <socket>`).
    @discardableResult
    private func runTmux(_ tmux: String, socket: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        let prefix = tmux.hasSuffix("env") ? ["tmux"] : []
        p.arguments = prefix + ["-L", socket] + args
        let null = FileHandle.nullDevice
        p.standardOutput = null
        p.standardError = null
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    /// On a throwaway socket holding ONLY a `ccorn-view-*` session and no base
    /// `ccorn`: the bare prefix target `ccorn` matches the view (the hazard),
    /// while the exact target `=ccorn` does not (the fix). Consumes the
    /// production strings so a regression in (a) is also caught by real tmux.
    @Test func exactTargetExcludesStrayViewSession() throws {
        guard let tmux = Self.tmuxPath() else {
            // Absence of tmux must not fail the suite.
            withKnownIssue("tmux not on PATH; skipping real-tmux behavior proof") {
                Issue.record("tmux unavailable")
            }
            return
        }

        // Unique, view-only socket so the throwaway server shares nothing with
        // the user's real one. NEVER the default socket.
        let socket = "ccorn-target-test-\(UUID().uuidString)"
        defer { runTmux(tmux, socket: socket, ["kill-server"]) }

        // Create ONLY a stray view session, no base `ccorn`.
        let viewName = TmuxController.viewSessionPrefix + "-130"   // e.g. ccorn-view-130
        let created = runTmux(tmux, socket: socket, ["new-session", "-d", "-s", viewName])
        try #require(created == 0, "could not create the stray view session on the throwaway socket")

        // The HAZARD is real: bare `ccorn` prefix-matches the view (exit 0).
        let bareExit = runTmux(tmux, socket: socket,
                               ["has-session", "-t", TmuxController.sessionName])
        #expect(bareExit == 0,
                "bare prefix target should match the stray ccorn-view session (the hazard the fix guards)")

        // The FIX excludes it: exact `=ccorn` does not match (exit non-zero).
        let exactExit = runTmux(tmux, socket: socket,
                                ["has-session", "-t", TmuxController.sessionTarget])
        #expect(exactExit != 0,
                "exact-match target must not resolve to the stray view when no base session exists")
    }

    // MARK: - (c) Shell-string safety (the Open-in-Terminal attach path)

    /// `attachViewCommand` is run by the user's SHELL (Terminal `do script`), not
    /// exec'd via argv like the engine's other tmux calls. zsh equals-expands a
    /// leading `=`, so a bare `-t =ccorn` makes zsh try to run `ccorn`
    /// ("zsh: ccorn not found") before tmux sees it. The exact-match base target
    /// must therefore be single-quoted in this one command. (Reads the default
    /// server read-only for the view name; degrades to a bare view name if tmux
    /// is absent, which does not affect the target-quoting this asserts.)
    @Test func attachViewCommandSingleQuotesExactTarget() {
        let cmd = TmuxController().attachViewCommand(windowId: "@15", mouseMode: true)
        // The base target is quoted, so zsh passes `=ccorn` to tmux literally.
        #expect(cmd.contains("new-session -t '\(TmuxController.sessionTarget)' -s "))
        // The bare, equals-expansion-prone form must never appear.
        #expect(!cmd.contains("new-session -t \(TmuxController.sessionTarget) -s "))
    }
}
