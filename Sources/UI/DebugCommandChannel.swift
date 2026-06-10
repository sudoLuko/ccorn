#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Debug-build-only command channel for end-to-end verification: when
/// CCORN_DEBUG_UI contains "cmd", the app polls /tmp/ccorn-debug-cmd for
/// one-line commands, executes the REAL model/engine flows (minus the modal
/// confirmations, which cannot be scripted), and writes results to
/// /tmp/ccorn-debug-out. Same hook family as the CCORN_DEBUG_UI screenshot
/// helpers; compiled out of release builds entirely.
///
/// Commands (arguments are space-separated; paths must not contain spaces):
///   dump                      -> JSON of all rows (incl. archived)
///   new <dir>                 -> startNewSession
///   kill <dir>                -> killSession for the managed row at <dir>
///   rename <dir> <name...>    -> renameSession (name may contain spaces)
///   restart <dir>             -> restartSession for the stopped/dead row
///   import <dir>              -> importSession for the unmanaged row
///   archive <dir> | unarchive <dir>
///   onboard <dir> [dir...]    -> completeOnboarding
///   onboarddir <dir>          -> add a directory to the onboarding card (gate check)
///   stale <seconds>           -> set stale threshold
///   importsheet               -> presentImportSheetIfNeeded
///   counters                  -> JSON of DebugLife gauges + memory (shakedown)
///   pids                      -> windowId:pid map of live sessions (shakedown)
///   watch <dir> | unwatch <dir> -> add/remove a watch directory (applySettings)
///   seed [empty|working]      -> stop the poll, stage curated rows (DebugStage)
///   appearance <light|dark|system> -> override NSApp.appearance
///   show <main|popover>       -> open a surface for screenshots
///   shoot <target> <path>     -> PNG of a window (main/popover/settings/onboarding/sheet/key)
///   authalert                 -> present the section-8 auth alert (sheet on main)
///   dismisssheet              -> end any attached sheet
@MainActor
final class DebugCommandChannel {
    private let model: AppModel
    private var task: Task<Void, Never>?
    private let cmdPath = "/tmp/ccorn-debug-cmd"
    private let outPath = "/tmp/ccorn-debug-out"

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard task == nil else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.poll()
            }
        }
    }

    private func poll() async {
        guard let data = FileManager.default.contents(atPath: cmdPath),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)
        var output: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let result = await execute(String(line))
            output.append(result)
        }
        try? output.joined(separator: "\n")
            .write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private func execute(_ line: String) async -> String {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { return "err empty" }

        func row(at dir: String, where match: (SessionRow) -> Bool = { _ in true }) -> SessionRow? {
            let canonical = SessionDiscovery.canonicalize(dir)
            return (model.rows + model.archivedRows).first { $0.path == canonical && match($0) }
        }

        switch command {
        case "dump":
            return Self.dumpJSON(rows: model.rows, archived: model.archivedRows)

        case "new" where parts.count >= 2:
            let result = await model.engine.startNewSession(directory: parts[1])
            await model.debugRefresh()
            return "new \(result)"

        case "kill" where parts.count >= 2:
            guard let target = row(at: parts[1], where: { $0.windowId != nil }) else { return "err no-row" }
            let uuid = await model.engine.killSession(windowId: target.windowId!)
            await model.debugRefresh()
            return "killed \(uuid)"

        case "rename" where parts.count >= 3:
            guard let target = row(at: parts[1]) else { return "err no-row" }
            let name = parts[2...].joined(separator: " ")
            let result = await model.engine.renameSession(windowId: target.windowId,
                                                          uuid: target.uuid, to: name)
            await model.debugRefresh()
            return "rename \(result)"

        case "restart" where parts.count >= 2:
            guard let target = row(at: parts[1], where: { !$0.uuid.isEmpty }) else { return "err no-row" }
            let result = await model.engine.restartSession(uuid: target.uuid,
                                                           directory: target.path,
                                                           replacingWindowId: target.windowId)
            await model.debugRefresh()
            return "restart \(result)"

        case "import" where parts.count >= 2:
            guard let target = row(at: parts[1], where: { $0.state == .unmanaged }) else { return "err no-row" }
            let result = await model.engine.importSession(uuid: target.uuid, directory: target.path)
            await model.debugRefresh()
            return "import \(result)"

        case "archive" where parts.count >= 2:
            guard let target = row(at: parts[1]) else { return "err no-row" }
            await model.engine.archiveSession(uuid: target.uuid, windowId: target.windowId)
            await model.debugRefresh()
            return "archived \(target.uuid)"

        case "unarchive" where parts.count >= 2:
            guard let target = row(at: parts[1]) else { return "err no-row" }
            await model.engine.unarchiveSession(uuid: target.uuid)
            await model.debugRefresh()
            return "unarchived \(target.uuid)"

        case "onboard" where parts.count >= 2:
            model.completeOnboarding(directories: Array(parts[1...]))
            return "onboarding \(Array(parts[1...]))"

        case "onboarddir" where parts.count >= 2:
            // Scripted stand-in for the onboarding NSOpenPanel: verifies the
            // Start Scanning disabled->enabled gate without a modal.
            NotificationCenter.default.post(name: OnboardingView.debugAddDirectory,
                                            object: parts[1])
            return "onboarddir \(parts[1])"

        case "stale" where parts.count >= 2:
            guard let seconds = TimeInterval(parts[1]) else { return "err bad-secs" }
            var settings = model.engine.settings
            settings.staleThresholdSeconds = seconds
            model.applySettings(settings)
            return "stale \(seconds)"

        case "importsheet":
            model.presentImportSheetIfNeeded()
            return "importsheet \(model.importFlow != nil)"

        case "importstart":
            guard let flow = model.importFlow else { return "err no-flow" }
            flow.startImport()
            return "importstart \(flow.selectedCount)"

        case "importclose":
            guard let flow = model.importFlow else { return "err no-flow" }
            if flow.stage == .complete { flow.close() } else { flow.skip() }
            return "importclose"

        case "importstage":
            guard let flow = model.importFlow else { return "no-flow" }
            return "stage \(flow.stage) items \(flow.items.map { "\($0.title):\($0.phase)" }.joined(separator: ","))"

        case "nav" where parts.count >= 2:
            model.sidebarNav = parts[1] == "archived" ? .archived : .allSessions
            return "nav \(model.sidebarNav)"

        case "notifs":
            return "notifs [\(NotificationManager.shared.firedKeys.joined(separator: ", "))]"

        case "counters":
            var snap: [String: Any] = DebugLife.snapshot()
            let mem = DebugLife.memoryBytes()
            snap["engine-live-sessions"] = model.engine.liveSessions.count
            snap["footprint-bytes"] = Int(mem.footprint)
            snap["rss-bytes"] = Int(mem.resident)
            guard let data = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return "err json" }
            return json

        case "pids":
            let pairs = model.engine.liveSessions.map { windowId, live in
                "\(windowId)=\(live.pid.map(String.init) ?? "-")"
            }
            return "pids \(pairs.sorted().joined(separator: " "))"

        case "watch" where parts.count >= 2:
            var settings = model.engine.settings
            if !settings.watchDirectories.contains(parts[1]) {
                settings.watchDirectories.append(parts[1])
                model.applySettings(settings)
            }
            return "watch \(settings.watchDirectories)"

        case "unwatch" where parts.count >= 2:
            var settings = model.engine.settings
            settings.watchDirectories.removeAll { $0 == parts[1] }
            model.applySettings(settings)
            return "unwatch \(settings.watchDirectories)"

        case "settingswindow":
            let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return "settingswindow \(opened)"

        case "settingspreview":
            // Renders SettingsView in a plain window so the form can be
            // screenshot-verified; the production path is the gear's
            // SettingsLink into the Settings scene.
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "CCorn Settings (debug preview)"
            window.makeKeyAndOrderFront(nil)
            return "settingspreview shown"

        case "seed":
            if parts.count >= 2, parts[1] == "empty" {
                model.debugSeed(rows: [], archived: [])
                return "seeded empty"
            }
            if parts.count >= 2, parts[1] == "working" {
                let rows = DebugStage.seedWorkingHeavyRows()
                model.debugSeed(rows: rows, archived: [])
                return "seeded working \(rows.count)"
            }
            let seeded = DebugStage.seedRows()
            model.debugSeed(rows: seeded.all, archived: seeded.archived)
            return "seeded \(seeded.all.count)+\(seeded.archived.count)"

        case "appearance" where parts.count >= 2:
            switch parts[1] {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
            return "appearance \(parts[1])"

        case "show" where parts.count >= 2:
            switch parts[1] {
            case "main": model.openMainWindow?()
            case "popover": model.openPopover?()
            default: return "err unknown surface \(parts[1])"
            }
            return "show \(parts[1])"

        case "shoot" where parts.count >= 3:
            // Let the runloop settle pending renders before capturing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            return DebugStage.shoot(target: parts[1], path: parts[2])

        case "windowid" where parts.count >= 2:
            // CGWindowID for `screencapture -l` — real compositor pixels,
            // which render materials/vibrancy faithfully where cacheDisplay
            // cannot.
            guard let number = DebugStage.windowNumber(for: parts[1]) else {
                return "err no-window \(parts[1])"
            }
            return "windowid \(number)"

        case "authalert":
            let content = AppModel.authAlertContent(
                notice: "Invalid API key · Please run /login")
            Alerts.sheetOrModal(title: content.title, message: content.message)
            return "authalert shown"

        case "dismisssheet":
            var ended = 0
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                    ended += 1
                }
            }
            return "dismissed \(ended)"

        default:
            return "err unknown: \(line)"
        }
    }

    private static func dumpJSON(rows: [SessionRow], archived: [SessionRow]) -> String {
        func encode(_ row: SessionRow, archivedList: Bool) -> [String: Any] {
            [
                "id": row.id,
                "title": row.title,
                "uuid": row.uuid,
                "path": row.path,
                "state": row.state.rawValue,
                "rc": row.remoteControlActive,
                "archived": archivedList,
                "windowId": row.windowId ?? "",
            ]
        }
        let all = rows.map { encode($0, archivedList: false) }
            + archived.map { encode($0, archivedList: true) }
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "err json" }
        return json
    }
}
#endif
