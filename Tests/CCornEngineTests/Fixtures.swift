import Foundation

/// Locates the real captured fixtures (tmux pane frames + a real Claude Code
/// transcript) that live next to this source file. Read at runtime via
/// `#filePath` rather than bundled as resources, so no resource plumbing is
/// needed for this hostless logic-test bundle.
enum Fixtures {
    /// `Tests/CCornEngineTests/Fixtures`
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// A captured `tmux capture-pane -p -J` frame, verbatim.
    static func paneText(_ name: String) -> String {
        let url = root.appendingPathComponent("panes").appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("missing pane fixture: \(url.path)")
        }
        return text
    }

    /// A fixture `~/.claude/projects`-shaped tree (one encoded project dir holding
    /// a real transcript plus a sibling `memory/` to be ignored).
    static var projectsRoot: URL {
        root.appendingPathComponent("projects")
    }

    /// The single real transcript fixture's absolute path.
    static var transcriptPath: String {
        projectsRoot
            .appendingPathComponent("-private-tmp-ccorn-fix-probe")
            .appendingPathComponent("f1c70000-0000-4000-8000-000000000000.jsonl")
            .path
    }

    /// The session UUID == transcript filename for the fixture.
    static let transcriptUUID = "f1c70000-0000-4000-8000-000000000000"

    static func firstLine(ofFileAt path: String) -> String {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}
