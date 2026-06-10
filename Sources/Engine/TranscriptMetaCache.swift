import Foundation

/// Caches per-transcript metadata (title + cwd) keyed by (path, mtime) so a
/// discovery pass re-reads a transcript only when it actually changed. Title
/// extraction is a head + tail read (see `SessionDiscovery.lastAITitle`), so an
/// unchanged transcript costs nothing and an active one is re-read at most once
/// per FSEvents-debounced discovery pass — never on the 3s poll, which only
/// consumes the cached results.
///
/// @unchecked Sendable: all access to `entries` is serialized through `queue`.
/// The file read itself happens outside the lock, so two concurrent passes may
/// redundantly read the same transcript — harmless, last write wins.
final class TranscriptMetaCache: @unchecked Sendable {
    private struct Entry {
        let mtime: Date
        let meta: TranscriptMeta
    }

    private let queue = DispatchQueue(label: "studio.ccorn.transcriptmeta")
    private var entries: [String: Entry] = [:]

    func meta(for transcript: DiscoveredSession) -> TranscriptMeta {
        let cached = queue.sync { entries[transcript.transcriptPath] }
        if let cached, cached.mtime == transcript.modified { return cached.meta }
        let meta = SessionDiscovery.meta(inTranscript: transcript.transcriptPath)
        queue.sync {
            entries[transcript.transcriptPath] = Entry(mtime: transcript.modified, meta: meta)
        }
        return meta
    }
}
