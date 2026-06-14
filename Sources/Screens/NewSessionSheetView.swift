import SwiftUI

/// New Session sheet (docs/CCORN_SPEC.md 6.3): native macOS sheet, 480px wide,
/// matching the import sheet's chrome. The folder is chosen first via
/// `NSOpenPanel`; this sheet collects the name, the permission mode (visible —
/// the one knob people vary per session), and, behind an Advanced disclosure,
/// the model / additional directories / extra args. Everything is seeded from
/// the Settings default (inherit → override).
struct NewSessionSheetView: View {
    @ObservedObject var flow: NewSessionFlowModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 0.5)
            content
                .padding(16)
            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 0.5)
            footer
                .padding(16)
        }
        .frame(width: 480)
        .background(Color(.windowBackgroundColor))
        // Click-away resigns a focused field instead of trapping focus until
        // Return; the fields write their binding live, so the value is already
        // captured. (The sheet is its own window, so the main window's resigner
        // does not reach it.)
        .endsEditingOnOutsideClick()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Session")
                .font(.title3.weight(.medium))
                .foregroundColor(.primary)
            Text("Start a Claude Code session in this folder")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            directoryRow
            existingSessionsNote
            nameField
            permissionPicker
            advanced
        }
    }

    // Passive awareness, not a gate: when the chosen folder already has live
    // sessions, surface the count so starting another is an informed choice.
    // Multiple sessions per directory is normal — Start Session proceeds either
    // way (the old blocking "Start Anyway" confirm is gone). Tracks Change…
    // because the count reads live off the flow's @Published directory.
    @ViewBuilder
    private var existingSessionsNote: some View {
        let count = flow.activeSessionsHere
        if count > 0 {
            Text("\(count) active session\(count == 1 ? "" : "s") in this folder")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var directoryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(flow.displayDirectory)
                .font(.subheadline.monospaced())
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Change…") { flow.changeDirectory() }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Leave blank to use Claude's session title", text: $flow.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var permissionPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Permission mode", selection: $flow.permissionMode) {
                ForEach(flow.selectableModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(flow.permissionMode.summary)
                .font(.caption)
                .foregroundColor(.secondary)
            if flow.isRoot {
                Text("Bypass modes are unavailable while CCorn is running as root.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Advanced

    // A custom disclosure (the app's pattern — see the popover), not
    // DisclosureGroup: DisclosureGroup animates its own content reveal on a
    // separate timeline from the sheet's auto-resize, so the two fight and the
    // expand looks janky.
    //
    // Do NOT wrap the toggle in withAnimation: animating the content height
    // *gradually* streams intermediate sizes to the auto-sizing sheet, which
    // chases each one with its own resize animation — that is the janky
    // desync. Snapping the state hands the sheet a single final size to animate
    // to once, so the rows are revealed/hidden cleanly by the growing/shrinking
    // sheet with the header pinned at the top. The chevron gets its own
    // (isolated) rotation, which doesn't drive the sheet size.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                flow.showAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(flow.showAdvanced ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: flow.showAdvanced)
                    Text("Advanced")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if flow.showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    modelField
                    additionalDirectories
                    extraArgsField
                }
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
            TextField("Account default (e.g. opus, sonnet)", text: $flow.modelText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var additionalDirectories: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional directories")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
            ForEach(flow.additionalDirectories, id: \.self) { dir in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text((dir as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        flow.removeDirectory(dir)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(dir)")
                }
            }
            Button("+ Add Directory") { flow.addDirectory() }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundColor(.primary)
        }
    }

    private var extraArgsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra arguments")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
            TextField("--example-flag value", text: $flow.extraArgsText)
                .textFieldStyle(.roundedBorder)
            Text("Passed to claude as-is, split on spaces. Advanced use only.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { flow.cancel() }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            FilledButton(title: "Start Session") { flow.start() }
        }
    }
}
