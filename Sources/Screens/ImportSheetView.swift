import SwiftUI

/// First-run import sheet (docs/CCORN_SPEC.md 5.4): native macOS sheet, 480px
/// wide, four states: discovery (checkboxes + an "Active" tag on live rows),
/// importing progress (locked list, per-row phase), the active-session
/// warning (an NSAlert raised by the flow model), and complete.
struct ImportSheetView: View {
    @ObservedObject var flow: ImportFlowModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 0.5)
            list
            footer
                .padding(16)
        }
        .frame(width: 480)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch flow.stage {
            case .discovery, .importing:
                Text("Found \(flow.items.count) session\(flow.items.count == 1 ? "" : "s")")
                    .font(.title3.weight(.medium))
                    .foregroundColor(.primary)
                Text("Import them into CCorn to manage them here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            case .complete:
                Text("All done")
                    .font(.title3.weight(.medium))
                    .foregroundColor(.primary)
                Text("\(flow.importedCount) session\(flow.importedCount == 1 ? " is" : "s are") now managed by CCorn")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            ForEach($flow.items) { $item in
                ImportRowView(item: $item, stage: flow.stage)
                Rectangle()
                    .fill(Color(.separatorColor))
                    .frame(height: 0.5)
            }
            if flow.stage == .importing {
                Text("Importing \(min(flow.progress.done + 1, flow.progress.total)) of \(flow.progress.total)…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch flow.stage {
        case .discovery:
            HStack {
                Button("Skip for Now") { flow.skip() }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                FilledButton(title: "Import Selected (\(flow.selectedCount))",
                             disabled: flow.selectedCount == 0) {
                    flow.startImport()
                }
            }
        case .importing:
            HStack {
                Spacer()
                FilledButton(title: "Importing…", disabled: true) {}
                Spacer()
            }
        case .complete:
            FilledButton(title: "Close", fullWidth: true) { flow.close() }
        }
    }
}

/// One 36px import row. Discovery: checkbox + neutral unmanaged ring + name +
/// path + an "Active" tag on live rows only (an unmanaged session's activity
/// state is unknowable without a pane; the row claims liveness, not Working/
/// Idle — see `ImportRowLiveness`). Importing: phase icon replaces the ring,
/// the current row highlights, done rows dim to 60%.
private struct ImportRowView: View {
    @Binding var item: ImportFlowModel.Item
    let stage: ImportFlowModel.Stage

    var body: some View {
        HStack(spacing: 8) {
            if stage == .discovery {
                Toggle("", isOn: $item.selected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                phaseIndicator
            } else {
                phaseIndicator
                    .padding(.leading, 4)
            }

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text((item.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            badge
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(item.phase == .importing || item.phase == .waitingForIdle
                    ? Color(.controlBackgroundColor) : .clear)
        .opacity(rowOpacity)
    }

    private var rowOpacity: Double {
        switch item.phase {
        case .done: return 0.6
        case .pending: return stage == .importing ? 0.6 : 1
        case .waitingForIdle, .importing, .failed: return 1
        }
    }

    /// Discovery: the neutral unmanaged ring, the same hollow mark a discovered
    /// row carries everywhere (we can't read an unmanaged session's state, so
    /// the dot claims nothing; liveness rides the "Active" tag instead).
    /// Importing: grey dot while waiting (5.4 State 2), then spinner / checkmark
    /// / xmark by phase.
    @ViewBuilder
    private var phaseIndicator: some View {
        switch (stage, item.phase) {
        case (.discovery, _):
            // 1px ring (not the 0.5px chrome hairline): a 0.5px ring is
            // sub-pixel at 7px and the dot vanishes. Matches `StatusMark`'s
            // unmanaged branch.
            Circle()
                .strokeBorder(StatusPalette.unmanagedOutline, lineWidth: 1)
                .frame(width: 7, height: 7)
        case (_, .pending):
            Circle()
                .fill(StatusPalette.importPending)
                .frame(width: 7, height: 7)
        case (_, .waitingForIdle), (_, .importing):
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case (_, .done):
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(StatusPalette.running)
        case (_, .failed):
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(StatusPalette.dead)
        }
    }

    /// The trailing slot. During import, the live "Waiting for idle" pill (5.4
    /// State 3). During discovery, a quiet "Active" caption on live rows only,
    /// the same greyscale metadata idiom as the row's "Local"/"Take over" tags;
    /// dormant rows make no claim. No "Working"/"Idle" pill: CCorn cannot read
    /// an unmanaged session's pane, so it never claims an activity state.
    @ViewBuilder
    private var badge: some View {
        if item.phase == .waitingForIdle {
            pill(text: "Waiting for idle", fill: StatusPalette.attention)
        } else if stage == .discovery, let tag = item.liveness.tagText {
            Text(tag)
                .font(.caption)
                .foregroundColor(.secondary)
                .help("A live Claude process is running in this session")
        }
    }

    private func pill(text: String, fill: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill)
            .cornerRadius(4)
    }
}
