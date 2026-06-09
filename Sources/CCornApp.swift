import SwiftUI

@main
struct CCornApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A Settings scene gives SwiftUI a valid Scene to host. The menu bar item
        // and popover are owned by the AppDelegate. No main WindowGroup on purpose:
        // this is a menu-bar app.
        Settings {
            SettingsPlaceholderView()
        }
    }
}
