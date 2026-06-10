import AppKit

/// Native NSAlert wrappers for every confirmation in the spec. Synchronous
/// (`runModal`) on purpose: each one gates a user-initiated action on the main
/// actor, exactly the modal-confirmation pattern the flows describe.
@MainActor
enum Alerts {
    /// The app is `.accessory` (no Dock icon) and often inactive when an alert
    /// fires — most critically the launch dependency gates, which run before
    /// any window exists. An inactive accessory app's modal sits invisible
    /// behind other apps, so every alert activates first.
    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Kill confirmation (flow 6.6): destructive, Cancel is the default.
    static func confirmKill(name: String) -> Bool {
        activate()
        let alert = NSAlert()
        alert.messageText = "Kill \(name)?"
        alert.informativeText = "This will end the session. This cannot be undone."
        alert.alertStyle = .warning
        // First button is the default; spec wants Cancel as default, Kill red.
        alert.addButton(withTitle: "Cancel")
        let kill = alert.addButton(withTitle: "Kill")
        kill.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Generic two-button confirmation; returns true when the action button is
    /// chosen. The action button is the default (archive/import are
    /// deliberately lighter than Kill).
    static func confirm(title: String, message: String, action: String,
                        destructive: Bool = false) -> Bool {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Informational alert with a single OK button.
    static func info(title: String, message: String = "") {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Two-choice alert returning which was picked (first = default).
    static func choice(title: String, message: String,
                       primary: String, secondary: String) -> Bool {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: secondary)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Folder picker (NSOpenPanel — the only sanctioned picker). nil on cancel.
    static func pickFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
