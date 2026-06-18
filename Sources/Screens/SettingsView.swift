import SwiftUI
import ServiceManagement

/// Settings (docs/CCORN_SPEC.md 5.5): single screen, three Form sections, no
/// tabs. Lives in the SwiftUI `Settings` scene, so it renders as a native
/// preferences window automatically.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: SessionEngine

    /// Mirrors SMAppService.mainApp; the toggle is the UI for the system state.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    init(model: AppModel) {
        self.model = model
        self.engine = model.engine
    }

    /// Stale threshold options (5.5): 1, 2, 4, 8, 24 hours.
    private static let thresholdOptions: [TimeInterval] = [3600, 7200, 14400, 28800, 86400]

    var body: some View {
        Form {
            watchDirectoriesSection
            appearanceSection
            behaviorSection
            launchDefaultsSection
            statusLegendSection
            aboutSection
        }
        .formStyle(.grouped)
        // Fixed width holds the 480pt design column; height is flexible with a
        // floor so the window resizes vertically and the Form scrolls its own
        // content once it outgrows the window. This drops the old
        // `.fixedSize(vertical:)`, which pinned the window to the Form's full
        // height: the window could only grow to fit, never scroll or shrink
        // below the screen. The window's resize handle, width lock, and size
        // bounds are applied by SettingsWindowConfigurator below, paired with
        // `.windowResizability(.contentMinSize)` on the Settings scene.
        .frame(width: 480)
        .frame(minHeight: 400, idealHeight: 640, maxHeight: .infinity)
        .background(SettingsWindowConfigurator())
        .onAppear(perform: snapLegacyThreshold)
    }

    /// A hand-edited or pre-picker value (e.g. the old 600s default) would
    /// display as the nearest option while the engine kept the raw value,
    /// which is misleading. Persist the snap once so display and behavior agree.
    private func snapLegacyThreshold() {
        let snapped = Self.nearestThreshold(engine.settings.staleThresholdSeconds)
        guard snapped != engine.settings.staleThresholdSeconds else { return }
        var settings = engine.settings
        settings.staleThresholdSeconds = snapped
        model.applySettings(settings)
    }

    // MARK: Section 1: Watch Directories

    private var watchDirectoriesSection: some View {
        Section("Watch Directories") {
            ForEach(engine.settings.watchDirectories, id: \.self) { dir in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text((dir as NSString).abbreviatingWithTildeInPath)
                        .font(.subheadline.monospaced())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        removeDirectory(dir)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(dir)")
                }
            }

            Button {
                addDirectory()
            } label: {
                Text("+ Add Directory")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            Text("CCorn scans these folders for Claude Code sessions")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Remove with the warning alert (5.5). Watch directories scope discovery
    /// only, so the rows that actually hide are the *unmanaged* ones under the
    /// directory; sessions CCorn manages (or has records for) stay listed.
    private func removeDirectory(_ dir: String) {
        let canonical = SessionDiscovery.canonicalize(SessionDiscovery.expandTilde(dir))
        let hidden = model.rows.filter {
            $0.state == .unmanaged && !$0.path.isEmpty
                && SessionDiscovery.isPath($0.path, inside: canonical)
        }.count
        let display = (dir as NSString).abbreviatingWithTildeInPath
        guard Alerts.confirm(
            title: "Remove \(display)?",
            message: "Hides \(hidden) session\(hidden == 1 ? "" : "s") from the list; they keep running in the background.",
            action: "Remove",
            destructive: true) else { return }
        var settings = engine.settings
        settings.watchDirectories.removeAll { $0 == dir }
        model.applySettings(settings)
    }

    /// Duplicates silently ignored (section 8).
    private func addDirectory() {
        guard let dir = Alerts.pickFolder(prompt: "Add Directory") else { return }
        var settings = engine.settings
        guard !settings.watchDirectories.contains(dir) else { return }
        settings.watchDirectories.append(dir)
        model.applySettings(settings)
    }

    // MARK: Section: Appearance

    /// Forces the whole app light or dark, or follows the system. Bound straight
    /// to the model-owned setting; its didSet persists the choice and applies it
    /// immediately via NSApp.appearance (AppModel.applyAppearance), so every
    /// window flips, the menu-bar popover included (its palette is appearance-
    /// paired). Menu picker to match the other Settings pickers.
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Window appearance", selection: $model.appearanceMode) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    // MARK: Section 2: Behavior

    private var behaviorSection: some View {
        Section("Behavior") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Revert the toggle; the system state is the truth.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        Alerts.info(title: "Could not update Login Items",
                                    message: error.localizedDescription)
                    }
                }

            Toggle("Auto-restart sessions on launch", isOn: Binding(
                get: { engine.settings.autoRestartOnLaunch },
                set: { value in
                    var settings = engine.settings
                    settings.autoRestartOnLaunch = value
                    model.applySettings(settings)
                }
            ))

            Toggle("Keep window in front of other apps", isOn: Binding(
                get: { engine.settings.keepWindowInFront },
                set: { value in
                    var settings = engine.settings
                    settings.keepWindowInFront = value
                    model.applySettings(settings)
                }
            ))

            // Drives `tmux set-option -t ccorn mouse` on CCorn's session (and
            // its Open-in-Terminal view sessions) only, never the tmux global,
            // so the user's own `set -g mouse` for other tmux work is untouched.
            // The second Text renders as the toggle's secondary caption in a
            // grouped Form, the place to spell out the tradeoff.
            Toggle(isOn: Binding(
                get: { engine.settings.mouseMode },
                set: { value in
                    var settings = engine.settings
                    settings.mouseMode = value
                    model.applySettings(settings)
                }
            )) {
                Text("Scroll wheel scrolls in sessions")
                Text("On, the scroll wheel scrolls. Off, native terminal text selection is simpler, but the wheel acts as arrow keys in full-screen views.")
            }

            Picker("Clicking a session opens", selection: Binding(
                get: { engine.settings.clickAction },
                set: { value in
                    var settings = engine.settings
                    settings.clickAction = value
                    model.applySettings(settings)
                }
            )) {
                Text("Terminal").tag(SessionClickAction.terminal)
                Text("Browser").tag(SessionClickAction.browser)
            }

            Picker("Stale session threshold", selection: Binding(
                get: { Self.nearestThreshold(engine.settings.staleThresholdSeconds) },
                set: { value in
                    var settings = engine.settings
                    settings.staleThresholdSeconds = value
                    model.applySettings(settings)
                }
            )) {
                Text("1 hour").tag(TimeInterval(3600))
                Text("2 hours").tag(TimeInterval(7200))
                Text("4 hours").tag(TimeInterval(14400))
                Text("8 hours").tag(TimeInterval(28800))
                Text("24 hours").tag(TimeInterval(86400))
            }
        }
    }

    /// A persisted value from an older build may not be one of the options;
    /// the picker shows the nearest so the selection is never blank.
    private static func nearestThreshold(_ value: TimeInterval) -> TimeInterval {
        thresholdOptions.min { abs($0 - value) < abs($1 - value) } ?? 3600
    }

    // MARK: Section: New Session Defaults

    /// Global defaults new sessions inherit (the New Session sheet seeds its
    /// per-session override from these). Discrete controls only (the Picker
    /// idiom of the Behavior section), so a keystroke never churns settings +
    /// rediscovery. Per-session free text (add-dirs, extra args) lives in the
    /// sheet, not here.
    private var launchDefaultsSection: some View {
        Section("New Session Defaults") {
            // The summary rides in each Picker's label closure: the second Text
            // renders as the grouped Form row's secondary caption (the
            // scroll-wheel toggle's idiom above), so it stays anchored under the
            // control it describes instead of floating to the bottom of the
            // section, where the permission summary read as the remote-control
            // note. The permission summary is dynamic per mode; the remote one
            // flips on the chosen value.
            Picker(selection: Binding(
                get: { engine.settings.defaultLaunchConfig.permissionMode },
                set: { value in
                    var settings = engine.settings
                    settings.defaultLaunchConfig.permissionMode = value
                    model.applySettings(settings)
                }
            )) {
                ForEach(CCPermissionMode.selectable(isRoot: LaunchEnvironment.isRoot), id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Text("Permission mode")
                Text(engine.settings.defaultLaunchConfig.permissionMode.summary)
            }

            // Seeds the New Session sheet's Remote Control checkbox so a user who
            // works local doesn't uncheck it every time. A learned
            // `rcKnownUnavailable` verdict still forces local on top of this
            // (CCornSettings.effectiveDefaultConfig); the stored choice here is
            // left intact and resumes once the account proves RC-capable again.
            Picker(selection: Binding(
                get: { engine.settings.defaultLaunchConfig.remoteControl },
                set: { value in
                    var settings = engine.settings
                    settings.defaultLaunchConfig.remoteControl = value
                    model.applySettings(settings)
                }
            )) {
                Text("On").tag(true)
                Text("Off").tag(false)
            } label: {
                Text("Remote control")
                Text(engine.settings.defaultLaunchConfig.remoteControl
                     ? "New sessions sync to claude.ai and your phone, and get a per-session URL."
                     : "New sessions start local: no remote or phone access, and no per-session URL.")
            }
        }
    }

    // MARK: Section: Status Legend

    /// What every status mark means, in one place (review: five of the nine
    /// states are color-only on a row, so a first-time user had to hover each
    /// dot to learn it). Each row renders the real `StatusMark` and the real
    /// `displayName`, so the legend reads exactly what a session row shows and
    /// cannot drift from the palette.
    private var statusLegendSection: some View {
        Section("Status Legend") {
            ForEach(StatusPresentation.legendOrder, id: \.self) { presentation in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusMark(presentation: presentation)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentation.displayName)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text(presentation.legendDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                }
            }
        }
    }

    // MARK: Section 3: About

    private var aboutSection: some View {
        Section("About") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—"
            Text("Version \(version)")
                .font(.caption)
                .foregroundColor(.secondary)
            Link("View on GitHub",
                 destination: URL(string: "https://github.com/sudoLuko/ccorn")!)
                .font(.caption)
                .foregroundColor(.accentColor)
            // OpenMoji is CC BY-SA 4.0; attribution must appear somewhere
            // user-facing (see design-assets/app-icon/ICON_CREDITS.md). The
            // markdown links render tappable in a Text/LocalizedStringKey.
            Text("App icon: ear-of-corn glyph from [OpenMoji](https://openmoji.org), [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Pins the Settings window to the 480pt design width while leaving the height
/// freely resizable. There is no `windowResizability` value that locks one axis
/// on a `Settings` window: `.contentSize` clamps both axes (so the window can't
/// grow taller either), and `.contentMinSize` frees both maximums (so the
/// window grows sideways and the 480 content floats with gutters). A manually
/// set `NSWindow.contentMaxSize` is overridden by the resizability policy on
/// each layout, so it can't hold the width. Clamping the proposed frame in
/// `windowWillResize(_:to:)` is the one hook the policy doesn't override; it
/// fires on every live user drag and we force the width back to 480.
///
/// Every other delegate message is forwarded to SwiftUI's original window
/// delegate (captured before we take over), so the Settings scene's own
/// lifecycle handling is untouched.
private final class FixedWidthWindowDelegate: NSObject, NSWindowDelegate {
    static let width: CGFloat = 480
    weak var forwarding: NSWindowDelegate?

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Let the original delegate constrain height first (if it cares), then
        // force the width. No horizontal window chrome, so frame width == the
        // 480 content width.
        var size = frameSize
        if let forwarding, forwarding.responds(to: #selector(windowWillResize(_:to:))) {
            size = forwarding.windowWillResize?(sender, to: frameSize) ?? frameSize
        }
        size.width = Self.width
        return size
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwarding?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forwarding, forwarding.responds(to: aSelector) { return forwarding }
        return super.forwardingTarget(for: aSelector)
    }
}

/// The Settings scene's window is created by SwiftUI, so there is no
/// controller to configure chrome on: this reaches the hosting window to
/// configure it directly.
///
/// 1. Hides the title-bar TEXT, the same treatment as the main and onboarding
///    windows, whose identity lives in their content, not the titlebar. The
///    title STRING stays whatever the scene set (it contains "Settings"), so
///    DebugStage's window lookup keeps working.
/// 2. Inserts `.resizable` into the style mask. SwiftUI builds a Settings
///    window WITHOUT it (a preferences window is fixed by default), and
///    `windowResizability` alone never adds it, so the handle has to be set by
///    hand for the window to resize at all.
/// 3. Installs `FixedWidthWindowDelegate` to lock the width to 480 (see there).
///
/// Re-run in `updateNSView` so a relayout can't quietly drop any of it; the
/// delegate install is guarded so it captures SwiftUI's delegate once, not
/// itself.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    final class ConfiguringView: NSView {
        let widthLock = FixedWidthWindowDelegate()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.styleMask.insert(.resizable)
            if window.delegate !== widthLock {
                widthLock.forwarding = window.delegate
                window.delegate = widthLock
            }
            // A frame saved before the width lock (when the window could be
            // dragged wide) is restored on open, so the window appears far too
            // wide until the first relayout snaps it to the 480 content width.
            // `windowWillResize` only fires on a drag, not on open, so correct
            // the restored width here, keeping the restored height and origin,
            // and the window opens at its natural width.
            if window.frame.width != FixedWidthWindowDelegate.width {
                var frame = window.frame
                frame.size.width = FixedWidthWindowDelegate.width
                window.setFrame(frame, display: false)
            }
        }
    }

    func makeNSView(context: Context) -> ConfiguringView { ConfiguringView() }
    func updateNSView(_ nsView: ConfiguringView, context: Context) { nsView.configureWindow() }
}
