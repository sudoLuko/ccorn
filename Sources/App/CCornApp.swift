import SwiftUI

@main
struct CCornApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item, popover, main window, and onboarding are owned by
        // the AppDelegate. No main WindowGroup on purpose: this is a menu-bar
        // app. Settings renders as the native preferences window (5.5).
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
