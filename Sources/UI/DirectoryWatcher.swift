import Foundation
import CoreServices

/// FSEvents wrapper that watches one directory tree and fires a debounced
/// callback on the main queue. Used on `~/.claude/projects/` so discovery
/// re-runs when transcripts appear or change — never by polling
/// (CLAUDE.md: "Use FSEvents, not polling, for directory watching").
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let debounce: TimeInterval
    private let handler: () -> Void
    private var pending: DispatchWorkItem?

    init?(path: String, debounce: TimeInterval = 1.0, handler: @escaping () -> Void) {
        self.debounce = debounce
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.schedule()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // FSEvents-side latency: coalesce bursts of transcript writes
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// Called on the main queue (the stream's dispatch queue).
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handler() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
