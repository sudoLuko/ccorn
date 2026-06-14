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

    /// The in-dialog brand mark: the trimmed, transparent OpenMoji corn glyph
    /// (`CornGlyph`), the same artwork every other in-app surface uses. Without
    /// this, NSAlert falls back to `NSApp.applicationIconImage` — the Dock/
    /// Finder app icon, which is the corn baked onto its rounded-square tile —
    /// so the glyph reads as boxed. Set on every alert below; the Dock/Finder
    /// icon (the appiconset) is deliberately left with its tile.
    private static var cornIcon: NSImage? { NSImage(named: "CornGlyph") }

    /// Kill confirmation (flow 6.6): destructive, Cancel is the default.
    static func confirmKill(name: String) -> Bool {
        activate()
        let alert = NSAlert()
        alert.icon = cornIcon
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
        alert.icon = cornIcon
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// One-button alert that attaches as a sheet when a regular CCorn window
    /// is visible (non-blocking, lands on what the user is looking at) and
    /// falls back to the app-modal alert otherwise (menu-bar-only state).
    /// Used by the detection-driven section-8 alerts, which fire from the poll
    /// loop — an app-modal `runModal` there would stall the 3s tick.
    static func sheetOrModal(title: String, message: String) {
        let alert = NSAlert()
        alert.icon = cornIcon
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // Prefer the main window — these alerts are about a session in its
        // list; never sheet onto whatever titled window happens to sort first.
        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled)
                && $0.level == .normal && !($0 is NSPanel) && $0.attachedSheet == nil
        }
        if let window = candidates.first(where: { $0.title == "CCorn" }) ?? candidates.first {
            alert.beginSheetModal(for: window)
        } else {
            activate()
            alert.runModal()
        }
    }

    /// Informational alert with a single OK button.
    static func info(title: String, message: String = "") {
        activate()
        let alert = NSAlert()
        alert.icon = cornIcon
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
        alert.icon = cornIcon
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: secondary)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Single-line text prompt with an accessory field (focused for immediate
    /// typing). Returns nil on Cancel; otherwise the trimmed entry, which MAY be
    /// empty — callers decide what an empty confirmed entry means.
    static func prompt(title: String, message: String = "",
                       placeholder: String = "", action: String = "OK") -> String? {
        activate()
        let alert = NSAlert()
        alert.icon = cornIcon
        alert.messageText = title
        if !message.isEmpty { alert.informativeText = message }
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
