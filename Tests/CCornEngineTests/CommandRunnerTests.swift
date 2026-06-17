import Foundation
import Testing

/// CommandRunner.run: the event-driven wait + concurrent-drain rewrite (lever B).
/// These pin the output-capture semantics every caller (state detection, tmux
/// ops, ProcessControl) depends on, plus the deadlock / timeout / concurrency
/// edges the rewrite must hold. Hermetic: only always-present system binaries,
/// no tmux/claude. Serialized because several cases spawn many processes and two
/// make timing assertions, which parallel execution would make flaky.
@Suite(.serialized) struct CommandRunnerTests {
    private let runner = CommandRunner.shared

    /// A temp file holding at least `bytes` of text; the caller `cat`s it to get
    /// large output through a single binary (no shell pipeline).
    private func tempTextFile(bytes: Int) -> String {
        let line = "the quick brown fox jumps over the lazy dog 0123456789\n"
        let blob = String(repeating: line, count: bytes / line.utf8.count + 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccorn-cmdrun-\(UUID().uuidString).txt")
        try! blob.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
    private func rm(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    // MARK: - Output-capture semantics (unchanged for every caller)

    @Test func instantCommandReturnsExitZeroAndEmptyOutput() {
        let r = runner.run("/usr/bin/true")
        #expect(r.exitCode == 0)
        #expect(r.ok)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.isEmpty)
    }

    @Test func smallStdoutCaptured() {
        let r = runner.run("/bin/echo", ["hello world"])
        #expect(r.exitCode == 0)
        #expect(r.trimmedOut == "hello world")
        #expect(r.stderr.isEmpty)
    }

    @Test func densePaneSizedBlobCapturedExactly() {
        // ~8KB, the size of a real Claude TUI capture frame (the state-detection
        // hot path): the parsing depends on the full pane text, so this must be
        // byte-exact.
        let path = tempTextFile(bytes: 8 * 1024)
        defer { rm(path) }
        let expected = try! String(contentsOfFile: path, encoding: .utf8)
        let r = runner.run("/bin/cat", [path])
        #expect(r.exitCode == 0)
        #expect(r.stdout == expected)
    }

    @Test func largeStdoutFullyCapturedNoDeadlock() {
        // ~2MB, far past the ~64KB pipe buffer: the concurrent drain must read it
        // all without the child blocking on write (risk #1) and without
        // truncation (risk #2). Byte-exact, in full.
        let path = tempTextFile(bytes: 2_000_000)
        defer { rm(path) }
        let expected = try! String(contentsOfFile: path, encoding: .utf8)
        let r = runner.run("/bin/cat", [path])
        #expect(r.exitCode == 0)
        #expect(r.stdout.utf8.count == expected.utf8.count)
        #expect(r.stdout == expected)
    }

    @Test func stderrOnlyWithNonZeroExitBothCorrect() {
        let r = runner.run("/bin/sh", ["-c", "echo oops 1>&2; exit 3"])
        #expect(r.exitCode == 3)
        #expect(!r.ok)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.contains("oops"))
    }

    @Test func largeStdoutAndStderrTogetherNoDeadlock() {
        // Both pipes past the buffer at once: if the two drains are not truly
        // concurrent, whichever the parent isn't reading fills and the child
        // blocks (the classic two-pipe deadlock, risk #1). Both come back whole.
        let path = tempTextFile(bytes: 1_500_000)
        defer { rm(path) }
        let expected = try! String(contentsOfFile: path, encoding: .utf8)
        let r = runner.run("/bin/sh", ["-c", "cat '\(path)'; cat '\(path)' 1>&2"])
        #expect(r.exitCode == 0)
        #expect(r.stdout == expected)
        #expect(r.stderr == expected)
    }

    @Test func nonexistentBinaryReturns127() {
        // Failure-path semantics are unchanged: a command that cannot be executed
        // returns 127 with empty stdout, and does not hang.
        let r = runner.run("/nonexistent/definitely-not-a-real-binary-xyz")
        #expect(r.exitCode == 127)
        #expect(r.stdout.isEmpty)
    }

    // MARK: - Edges introduced by the rewrite

    @Test func neverExitingProcessBoundedByTimeout() {
        // `sleep 100` never exits on its own; the bounded wait must SIGTERM/SIGKILL
        // it and return promptly rather than hang the caller (risk #4), reporting a
        // non-zero (signal) status.
        let start = Date()
        let r = runner.run("/bin/sleep", ["100"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0)      // bounded, not hung
        #expect(r.exitCode != 0)    // killed, not a clean exit
    }

    @Test func concurrentCallsDoNotCrossTalk() {
        // Every tmux/process call routes through one shared ioQueue; N concurrent
        // calls must each receive exactly their own output (risk #3, blast radius).
        let n = 24
        let lock = NSLock()
        var results = [Int: String](minimumCapacity: n)
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let out = runner.run("/bin/sh", ["-c", "echo token-\(i)"]).trimmedOut
            lock.lock(); results[i] = out; lock.unlock()
        }
        #expect(results.count == n)
        for i in 0..<n { #expect(results[i] == "token-\(i)") }
    }

    @Test func manyInstantCallsStayFast() {
        // Soft regression tripwire for the per-call overhead (the authoritative
        // proof is the standalone micro-timing). The event-driven wait finishes 80
        // trivial calls in well under a second; the old polling waitUntilExit()
        // (~60ms each) took >4.5s, so this 3s bound trips on a regression while
        // leaving the fast path ~7x of headroom against CI jitter.
        let start = Date()
        for _ in 0..<80 { _ = runner.run("/usr/bin/true") }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0)
    }
}
