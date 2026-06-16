import Foundation

/// Thin CLI over the production `StateDetector`: classifies captured pane
/// frames exactly as the engine's pure classifier would (first observation,
/// no previous hash, and a huge stale threshold so idle frames read Running,
/// never Stale) and prints one TSV row per file.
///
/// Columns:
///   state  live_activity  waiting  rc_marker  claude_evidence  auth_notice  rc_plan_notice  file
///
/// Every phrase and rule lives in Sources/Engine/StateDetector.swift, which is
/// compiled into this binary by scripts/preflight/run.sh. This file must never
/// duplicate a detection phrase: if it needs one, the contract test would stop
/// testing the app and start testing itself.
@main
struct PaneClassify {
    static func main() {
        var paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("usage: pane-classify <frame.txt> [...] | pane-classify --bridge <transcript.jsonl>\n".utf8))
            exit(2)
        }

        // --bridge: the engine's other remote-control signal. Prints true/false
        // using the production transcript check (runtime findings C1/C2).
        if paths.first == "--bridge" {
            paths.removeFirst()
            guard paths.count == 1 else {
                FileHandle.standardError.write(Data("usage: pane-classify --bridge <transcript.jsonl>\n".utf8))
                exit(2)
            }
            print(SessionDiscovery.transcriptHasBridgeSession(path: paths[0]))
            exit(0)
        }

        let detector = StateDetector()
        let now = Date()
        var unreadable = false

        print("state\tlive_activity\twaiting\trc_marker\tclaude_evidence\tauth_notice\trc_plan_notice\tfile")
        for path in paths {
            guard let pane = try? String(contentsOfFile: path, encoding: .utf8) else {
                FileHandle.standardError.write(Data("error: cannot read \(path)\n".utf8))
                unreadable = true
                continue
            }
            let verdict = detector.classifyPane(pane: pane,
                                                lastPaneHash: nil,
                                                lastHashChange: nil,
                                                staleThreshold: 86_400,
                                                now: now)
            let fields = [
                verdict.state.rawValue,
                String(detector.showsLiveActivity(pane: pane)),
                String(detector.isWaiting(pane: pane)),
                String(pane.contains(StateDetector.remoteControlMarker)),
                String(detector.showsClaudeEvidence(pane: pane)),
                oneLine(detector.authNotice(pane: pane)),
                oneLine(detector.rcPlanNotice(pane: pane)),
                path,
            ]
            print(fields.joined(separator: "\t"))
        }
        exit(unreadable ? 1 : 0)
    }

    /// Notices are pane lines; keep the TSV one row per frame.
    private static func oneLine(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
