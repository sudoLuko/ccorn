import AppKit
import SwiftUI

/// NSMenuItem that invokes a closure. Target/action wiring without a shared
/// responder; items are rebuilt per menu presentation.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String,
         enabled: Bool = true,
         destructive: Bool = false,
         toolTip: String? = nil,
         handler: @escaping () -> Void = {}) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
        self.toolTip = toolTip
        if destructive && enabled {
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.menuFont(ofSize: 0)])
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func invoke() { handler() }
}

/// Builds the per-row context menu (docs/CCORN_SPEC.md section 5.7). Native
/// NSMenu, no custom styling. Four variants: live, dead/stopped, archived,
/// unmanaged. Every record-backed variant carries the Groups submenu (5.11);
/// unmanaged rows do not; they have no record, and Import is the doorway.
@MainActor
enum SessionMenu {
    static func menu(for row: SessionRow, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copyItem = ActionMenuItem(title: "Copy Session ID",
                                      enabled: !row.uuid.isEmpty) { [weak model] in
            model?.copySessionID(row)
        }

        // While a group view is active, removal from THIS group is one click
        // (membership row.groupIDs is always [] for unmanaged rows, and
        // archived rows never render inside a group view).
        if case let .group(groupId) = model.sidebarNav,
           let group = model.groups.first(where: { $0.id == groupId }),
           row.groupIDs.contains(groupId) {
            menu.addItem(ActionMenuItem(title: "Remove from “\(group.name)”") { [weak model] in
                model?.removeFromGroup(row, groupId: groupId)
            })
            menu.addItem(.separator())
        }

        // Archived rows are stopped, so check the flag before the state.
        if row.archived {
            menu.addItem(ActionMenuItem(title: "Unarchive") { [weak model] in
                model?.unarchiveSession(row)
            })
            menu.addItem(removeItem(for: row, model: model))
            menu.addItem(.separator())
            menu.addItem(groupsItem(for: row, model: model))
            menu.addItem(.separator())
            menu.addItem(copyItem)
            return menu
        }

        switch row.state {
        case .running, .working, .waiting, .needsAuth, .stale:
            menu.addItem(ActionMenuItem(
                title: "Open in Browser",
                enabled: row.remoteControlActive,
                toolTip: row.remoteControlActive ? nil
                    : (row.remoteControlRequested
                        ? "Remote control is not active on this session"
                        : "This is a local session, so there is no browser access")) { [weak model] in
                model?.openInBrowser(row)
            })
            menu.addItem(ActionMenuItem(title: "Open in Terminal") { [weak model] in
                model?.openInTerminal(row)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Rename") { [weak model] in
                model?.beginRename(row)
            })
            menu.addItem(groupsItem(for: row, model: model))
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Stop Session") { [weak model] in
                model?.stopSession(row)
            })
            menu.addItem(ActionMenuItem(title: "Archive") { [weak model] in
                model?.archiveSession(row)
            })
            menu.addItem(removeItem(for: row, model: model))
            menu.addItem(.separator())
            menu.addItem(copyItem)

        case .dead, .stopped:
            menu.addItem(ActionMenuItem(
                title: "Restart Session",
                enabled: !row.path.isEmpty) { [weak model] in
                model?.restartSession(row)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Rename") { [weak model] in
                model?.beginRename(row)
            })
            menu.addItem(groupsItem(for: row, model: model))
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Archive") { [weak model] in
                model?.archiveSession(row)
            })
            menu.addItem(removeItem(for: row, model: model))
            menu.addItem(.separator())
            menu.addItem(copyItem)

        case .unmanaged:
            let canImport = !row.uuid.isEmpty && !row.path.isEmpty
            // An unmanaged row is someone else's running session. Both items
            // adopt it (SIGTERM the external claude → `claude --resume` under
            // CCorn, which preserves the conversation); the first also attaches
            // the fresh window in Terminal. Both labels say "Take Over", never a
            // bare "Open in Terminal" like a managed row (line 83), so the
            // takeover is plain before the click, and the confirm
            // (confirmDestructive) spells out the consequences.
            menu.addItem(ActionMenuItem(
                title: "Take Over & Open in Terminal",
                enabled: canImport,
                toolTip: "Take over this session, then open it in Terminal. Your existing terminal stops working; the conversation is preserved.") { [weak model] in
                model?.importSession(row, attachInTerminal: true)
            })
            menu.addItem(ActionMenuItem(
                title: "Take Over Session",
                enabled: canImport,
                toolTip: "Take over this session under CCorn. Your existing terminal stops working; the conversation is preserved.") { [weak model] in
                model?.importSession(row)
            })
            menu.addItem(.separator())
            menu.addItem(removeItem(for: row, model: model))
            menu.addItem(copyItem)
        }
        return menu
    }

    /// "Remove from CCorn" (untrack): drops CCorn's own record and adds the
    /// session's UUID to the ignore-list so discovery stops surfacing it; the
    /// Claude conversation on disk is never touched, so it can still be resumed
    /// from the terminal. Offered wherever Archive is (live + dead rows), after
    /// Unarchive on archived rows, and on unmanaged rows. Disabled only when
    /// there is nothing to act on: a row with neither a live window to stop nor
    /// a bound UUID to ignore (e.g. an empty dormant directory summary).
    private static func removeItem(for row: SessionRow, model: AppModel) -> NSMenuItem {
        let actionable = row.windowId != nil || !row.uuid.isEmpty
        return ActionMenuItem(title: "Remove from CCorn", enabled: actionable) { [weak model] in
            model?.removeFromCCorn(row)
        }
    }

    /// The "Groups" submenu (5.11): one check-state item per group (the one
    /// control that assigns, unassigns, and shows membership inline), plus
    /// "New Group…", which creates a group, assigns the session, and opens
    /// the sidebar's inline editor for naming. Gated until the session's
    /// uuid has bound: membership keys on the uuid, and a brand-new session
    /// has none until its first transcript (the Restart-on-missing-path
    /// gating family).
    private static func groupsItem(for row: SessionRow, model: AppModel) -> NSMenuItem {
        let assignable = SessionGroup.canAssign(uuid: row.uuid)
        let parent = NSMenuItem(title: "Groups", action: nil, keyEquivalent: "")
        parent.isEnabled = assignable
        if !assignable {
            parent.toolTip = "Available once the session has started its first conversation"
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for group in model.groups {
            let item = ActionMenuItem(title: group.name, enabled: assignable) { [weak model] in
                model?.toggleGroupMembership(row, groupId: group.id)
            }
            item.state = row.groupIDs.contains(group.id) ? .on : .off
            submenu.addItem(item)
        }
        if !model.groups.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(ActionMenuItem(title: "New Group…", enabled: assignable) { [weak model] in
            model?.createGroupAndAssign(row)
        })
        parent.submenu = submenu
        return parent
    }
}

/// Bridges a row's SwiftUI content to the AppKit context-menu machinery: holds
/// the catcher NSView so the `…` button can pop the same NSMenu the right-click
/// path uses.
@MainActor
final class RowMenuHost: ObservableObject {
    weak var view: NSView?

    func popMenu(_ menu: NSMenu) {
        guard let view, let window = view.window else { return }
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }
}

/// Transparent overlay that catches ONLY right-clicks (and control-clicks) and
/// shows the row's NSMenu; every other event falls through to the SwiftUI row
/// underneath. The spec mandates native NSMenu; SwiftUI `.contextMenu` is not
/// used (docs/CCORN_SPEC.md section 5.7).
struct RowRightClickCatcher: NSViewRepresentable {
    let host: RowMenuHost
    let menuProvider: () -> NSMenu
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.menuProvider = menuProvider
        view.onRightClick = onRightClick
        host.view = view
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.menuProvider = menuProvider
        view.onRightClick = onRightClick
        host.view = view
    }

    final class CatcherView: NSView {
        var menuProvider: (() -> NSMenu)?
        var onRightClick: (() -> Void)?

        /// Claim the hit only for context-menu events; let everything else
        /// (left clicks, scroll, hover) pass through to SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            onRightClick?() // select the row, standard macOS behavior
            return menuProvider?()
        }

        /// Control-click arrives as a plain mouseDown; route it to the menu.
        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
                super.mouseDown(with: event)
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
