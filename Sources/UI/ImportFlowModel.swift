import AppKit
import Foundation

/// Drives the first-run import sheet (docs/CCORN_SPEC.md 5.4, flow 6.2):
/// discovery list → sequential import (one at a time, per the spec's race
/// rationale) → complete. Active sessions pause the run with the Wait for
/// Idle / Import Anyway alert; "wait" polls every 10s and auto-continues.
@MainActor
final class ImportFlowModel: ObservableObject, Identifiable {
    enum Stage: Equatable { case discovery, importing, complete }
    enum Phase: Equatable { case pending, waitingForIdle, importing, done, failed }

    struct Item: Identifiable, Equatable, Sendable {
        let id: String   // session uuid
        let title: String
        let path: String
        var selected = true
        /// Whether a live external `claude` process exists for this session at
        /// probe time, the one thing knowable about an unmanaged session without
        /// a pane (see `ImportRowLiveness`). Drives the row's "Active" tag; it is
        /// never an activity state (working vs waiting is unknowable here).
        var liveness: ImportRowLiveness
        var phase: Phase = .pending
    }

    @Published var items: [Item]
    @Published private(set) var stage: Stage = .discovery
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)

    private weak var model: AppModel?

    init(items: [Item], model: AppModel) {
        self.items = items
        self.model = model
    }

    var selectedCount: Int { items.filter(\.selected).count }
    var importedCount: Int { items.filter { $0.phase == .done }.count }

    /// Build items off-main: each candidate is probed only for a *live* external
    /// claude process (registry/cwd match). That liveness is the one thing
    /// knowable about an unmanaged session without a pane; working vs waiting vs
    /// idle is not, so the row claims liveness only (the "Active" tag), never an
    /// activity state (see `ImportRowLiveness`). A session with no live process
    /// imports trivially (no kill step) and shows as dormant.
    static func probe(candidates: [SessionRow]) async -> [Item] {
        struct Probe: Sendable {
            let uuid: String, title: String, path: String
        }
        let snapshot = candidates.map {
            Probe(uuid: $0.uuid, title: $0.title, path: $0.path)
        }
        return await Task.detached {
            snapshot.map { probe in
                let live = UnmanagedClaudeFinder.find(inDirectory: probe.path,
                                                      sessionId: probe.uuid) != nil
                return Item(id: probe.uuid, title: probe.title, path: probe.path,
                            liveness: ImportRowLiveness(isLive: live))
            }
        }.value
    }

    func startImport() {
        guard stage == .discovery, selectedCount > 0 else { return }
        stage = .importing
        Task { await runImport() }
    }

    func skip() {
        guard stage == .discovery else { return }
        model?.importFlowFinished()
    }

    func close() {
        guard stage == .complete else { return }
        model?.importFlowFinished()
    }

    private func runImport() async {
        guard let model else { return }
        let selected = items.indices.filter { items[$0].selected }
        progress = (0, selected.count)

        for (n, idx) in selected.enumerated() {
            progress = (n, selected.count)

            // State 3: active session warning. "Wait for Idle" polls every
            // 10s and auto-continues once the session goes quiet.
            if await isActivelyWorking(items[idx]) {
                let wait = Alerts.choice(
                    title: "Claude is mid-task in \(items[idx].title)",
                    message: "Importing now may interrupt active work.",
                    primary: "Wait for Idle",
                    secondary: "Import Anyway")
                if wait {
                    items[idx].phase = .waitingForIdle
                    while await isActivelyWorking(items[idx]) {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                }
            }

            items[idx].phase = .importing
            let result = await model.engine.importSession(uuid: items[idx].id,
                                                          directory: items[idx].path)
            if case .started = result {
                items[idx].phase = .done
            } else {
                items[idx].phase = .failed
            }
        }
        progress = (selected.count, selected.count)
        stage = .complete
        model.importDidMutateSessions()
    }

    /// Fresh activity check: a live external process AND transcript writes in
    /// the last two minutes. Quiet transcript or gone process = idle. Shared
    /// with the single-row adopt path via the engine (flow 6.10).
    private func isActivelyWorking(_ item: Item) async -> Bool {
        guard let engine = model?.engine else { return false }
        return await engine.isExternalSessionWorking(uuid: item.id, directory: item.path)
    }
}
