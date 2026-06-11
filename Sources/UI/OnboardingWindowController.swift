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
            window.styleMask = [.titled] // no close/minimize/resize: required flow
            // Same treatment as the main window: the card body already shows
            // the corn lockup, so the title-bar TEXT is hidden rather than
            // duplicated. The title STRING stays set (DebugStage finds this
            // window by it), and both come after the styleMask assignment —
            // reassigning the mask rebuilds the titlebar.
            window.title = "Welcome to CCorn"
            window.titleVisibility = .hidden
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
