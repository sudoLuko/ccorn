import Foundation

/// JSON persistence under `~/Library/Application Support/CCorn/`.
/// Persists session records (identity = session UUID) and user settings.
/// Live state (PID, current state, hashes, window id) is never persisted — it is
/// re-derived on launch (see docs/CCORN_SPEC.md "Session Record" / "Launch Reconciliation").
final class SessionStore {
    static let shared = SessionStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "studio.ccorn.store")

    /// `~/Library/Application Support/CCorn`
    var supportDir: URL {
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
        guard let data = try? Data(contentsOf: sessionsURL) else { return [] }
        return (try? JSONDecoder().decode([SessionRecord].self, from: data)) ?? []
    }

    private func saveRecordsLocked(_ records: [SessionRecord]) {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
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
