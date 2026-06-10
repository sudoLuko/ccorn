import Foundation

/// JSON persistence under `~/Library/Application Support/CCorn/`.
/// Persists session records (identity = session UUID) and user settings.
/// Live state (PID, current state, hashes, window id) is never persisted — it is
/// re-derived on launch (see docs/CCORN_SPEC.md "Session Record" / "Launch Reconciliation").
///
/// @unchecked Sendable: all reads and writes are serialized through `queue`.
///
/// Retention: records whose transcript no longer exists (and which have no
/// live window) are pruned at launch — `claude --resume` would have nothing to
/// resume, so the record is dead weight (see AppModel.pruneOrphanedRecords).
final class SessionStore: @unchecked Sendable {
    static let shared = SessionStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "studio.ccorn.store")
    /// Test override; nil in normal app use.
    private let supportDirOverride: URL?

    init(supportDir: URL? = nil) {
        #if DEBUG
        // Shakedown isolation: a debug run can point the whole store at a
        // scratch directory so churn never touches the real records/settings.
        if supportDir == nil,
           let override = ProcessInfo.processInfo.environment["CCORN_DEBUG_SUPPORT_DIR"],
           !override.isEmpty {
            self.supportDirOverride = URL(fileURLWithPath: override, isDirectory: true)
            DebugLife.event("init SessionStore (override \(override))")
            return
        }
        DebugLife.event("init SessionStore")
        #endif
        self.supportDirOverride = supportDir
    }

    #if DEBUG
    deinit { DebugLife.event("deinit SessionStore") }
    #endif

    /// `~/Library/Application Support/CCorn` (or the test override).
    var supportDir: URL {
        if let supportDirOverride { return supportDirOverride }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CCorn", isDirectory: true)
    }

    private var sessionsURL: URL { supportDir.appendingPathComponent("sessions.json") }
    private var settingsURL: URL { supportDir.appendingPathComponent("settings.json") }

    private func ensureDir() {
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    // MARK: - Session records

    /// Non-locking core reads/writes; callers must already hold `queue`.
    private func loadRecordsLocked() -> [SessionRecord] {
        let records = (try? Data(contentsOf: sessionsURL))
            .flatMap { try? JSONDecoder().decode([SessionRecord].self, from: $0) } ?? []
        #if DEBUG
        DebugLife.set("store-records", to: records.count)
        #endif
        return records
    }

    private func saveRecordsLocked(_ records: [SessionRecord]) {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
        #if DEBUG
        DebugLife.set("store-records", to: records.count)
        DebugLife.adjust("store-writes", by: 1)
        #endif
    }

    func loadRecords() -> [SessionRecord] {
        queue.sync { loadRecordsLocked() }
    }

    func saveRecords(_ records: [SessionRecord]) {
        queue.sync { saveRecordsLocked(records) }
    }

    /// Insert or update a record by UUID identity. The whole read-modify-write
    /// runs inside ONE critical section so concurrent upserts can't lose an update
    /// in the gap between separate `loadRecords`/`saveRecords` lock acquisitions.
    func upsert(_ record: SessionRecord) {
        queue.sync {
            var records = loadRecordsLocked()
            if let idx = records.firstIndex(where: { $0.uuid == record.uuid }) {
                records[idx] = record
            } else {
                records.append(record)
            }
            saveRecordsLocked(records)
        }
    }

    /// Read-modify-write one record (created if absent) in a single critical
    /// section. nil parameters leave the existing field untouched, so a caller
    /// that only knows part of a session's identity can't clobber the rest.
    func mergeRecord(uuid: String,
                     path: String? = nil,
                     title: String? = nil,
                     archived: Bool? = nil) {
        guard !uuid.isEmpty else { return }
        queue.sync {
            var records = loadRecordsLocked()
            var record = records.first { $0.uuid == uuid }
                ?? SessionRecord(uuid: uuid, path: "", title: "")
            if let path { record.path = path }
            if let title { record.title = title }
            if let archived { record.archived = archived }
            if let idx = records.firstIndex(where: { $0.uuid == uuid }) {
                records[idx] = record
            } else {
                records.append(record)
            }
            saveRecordsLocked(records)
        }
    }

    /// Drop records for sessions that can no longer be resumed. `keep` is the
    /// set of UUIDs that must survive regardless (live windows).
    func pruneRecords(withoutTranscriptIn transcripts: Set<String>, keeping keep: Set<String>) {
        queue.sync {
            let records = loadRecordsLocked()
            let kept = records.filter { transcripts.contains($0.uuid) || keep.contains($0.uuid) }
            if kept.count != records.count {
                saveRecordsLocked(kept)
            }
        }
    }

    /// Default retention: an archived session untouched for 90 days is gone,
    /// and the store never holds more than 500 records.
    static let archivedMaxAge: TimeInterval = 90 * 24 * 3600
    static let maxRecords = 500

    /// Retention policy (launch, after the transcript-existence prune): drop
    /// archived records whose transcript has been inactive past
    /// `archivedMaxAge`, then cap the total at `maxRecords` — evicting
    /// archived records before active ones, oldest transcript activity first —
    /// so the store cannot grow unbounded. `keep` (live windows) always
    /// survives; age comes from the transcript mtime, the same last-activity
    /// signal the rows display, so no schema change is needed.
    func applyRetention(transcriptMtimes: [String: Date],
                        keeping keep: Set<String>,
                        archivedMaxAge: TimeInterval = SessionStore.archivedMaxAge,
                        maxRecords: Int = SessionStore.maxRecords,
                        now: Date = Date()) {
        queue.sync {
            var records = loadRecordsLocked()
            let before = records.count

            records.removeAll { record in
                guard record.archived, !keep.contains(record.uuid) else { return false }
                let mtime = transcriptMtimes[record.uuid] ?? .distantPast
                return now.timeIntervalSince(mtime) > archivedMaxAge
            }

            if records.count > maxRecords {
                let evictable = records
                    .filter { !keep.contains($0.uuid) }
                    .sorted { a, b in
                        if a.archived != b.archived { return a.archived }
                        let am = transcriptMtimes[a.uuid] ?? .distantPast
                        let bm = transcriptMtimes[b.uuid] ?? .distantPast
                        return am < bm
                    }
                var doomed = Set<String>()
                for record in evictable {
                    guard records.count - doomed.count > maxRecords else { break }
                    doomed.insert(record.uuid)
                }
                records.removeAll { doomed.contains($0.uuid) }
            }

            if records.count != before {
                saveRecordsLocked(records)
            }
        }
    }

    // MARK: - Settings

    func loadSettings() -> CCornSettings {
        queue.sync {
            guard let data = try? Data(contentsOf: settingsURL),
                  let settings = try? JSONDecoder().decode(CCornSettings.self, from: data) else {
                return .default
            }
            return settings
        }
    }

    func saveSettings(_ settings: CCornSettings) {
        queue.sync {
            ensureDir()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(settings) {
                try? data.write(to: settingsURL, options: .atomic)
            }
        }
    }
}
