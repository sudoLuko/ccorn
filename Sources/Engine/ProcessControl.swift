import Foundation
import Darwin

/// Identifies and controls the `claude` process for a session.
///
/// Critical matching rule (verified on native claude 2.1.169, see
/// docs/RUNTIME_FINDINGS.md C3): the executable is *version-named*
/// (`~/.local/share/claude/versions/2.1.169`), so the kernel `p_comm` /
/// `proc_name()` / `ps -o ucomm` all return `2.1.169`, NOT `claude`. We must
/// therefore match by **argv** (argv[0] basename == `claude`, or args contain
/// `--rc`) or by **exec-path basename**, never by process name. We also only
/// ever search among the children of the shell CCorn itself spawned — never a
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
        // separated by a single NUL — skipping a run would swallow an empty
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

    /// Direct children of a pid (via `pgrep -P`).
    static func childPIDs(of pid: Int32) -> [Int32] {
        let r = CommandRunner.shared.run("/usr/bin/pgrep", ["-P", "\(pid)"])
        return r.stdout
            .split(whereSeparator: { $0 == "\n" })
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Find the `claude` process descending from a known shell pid (the tmux
    /// pane's shell). Searches direct children first, then recurses one level at
    /// a time, so an intermediate subshell doesn't hide it. Bounded by tree depth.
    static func findClaude(belowShell shellPID: Int32, maxDepth: Int = 4) -> Int32? {
        var frontier = [shellPID]
        var depth = 0
        var visited = Set<Int32>()
        while !frontier.isEmpty && depth <= maxDepth {
            var next: [Int32] = []
            for parent in frontier {
                for child in childPIDs(of: parent) {
                    if visited.contains(child) { continue }
                    visited.insert(child)
                    if let info = processInfo(pid: child),
                       looksLikeClaude(execPath: info.execPath, argv: info.argv) {
                        return child
                    }
                    next.append(child)
                }
            }
            frontier = next
            depth += 1
        }
        return nil
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
    // TODO(M3): PID-reuse race — between an isAlive() check and the kill() the
    // pid could in principle be recycled by an unrelated process (low-probability
    // TOCTOU). Revisit with a start-time identity check when polishing.
    static func terminate(pid: Int32) async {
        guard isAlive(pid) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<50 {            // 50 * 100ms = 5s
            if !isAlive(pid) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if isAlive(pid) { kill(pid, SIGKILL) }
    }
}
