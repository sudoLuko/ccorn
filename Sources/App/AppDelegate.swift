import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let windowController = MainWindowController()
    private let onboarding = OnboardingWindowController()
    /// Created in init (not didFinishLaunching) so the SwiftUI `Settings` scene
    /// can reference it the moment the scene body is built.
    let model: AppModel
    #if DEBUG
    private var debugChannel: DebugCommandChannel?
    #endif

    override init() {
        model = AppModel(engine: SessionEngine())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory by default: no Dock icon, no Cmd+Tab. Switches to .regular
        // while a regular window is open (MainWindowController).
        NSApp.setActivationPolicy(.accessory)

        model.openMainWindow = { [weak self] in self?.openMainWindow() }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }

        configureStatusItem()
        configurePopover()

        Task { await launchSequence() }

        // Debug-only hook so screenshot-based verification can open the UI
        // without clicking the status item (no effect unless the env var is set).
        let debugUI = ProcessInfo.processInfo.environment["CCORN_DEBUG_UI"] ?? ""
        if debugUI.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
        #if DEBUG
        if debugUI.contains("cmd") {
            debugChannel = DebugCommandChannel(model: model)
            debugChannel?.start()
        }
        #endif
        if debugUI.contains("window") { openMainWindow() }
        if debugUI.contains("popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // menu-bar app: closing the main window must not quit
    }

    // MARK: - Launch sequence (flow 6.1)

    /// Dependency gates first — the app halts until tmux and claude exist —
    /// then onboarding (first launch) or a normal engine start.
    private func launchSequence() async {
        await ensureDependencies()
        if model.onboardingNeeded {
            onboarding.show(model: model)
            // model.completeOnboarding (wired in OnboardingView) starts the
            // engine, opens the main window, and triggers the import sheet.
        } else {
            NotificationManager.shared.requestPermission()
            model.start()
        }
    }

    /// Section 8 dependency gates. Each missing dependency raises a modal; the
    /// user paces the re-checks by dismissing it. After kicking off a Homebrew
    /// install, poll quietly instead of re-alerting every few seconds.
    private func ensureDependencies() async {
        let engine = model.engine
        while true {
            let deps = await Task.detached { engine.checkDependencies() }.value
            if deps.tmuxInstalled && deps.claudeInstalled { return }

            if !deps.tmuxInstalled {
                if deps.brewPath != nil {
                    if Alerts.choice(title: "CCorn requires tmux",
                                     message: "Install it with Homebrew?",
                                     primary: "Install",
                                     secondary: "Check Again") {
                        runInTerminal("brew install tmux")
                        await waitForBinary("tmux")
                    }
                } else {
                    if !Alerts.choice(title: "CCorn requires tmux",
                                      message: "Visit brew.sh to install Homebrew first, then relaunch CCorn or click Check Again.",
                                      primary: "Check Again",
                                      secondary: "Open brew.sh") {
                        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                    }
                }
            } else if !deps.claudeInstalled {
                if !Alerts.choice(title: "Claude Code is not installed",
                                  message: "Install the Claude Code CLI, then click Check Again.",
                                  primary: "Check Again",
                                  secondary: "Open Install Docs") {
                    NSWorkspace.shared.open(
                        URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                }
            }
        }
    }

    /// Quiet poll (no modal spam) while a Homebrew install runs in Terminal;
    /// gives up after 15 minutes and falls back to the alert loop.
    private func waitForBinary(_ binary: String) async {
        let runner = model.engine.runner
        for _ in 0..<300 {
            let found = await Task.detached { runner.which(binary) != nil }.value
            if found { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Visible Terminal window running an install command (section 8: "Install
    /// button runs `brew install tmux` in a visible terminal").
    private func runInTerminal(_ command: String) {
        let runner = model.engine.runner
        Task.detached {
            let script = """
            tell application "Terminal"
                do script "\(command)"
                activate
            end tell
            """
            runner.run("osascript", ["-e", script])
        }
    }

    // MARK: - Status item + popover

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = CornIcon.menuBarImage // template: macOS tints it
            button.action = #selector(statusItemClicked)
            button.target = self
            // Left click toggles the popover; right click opens the main window
            // (docs/CCORN_SPEC.md section 5.1).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func configurePopover() {
        popover.behavior = .transient
        // The popover is fixed dark regardless of system appearance.
        popover.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    @objc private func statusItemClicked() {
        // Right-click OR control-click (the system-wide secondary-click alias)
        // opens the main window; plain left click toggles the popover.
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            openMainWindow()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Before onboarding completes there is no usable main window — route every
    /// "open" request to the onboarding card instead (it is the required flow).
    private func openMainWindow() {
        popover.performClose(nil)
        if model.onboardingNeeded {
            onboarding.show(model: model)
            return
        }
        windowController.show(model: model)
    }
}
