import Foundation

/// A single transcript discovered under a project directory.
struct DiscoveredSession {
    /// The JSONL filename without extension — this *is* the session UUID.
    let uuid: String
    let transcriptPath: String
    let modified: Date
}

/// A project found under `~/.claude/projects/`. The directory name is an opaque,
/// lossy-encoded key (see docs/CCORN_SPEC.md "Encoded Path Format") — we never
/// decode it. The real path comes from the transcript `cwd`.
struct DiscoveredProject {
    /// The encoded directory name under `~/.claude/projects/` (opaque key).
    let encodedKey: String
    /// Full path to that directory.
    let projectDir: String
    /// Real absolute path, resolved from a transcript `cwd` (nil if no transcript
    /// has surfaced a `cwd` yet — transcripts are created lazily).
    let resolvedPath: String?
    /// Transcripts in the directory, newest first.
    let sessions: [DiscoveredSession]

    var mostRecentSession: DiscoveredSession? { sessions.first }
}
