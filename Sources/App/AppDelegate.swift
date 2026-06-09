import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let windowController = MainWindowController()
    private(set) var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory by default: no Dock icon, no Cmd+Tab. Switches to .regular
        // while a regular window is open (MainWindowController).
        NSApp.setActivationPolicy(.accessory)

        model = AppModel(engine: SessionEngine())
        model.openMainWindow = { [weak self] in self?.openMainWindow() }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }

        configureStatusItem()
        configurePopover()

        model.start()

        // Debug-only hook so screenshot-based verification can open the UI
        // without clicking the status item (no effect unless the env var is set).
        let debugUI = ProcessInfo.processInfo.environment["CCORN_DEBUG_UI"] ?? ""
        if debugUI.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if debugUI.contains("window") { openMainWindow() }
        if debugUI.contains("popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // menu-bar app: closing the main window must not quit
    }

    // MARK: - Status item + popover

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = CornIcon.menuBarImage // template: macOS tints it
            button.action = #selector(statusItemClicked)
            button.target = self
            // Left click toggles the popover; right click opens the main window
            // (docs/CCORN_SPEC.md section 5.1).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func configurePopover() {
        popover.behavior = .transient
        // The popover is fixed dark regardless of system appearance.
        popover.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    @objc private func statusItemClicked() {
        // Right-click OR control-click (the system-wide secondary-click alias)
        // opens the main window; plain left click toggles the popover.
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            openMainWindow()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openMainWindow() {
        popover.performClose(nil)
        windowController.show(model: model)
    }
}
