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
            behaviorSection
            launchDefaultsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowTitleTextHider())
        .onAppear(perform: snapLegacyThreshold)
    }

    /// A hand-edited or pre-picker value (e.g. the old 600s default) would
    /// display as the nearest option while the engine kept the raw value —
    /// misleading. Persist the snap once so display and behavior agree.
    private func snapLegacyThreshold() {
        let snapped = Self.nearestThreshold(engine.settings.staleThresholdSeconds)
        guard snapped != engine.settings.staleThresholdSeconds else { return }
        var settings = engine.settings
        settings.staleThresholdSeconds = snapped
        model.applySettings(settings)
    }

    // MARK: Section 1 — Watch Directories

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
    /// directory — sessions CCorn manages (or has records for) stay listed.
    private func removeDirectory(_ dir: String) {
        let canonical = SessionDiscovery.canonicalize(SessionDiscovery.expandTilde(dir))
        let hidden = model.rows.filter {
            $0.state == .unmanaged && !$0.path.isEmpty
                && SessionDiscovery.isPath($0.path, inside: canonical)
        }.count
        let display = (dir as NSString).abbreviatingWithTildeInPath
        guard Alerts.confirm(
            title: "Remove \(display)?",
            message: "This will hide \(hidden) session\(hidden == 1 ? "" : "s") from the list. Sessions will continue running in the background.",
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

    // MARK: Section 2 — Behavior

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
            // its Open-in-Terminal view sessions) only — never the tmux global,
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

    // MARK: Section — New Session Defaults

    /// Global defaults new sessions inherit (the New Session sheet seeds its
    /// per-session override from these). Discrete controls only — the Picker
    /// idiom of the Behavior section — so a keystroke never churns settings +
    /// rediscovery. Per-session free text (custom model, add-dirs, extra args)
    /// lives in the sheet, not here.
    private var launchDefaultsSection: some View {
        Section("New Session Defaults") {
            Picker("Permission mode", selection: Binding(
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
            }

            Picker("Model", selection: Binding(
                get: { engine.settings.defaultLaunchConfig.model ?? "" },
                set: { value in
                    var settings = engine.settings
                    settings.defaultLaunchConfig.model = value.isEmpty ? nil : value
                    model.applySettings(settings)
                }
            )) {
                Text("Account default").tag("")
                Text("Opus").tag("opus")
                Text("Sonnet").tag("sonnet")
                Text("Fable").tag("fable")
            }

            Text(engine.settings.defaultLaunchConfig.permissionMode.summary)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Section 3 — About

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
            // OpenMoji is CC BY-SA 4.0 — attribution must appear somewhere
            // user-facing (see design-assets/app-icon/ICON_CREDITS.md). The
            // markdown links render tappable in a Text/LocalizedStringKey.
            Text("App icon: ear-of-corn glyph from [OpenMoji](https://openmoji.org), [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// The Settings scene's window is created by SwiftUI, so there is no
/// controller to configure chrome on: this reaches the hosting window and
/// hides the title-bar TEXT — the same treatment as the main and onboarding
/// windows, whose identity lives in their content, not the titlebar. The
/// title STRING stays whatever the scene set (it contains "Settings"), so
/// DebugStage's window lookup keeps working.
private struct WindowTitleTextHider: NSViewRepresentable {
    final class HidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }

    func makeNSView(context: Context) -> HidingView { HidingView() }
    func updateNSView(_ nsView: HidingView, context: Context) {}
}
