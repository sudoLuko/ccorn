import Foundation

/// A single transcript discovered under a project directory.
struct DiscoveredSession: Sendable {
    /// The JSONL filename without extension; this *is* the session UUID.
    let uuid: String
    let transcriptPath: String
    let modified: Date
}

/// Per-transcript metadata read in one pass: the session title (the LAST
/// `ai-title` record, what `claude --resume` and claude.ai show) and the
/// resolved `cwd`. Either is nil when the transcript doesn't carry it.
struct TranscriptMeta: Sendable, Equatable {
    var title: String?
    var cwd: String?
}

/// A project found under `~/.claude/projects/`. The directory name is an opaque,
/// lossy-encoded key (see docs/CCORN_SPEC.md "Encoded Path Format"); we never
/// decode it. The real path comes from the transcript `cwd`.
struct DiscoveredProject {
    /// The encoded directory name under `~/.claude/projects/` (opaque key).
    let encodedKey: String
    /// Full path to that directory.
    let projectDir: String
    /// Real absolute path, resolved from a transcript `cwd` (nil if no transcript
    /// has surfaced a `cwd` yet; transcripts are created lazily).
    let resolvedPath: String?
    /// Transcripts in the directory, newest first.
    let sessions: [DiscoveredSession]

    var mostRecentSession: DiscoveredSession? { sessions.first }
}
