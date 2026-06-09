import Foundation

/// Discovers Claude Code projects/sessions from `~/.claude/projects/`.
///
/// Rules (docs/CCORN_SPEC.md "Session Discovery" / "Encoded Path Format",
/// docs/RUNTIME_FINDINGS.md C4/C5):
/// - Enumerate every subdirectory of `~/.claude/projects/`. Each is a project.
/// - The directory name is an opaque, lossy key — NEVER decode it.
/// - Resolve the real path from the first transcript line that carries `cwd`
///   (line 1 is a `{leafUuid, sessionId, type}` metadata record without `cwd`).
/// - Transcripts are flat `*.jsonl` directly in the dir; ignore the `memory/`
///   sibling (we only read `*.jsonl`, so it's excluded naturally).
/// - Transcripts are created lazily, so a brand-new project may have no `cwd` yet.
/// - Keep only projects whose resolved `cwd` is inside a (symlink-resolved) watch dir.
struct SessionDiscovery {
    let fileManager = FileManager.default

    /// Override for the projects root. Defaults to `~/.claude/projects`; tests
    /// point it at a fixture tree. Nil in normal app use.
    private let projectsRootOverride: URL?

    init(projectsRoot: URL? = nil) {
        self.projectsRootOverride = projectsRoot
    }

    /// `~/.claude/projects` (or the test override).
    var projectsRoot: URL {
        if let projectsRootOverride { return projectsRootOverride }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// Enumerate all projects (unfiltered). `resolvedPath` is nil where no
    /// transcript has surfaced a `cwd` yet.
    func discoverAll() -> [DiscoveredProject] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var projects: [DiscoveredProject] = []
        for dir in entries {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let encodedKey = dir.lastPathComponent

            // Flat *.jsonl only — this excludes the sibling `memory/` directory.
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var sessions: [DiscoveredSession] = []
            for file in files where file.pathExtension == "jsonl" {
                let uuid = file.deletingPathExtension().lastPathComponent
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                sessions.append(DiscoveredSession(uuid: uuid, transcriptPath: file.path, modified: modified))
            }
            sessions.sort { $0.modified > $1.modified } // newest first

            // Resolve the real path from the newest transcript that carries a cwd.
            var resolved: String?
            for session in sessions {
                if let cwd = Self.firstCwd(inTranscript: session.transcriptPath) {
                    resolved = Self.canonicalize(cwd)
                    break
                }
            }

            projects.append(DiscoveredProject(
                encodedKey: encodedKey,
                projectDir: dir.path,
                resolvedPath: resolved,
                sessions: sessions
            ))
        }
        return projects
    }

    /// Projects whose resolved path is inside one of the watch directories.
    /// Watch dirs are symlink-resolved before comparison. Non-existent watch
    /// dirs are skipped silently. Deduplicated by resolved path.
    func discover(watchDirectories: [String]) -> [DiscoveredProject] {
        let watch = watchDirectories
            .map { Self.canonicalize(Self.expandTilde($0)) }
            .filter { fileManager.fileExists(atPath: $0) }

        var seen = Set<String>()
        var kept: [DiscoveredProject] = []
        for project in discoverAll() {
            guard let path = project.resolvedPath else { continue }
            guard watch.contains(where: { Self.isPath(path, inside: $0) }) else { continue }
            if seen.contains(path) { continue } // dedup by absolute path
            seen.insert(path)
            kept.append(project)
        }
        return kept
    }

    // MARK: - Transcript parsing

    /// Read the `cwd` from the first transcript line that carries one. Reads only
    /// the head of the file (the cwd-bearing `system`/`user` record appears near
    /// the top); falls back to the full file if the head doesn't contain it.
    static func firstCwd(inTranscript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 256 * 1024)
        // Only drop a partial trailing line when the head was actually truncated
        // at the 256 KB boundary. A small transcript that fit entirely in the head
        // keeps its complete final line — otherwise a freshly-created,
        // newline-less transcript whose only cwd is on the last written line would
        // be missed here, and the fallback read below returns empty (the whole
        // file was already consumed), yielding a spurious nil.
        let headTruncated = head.count >= 256 * 1024
        if let cwd = cwd(inJSONLData: head, allowPartialLastLine: headTruncated) { return cwd }

        // Rare: cwd beyond the first 256 KB. Read the rest.
        let rest = handle.readDataToEndOfFile()
        if rest.isEmpty { return nil }
        var full = head
        full.append(rest)
        return cwd(inJSONLData: full, allowPartialLastLine: false)
    }

    private static func cwd(inJSONLData data: Data, allowPartialLastLine: Bool) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // A truncated head may end mid-line; drop the last (possibly partial) line.
        if allowPartialLastLine, !lines.isEmpty, !text.hasSuffix("\n") {
            lines.removeLast()
        }
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// True if the transcript contains a `bridge-session` record (remote-control
    /// linkage, version-independent signal — see docs/RUNTIME_FINDINGS.md C1/C2).
    static func transcriptHasBridgeSession(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("\"bridge-session\"")
    }

    // MARK: - Path helpers

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Resolve symlinks so `/tmp/x` and `/private/tmp/x` compare equal (and match
    /// the encoded form, which is built from the resolved path).
    static func canonicalize(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        return resolved
    }

    /// True if `path` is `parent` or nested inside it (component-aware, so
    /// `/a/bc` is not considered inside `/a/b`).
    static func isPath(_ path: String, inside parent: String) -> Bool {
        if path == parent { return true }
        let p = parent.hasSuffix("/") ? parent : parent + "/"
        return path.hasPrefix(p)
    }
}
