import AppKit
import SwiftUI

/// Owns the onboarding window: standalone, centered, not resizable, and NOT
/// closable — onboarding is required, the app is unusable without a watch
/// directory (docs/CCORN_SPEC.md 5.3). Shown with `.regular` activation so it
/// can take focus (the app launches as `.accessory`).
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let view = OnboardingView { directories in
                // completeOnboarding closes this window via the model's
                // closeOnboarding hook, so every completion path (including
                // the debug channel's `onboard`) tears the card down.
                model.completeOnboarding(directories: directories)
            }
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to CCorn"
            window.styleMask = [.titled] // no close/minimize/resize: required flow
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isShowing: Bool { window?.isVisible == true }

    func close() {
        window?.close()
        window = nil
        MainWindowController.updateActivationPolicy()
    }
}
