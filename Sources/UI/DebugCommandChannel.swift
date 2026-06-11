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
///   popovercalm               -> toggle the popover's calm disclosure (triage)
///   nav group <id-or-name>    -> select a group view in the sidebar
///   groups                    -> JSON of the group definitions
///   groupcreate <name...>     -> createGroup
///   groupnew                  -> beginNewGroup (placeholder + inline editor)
///   groupedit <id>            -> beginGroupRename (inline editor open)
///   groupeditcommit <name...> -> commit the open inline editor
///   groupeditcancel           -> cancel the open inline editor
///   groupdelete <id>          -> performGroupDelete (no confirm modal)
///   groupassign <dir> <gid>   -> add the row at <dir> to a group
///   groupunassign <dir> <gid> -> remove the row at <dir> from a group
///   groupsmenu <dir> [secs]   -> pop the row's Groups submenu (screenshots)
///   stale <seconds>           -> set stale threshold
///   importsheet               -> presentImportSheetIfNeeded
///   counters                  -> JSON of DebugLife gauges + memory (shakedown)
///   pids                      -> windowId:pid map of live sessions (shakedown)
///   watch <dir> | unwatch <dir> -> add/remove a watch directory (applySettings)
///   seed [empty|working|calm] -> stop the poll, stage curated rows (DebugStage)
///   appearance <light|dark|system> -> override NSApp.appearance
///   show <main|popover>       -> open a surface for screenshots
///   shoot <target> <path>     -> PNG of a window (main/popover/settings/onboarding/sheet/key)
///   authalert                 -> present the section-8 auth alert (sheet on main)
///   dismisssheet              -> end any attached sheet
@MainActor
final class DebugCommandChannel {
    private let model: AppModel
    private var task: Task<Void, Never>?
    /// Default paths serve the single-instance case; CCORN_DEBUG_CHANNEL_DIR
    /// gives a concurrent instance (hermetic e2e next to a normal debug run)
    /// its own channel so two apps never race on one cmd file.
    private let cmdPath: String
    private let outPath: String

    init(model: AppModel) {
        self.model = model
        if let dir = ProcessInfo.processInfo.environment["CCORN_DEBUG_CHANNEL_DIR"] {
            cmdPath = dir + "/cmd"
            outPath = dir + "/out"
        } else {
            cmdPath = "/tmp/ccorn-debug-cmd"
            outPath = "/tmp/ccorn-debug-out"
        }
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

        case "popovercalm":
            // Scripted click on the popover's calm disclosure (expand/collapse).
            NotificationCenter.default.post(name: PopoverView.debugToggleCalm, object: nil)
            return "popovercalm toggled"

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
            switch parts[1] {
            case "archived":
                model.sidebarNav = .archived
            case "group" where parts.count >= 3:
                let key = parts[2...].joined(separator: " ")
                guard let group = model.groups.first(where: { $0.id == key || $0.name == key }) else {
                    return "err no-group \(key)"
                }
                model.sidebarNav = .group(group.id)
            default:
                model.sidebarNav = .allSessions
            }
            return "nav \(model.sidebarNav)"

        // MARK: Groups (5.11)

        case "groups":
            let defs = model.groups.map { ["id": $0.id, "name": $0.name] }
            guard let data = try? JSONSerialization.data(withJSONObject: defs, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return "err json" }
            return json

        case "groupcreate" where parts.count >= 2:
            let group = model.createGroup(named: parts[1...].joined(separator: " "))
            return "groupcreate \(group.id)"

        case "groupnew":
            model.beginNewGroup()
            return "groupnew \(model.editingGroupId ?? "-")"

        case "groupedit" where parts.count >= 2:
            model.beginGroupRename(parts[1])
            return "groupedit \(parts[1])"

        case "groupeditcommit" where parts.count >= 2:
            guard let id = model.editingGroupId else { return "err not-editing" }
            model.commitGroupName(id, to: parts[1...].joined(separator: " "))
            return "groupeditcommit \(id)"

        case "groupeditcancel":
            model.cancelGroupEdit()
            return "groupeditcancel"

        case "groupdelete" where parts.count >= 2:
            // Confirmation-free core, same split as the kill flow.
            model.performGroupDelete(parts[1])
            return "groupdelete \(parts[1])"

        case "groupassign" where parts.count >= 3:
            guard let target = row(at: parts[1]) else { return "err no-row" }
            guard !target.groupIDs.contains(parts[2]) else { return "already-member" }
            model.toggleGroupMembership(target, groupId: parts[2])
            return "groupassign \(target.uuid) -> \(parts[2])"

        case "groupunassign" where parts.count >= 3:
            guard let target = row(at: parts[1]) else { return "err no-row" }
            model.removeFromGroup(target, groupId: parts[2])
            return "groupunassign \(target.uuid) -x \(parts[2])"

        case "groupsmenu" where parts.count >= 2:
            // Pop the row's Groups submenu (screenshot aid). popUp BLOCKS in
            // its tracking loop, so dismissal is armed first on a .common-mode
            // timer, which still fires during menu tracking.
            guard let target = row(at: parts[1]) else { return "err no-row" }
            let menu = SessionMenu.menu(for: target, model: model)
            guard let submenu = menu.items.first(where: { $0.title == "Groups" })?.submenu else {
                return "err no-groups-submenu"
            }
            let seconds = parts.count >= 3 ? (Double(parts[2]) ?? 6) : 6
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                submenu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
            let anchor = NSApp.windows.first { $0.title == "CCorn" }
            let origin = anchor.map { NSPoint(x: $0.frame.midX - 80, y: $0.frame.midY) }
                ?? NSPoint(x: 400, y: 400)
            submenu.popUp(positioning: nil, at: origin, in: nil)
            return "groupsmenu dismissed"

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
            if parts.count >= 2, parts[1] == "calm" {
                let rows = DebugStage.seedCalmRows()
                model.debugSeed(rows: rows, archived: [])
                return "seeded calm \(rows.count)"
            }
            let seeded = DebugStage.seedRows()
            model.debugSeed(rows: seeded.all, archived: seeded.archived,
                            groups: DebugStage.seedGroups)
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
                "authNotice": row.authNotice ?? "",
                "groups": row.groupIDs,
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
