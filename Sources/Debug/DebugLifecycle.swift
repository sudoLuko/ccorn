#if DEBUG
import Darwin
import Foundation
import os

/// Debug-build-only lifecycle instrumentation for resource shakedowns: deinit
/// markers on every long-lived object, named gauges (instance counts, active
/// loops, store writes), and resident-memory sampling. Events go to os_log on
/// the dedicated `studio.ccorn.debug` subsystem AND are appended to
/// `/tmp/ccorn-debug-lifecycle.log` so a CLI harness can tail them without
/// `log stream` privileges. Same family as DebugCommandChannel; compiled out
/// of release builds entirely.
enum DebugLife {
    static let logger = Logger(subsystem: "studio.ccorn.debug", category: "lifecycle")
    static let logPath = "/tmp/ccorn-debug-lifecycle.log"

    private static let lock = NSLock()
    private static var counters: [String: Int] = [:]
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        return FileHandle(forWritingAtPath: logPath)
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Timestamped event line (init/deinit markers, per-tick summaries).
    static func event(_ message: String) {
        logger.info("\(message, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stampFormatter.string(from: Date())) \(message)\n"
        handle?.write(Data(line.utf8))
    }

    /// Adjust a named gauge (instance count, active loop count) and log the edge.
    static func adjust(_ key: String, by delta: Int, note: String = "") {
        lock.lock()
        let value = (counters[key] ?? 0) + delta
        counters[key] = value
        lock.unlock()
        let suffix = note.isEmpty ? "" : " (\(note))"
        event("\(delta > 0 ? "+" : "")\(delta) \(key)=\(value)\(suffix)")
    }

    /// Set a named gauge to an absolute value without logging (high-frequency
    /// gauges like the persisted-record count; the tick line reports them).
    static func set(_ key: String, to value: Int) {
        lock.lock()
        counters[key] = value
        lock.unlock()
    }

    static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Resident memory of this process: (phys_footprint, resident_size) in
    /// bytes — footprint is what Activity Monitor's "Memory" approximates.
    /// (0, 0) if the task_info call fails.
    static func memoryBytes() -> (footprint: UInt64, resident: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(info.resident_size))
    }
}
#endif
