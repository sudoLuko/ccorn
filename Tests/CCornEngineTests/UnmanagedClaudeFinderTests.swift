import Foundation
import Testing

/// `UnmanagedClaudeFinder` is the kill-target selector for the import/take-over
/// flow: `SessionEngine.importSession` unconditionally SIGTERM/SIGKILLs whatever
/// `find()` returns. A wrong answer destroys an unrelated *live* session, so the
/// two pure decision points below are pinned here.
///
/// `find()`'s registry path needs a *live claude-shaped pid* to produce a
/// candidate (`isLiveClaude` checks both liveness and argv shape), which a unit
/// test cannot fabricate without a real claude process. So these tests target
/// the two pure helpers the destructive defects live in: the process-table
/// selection gate (`selectFromProcessTable`) and the strict global claude
/// signal (`looksStronglyLikeClaude`).
@Suite struct UnmanagedClaudeFinderTests {

    private func candidate(pid: Int32, cwd: String) -> UnmanagedClaudeFinder.Candidate {
        // Process-table candidates never carry a sessionId (the registry didn't
        // know it); that is exactly the ambiguous case the gate must handle.
        UnmanagedClaudeFinder.Candidate(pid: pid, sessionId: nil, cwd: cwd)
    }

    // MARK: selectFromProcessTable — the destructive-ambiguity gate (defect #1)

    /// (a) Single unambiguous claude in the requested directory while its
    /// registry file is merely lazy/absent: still selected, so the common
    /// single-session take-over keeps working.
    @Test func singleCandidateInDirIsSelected() {
        let only = candidate(pid: 100, cwd: "/work/a")
        let picked = UnmanagedClaudeFinder.selectFromProcessTable(
            [only, candidate(pid: 200, cwd: "/work/b")],
            target: "/work/a", sessionId: "the-uuid")
        #expect(picked == only)
    }

    /// (b) Ambiguous: two claude processes share the requested session's
    /// directory, neither registry-confirmed as the one asked for. The old
    /// `.first` would SIGKILL whichever the scan happened to list first — which
    /// can be the *other* live session. The gate must refuse and return nil.
    @Test func ambiguousSameDirWithRequestedSessionReturnsNil() {
        let picked = UnmanagedClaudeFinder.selectFromProcessTable(
            [candidate(pid: 100, cwd: "/work/a"),
             candidate(pid: 200, cwd: "/work/a")],
            target: "/work/a", sessionId: "the-uuid")
        #expect(picked == nil)
    }

    /// The gate is keyed on an *explicit* session request. Reconcile-style calls
    /// with no sessionId (no identity to protect) keep the prior first-match
    /// behavior, so this change does not alter the no-identity path.
    @Test func ambiguousSameDirWithoutSessionKeepsFirst() {
        let first = candidate(pid: 100, cwd: "/work/a")
        let picked = UnmanagedClaudeFinder.selectFromProcessTable(
            [first, candidate(pid: 200, cwd: "/work/a")],
            target: "/work/a", sessionId: nil)
        #expect(picked == first)
    }

    /// No claude in the target directory → nil (import skips the kill step),
    /// regardless of candidates running elsewhere.
    @Test func noMatchInDirReturnsNil() {
        let picked = UnmanagedClaudeFinder.selectFromProcessTable(
            [candidate(pid: 100, cwd: "/work/b")],
            target: "/work/a", sessionId: "the-uuid")
        #expect(picked == nil)
    }

    // MARK: looksStronglyLikeClaude — strict global signal (defect #2)

    /// (c) A non-claude process invoked with a `--rc` argument must NOT be
    /// accepted by the whole-machine scan. `ProcessControl.looksLikeClaude`
    /// accepts bare `--rc` (safe only for descendant-constrained callers); the
    /// global scan must reject it, or such a process could be killed.
    @Test func bareRcAloneIsRejectedGlobally() {
        #expect(!UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/bin/zsh", argv: ["zsh", "--rc"]))
        #expect(!UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/usr/bin/make", argv: ["make", "--rc"]))
    }

    /// Real claude shapes still match strictly: native version-named binary,
    /// argv[0]/exec basename `claude`, and the node-wrapped `cli.js` install. So
    /// the common take-over targets are still found.
    @Test func realClaudeShapesStillMatchStrictly() {
        // Native, version-named (argv[0] is the version, not "claude"): matched
        // via the /claude/versions/ exec path.
        #expect(UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/Users/x/.local/share/claude/versions/2.1.169",
            argv: ["2.1.169", "--rc"]))
        #expect(UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/usr/local/bin/claude", argv: ["claude", "--rc"]))
        #expect(UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/opt/homebrew/bin/claude", argv: ["claude"]))
        #expect(UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/usr/local/bin/node",
            argv: ["node", "/Users/x/.npm/claude/cli.js", "--rc"]))
    }

    /// Unrelated processes are rejected (parity with the tolerant predicate's
    /// rejections, minus the bare-`--rc` acceptance).
    @Test func unrelatedProcessesRejectedStrictly() {
        #expect(!UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/bin/zsh", argv: ["zsh", "-l"]))
        #expect(!UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/usr/bin/vim", argv: ["vim", "file.txt"]))
        #expect(!UnmanagedClaudeFinder.looksStronglyLikeClaude(
            execPath: "/usr/bin/top", argv: []))
    }
}
