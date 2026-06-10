import SwiftUI

/// One 36px session row (docs/CCORN_SPEC.md section 5.1): status dot (+ warning
/// indicator), name, status label, directory, last active, hover-only `…`
/// button. Single click selects; double click = Open in Browser (disabled when
/// remote control is inactive); right-click / `…` shows the NSMenu. Rename
/// swaps the name for an inline TextField (5.8) with the error caption below.
/// Archived rows render muted with the empty dot (5.9).
struct SessionRowView: View {
    let row: SessionRow
    @ObservedObject var model: AppModel

    @State private var hovering = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    @StateObject private var menuHost = RowMenuHost()

    private var isSelected: Bool { model.selection == row.id }
    private var isRenaming: Bool { model.renamingRowId == row.id }

    var body: some View {
        VStack(spacing: 0) {
            rowContent
                .frame(height: 36)
            if isRenaming, let error = model.renameError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(StatusPalette.dead)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 31) // dot (7) + gap (8) + left padding (16)
                    .padding(.bottom, 6)
            }
        }
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            // Same gate as the context-menu item: greyed out without remote control.
            if row.remoteControlActive {
                model.openInBrowser(row)
            }
        })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            model.selection = row.id
        })
        .overlay(
            RowRightClickCatcher(host: menuHost) {
                SessionMenu.menu(for: row, model: model)
            } onRightClick: {
                model.selection = row.id
            }
            .allowsHitTesting(!isRenaming)
        )
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            nameColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.state.displayName)
                .font(.caption)
                .foregroundColor(row.state.labelColor)
                .frame(width: SessionColumns.status, alignment: .leading)

            Text(row.displayPath)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(LastActiveFormat.string(from: row.lastActive))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: SessionColumns.lastActive, alignment: .trailing)

            ellipsisButton
                .frame(width: SessionColumns.actions)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
    }

    private var nameColumn: some View {
        HStack(spacing: 8) {
            StatusDot(state: row.state)
            if row.needsAttention {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(StatusPalette.warning)
                    .help("Remote control is not active on this session")
            }
            if isRenaming {
                renameField
            } else {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                    // Archived sessions are visually muted (5.9).
                    .foregroundColor(row.archived ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Inline rename (5.8): same font/position, subtle border, pre-selected
    /// text. Enter commits, Escape cancels, empty commits cancel.
    private var renameField: some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundColor(.primary)
            .focused($renameFocused)
            .disabled(model.renameInFlight)
            .onSubmit { model.commitRename(row, to: renameDraft) }
            .onExitCommand { model.cancelRename() }
            .padding(.horizontal, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
            .frame(maxWidth: 260)
            .onAppear {
                renameDraft = row.title
                renameFocused = true
                // Pre-select so the user can type immediately (Finder-style).
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.15)
        } else if hovering {
            Color(.controlBackgroundColor)
        } else {
            Color(.windowBackgroundColor)
        }
    }

    private var ellipsisButton: some View {
        Button {
            model.selection = row.id
            menuHost.popMenu(SessionMenu.menu(for: row, model: model))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .accessibilityLabel("Session actions")
    }
}
