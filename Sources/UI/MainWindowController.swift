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
    /// For publishing mainWindowOnScreen (row-motion gating): the closed
    /// window keeps its SwiftUI tree alive (isReleasedWhenClosed = false),
    /// so the marks must be told when it leaves the screen.
    private weak var model: AppModel?
    /// Local key monitor: Return on a selected, renameable row begins inline
    /// rename (macOS 13 has no SwiftUI .onKeyPress).
    private var keyMonitor: Any?

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
        self.model = model
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

            // App identity: the corn glyph pinned to the trailing edge of the
            // title bar via a titlebar accessory. Deliberately NOT an NSToolbar:
            // any window with a toolbar gets AppKit's built-in "Icon and Text /
            // Icon Only" display-mode context menu on right-click, and there is
            // no API to suppress just those items. A titlebar accessory hosts
            // the same glyph with no toolbar and no context menu (spec §5.1:
            // "No toolbar").
            let cornHost = NSHostingView(rootView: CornMark(size: 16).padding(.trailing, 14))
            cornHost.frame = NSRect(x: 0, y: 0, width: 38, height: 24)
            let cornAccessory = NSTitlebarAccessoryViewController()
            cornAccessory.view = cornHost
            cornAccessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(cornAccessory)

            // Sidebar toggle in the titlebar, next to the traffic lights:
            // window chrome is the one region that can never collapse, so the
            // restore control survives a hidden sidebar (and a persisted-hidden
            // relaunch), and its position is identical in both states.
            let toggleHost = NSHostingView(rootView: SidebarToggleButton(model: model))
            toggleHost.frame = NSRect(x: 0, y: 0, width: 32, height: 24)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = toggleHost
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
            self.window = window
            // One signal covers close, miniaturize, and full occlusion: the
            // occlusion state drops .visible for all of them (and regains it
            // on order-front), driving the row-motion gate.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self, weak window] _ in
                DispatchQueue.main.async {
                    guard let self, let window else { return }
                    self.model?.mainWindowOnScreen =
                        window.occlusionState.contains(.visible)
                }
            })

            // Return begins inline rename of the selected row (Finder-style),
            // complementing the double-click-title gesture. Scoped to this
            // window; skipped while a text field is first responder (the rename
            // editor itself) so typing is never hijacked. Key events arrive on
            // the main thread, so touching the main-actor model here is safe.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, let model = self.model,
                      event.window === window,
                      event.keyCode == 36 || event.keyCode == 76,   // Return / numpad Enter
                      !(window.firstResponder is NSText),
                      model.renamingRowId == nil,
                      let id = model.selection,
                      let row = (model.rows + model.archivedRows).first(where: { $0.id == id }),
                      Self.isRenameable(row)
                else { return event }
                model.beginRename(row)
                return nil
            }
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        applyWindowLevel()
        NSApp.activate(ignoringOtherApps: true)
        model.mainWindowOnScreen = true
    }

    /// The level the main window floats at when "keep in front" is on. Just
    /// above other apps' normal windows, but well below the popover panel
    /// (`.popUpMenu`) and system UI, so the menu-bar surface still overlays it.
    private static let keepInFrontLevel: NSWindow.Level = .floating

    /// Push the main window above other apps' windows when the "keep window in
    /// front" preference is on, back to normal when off. Reads the live setting
    /// off the model, so it is also the apply-on-change hook (AppModel calls it
    /// from applySettings). No-op until the window exists. NEVER touches the
    /// popover (an NSPanel, and at a higher level anyway); the raised level is
    /// counted by updateActivationPolicy, so the .regular/.accessory switch is
    /// unaffected.
    func applyWindowLevel() {
        guard let window else { return }
        let keepInFront = model?.engine.settings.keepWindowInFront ?? false
        window.level = keepInFront ? Self.keepInFrontLevel : .normal
    }

    /// Titlebar sidebar toggle. Lives in window chrome, NEVER inside the
    /// collapsible column, so hiding the sidebar cannot hide its own restore
    /// control — the stuck state this exists to prevent. Drives the same
    /// model state as the View menu and ⌘⌃S.
    private struct SidebarToggleButton: View {
        @ObservedObject var model: AppModel

        var body: some View {
            Button {
                model.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        }
    }

    /// `.regular` iff a regular window remains: titled, visible or minimized
    /// (a miniaturized window is open but not `isVisible`), at the normal level
    /// or the "keep in front" level (excludes the status-bar window and the
    /// borderless popover window, which sit at higher levels — the main window
    /// raised to `.floating` by keep-in-front must still count, or the policy
    /// would drop to `.accessory` while it is on screen).
    /// Managed and stopped (record) rows can be renamed; unmanaged discovery
    /// rows cannot. Mirrors SessionRowView.canRename.
    private static func isRenameable(_ row: SessionRow) -> Bool {
        switch row.kind {
        case .managed, .record: return true
        case .unmanaged: return false
        }
    }

    static func updateActivationPolicy() {
        let hasRegularWindow = NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized)
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && (window.level == .normal || window.level == keepInFrontLevel)
        }
        NSApp.setActivationPolicy(hasRegularWindow ? .regular : .accessory)
    }
}
