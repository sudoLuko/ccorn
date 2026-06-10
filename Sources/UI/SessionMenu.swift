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
/// unmanaged.
@MainActor
enum SessionMenu {
    static func menu(for row: SessionRow, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copyItem = ActionMenuItem(title: "Copy Session ID",
                                      enabled: !row.uuid.isEmpty) { [weak model] in
            model?.copySessionID(row)
        }

        // Archived rows are stopped, so check the flag before the state.
        if row.archived {
            menu.addItem(ActionMenuItem(title: "Unarchive") { [weak model] in
                model?.unarchiveSession(row)
            })
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
                    : "Remote control is not active on this session") { [weak model] in
                model?.openInBrowser(row)
            })
            menu.addItem(ActionMenuItem(title: "Open in Terminal") { [weak model] in
                model?.openInTerminal(row)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Rename") { [weak model] in
                model?.beginRename(row)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Kill Session", destructive: true) { [weak model] in
                model?.killSession(row)
            })
            menu.addItem(ActionMenuItem(title: "Archive") { [weak model] in
                model?.archiveSession(row)
            })
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
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Archive") { [weak model] in
                model?.archiveSession(row)
            })
            menu.addItem(.separator())
            menu.addItem(copyItem)

        case .unmanaged:
            menu.addItem(ActionMenuItem(
                title: "Import Session",
                enabled: !row.uuid.isEmpty && !row.path.isEmpty) { [weak model] in
                model?.importSession(row)
            })
            menu.addItem(.separator())
            menu.addItem(copyItem)
        }
        return menu
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
/// underneath. The spec mandates native NSMenu — SwiftUI `.contextMenu` is not
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
