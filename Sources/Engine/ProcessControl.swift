import Foundation
import Darwin

/// Identifies and controls the `claude` process for a session.
///
/// Critical matching rule (verified on native claude 2.1.169, see
/// runtime findings C3): the executable is *version-named*
/// (`~/.local/share/claude/versions/2.1.169`), so the kernel `p_comm` /
/// `proc_name()` / `ps -o ucomm` all return `2.1.169`, NOT `claude`. We must
/// therefore match by **argv** (argv[0] basename == `claude`, or args contain
/// `--rc`) or by **exec-path basename**, never by process name. We also only
/// ever search among the children of the shell CCorn itself spawned; never a
/// global `pgrep claude` (the probe machine had ~15 unrelated claude processes).
enum ProcessControl {

    /// argv + exec path for a pid, read from the kernel via KERN_PROCARGS2.
    /// Returns nil if the process is gone or args can't be read.
    static func processInfo(pid: Int32) -> (execPath: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) != 0 || size == 0 {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
        }
        if rc != 0 || size < MemoryLayout<Int32>.size { return nil }

        // Layout: [argc: Int32][exec_path \0 (+padding \0s)][argv[0] \0]...[argv[argc-1] \0]...
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size

        // After the exec_path string the kernel inserts a run of NUL padding for
        // alignment, so skip the whole run there. Within argv, elements are
        // separated by a single NUL; skipping a run would swallow an empty
        // argument (e.g. `claude --rc ""`) and shift later reads into the env
        // block, so advance past exactly one terminator.
        func readCString(skipPadding: Bool) -> String {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            let s = String(decoding: buffer[start..<i], as: UTF8.self)
            if skipPadding {
                while i < size && buffer[i] == 0 { i += 1 }
            } else if i < size && buffer[i] == 0 {
                i += 1
            }
            return s
        }

        let execPath = readCString(skipPadding: true)
        var argv: [String] = []
        var n: Int32 = 0
        while n < argc && i < size {
            argv.append(readCString(skipPadding: false))
            n += 1
        }
        return (execPath, argv)
    }

    /// True if (execPath, argv) looks like a Claude Code process. Tolerant of both
    /// the native version-named binary and a node-wrapped `cli.js` install.
    static func looksLikeClaude(execPath: String, argv: [String]) -> Bool {
        let arg0Base = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let execBase = (execPath as NSString).lastPathComponent
        if arg0Base == "claude" { return true }
        if execBase == "claude" { return true }
        if argv.contains("--rc") { return true }
        if execPath.contains("/claude/versions/") { return true }     // native, version-named
        if argv.contains(where: { $0.hasSuffix("cli.js") }) { return true } // node-wrapped
        return false
    }

    /// A child-process scan either ANSWERS (the tool ran and reported its
    /// result, even if that result is "no children") or FAILS TO ANSWER (the
    /// tool could not be run or errored). Detection must treat `.unknown` as "we
    /// could not tell", never as "no process": reading a transient `pgrep`
    /// failure as a determined absence is what would false-flag a live session
    /// crashed during launch reconcile.
    enum ChildScan: Sendable, Equatable {
        /// `pgrep` answered; the list may be empty (a determined "no children").
        case children([Int32])
        /// `pgrep` could not run / errored; child liveness is undetermined.
        case unknown
    }

    /// Result of searching a shell's descendants for the `claude` process:
    /// `.found` the pid, `.absent` (the tree was fully walked and there is
    /// genuinely no claude), or `.unknown` (a `pgrep` call along the way failed
    /// to answer, so absence cannot be concluded). The `.absent`/`.unknown`
    /// split is what lets `StateDetector` flip to Dead only on a real "the
    /// process is gone", never on a tool that didn't answer.
    enum ClaudeScan: Sendable, Equatable {
        case found(Int32)
        case absent
        case unknown
    }

    /// Map a `pgrep -P` result to a child scan, distinguishing a determined
    /// answer from a tool failure. Exit 0 = matches; exit 1 = ran but found none
    /// (a real, determined absence); ANY other code (127 launch failure from
    /// `CommandRunner`, or a signal status when its timeout kills a hung pgrep)
    /// means it could not answer -> `.unknown`. Pure, so the exit-code contract
    /// is unit-tested without spawning pgrep.
    static func childScan(from r: CommandResult) -> ChildScan {
        switch r.exitCode {
        case 0:  return .children(parsePIDs(r.stdout))
        case 1:  return .children([])            // pgrep ran, no matches: determined
        default: return .unknown                 // 127 / signal: could not answer
        }
    }

    private static func parsePIDs(_ s: String) -> [Int32] {
        s.split(whereSeparator: { $0 == "\n" })
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Direct children of a pid (via `pgrep -P`), as a determined list or
    /// `.unknown` when the tool could not answer (see `childScan`).
    static func childPIDs(of pid: Int32) -> ChildScan {
        childScan(from: CommandRunner.shared.run("/usr/bin/pgrep", ["-P", "\(pid)"]))
    }

    /// Find the `claude` process descending from a known shell pid (the tmux
    /// pane's shell). Searches direct children first, then recurses one level at
    /// a time, so an intermediate subshell doesn't hide it. Bounded by tree depth.
    ///
    /// Three-way so a transient tool failure is never read as a dead session: if
    /// any `pgrep` call in the walk returns `.unknown`, an unfound claude is
    /// reported `.unknown` (we could not enumerate part of the tree), NOT
    /// `.absent`. A child that vanished between `pgrep` and the `processInfo`
    /// read is a genuine exit, so it is simply skipped (still a determined
    /// absence if nothing else matches) rather than poisoning the scan to unknown.
    static func findClaude(belowShell shellPID: Int32, maxDepth: Int = 4) -> ClaudeScan {
        var frontier = [shellPID]
        var depth = 0
        var visited = Set<Int32>()
        var sawUnknown = false
        while !frontier.isEmpty && depth <= maxDepth {
            var next: [Int32] = []
            for parent in frontier {
                switch childPIDs(of: parent) {
                case .unknown:
                    sawUnknown = true            // could not enumerate this subtree
                case .children(let kids):
                    for child in kids {
                        if visited.contains(child) { continue }
                        visited.insert(child)
                        if let info = processInfo(pid: child),
                           looksLikeClaude(execPath: info.execPath, argv: info.argv) {
                            return .found(child)
                        }
                        next.append(child)
                    }
                }
            }
            frontier = next
            depth += 1
        }
        return sawUnknown ? .unknown : .absent
    }

    /// Liveness via `kill(pid, 0)`. EPERM means it exists but we lack permission
    /// (still alive); ESRCH means gone.
    static func isAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The process's start time via sysctl(KERN_PROC). Used for the spawn grace
    /// window: a tmux pane shell younger than the grace period with no `claude`
    /// child yet is "still spawning", not Dead. nil if the process is gone.
    static func startTime(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            sysctl(&mib, UInt32(mib.count), ptr, &size, nil, 0)
        }
        // A gone pid "succeeds" with zero bytes returned, so check size and echo
        // the pid back from the struct before trusting it.
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            return nil
        }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// Canonical termination: SIGTERM, wait up to 5s, SIGKILL if still alive.
    /// Caller is responsible for killing the tmux window first (see SessionEngine).
    /// Suspends between liveness checks, so it is safe to await from anywhere.
    ///
    /// PID-reuse guard (closes the former M3 TODO TOCTOU): the caller kills the
    /// tmux window first (SIGHUP), so `claude` can exit during the up-to-5s wait,
    /// and the kernel can recycle that pid onto an unrelated process. We capture
    /// the original process's start time on entry and re-check it before EACH
    /// signal: if `startTime(pid:)` is now nil (process gone) or differs from the
    /// captured value (pid recycled to a *different* process), we send nothing —
    /// the process we meant to kill is already gone. `kill(pid, 0)` liveness alone
    /// cannot tell the two apart; the (pid, start time) pair is a stable identity.
    /// The same-process happy path (SIGTERM → wait → SIGKILL) is unchanged.
    ///
    /// Residual race (out of scope, would need a call-site change): the pid is
    /// learned at the call site (SessionEngine.terminate) before this runs, so a
    /// recycle in that gap is not caught here. Handing the call-site start time
    /// into terminate() would close it; left as follow-up.
    static func terminate(pid: Int32) async {
        guard let startedAt = startTime(pid: pid) else { return }

        // True only while pid still maps to the same process we captured on entry.
        func isSameProcess() -> Bool { startTime(pid: pid) == startedAt }

        guard isSameProcess() else { return }
        kill(pid, SIGTERM)
        for _ in 0..<50 {            // 50 * 100ms = 5s
            if !isSameProcess() { return }   // exited (gone) or recycled: done
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if isSameProcess() { kill(pid, SIGKILL) }
    }
}
