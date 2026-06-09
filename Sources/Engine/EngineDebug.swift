import Foundation

/// Temporary milestone-1 verification harness. Runs the engine against the real
/// `~/.claude/projects/` and a live `claude --rc` session, printing what it
/// found. Triggered only when the `CCORN_DEBUG` env var is set, so the normal
/// app launch is untouched. REMOVE after milestone 1 is verified.
enum EngineDebug {

    static func run() {
        let line = String(repeating: "=", count: 72)
        func section(_ t: String) { print("\n\(line)\n\(t)\n\(line)") }

        let engine = SessionEngine(settings: debugSettings())

        // 1. Dependencies + resolved PATH ------------------------------------
        section("1. ENVIRONMENT / DEPENDENCIES")
        print("resolved PATH: \(CommandRunner.shared.resolvedPath)")
        let deps = engine.checkDependencies()
        print("tmux:   \(deps.tmuxPath ?? "NOT FOUND")")
        print("claude: \(deps.claudePath ?? "NOT FOUND")  version=\(deps.claudeVersion ?? "?")")
        print("brew:   \(deps.brewPath ?? "NOT FOUND")")

        // 2. Discovery -------------------------------------------------------
        section("2. DISCOVERY (filtered to watch dirs \(engine.settings.watchDirectories))")
        let projects = engine.discoverProjects()
        print("discovered \(projects.count) project(s) inside watch dirs:")
        for p in projects {
            let newest = p.mostRecentSession
            print("""
              • key=\(p.encodedKey)
                resolvedPath=\(p.resolvedPath ?? "nil")
                sessions=\(p.sessions.count)  newest=\(newest?.uuid ?? "-")  modified=\(newest.map { "\($0.modified)" } ?? "-")
            """)
        }
        let allCount = engine.discoverAllProjects().count
        print("\n(total projects on disk, unfiltered: \(allCount))")

        // 3. Launch reconciliation ------------------------------------------
        section("3. LAUNCH RECONCILIATION (existing ccorn windows)")
        let reconciled = engine.reconcile()
        if reconciled.isEmpty {
            print("no existing `ccorn` tmux session/windows.")
        } else {
            for live in reconciled {
                print("  • window=\(live.windowId ?? "-") tag=\(live.ccornTag ?? "-") pid=\(live.pid.map(String.init) ?? "-") state=\(live.state.rawValue) rcActive=\(live.remoteControlActive)")
            }
        }

        // 4. Round-trip: spawn -> detect -> kill ----------------------------
        section("4. ROUND-TRIP: spawn -> detect -> kill")
        guard deps.tmuxInstalled, deps.claudeInstalled else {
            print("SKIPPED: tmux and/or claude not found on PATH.")
            finish()
            return
        }
        let dir = "/tmp/ccorn-m1-debug"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        print("starting `claude --rc \"CCorn M1 Debug\"` in \(dir) ...")
        let result = engine.startNewSession(directory: dir, title: "CCorn M1 Debug")

        switch result {
        case .failed(let msg):
            print("FAILED to start: \(msg)")
            finish()
            return
        case .windowCreatedNoProcess(let windowId):
            print("window \(windowId) created but no claude child appeared within 5s.")
            print("pane snapshot:\n\(indent(engine.tmux.capturePane(windowId: windowId)))")
            engine.terminate(windowId: windowId)
            finish()
            return
        case .started(let windowId, let pid):
            print("started: window=\(windowId) pid=\(pid)  (alive=\(ProcessControl.isAlive(pid)))")

            // A fresh directory triggers Claude's "trust this folder" prompt
            // (correctly seen as Waiting). Accept it so we also reach the
            // Running / "Remote Control active" state.
            usleep(2_000_000)
            if engine.tmux.capturePane(windowId: windowId).localizedCaseInsensitiveContains("trust this folder") {
                print("(trust prompt shown -> detected Waiting; sending \"1\" to accept)")
                engine.tmux.sendCommand(windowId: windowId, "1")
            }

            // Give the TUI a moment to render the footer, then detect a few times.
            for i in 1...3 {
                usleep(1_500_000) // 1.5s
                engine.refreshState(windowId: windowId)
                let live = engine.liveSessions[windowId]
                print("  detect #\(i): state=\(live?.state.rawValue ?? "-") rcActive=\(live?.remoteControlActive ?? false) pid=\(live?.pid.map(String.init) ?? "-")")
            }

            let pane = engine.tmux.capturePane(windowId: windowId)
            print("\n--- pane snapshot (last 12 lines) ---")
            print(indent(lastLines(pane, 12)))
            print("--- contains \"\(StateDetector.remoteControlMarker)\": \(pane.contains(StateDetector.remoteControlMarker)) ---")

            // Try to bind the lazily-created transcript UUID.
            if let uuid = engine.mostRecentUUID(inDirectory: dir) {
                print("discovered transcript UUID for this dir: \(uuid)")
            } else {
                print("no transcript UUID yet (transcript is created lazily after the first turn).")
            }

            // Kill: terminate routine, then confirm gone.
            print("\nterminating window \(windowId) (kill-window -> SIGTERM/SIGKILL) ...")
            engine.terminate(windowId: windowId)
            usleep(500_000)
            let stillAlive = ProcessControl.isAlive(pid)
            let windowGone = engine.tmux.window(forCcornId: windowId) == nil &&
                !engine.tmux.listWindows().contains { $0.windowId == windowId }
            print("after terminate: pid \(pid) alive=\(stillAlive)  window present=\(!windowGone)")
            print(stillAlive || !windowGone ? "  ⚠️  cleanup incomplete — investigate" : "  ✅ round-trip clean: process and window gone")
        }

        finish()
    }

    // MARK: - Helpers

    /// Debug watch dirs: include the user's dev dir and /tmp so the probe project surfaces.
    private static func debugSettings() -> CCornSettings {
        var s = CCornSettings.default
        s.watchDirectories = [
            "\(NSHomeDirectory())/dev",
            "/private/tmp",
            "/tmp",
        ]
        s.staleThresholdSeconds = 600
        return s
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    private static func lastLines(_ s: String, _ n: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    private static func finish() {
        print("\n[CCORN_DEBUG] done. exiting.\n")
        // Flush stdout before the process exits.
        fflush(stdout)
        exit(0)
    }
}
