import Foundation

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
    @discardableResult
    func run(_ binary: String, _ args: [String] = [], cwd: String? = nil) -> CommandResult {
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

        // Drain pipes on background queues so a command producing more output
        // than the pipe buffer can hold never deadlocks against waitUntilExit().
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "studio.ccorn.commandrunner.io", attributes: .concurrent)

        do {
            try proc.run()
        } catch {
            return CommandResult(stdout: "", stderr: "failed to launch \(binary): \(error)", exitCode: 127)
        }

        group.enter()
        ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        proc.waitUntilExit()
        group.wait()

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
