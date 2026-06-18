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
        .commands {
            SidebarToggleCommands(model: appDelegate.model)
            SearchCommands(model: appDelegate.model)
        }
    }
}

/// Edit ▸ Find (⌘F): reveals the hidden title-bar name filter and focuses it.
/// Like `SidebarToggleCommands`, the main window is AppKit-hosted rather than a
/// SwiftUI scene, so this drives the model directly (the same `searchActive`
/// state the title-bar field and the list filter bind to) instead of routing
/// through a focused-scene command. Escape (handled on the field itself)
/// dismisses it; there is no menu item for that, matching the field's behavior.
struct SearchCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") {
                model.beginSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}

/// View ▸ Show/Hide Sidebar (⌘⌃S). The menu bar is present whenever the
/// activation policy is .regular (any regular window open). The main window
/// is an AppKit-hosted window, not a SwiftUI scene, so SwiftUI's built-in
/// SidebarCommands (focused-scene based) can't reach it; this drives the
/// model directly, the same state the split view and titlebar toggle bind to.
struct SidebarToggleCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button {
                model.toggleSidebar()
            } label: {
                // Observation lives in the LABEL view, not the Commands body:
                // the menu bridge re-renders item labels on model change, but
                // a Commands body is not reliably re-evaluated, which would
                // freeze the title at its launch value.
                SidebarToggleTitle(model: model)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }

    private struct SidebarToggleTitle: View {
        @ObservedObject var model: AppModel

        var body: some View {
            Text(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        }
    }
}
