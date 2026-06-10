import SwiftUI

/// Column layout shared by the header row and session rows so they stay
/// aligned. NAME and DIRECTORY flex equally; the rest are fixed.
enum SessionColumns {
    static let status: CGFloat = 92
    static let lastActive: CGFloat = 88
    static let actions: CGFloat = 28
}

/// Main panel: column headers + session rows, or the empty state
/// (docs/CCORN_SPEC.md sections 5.1 and 5.6).
struct SessionListView: View {
    @ObservedObject var model: AppModel

    /// Debug-only (CCORN_DEBUG_UI contains "empty"): force the empty state so
    /// the corn-cob identity moment can be verified without clearing real
    /// sessions. Same hook family as the AppDelegate's screenshot helpers.
    private let forceEmpty =
        ProcessInfo.processInfo.environment["CCORN_DEBUG_UI"]?.contains("empty") == true

    var body: some View {
        Group {
            if (model.hasScanned && model.rows.isEmpty) || forceEmpty {
                EmptyStateView()
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    private var list: some View {
        VStack(spacing: 0) {
            headerRow
            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        SessionRowView(row: row, model: model)
                        Rectangle()
                            .fill(Color(.separatorColor))
                            .frame(height: 0.5)
                    }
                }
            }
        }
    }

    /// 28px column header row: NAME — STATUS — DIRECTORY — LAST ACTIVE — (actions).
    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Status")
                .frame(width: SessionColumns.status, alignment: .leading)
            Text("Directory")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Last Active")
                .frame(width: SessionColumns.lastActive, alignment: .trailing)
            Color.clear
                .frame(width: SessionColumns.actions, height: 1)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .textCase(.uppercase)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 28)
        .background(Color(.controlBackgroundColor))
    }
}

/// Centered empty state (docs/CCORN_SPEC.md section 5.6). Both actions are
/// milestone-3 flows: present but disabled.
private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 0) {
            CornCobShape()
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5,
                                                            lineCap: .round,
                                                            lineJoin: .round))
                .frame(width: 48, height: 48)
                .padding(.bottom, 16)

            Text("No sessions found")
                .font(.title3.weight(.medium))
                .foregroundColor(.primary)
                .padding(.bottom, 8)

            Text("Add a watch directory or start a new Claude Code session")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.bottom, 16)

            HStack(spacing: 8) {
                Button {} label: {
                    Text("New Session")
                        .font(.subheadline.weight(.medium))
                        // Knockout text on the primary-action fill: dark-on-light
                        // in dark mode, light-on-dark in light mode. Color.white
                        // would vanish on the white fill dark mode produces.
                        .foregroundColor(Color(.windowBackgroundColor))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Color.primary)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.4)

                Button {} label: {
                    Text("Add Directory")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
