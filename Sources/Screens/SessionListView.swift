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
    var nav: SidebarNav = .allSessions

    /// Collapsed state of the DISCOVERED section, persisted across launches.
    @AppStorage("discoveredSectionCollapsed") private var discoveredCollapsed = false

    /// Debug-only (CCORN_DEBUG_UI contains "empty"): force the empty state so
    /// the corn-cob identity moment can be verified without clearing real
    /// sessions. Same hook family as the AppDelegate's screenshot helpers.
    #if DEBUG
    private let forceEmpty =
        ProcessInfo.processInfo.environment["CCORN_DEBUG_UI"]?.contains("empty") == true
    #else
    private let forceEmpty = false
    #endif

    private var archived: Bool { nav == .archived }

    /// The list's source per sidebar view — All Sessions, Archived, or one
    /// group's members (record-backed, non-archived).
    private var managedRows: [SessionRow] {
        switch nav {
        case .allSessions: return model.managedRows
        case .archived: return model.archivedRows
        case .group(let id): return model.groupRows(id: id)
        }
    }

    /// Ambient discoveries belong to All Sessions only: groups are
    /// record-backed, and the archived view is records by definition.
    private var discoveredRows: [SessionRow] {
        nav == .allSessions ? model.unmanagedRows : []
    }

    var body: some View {
        Group {
            if (model.hasScanned && managedRows.isEmpty && discoveredRows.isEmpty) || forceEmpty {
                EmptyStateView(model: model, nav: nav)
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
        // Fresh identity per sidebar view (F2): a nav switch swaps the whole
        // row set, and without this the ids animation above plays it as a
        // cross-view slide. New subtree = instant swap; within-view row
        // changes still animate. Scroll position resetting on a nav change
        // is the correct behavior, not a cost.
        .id(nav)
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

/// Centered empty state (docs/CCORN_SPEC.md 5.6; 5.9 for the archived view
/// and 5.11 for an empty group, which get the mark, title, and a hint but no
/// action buttons). The corn glyph plus the tagline are the one place
/// CCorn's identity shows: the shared OpenMoji corn (CornMark), the same
/// artwork as the app icon, drawn from one bundled asset everywhere in-app.
private struct EmptyStateView: View {
    @ObservedObject var model: AppModel
    var nav: SidebarNav = .allSessions

    private var archived: Bool { nav == .archived }
    private var isGroup: Bool {
        if case .group = nav { return true }
        return false
    }

    private var title: String {
        switch nav {
        case .allSessions: return "No sessions found"
        case .archived: return "No archived sessions"
        case .group: return "No sessions in this group"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            CornMark(size: 40)
                .padding(.bottom, 16)

            Text(title)
                .font(.title3.weight(.medium))
                .foregroundColor(.primary)
                .padding(.bottom, 8)

            if isGroup {
                Text("Add sessions from a session's ⋯ menu → Groups")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if archived {
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
