import SwiftUI

/// Trailing fixed-width columns shared by every row so the right edge stays
/// aligned. NAME and DIRECTORY flex equally.
enum SessionColumns {
    static let lastActive: CGFloat = 88
    static let actions: CGFloat = 28
}

/// Main panel (docs/CCORN_SPEC.md sections 5.1, 5.6, 5.9). Managed sessions
/// are the primary content and render first, with no chrome above them — the
/// sidebar already names the view. Unmanaged sessions discovered on the system
/// are ambient context: they sit below a collapsible DISCOVERED divider,
/// visibly de-emphasized, so a glance lands on your sessions first.
struct SessionListView: View {
    @ObservedObject var model: AppModel
    var archived = false

    /// Collapsed state of the DISCOVERED section, persisted across launches.
    @AppStorage("discoveredSectionCollapsed") private var discoveredCollapsed = false

    /// Debug-only (CCORN_DEBUG_UI contains "empty"): force the empty state so
    /// the corn-cob identity moment can be verified without clearing real
    /// sessions. Same hook family as the AppDelegate's screenshot helpers.
    private let forceEmpty =
        ProcessInfo.processInfo.environment["CCORN_DEBUG_UI"]?.contains("empty") == true

    private var managedRows: [SessionRow] {
        archived ? model.archivedRows : model.managedRows
    }

    private var discoveredRows: [SessionRow] {
        archived ? [] : model.unmanagedRows
    }

    var body: some View {
        Group {
            if (model.hasScanned && managedRows.isEmpty && discoveredRows.isEmpty) || forceEmpty {
                EmptyStateView(model: model, archived: archived)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if managedRows.isEmpty {
                    noManagedHint
                } else {
                    ForEach(managedRows) { row in
                        SessionRowView(row: row, model: model)
                        rowDivider
                    }
                }

                if !discoveredRows.isEmpty {
                    discoveredHeader
                    if !discoveredCollapsed {
                        ForEach(discoveredRows) { row in
                            SessionRowView(row: row, model: model)
                            rowDivider
                        }
                    }
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.2),
                       value: (managedRows + discoveredRows).map(\.id))
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    /// Divider between your sessions and ambient discovery. Click to collapse;
    /// the chevron and count keep the collapsed state legible.
    private var discoveredHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                discoveredCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("Discovered")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text("\(discoveredRows.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(discoveredCollapsed ? -90 : 0))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, managedRows.isEmpty ? 0 : 12)
        .help("Sessions found on this Mac that CCorn doesn't manage yet")
    }

    /// Managed list is empty but discovery found sessions: a quiet inline
    /// hint, not the full empty state — the discovered rows below are the
    /// likely next step.
    private var noManagedHint: some View {
        VStack(spacing: 8) {
            Text("No sessions yet")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
            Text("Start a new session, or import one below")
                .font(.caption)
                .foregroundColor(.secondary)
            FilledButton(title: "New Session") {
                model.newSession()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// Centered empty state (docs/CCORN_SPEC.md 5.6; 5.9 for the archived view,
/// which gets the mark and title but no action buttons). The corn emoji plus
/// the tagline are the one place CCorn's identity shows (review item 3: the
/// emoji is the in-app mark; vector assets are reserved for the app icon and
/// menu-bar glyph).
private struct EmptyStateView: View {
    @ObservedObject var model: AppModel
    var archived = false

    var body: some View {
        VStack(spacing: 0) {
            Text("🌽")
                .font(.system(size: 40))
                .padding(.bottom, 16)
                .accessibilityHidden(true)

            Text(archived ? "No archived sessions" : "No sessions found")
                .font(.title3.weight(.medium))
                .foregroundColor(.primary)
                .padding(.bottom, 8)

            if archived {
                Text("Sessions you archive are kept here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Add a watch directory or start a new Claude Code session")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.bottom, 16)

                HStack(spacing: 8) {
                    FilledButton(title: "New Session") {
                        model.newSession()
                    }

                    Button {
                        model.addWatchDirectory()
                    } label: {
                        Text("Add Directory")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 24)

                Text("All your kernels, one cob.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
