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
            nameField
            permissionPicker
            advanced
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

    private var advanced: some View {
        DisclosureGroup(isExpanded: $flow.showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                modelField
                additionalDirectories
                extraArgsField
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
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
