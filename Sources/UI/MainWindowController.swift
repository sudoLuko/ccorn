import AppKit
import SwiftUI

/// Owns the single main window and the activation-policy dance: `.regular`
/// while any regular (titled) window is open so it can take focus and appear in
/// Cmd+Tab, back to `.accessory` only when none remain (docs/CCORN_SPEC.md
/// section 5.1, "Activation policy").
@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var toolbarDelegate: ToolbarDelegate?
    /// For publishing mainWindowOnScreen (row-motion gating): the closed
    /// window keeps its SwiftUI tree alive (isReleasedWhenClosed = false),
    /// so the marks must be told when it leaves the screen.
    private weak var model: AppModel?

    init() {
        // Global observers cover the main window, Settings, and any future
        // regular window: didBecomeKey catches windows this controller didn't
        // open (e.g. the Settings scene via Cmd+,), willClose catches the last
        // regular window going away. The window is still visible when willClose
        // fires, so recompute on the next runloop turn.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                DispatchQueue.main.async {
                    Self.updateActivationPolicy()
                }
            })
        }
    }

    func show(model: AppModel) {
        self.model = model
        if window == nil {
            let hosting = NSHostingController(rootView: MainWindowView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // App identity lives in the branded sidebar header; the title bar
            // keeps standard chrome (traffic lights, .titled mask) but hides
            // its text so "CCorn" isn't duplicated. The title STRING must
            // stay set: DebugStage finds this window by title == "CCorn", and
            // the activation policy keys off .titled. titleVisibility comes
            // AFTER the styleMask assignment — reassigning the mask rebuilds
            // the titlebar and the hidden setting resurfaces on resign-key.
            window.title = "CCorn"
            window.titleVisibility = .hidden
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.setContentSize(NSSize(width: 860, height: 540))
            window.isReleasedWhenClosed = false
            window.center()

            // Set up custom NSToolbar with corn icon, bypassing SwiftUI's
            // automatic toolbar item styling (which adds the ring/halo).
            let toolbar = NSToolbar(identifier: "MainToolbar")
            let delegate = ToolbarDelegate()
            toolbar.delegate = delegate
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            self.toolbarDelegate = delegate

            // Sidebar toggle in the titlebar, next to the traffic lights:
            // window chrome is the one region that can never collapse, so the
            // restore control survives a hidden sidebar (and a persisted-hidden
            // relaunch), and its position is identical in both states.
            let toggleHost = NSHostingView(rootView: SidebarToggleButton(model: model))
            toggleHost.frame = NSRect(x: 0, y: 0, width: 32, height: 24)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = toggleHost
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
            self.window = window
            // One signal covers close, miniaturize, and full occlusion: the
            // occlusion state drops .visible for all of them (and regains it
            // on order-front), driving the row-motion gate.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self, weak window] _ in
                DispatchQueue.main.async {
                    guard let self, let window else { return }
                    self.model?.mainWindowOnScreen =
                        window.occlusionState.contains(.visible)
                }
            })
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.mainWindowOnScreen = true
    }

    /// Titlebar sidebar toggle. Lives in window chrome, NEVER inside the
    /// collapsible column, so hiding the sidebar cannot hide its own restore
    /// control — the stuck state this exists to prevent. Drives the same
    /// model state as the View menu and ⌘⌃S.
    private struct SidebarToggleButton: View {
        @ObservedObject var model: AppModel

        var body: some View {
            Button {
                model.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        }
    }

    /// `.regular` iff a regular window remains: titled, visible or minimized
    /// (a miniaturized window is open but not `isVisible`), normal level
    /// (excludes the status-bar window and the borderless popover window).
    static func updateActivationPolicy() {
        let hasRegularWindow = NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized)
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && window.level == .normal
        }
        NSApp.setActivationPolicy(hasRegularWindow ? .regular : .accessory)
    }
}

// MARK: - Toolbar Delegate

private class ToolbarDelegate: NSObject, NSToolbarDelegate {
    static let cornIconID = NSToolbarItem.Identifier("CornIcon")

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Self.cornIconID {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)

            // Corn icon image view.
            let imageView = NSImageView()
            imageView.image = NSImage(named: "CornGlyph")
            imageView.imageScaling = .scaleProportionallyDown
            imageView.frame.size = CGSize(width: 16, height: 16)

            item.view = imageView
            item.minSize = CGSize(width: 16, height: 16)
            item.maxSize = CGSize(width: 16, height: 16)

            // The key setting: disable the border/ring that appears on toolbar items.
            item.isBordered = false

            return item
        }
        return nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Leading flexible space pushes the corn glyph to the trailing (right)
        // edge, balancing it against the traffic lights and sidebar toggle on
        // the left.
        return [.flexibleSpace, Self.cornIconID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [Self.cornIconID, .flexibleSpace]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }
}
