import Foundation

/// Precedence resolution for the discovered ("unmanaged") surface, factored out
/// of `AppModel.rebuildRows` so it is pure and unit-testable; `rebuildRows`
/// itself lives in the AppKit UI layer, outside the hostless logic-test bundle.
///
/// The discovered surface is **session-granular**: every running external Claude
/// session is its own row, keyed by its session UUID. Two sessions sharing one
/// directory no longer collapse into a single row that flips between them as
/// each writes its transcript (the directory-keyed, most-recent-wins bug). A
/// directory whose sessions are all *dormant* (none managed, none live, none
/// recorded) collapses instead to a single summary row, so a project's
/// historical transcripts don't flood the list.
///
/// Liveness comes from the per-process registry (`~/.claude/sessions/<pid>.json`,
/// via `UnmanagedClaudeFinder.registryCandidates`), the same file-based signal
/// the import flow already trusts, never a global `pgrep`. Candidates are
/// expected to be pre-scoped to the watch directories by the caller.
enum DiscoveryMerge {
    /// One live external session that renders as its own discovered row.
    struct LiveSession: Equatable, Sendable {
        let uuid: String
        /// Canonical working directory (from the registry).
        let path: String
    }

    /// The discovered rows to build, after precedence is applied.
    struct Resolution: Equatable {
        /// Live external sessions, one row each (UUID-keyed), order preserved
        /// from `liveCandidates` and deduped by UUID.
        let live: [LiveSession]
        /// UUIDs of `live`; the record loop and dormant summaries defer to
        /// these so a running session never renders as Stopped or hides inside
        /// a directory summary.
        let liveUUIDs: Set<String>
        /// Encoded keys of directories that collapse to a single dormant summary
        /// row, in `projects` order.
        let dormantDirKeys: [String]
    }

    /// Resolve which discovered rows to build from value inputs only.
    ///
    /// - Parameters:
    ///   - projects: discovered projects (one per directory), already watch-scoped.
    ///   - liveCandidates: live external claude processes, already watch-scoped.
    ///   - managedUUIDs: sessions CCorn manages in tmux; they outrank discovery.
    ///   - managedPaths: canonical paths of managed sessions; a managed window in
    ///     a directory suppresses that directory's dormant summary (the managed
    ///     row already represents it), while still allowing *other* live sessions
    ///     in the same directory to surface as their own rows.
    ///   - recordUUIDs: persisted-record UUIDs; a recorded session already
    ///     represents its directory, so that directory gets no dormant summary.
    static func resolve(projects: [DiscoveredProject],
                        liveCandidates: [UnmanagedClaudeFinder.Candidate],
                        managedUUIDs: Set<String>,
                        managedPaths: Set<String>,
                        recordUUIDs: Set<String>) -> Resolution {
        // Live external sessions: registry hits CCorn doesn't already manage.
        // Stale files for dead pids are filtered upstream (registryCandidates);
        // a duplicate UUID across files is deduped here.
        var live: [LiveSession] = []
        var liveUUIDs = Set<String>()
        for candidate in liveCandidates {
            guard let uuid = candidate.sessionId, !uuid.isEmpty,
                  !managedUUIDs.contains(uuid),
                  !liveUUIDs.contains(uuid) else { continue }
            liveUUIDs.insert(uuid)
            live.append(LiveSession(uuid: uuid, path: candidate.cwd))
        }

        // Dormant directories: a project whose sessions are ALL dormant (none
        // managed, none live, none recorded) collapses to one summary row. A
        // directory with any individually-represented session is skipped here
        // (those sessions are their own rows).
        var dormantDirKeys: [String] = []
        for project in projects {
            guard let path = project.resolvedPath, !managedPaths.contains(path) else { continue }
            let uuids = Set(project.sessions.map(\.uuid))
            if uuids.isDisjoint(with: managedUUIDs),
               uuids.isDisjoint(with: liveUUIDs),
               uuids.isDisjoint(with: recordUUIDs) {
                dormantDirKeys.append(project.encodedKey)
            }
        }

        return Resolution(live: live, liveUUIDs: liveUUIDs, dormantDirKeys: dormantDirKeys)
    }
}
