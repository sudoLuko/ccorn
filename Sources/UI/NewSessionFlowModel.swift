import AppKit
import Foundation

/// Backing model for the New Session sheet (flow 6.3). Seeded from the global
/// default launch config (Settings); the user names the session and optionally
/// overrides the launch flags before starting. Held by `AppModel` and presented
/// via `.sheet(item:)`, the same hosting pattern as `ImportFlowModel`.
@MainActor
final class NewSessionFlowModel: ObservableObject, Identifiable {
    /// Stable identity for `.sheet(item:)`. nonisolated so SwiftUI can read it
    /// off the main actor when diffing the item binding.
    nonisolated let id = UUID().uuidString

    /// Canonicalized target directory (picked before the sheet opened; the
    /// Change… button re-picks).
    @Published var directory: String
    @Published var name: String = ""
    @Published var permissionMode: CCPermissionMode
    @Published var additionalDirectories: [String]
    /// Raw extra-args text; whitespace-split into tokens when the session starts
    /// (the advanced escape hatch: one flag/value per token, no quoting).
    @Published var extraArgsText: String
    /// Launch with remote control (`--rc`). Checked = remote (the default and
    /// CCorn's historical behavior); unchecked = a local session with no remote
    /// or phone access and no per-session URL.
    @Published var remoteControl: Bool
    @Published var showAdvanced = false

    private weak var model: AppModel?

    /// Running as root: bypass modes are unavailable (the CLI refuses them).
    let isRoot = LaunchEnvironment.isRoot

    init(directory: String, defaultConfig: SessionLaunchConfig, model: AppModel) {
        self.directory = directory
        // A bypass default can't launch under root; fall back to the safe mode
        // so the picker never opens on an unavailable selection.
        self.permissionMode = (LaunchEnvironment.isRoot && defaultConfig.permissionMode.involvesBypass)
            ? .auto : defaultConfig.permissionMode
        self.additionalDirectories = defaultConfig.additionalDirectories
        self.extraArgsText = defaultConfig.extraArgs.joined(separator: " ")
        self.remoteControl = defaultConfig.remoteControl
        self.model = model
    }

    /// Permission modes the picker offers (bypass dropped under root).
    var selectableModes: [CCPermissionMode] { CCPermissionMode.selectable(isRoot: isRoot) }

    /// Home-relative folder display ("~/dev/ccorn").
    var displayDirectory: String { (directory as NSString).abbreviatingWithTildeInPath }

    /// Sessions already alive in the chosen folder; a passive heads-up shown in
    /// the sheet, not a gate. Read live from the model so it tracks the Change…
    /// button re-picking the directory (`directory` is @Published).
    var activeSessionsHere: Int { model?.activeSessionCount(in: directory) ?? 0 }

    /// The per-session override assembled from the fields.
    var finalConfig: SessionLaunchConfig {
        return SessionLaunchConfig(
            permissionMode: permissionMode,
            additionalDirectories: additionalDirectories,
            extraArgs: extraArgsText
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init),
            remoteControl: remoteControl)
    }

    /// nil = fall through to Claude's AI session title (an empty typed name).
    var finalTitle: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func changeDirectory() {
        guard let dir = Alerts.pickFolder(prompt: "Choose Folder") else { return }
        directory = SessionDiscovery.canonicalize(dir)
    }

    func addDirectory() {
        guard let dir = Alerts.pickFolder(prompt: "Add Directory") else { return }
        let canonical = SessionDiscovery.canonicalize(dir)
        guard !additionalDirectories.contains(canonical) else { return }
        additionalDirectories.append(canonical)
    }

    func removeDirectory(_ dir: String) {
        additionalDirectories.removeAll { $0 == dir }
    }

    func start() {
        model?.startConfiguredSession(directory: directory, title: finalTitle, config: finalConfig)
    }

    func cancel() {
        model?.dismissNewSession()
    }
}
