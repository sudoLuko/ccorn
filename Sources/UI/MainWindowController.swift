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
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
