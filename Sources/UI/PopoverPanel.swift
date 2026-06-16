import AppKit
import SwiftUI

/// Borderless menu-bar surface replacing NSPopover: flat-topped (no arrow),
/// appears instantly like a native status menu. Deliberately an NSPanel
/// subclass (MainWindowController.updateActivationPolicy excludes NSPanel,
/// which keeps the .accessory/.regular switch blind to this surface) and
/// named "Popover…" so DebugStage's window lookup (class name containing
/// "Popover") still resolves it.
final class PopoverPanel: NSPanel {
    /// Borderless panels refuse key by default; Escape handling and
    /// resign-key dismissal both need key status.
    override var canBecomeKey: Bool { true }

    var onDismiss: (() -> Void)?

    /// Escape via the responder-chain cancel action…
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// …and via raw keyDown for when the hosting view consumes the cancel
    /// action instead of letting it bubble. 53 is the Escape keycode.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the panel: shows it anchored under the status-item button, tracks the
/// content's preferred size with the top edge pinned, and reproduces the
/// dismissal behavior NSPopover's .transient used to provide (outside click,
/// key loss, Escape, in-content closes via model.closePopover).
@MainActor
final class PopoverPanelController {
    private let panel: PopoverPanel
    private let hosting: NSHostingController<PopoverView>
    /// For publishing popoverOnScreen (row-motion gating): the panel orders
    /// out but its SwiftUI tree stays alive, so the marks must be told.
    private let model: AppModel
    private var sizeObservation: NSKeyValueObservation?
    private var resignKeyObserver: NSObjectProtocol?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Status-button screen rect captured at show time; the anchor every
    /// later size change re-pins the top edge to.
    private var anchorRect: NSRect?
    /// Visible frame of the screen holding the clicked status item (not
    /// NSScreen.main, multi-display menu bars differ), for edge clamping.
    private var screenVisibleFrame: NSRect?
    private weak var statusButton: NSStatusBarButton?
    private var isClosing = false
    /// Re-entrancy brakes for the size tracking: the KVO fires inside
    /// SwiftUI's render pass (and again, same value, on every layout tick of
    /// the window's own frame animation). Setting the window frame right
    /// there re-enters layout and recurses until the stack dies, so the
    /// reaction hops to the next runloop turn, and echoes of a size already
    /// applied are dropped.
    private var sizeUpdateScheduled = false
    private var lastAppliedSize: NSSize?

    private static let screenEdgeInset: CGFloat = 8

    var isVisible: Bool { panel.isVisible }

    init(model: AppModel) {
        self.model = model
        // Built once and kept for the app's lifetime, exactly as the popover's
        // hosting controller was; the model flows in live.
        hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize

        panel = PopoverPanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // Dismissal is the monitors' + resign-key's job; hidesOnDeactivate
        // would orderOut behind the controller's back (and the app, being
        // .accessory and shown without activation, rarely deactivates anyway).
        panel.hidesOnDeactivate = false
        // Instant like a native menu: no fade or scale on order-front.
        panel.animationBehavior = .none
        // The popover surface is fixed dark regardless of system appearance;
        // AppKit-vended colors inside the content must resolve dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        // Clear + non-opaque: only the content's rounded fill is visible, and
        // hasShadow shapes the shadow to it.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // The hosting view must NOT be the panel's contentView: an
        // NSHostingView that is a window's content view manages animated
        // window resizing itself (windowDidLayout ->
        // updateAnimatedWindowSize), which fights the controller's anchored
        // sizing below and recurses layout until the stack dies. Nested in a
        // plain container, it stays a passive view and the controller is the
        // only writer of the panel frame.
        let container = NSView()
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        panel.onDismiss = { [weak self] in self?.close() }

        // The hosting controller publishes its SwiftUI fitting size through
        // preferredContentSize (sizingOptions above); resize the panel to
        // follow, keeping the top edge anchored under the status item.
        sizeObservation = hosting.observe(\.preferredContentSize) { [weak self] _, _ in
            self?.scheduleSizeUpdate()
        }

        // Key loss means another window (ours or not) took over; close.
        // NSApplication.didResignActive is NOT a usable proxy here: the app
        // runs .accessory and the panel shows without activating it.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        statusButton = button
        let rectInWindow = button.convert(button.bounds, to: nil)
        anchorRect = buttonWindow.convertToScreen(rectInWindow)
        screenVisibleFrame = buttonWindow.screen?.visibleFrame

        var size = hosting.preferredContentSize
        if size.width < 1 || size.height < 1 {
            size = hosting.view.fittingSize // first show, before any layout pass
        }
        // Initial frame lands without animation: the open is instant.
        lastAppliedSize = size
        panel.setFrame(anchoredFrame(for: size), display: true)
        installMonitors()
        // Key without activating (.nonactivatingPanel), as makeKey() did for
        // the popover window: Escape and resign-key dismissal need key.
        panel.makeKeyAndOrderFront(nil)
        model.popoverOnScreen = true
    }

    func close() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        removeMonitors()
        panel.orderOut(nil)
        isClosing = false
        // The tree stays alive in the hidden panel; stop the mark motion.
        model.popoverOnScreen = false
    }

    // MARK: - Geometry

    /// Top edge just under the button, left-aligned like a native menu
    /// (screen coords are bottom-left origin, hence minY - height), shifted
    /// left only when the right edge would leave the button's screen.
    private func anchoredFrame(for size: NSSize) -> NSRect {
        guard let anchor = anchorRect else {
            return NSRect(origin: panel.frame.origin, size: size)
        }
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height)
        if let visible = screenVisibleFrame {
            let maxX = visible.maxX - Self.screenEdgeInset
            if origin.x + size.width > maxX {
                origin.x = maxX - size.width
            }
        }
        return NSRect(origin: origin, size: size)
    }

    /// Coalesce KVO bursts and, critically, get OUT of the layout pass that
    /// fired the observation before touching the window frame.
    private func scheduleSizeUpdate() {
        guard !sizeUpdateScheduled else { return }
        sizeUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeUpdateScheduled = false
            self.applyPreferredSize()
        }
    }

    private func applyPreferredSize() {
        let size = hosting.preferredContentSize
        guard size.width > 1, size.height > 1 else { return }
        guard size != lastAppliedSize else { return }
        lastAppliedSize = size
        let frame = anchoredFrame(for: size)
        guard panel.isVisible else {
            panel.setFrame(frame, display: false)
            return
        }
        // The calm disclosure animates its layout at 0.2s easeInOut
        // (PopoverView.triageStack); match it so the window tracks the
        // content instead of jumping, re-anchoring the top edge in the
        // animated frame.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.panel.invalidateShadow()
        })
    }

    // MARK: - Outside-click dismissal (what .transient used to do)

    /// Both monitors are required: the global one sees clicks in other apps
    /// and on the desktop; clicks inside CCorn's own windows (e.g. the main
    /// window) never reach a global monitor, so a local one covers those.
    private func installMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                self?.handleClickElsewhere(event)
            }
        }
        if localMonitor == nil {
            // Also watches keyDown: Escape must close even when the hosting
            // view consumes the key before it reaches the panel's responder
            // overrides (the monitor sees events before dispatch).
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53, event.window === self.panel {
                        self.close()
                        return nil // consumed; nothing else should beep on it
                    }
                    return event
                }
                if event.window !== self.panel {
                    self.handleClickElsewhere(event)
                }
                return event
            }
        }
    }

    private func removeMonitors() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    /// Close on any outside click EXCEPT one on the status-item button: there
    /// the mouse-DOWN would close the panel, then the button's mouse-up action
    /// would see isVisible == false and immediately reopen, a close-then-
    /// reopen flicker. The AppDelegate toggle owns clicks on the button.
    private func handleClickElsewhere(_ event: NSEvent) {
        guard panel.isVisible else { return }
        if let button = statusButton, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil))
            if buttonRect.contains(screenPoint(of: event)) { return }
        }
        close()
    }

    /// Global-monitor events from other apps carry no window: their location
    /// is already in screen coordinates.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }
}
