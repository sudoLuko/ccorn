import Foundation

/// Locates the external (non-CCorn) `claude` process running in a directory,
/// the kill step of the import flows (6.2 / 6.10). This is the one sanctioned
/// exception to "only search children of our own pane shells": an unmanaged
/// session by definition has no CCorn shell above it.
///
/// Registry-first: every running claude writes `~/.claude/sessions/<pid>.json`
/// with its pid, sessionId, and cwd (runtime findings F3). Files for dead pids
/// linger, so a hit counts only if the pid is alive AND still claude-shaped by
/// argv/exec-path (`ProcessControl.looksLikeClaude`); never by process name.
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
    /// registry knows it (exact: survives two sessions in one directory), else
    /// by working directory. nil when nothing is running there, in which case
    /// import simply skips the kill step.
    ///
    /// Because the only caller of the kill path (`SessionEngine.importSession`)
    /// unconditionally SIGTERM/SIGKILLs whatever this returns, the *cost of a
    /// wrong answer is destroying an unrelated live session*. So the
    /// process-table fallback (no session identity, only a cwd match) is gated:
    /// when an explicit `sessionId` was requested but the registry could not
    /// confirm it, and two-or-more claude processes share the target directory,
    /// we cannot prove which one is the requested session — so we refuse to pick
    /// one to kill and return nil (import then skips the kill step and resume
    /// reconciles). A single unambiguous claude in the directory is still
    /// returned, so the common lazy/stale-registry take-over keeps working.
    static func find(inDirectory directory: String,
                     sessionId: String? = nil,
                     claudeDir: URL = defaultClaudeDir) -> Candidate? {
        let target = SessionDiscovery.canonicalize(directory)
        let registry = registryCandidates(claudeDir: claudeDir)
        if let sessionId, let exact = registry.first(where: { $0.sessionId == sessionId }) {
            return exact
        }
        // Directory fallback: never a candidate the registry PROVES belongs to
        // a different session; two sessions can share one directory, and
        // killing the other one's process would be destructive.
        if let byDir = registry.first(where: { $0.cwd == target
            && (sessionId == nil || $0.sessionId == nil || $0.sessionId == sessionId) }) {
            return byDir
        }
        // Process-table fallback: claude-shaped pids whose cwd matches, with no
        // session identity (the registry didn't have it). The strict global
        // signal is applied inside `processTableCandidates()`, since this scan is
        // NOT constrained to our own shell's descendants. The selection itself is
        // the pure `selectFromProcessTable`, so its destructive-ambiguity gate is
        // unit-testable without spawning `ps`/`lsof`.
        return selectFromProcessTable(processTableCandidates(),
                                      target: target, sessionId: sessionId)
    }

    /// Choose at most one process-table candidate to hand to the kill path. Pure
    /// (no `ps`/`lsof`), so its safety contract is unit-tested. The caller
    /// SIGTERM/SIGKILLs the result unconditionally, so a wrong pick destroys an
    /// unrelated live session:
    /// - When a specific `sessionId` was requested but two-or-more claude
    ///   processes share its directory (none registry-confirmed as that
    ///   session), we cannot prove which is the one asked for → return nil
    ///   (skip the kill; resume reconciles). The old `.first` here is what could
    ///   kill the *other* session.
    /// - A single match (the common lazy/stale-registry single-session
    ///   take-over) is returned. With no `sessionId` (no identity requested) the
    ///   first match is returned as before.
    static func selectFromProcessTable(_ candidates: [Candidate],
                                       target: String,
                                       sessionId: String?) -> Candidate? {
        let inDir = candidates.filter { $0.cwd == target }
        if sessionId != nil && inDir.count > 1 { return nil }
        return inDir.first
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
        if !r.ok {
            // ps could not enumerate the process table; the import kill step
            // can't find the unmanaged claude and skips it. .notice; exit public.
            Log.process.notice("ps process-table scan failed (exit \(r.exitCode, privacy: .public))")
        }
        var out: [Candidate] = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)),
                  pid != ProcessInfo.processInfo.processIdentifier,
                  isStronglyLiveClaude(pid: pid),
                  let cwd = cwd(ofPid: pid)
            else { continue }
            out.append(Candidate(pid: pid, sessionId: nil,
                                 cwd: SessionDiscovery.canonicalize(cwd)))
        }
        return out
    }

    /// Alive AND claude by argv/exec-path. Guards against pid reuse under a
    /// lingering registry file. Used by the registry scan, where the candidate
    /// pid came from a `~/.claude/sessions/<pid>.json` file claude wrote for
    /// itself — i.e. there is already strong evidence the pid is claude — so the
    /// tolerant `looksLikeClaude` (including the bare `--rc` heuristic) is fine.
    static func isLiveClaude(pid: Int32) -> Bool {
        guard ProcessControl.isAlive(pid),
              let info = ProcessControl.processInfo(pid: pid) else { return false }
        return ProcessControl.looksLikeClaude(execPath: info.execPath, argv: info.argv)
    }

    /// Alive AND *strongly* claude by argv/exec-path, for the whole-machine
    /// process-table fallback. That scan is NOT constrained to our own shell's
    /// descendants and feeds an unconditional kill, so it must not accept the
    /// bare `--rc` heuristic that `looksLikeClaude` allows: `--rc` alone is
    /// "safe only because callers constrain the search to the spawned shell's
    /// descendants" (ProcessControlTests). Globally, an unrelated process
    /// invoked with a `--rc` argument is not claude. Require a real claude
    /// signal: argv[0]/exec basename == "claude", a `/claude/versions/` exec
    /// path (native, version-named), or a `cli.js` arg (node-wrapped). This
    /// tightens only the global path; the shared `looksLikeClaude` and its
    /// descendant-constrained callers are untouched.
    static func isStronglyLiveClaude(pid: Int32) -> Bool {
        guard ProcessControl.isAlive(pid),
              let info = ProcessControl.processInfo(pid: pid) else { return false }
        return looksStronglyLikeClaude(execPath: info.execPath, argv: info.argv)
    }

    /// Strict claude predicate for the global scan: `looksLikeClaude` minus the
    /// bare `--rc`-alone match. Pure, so it is unit-testable without a process.
    static func looksStronglyLikeClaude(execPath: String, argv: [String]) -> Bool {
        let arg0Base = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let execBase = (execPath as NSString).lastPathComponent
        if arg0Base == "claude" { return true }
        if execBase == "claude" { return true }
        if execPath.contains("/claude/versions/") { return true }     // native, version-named
        if argv.contains(where: { $0.hasSuffix("cli.js") }) { return true } // node-wrapped
        return false                                                  // bare `--rc` is NOT enough here
    }

    /// Working directory via `lsof -a -p <pid> -d cwd -Fn` (field output: the
    /// `n`-prefixed line is the path).
    static func cwd(ofPid pid: Int32) -> String? {
        let r = CommandRunner.shared.run("lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        for line in r.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        // No cwd line: lsof failed or the pid's cwd is unreadable (e.g. another
        // user's process); the candidate drops out. .notice; pid + exit public.
        Log.process.notice("lsof could not read cwd for pid \(pid, privacy: .public) (exit \(r.exitCode, privacy: .public))")
        return nil
    }
}
