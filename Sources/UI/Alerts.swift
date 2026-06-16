import AppKit

/// Native NSAlert wrappers for every confirmation in the spec. Synchronous
/// (`runModal`) on purpose: each one gates a user-initiated action on the main
/// actor, exactly the modal-confirmation pattern the flows describe.
@MainActor
enum Alerts {
    /// The app is `.accessory` (no Dock icon) and often inactive when an alert
    /// fires; most critically the launch dependency gates, which run before
    /// any window exists. An inactive accessory app's modal sits invisible
    /// behind other apps, so every alert activates first.
    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The in-dialog brand mark: the trimmed, transparent OpenMoji corn glyph
    /// (`CornGlyph`), the same artwork every other in-app surface uses. Without
    /// this, NSAlert falls back to `NSApp.applicationIconImage` (the Dock/
    /// Finder app icon, which is the corn baked onto its rounded-square tile),
    /// so the glyph reads as boxed. Set on every alert below; the Dock/Finder
    /// icon (the appiconset) is deliberately left with its tile.
    private static var cornIcon: NSImage? { NSImage(named: "CornGlyph") }

    /// Stop confirmation (flow 6.6): Stop is the default action so Return
    /// confirms; mirrors Start Session's default button. Stopping is
    /// recoverable (the session survives as Stopped and can be restarted), so
    /// this is a plain default button, not the old destructive-red treatment.
    static func confirmStop(name: String) -> Bool {
        activate()
        let alert = NSAlert()
        alert.icon = cornIcon
        alert.messageText = "Stop \(name)?"
        alert.informativeText = "It stays in your list and can be restarted anytime."
        alert.alertStyle = .warning
        // First button is the default (Return); a button titled "Cancel" gets
        // Escape automatically. Stop is not destructive, so it needs neither
        // `hasDestructiveAction` (which would block Return) nor a red bezel;
        // a plain default button confirms on Return. Escape and Cancel stay the
        // safety valve against an accidental stop of a live session.
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Generic two-button confirmation; returns true when the action button is
    /// chosen. The action button is the default (archive/import are
    /// deliberately lighter than Stop).
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

    /// Destructive confirmation with Cancel as the default, the deliberate
    /// mirror of `confirmStop`. Here the confirming action is irreversible from
    /// the user's side (the unmanaged-session takeover, flow 6.10, SIGTERMs the
    /// external claude and breaks their terminal), so a reflexive Return must
    /// NOT trigger it. Cancel is added first, which makes it NSAlert's default
    /// button (Return) and gives it Escape; the action is the second button,
    /// `hasDestructiveAction` (red bezel, and excluded from Return); confirming
    /// takes an intentional click. Returns true only when the action is chosen.
    static func confirmDestructive(title: String, message: String, action: String) -> Bool {
        activate()
        let alert = NSAlert()
        alert.icon = cornIcon
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let confirm = alert.addButton(withTitle: action)
        confirm.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// One-button alert that attaches as a sheet when a regular CCorn window
    /// is visible (non-blocking, lands on what the user is looking at) and
    /// falls back to the app-modal alert otherwise (menu-bar-only state).
    /// Used by the detection-driven section-8 alerts, which fire from the poll
    /// loop; an app-modal `runModal` there would stall the 3s tick.
    static func sheetOrModal(title: String, message: String) {
        let alert = NSAlert()
        alert.icon = cornIcon
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // Prefer the main window. These alerts are about a session in its
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
    /// empty; callers decide what an empty confirmed entry means.
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

    /// Folder picker (NSOpenPanel, the only sanctioned picker). nil on cancel.
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
