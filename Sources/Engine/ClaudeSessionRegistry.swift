import Foundation

/// Reads Claude Code's per-process session registry: `~/.claude/sessions/<pid>.json`,
/// written by each running `claude` process for itself (verified on 2.1.170 —
/// milestone-2 fix findings). It carries the session
/// UUID and cwd for a live pid, which lets launch reconciliation bind an
/// adopted window to its session exactly, instead of guessing from pane
/// contents or directory matching.
///
/// Files for dead pids linger in the directory, so this must only be consulted
/// for a pid that was just verified to be a live claude child of one of our
/// pane shells (`ProcessControl.findClaude`).
enum ClaudeSessionRegistry {
    struct Info: Sendable {
        let sessionId: String
        let cwd: String?
    }

    /// `~/.claude` by default; tests point it at a fixture tree.
    static func info(forPid pid: Int32,
                     claudeDir: URL = URL(fileURLWithPath: NSHomeDirectory())
                         .appendingPathComponent(".claude")) -> Info? {
        let url = claudeDir
            .appendingPathComponent("sessions")
            .appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              !sessionId.isEmpty else { return nil }
        let cwd = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Info(sessionId: sessionId, cwd: cwd)
    }
}
