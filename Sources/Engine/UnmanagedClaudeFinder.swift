import Foundation

/// Locates the external (non-CCorn) `claude` process running in a directory —
/// the kill step of the import flows (6.2 / 6.10). This is the one sanctioned
/// exception to "only search children of our own pane shells": an unmanaged
/// session by definition has no CCorn shell above it.
///
/// Registry-first: every running claude writes `~/.claude/sessions/<pid>.json`
/// with its pid, sessionId, and cwd (RUNTIME_FINDINGS F3). Files for dead pids
/// linger, so a hit counts only if the pid is alive AND still claude-shaped by
/// argv/exec-path (`ProcessControl.looksLikeClaude`) — never by process name.
/// Fallback when the registry has no match: walk the process table for
/// claude-shaped argvs and resolve each candidate's cwd with
/// `lsof -a -p <pid> -d cwd` (`ps` cannot report a process's cwd).
enum UnmanagedClaudeFinder {
    struct Candidate: Sendable, Equatable {
        let pid: Int32
        /// Known only for registry hits.
        let sessionId: String?
        /// Canonicalized working directory.
        let cwd: String
    }

    static var defaultClaudeDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// The live claude process for a session: matched by session UUID when the
    /// registry knows it (exact — survives two sessions in one directory), else
    /// by working directory. nil when nothing is running there, in which case
    /// import simply skips the kill step.
    static func find(inDirectory directory: String,
                     sessionId: String? = nil,
                     claudeDir: URL = defaultClaudeDir) -> Candidate? {
        let target = SessionDiscovery.canonicalize(directory)
        let registry = registryCandidates(claudeDir: claudeDir)
        if let sessionId, let exact = registry.first(where: { $0.sessionId == sessionId }) {
            return exact
        }
        // Directory fallback: never a candidate the registry PROVES belongs to
        // a different session — two sessions can share one directory, and
        // killing the other one's process would be destructive.
        if let byDir = registry.first(where: { $0.cwd == target
            && (sessionId == nil || $0.sessionId == nil || $0.sessionId == sessionId) }) {
            return byDir
        }
        return processTableCandidates().first { $0.cwd == target }
    }

    /// Registry entries whose pid is alive and still claude-shaped.
    static func registryCandidates(claudeDir: URL = defaultClaudeDir) -> [Candidate] {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [Candidate] = []
        for file in files where file.pathExtension == "json" {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent),
                  isLiveClaude(pid: pid),
                  let info = ClaudeSessionRegistry.info(forPid: pid, claudeDir: claudeDir),
                  let cwd = info.cwd
            else { continue }
            out.append(Candidate(pid: pid,
                                 sessionId: info.sessionId,
                                 cwd: SessionDiscovery.canonicalize(cwd)))
        }
        return out
    }

    /// Process-table fallback: every live claude-shaped pid with a readable cwd.
    /// KERN_PROCARGS2 fails for other users' processes, which silently (and
    /// correctly) excludes them.
    static func processTableCandidates() -> [Candidate] {
        let r = CommandRunner.shared.run("/bin/ps", ["-axo", "pid="])
        var out: [Candidate] = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)),
                  pid != ProcessInfo.processInfo.processIdentifier,
                  isLiveClaude(pid: pid),
                  let cwd = cwd(ofPid: pid)
            else { continue }
            out.append(Candidate(pid: pid, sessionId: nil,
                                 cwd: SessionDiscovery.canonicalize(cwd)))
        }
        return out
    }

    /// Alive AND claude by argv/exec-path. Guards against pid reuse under a
    /// lingering registry file.
    static func isLiveClaude(pid: Int32) -> Bool {
        guard ProcessControl.isAlive(pid),
              let info = ProcessControl.processInfo(pid: pid) else { return false }
        return ProcessControl.looksLikeClaude(execPath: info.execPath, argv: info.argv)
    }

    /// Working directory via `lsof -a -p <pid> -d cwd -Fn` (field output: the
    /// `n`-prefixed line is the path).
    static func cwd(ofPid pid: Int32) -> String? {
        let r = CommandRunner.shared.run("lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        for line in r.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }
}
