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
struct SessionDiscovery: Sendable {
    /// Computed, not stored: FileManager is thread-safe in practice but not
    /// `Sendable`, and storing it would break this struct's conformance.
    var fileManager: FileManager { .default }

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

    /// The project subdirectories of the projects root, sorted by encoded name so
    /// every enumeration-based API below is deterministic (directory listing
    /// order is not).
    private func projectDirs() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The transcripts directly inside one project dir, newest first. Flat
    /// `*.jsonl` only — this excludes the sibling `memory/` directory. Reads
    /// directory metadata only, never file contents.
    private func sessions(inProjectDir dir: URL) -> [DiscoveredSession] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [DiscoveredSession] = []
        for file in files where file.pathExtension == "jsonl" {
            let uuid = file.deletingPathExtension().lastPathComponent
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            sessions.append(DiscoveredSession(uuid: uuid, transcriptPath: file.path, modified: modified))
        }
        sessions.sort { $0.modified > $1.modified } // newest first
        return sessions
    }

    /// Enumerate all projects (unfiltered). `resolvedPath` is nil where no
    /// transcript has surfaced a `cwd` yet. Reads transcript heads to resolve
    /// each project's real path — use `transcriptIndex()` on the refresh hot
    /// path instead, which never opens a transcript.
    func discoverAll() -> [DiscoveredProject] {
        projectDirs().map { dir in
            let sessions = sessions(inProjectDir: dir)

            // Resolve the real path from the newest transcript that carries a cwd.
            var resolved: String?
            for session in sessions {
                if let cwd = Self.firstCwd(inTranscript: session.transcriptPath) {
                    resolved = Self.canonicalize(cwd)
                    break
                }
            }

            return DiscoveredProject(
                encodedKey: dir.lastPathComponent,
                projectDir: dir.path,
                resolvedPath: resolved,
                sessions: sessions
            )
        }
    }

    /// Single-enumeration index for the refresh hot path: session UUID ->
    /// transcript (path + mtime). Lists directories only — no transcript is
    /// opened, so a 3s poll cycle costs one readdir per project dir and nothing
    /// more. On a UUID collision across project dirs (should not happen; UUIDs
    /// are unique) the most recently modified transcript wins.
    func transcriptIndex() -> [String: DiscoveredSession] {
        var index: [String: DiscoveredSession] = [:]
        for dir in projectDirs() {
            for session in sessions(inProjectDir: dir) {
                if let existing = index[session.uuid], existing.modified >= session.modified {
                    continue
                }
                index[session.uuid] = session
            }
        }
        return index
    }

    /// Projects whose resolved path is inside one of the watch directories.
    /// Watch dirs are symlink-resolved before comparison. Non-existent watch
    /// dirs are skipped silently. Deduplicated by resolved path: on a collision
    /// (the same project under two encoded dirs) the winner is deterministic —
    /// the project with the most recently modified transcript.
    func discover(watchDirectories: [String]) -> [DiscoveredProject] {
        let watch = watchDirectories
            .map { Self.canonicalize(Self.expandTilde($0)) }
            .filter { fileManager.fileExists(atPath: $0) }

        var keptByPath: [String: DiscoveredProject] = [:]
        var order: [String] = []
        for project in discoverAll() {
            guard let path = project.resolvedPath else { continue }
            guard watch.contains(where: { Self.isPath(path, inside: $0) }) else { continue }
            if let existing = keptByPath[path] {
                let existingModified = existing.mostRecentSession?.modified ?? .distantPast
                let candidateModified = project.mostRecentSession?.modified ?? .distantPast
                if candidateModified > existingModified {
                    keptByPath[path] = project
                }
            } else {
                keptByPath[path] = project
                order.append(path)
            }
        }
        return order.compactMap { keptByPath[$0] }
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

    /// Title + cwd for a transcript. Cache through `TranscriptMetaCache` on any
    /// repeated path — this opens the file twice (head for cwd, head+tail for
    /// the title).
    static func meta(inTranscript path: String) -> TranscriptMeta {
        TranscriptMeta(title: lastAITitle(inTranscript: path),
                       cwd: firstCwd(inTranscript: path))
    }

    /// The session title: the LAST `ai-title` record's `aiTitle`. Claude
    /// re-appends the record as the session progresses (verified 2.1.170: the
    /// final occurrence sat within ~32 KB of EOF in every sampled transcript,
    /// while early copies go stale), so the last one is current and a bounded
    /// head + tail read finds it without scanning multi-MB transcripts. Some
    /// transcripts carry no ai-title at all — callers fall back to the
    /// directory basename.
    static func lastAITitle(inTranscript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let window = 256 * 1024
        // Throwing read API, not the legacy readData(ofLength:) — that one
        // raises an uncatchable ObjC exception on an I/O error, and this runs
        // for every changed transcript on the discovery path. Degrade to "no
        // title" instead.
        let head = (try? handle.read(upToCount: window)) ?? Data()
        var title = lastAITitle(inJSONLData: head, dropLeadingPartialLine: false)

        // File extends past the head window: the current title lives near EOF.
        if head.count >= window,
           let size = try? handle.seekToEnd(), size > UInt64(window) {
            try? handle.seek(toOffset: size - UInt64(window))
            if let tail = try? handle.read(upToCount: window),
               // The seek lands mid-line, so the tail's first line is partial.
               let fromTail = lastAITitle(inJSONLData: tail, dropLeadingPartialLine: true) {
                title = fromTail
            }
        }
        return title
    }

    private static func lastAITitle(inJSONLData data: Data, dropLeadingPartialLine: Bool) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropLeadingPartialLine, !lines.isEmpty { lines.removeFirst() }
        // A partial trailing line (truncated head window) simply fails the JSON
        // parse and is skipped — no separate handling needed.
        for line in lines.reversed() {
            guard line.contains("\"ai-title\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let title = obj["aiTitle"] as? String,
                  !title.isEmpty else { continue }
            return title
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
    ///
    /// Foundation normalizes toward the shorter `/tmp` form, but ONLY when the
    /// leaf exists on disk (RUNTIME_FINDINGS T3) — so without the manual strip
    /// below, `/private/tmp/<deleted>` and `/tmp/<deleted>` would canonicalize
    /// differently and a deleted-or-symlinked project dir would silently stop
    /// matching its watch directory. The strip makes the mapping unconditional:
    /// `/private/{tmp,var,etc}` are the firmlink targets of the `/{tmp,var,etc}`
    /// symlinks on every macOS install, so rewriting is always safe.
    static func canonicalize(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        var resolved = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        for prefix in ["/private/tmp", "/private/var", "/private/etc"] {
            if resolved == prefix || resolved.hasPrefix(prefix + "/") {
                resolved.removeFirst("/private".count)
                break
            }
        }
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
