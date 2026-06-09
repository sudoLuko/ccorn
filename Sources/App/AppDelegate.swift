import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as an accessory (menu-bar) app. The real app will switch to
        // .regular when it opens a window, then back. See the build spec.
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "circle.grid.2x2",
                                accessibilityDescription: "CCorn")
            image?.isTemplate = true   // template so macOS tints it for light/dark menu bar
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 220)
        popover.contentViewController = NSHostingController(rootView: PopoverPlaceholderView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
