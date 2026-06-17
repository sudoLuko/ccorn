import Foundation
import Darwin

/// Result of running an external command.
struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }

    var trimmedOut: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs external commands with a PATH that includes the user's shell PATH plus
/// the Homebrew prefixes. A GUI app launched from Finder/Xcode does NOT inherit
/// the shell PATH (it gets roughly `/usr/bin:/bin:/usr/sbin:/sbin`), so `tmux`,
/// `claude`, and `brew` in `/opt/homebrew/bin` are invisible unless we resolve
/// it. We source the login shell once, cache the result, and run every command
/// via `/usr/bin/env <binary> <args...>` with that PATH so binaries resolve by
/// name and arguments are passed as an array (no shell-quoting hazards).
///
/// See docs/CCORN_SPEC.md, "Process Execution Environment".
///
/// @unchecked Sendable: the only mutable state is `cachedPath`, and every
/// access to it is serialized through `queue`.
final class CommandRunner: @unchecked Sendable {
    static let shared = CommandRunner()

    private let queue = DispatchQueue(label: "studio.ccorn.commandrunner.path")
    private var cachedPath: String?

    /// Common bin locations we always want on PATH even if the login shell omits them.
    private static let extraBins = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// Shared concurrent queue for the per-call pipe drains: one queue for the
    /// whole app instead of allocating a fresh concurrent queue on every `run`.
    /// Each drain writes only to its own call-local buffer, so concurrent calls
    /// never cross-talk.
    private static let ioQueue = DispatchQueue(label: "studio.ccorn.commandrunner.io",
                                               attributes: .concurrent)

    /// Safety bound for the event-driven wait in `run`. Every real caller (tmux,
    /// ps, lsof, pgrep, osascript, `which`, the login-shell PATH probe) returns
    /// in well under a second; this only fires on a child that never exits, so
    /// the wait cannot block the caller forever the way the old `waitUntilExit()`
    /// could. Override per call (tests pass a short value to exercise the bound).
    static let defaultTimeout: TimeInterval = 30

    /// The resolved PATH used for all spawned commands. Computed once and cached.
    var resolvedPath: String {
        queue.sync {
            if let cachedPath { return cachedPath }
            let p = Self.resolvePath()
            cachedPath = p
            return p
        }
    }

    private static func resolvePath() -> String {
        let fallback = extraBins.joined(separator: ":")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "printf '%s' \"$PATH\""]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        var shellPath = ""
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            shellPath = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return fallback
        }
        var parts = shellPath.split(separator: ":").map(String.init)
        // Prepend any missing well-known locations so resolution never depends on
        // a perfectly configured login shell.
        for bin in extraBins.reversed() where !parts.contains(bin) {
            parts.insert(bin, at: 0)
        }
        let joined = parts.joined(separator: ":")
        return joined.isEmpty ? fallback : joined
    }

    /// Run `binary args...` with the resolved PATH. Arguments are passed as an
    /// array, never interpolated into a shell string.
    ///
    /// The wait is event-driven: a `terminationHandler` (the kernel signals the
    /// exit, no polling) and the two EOF-blocking pipe drains all `leave` one
    /// `DispatchGroup`, so the call returns the instant the process has exited
    /// AND both pipes are fully drained, with no fixed poll latency. The old
    /// `proc.waitUntilExit()` added ~60ms per call regardless of how fast the
    /// command ran (it polls); this brings a trivial command down to a few ms.
    /// The public result (stdout, stderr, exit status) is unchanged.
    @discardableResult
    func run(_ binary: String, _ args: [String] = [], cwd: String? = nil,
             timeout: TimeInterval = CommandRunner.defaultTimeout) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [binary] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolvedPath
        proc.environment = env
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // One group gates the return on three independent completions: the
        // process exit (terminationHandler) plus both pipe drains reaching EOF.
        // The drains run on a background queue concurrently with the process, so
        // a child writing more than the ~64KB pipe buffer never blocks against
        // the wait, and we never return before its output has been read in full.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        // terminationHandler must be armed before run(): a process that exits
        // immediately could otherwise fire before the handler is registered and
        // the group would never balance. It is event-driven, so no poll latency.
        group.enter()
        proc.terminationHandler = { _ in group.leave() }

        do {
            try proc.run()
        } catch {
            // The process never started, so the handler will not fire and the
            // pipes will never EOF: balance the termination enter, leave the
            // drains undispatched, and return the launch failure (still 127).
            group.leave()
            return CommandResult(stdout: "", stderr: "failed to launch \(binary): \(error)", exitCode: 127)
        }

        group.enter()
        Self.ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        Self.ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Bound the wait so a child that never exits (and so never EOFs its
        // pipes) cannot hang the caller forever, as `waitUntilExit()` could.
        // SIGTERM first, then SIGKILL if it is ignored; either closes the write
        // ends, which EOFs the drains and fires the handler, so the group always
        // balances afterwards and we still return whatever output was captured.
        if group.wait(timeout: .now() + timeout) == .timedOut {
            kill(proc.processIdentifier, SIGTERM)
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                group.wait()
            }
        }

        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus
        )
    }

    /// Run a command through a login shell. Used only where shell semantics or a
    /// freshly-sourced PATH matter; prefer `run(_:_:)` for plain binaries.
    @discardableResult
    func loginShell(_ command: String, cwd: String? = nil) -> CommandResult {
        run("/bin/zsh", ["-lc", command], cwd: cwd)
    }

    /// Resolve a binary to an absolute path on the resolved PATH (like `which`).
    func which(_ binary: String) -> String? {
        let r = run("/usr/bin/which", [binary])
        let path = r.trimmedOut
        return (r.ok && !path.isEmpty) ? path : nil
    }
}
