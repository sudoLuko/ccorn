import Foundation
import Testing

/// ProcessControl: the claude-match predicate (pure) and the KERN_PROCARGS2
/// argv/exec-path parser. The parser is the most syscall-fragile engine code and
/// previously had no coverage; these tests pin its contract by parsing the
/// running test process, a guaranteed-live pid whose argv we can cross-check.
@Suite struct ProcessControlTests {

    // MARK: looksLikeClaude: match by argv / exec-path basename, NEVER proc_name

    /// Native install: the binary is version-named, so argv[0] and the exec path
    /// basename are the version (e.g. `2.1.169`); we must still match via the
    /// `/claude/versions/` exec path and the `--rc` argument (runtime findings C3).
    @Test func matchesNativeVersionNamedBinary() {
        #expect(ProcessControl.looksLikeClaude(
            execPath: "/Users/x/.local/share/claude/versions/2.1.169",
            argv: ["2.1.169", "--rc"]))
    }

    @Test func matchesClaudeArgv0AndExecBasename() {
        #expect(ProcessControl.looksLikeClaude(execPath: "/usr/local/bin/claude", argv: ["claude", "--rc"]))
        #expect(ProcessControl.looksLikeClaude(execPath: "/opt/homebrew/bin/claude", argv: ["claude"]))
    }

    /// Node-wrapped install shape: `node .../cli.js`.
    @Test func matchesNodeWrappedCliJs() {
        #expect(ProcessControl.looksLikeClaude(
            execPath: "/usr/local/bin/node",
            argv: ["node", "/Users/x/.npm/claude/cli.js", "--rc"]))
    }

    @Test func matchesBareRcFlag() {
        // The `--rc` heuristic is intentionally broad; it is safe only because
        // callers constrain the search to the spawned shell's descendants.
        #expect(ProcessControl.looksLikeClaude(execPath: "/bin/zsh", argv: ["zsh", "--rc"]))
    }

    @Test func rejectsUnrelatedProcesses() {
        #expect(!ProcessControl.looksLikeClaude(execPath: "/bin/zsh", argv: ["zsh", "-l"]))
        #expect(!ProcessControl.looksLikeClaude(execPath: "/usr/bin/vim", argv: ["vim", "file.txt"]))
        // An empty argv + unrelated exec path is not claude (and the truncated
        // proc_name `2.1.169` is deliberately NOT part of the match set).
        #expect(!ProcessControl.looksLikeClaude(execPath: "/usr/bin/top", argv: []))
    }

    // MARK: KERN_PROCARGS2 parser

    /// The test process is a guaranteed-live pid: parsing it must yield a
    /// non-empty exec path and a non-empty argv with a non-empty argv[0]. This
    /// exercises the full walk (argc, exec_path + alignment padding, single-NUL
    /// argv terminators) and proves the empty-element fix didn't break normal args.
    @Test func parsesArgvOfRunningProcess() throws {
        let info = try #require(ProcessControl.processInfo(pid: getpid()))
        #expect(!info.execPath.isEmpty)
        #expect(!info.argv.isEmpty)
        #expect(!(info.argv.first ?? "").isEmpty)
    }

    /// A reaped pid has no args to read -> nil (no crash, no garbage).
    @Test func returnsNilForReapedPid() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        #expect(ProcessControl.processInfo(pid: p.processIdentifier) == nil)
    }

    // MARK: startTime (drives the spawn grace window)

    /// The running test process has a sane start time: non-nil and in the past.
    @Test func startTimeOfRunningProcessIsSane() throws {
        let start = try #require(ProcessControl.startTime(pid: getpid()))
        #expect(start <= Date())
        #expect(start > Date(timeIntervalSince1970: 0))
    }

    /// A reaped pid has no start time -> nil (this is what denies grace to a
    /// vanished shell).
    @Test func startTimeOfReapedPidIsNil() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        #expect(ProcessControl.startTime(pid: p.processIdentifier) == nil)
        #expect(ProcessControl.startTime(pid: -1) == nil)
    }

    // MARK: terminate (PID-reuse guard)

    /// terminate() on a pid that never existed is a clean no-op: `startTime` is
    /// nil on entry, so the guard returns before any signal and the call does not
    /// hang on the 5s wait loop. (`-1` and a 0 pid also exercise the `pid > 0`
    /// rejection inside `startTime`.)
    @Test func terminateOnNonexistentPidIsNoOp() async {
        await ProcessControl.terminate(pid: -1)
        await ProcessControl.terminate(pid: 0)
    }

    /// terminate() on an already-reaped child returns promptly without signalling
    /// anything: by the time we call it the child is gone, so the entry-point
    /// `startTime` lookup is nil and the routine returns immediately. A 5s wait
    /// would only happen for a genuinely-alive same-identity process, so a slow
    /// return here would surface a broken guard. We can't *force* a same-pid
    /// recycle deterministically, so the recycle branch (start time differs ->
    /// skip) is covered by reasoning, not a spawned victim.
    @Test func terminateOnReapedChildReturnsWithoutSignalling() async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        let pid = p.processIdentifier
        #expect(ProcessControl.startTime(pid: pid) == nil)   // genuinely gone

        let start = Date()
        await ProcessControl.terminate(pid: pid)             // must not enter the wait loop
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
