import SwiftUI

/// One 36px session row (docs/CCORN_SPEC.md section 5.1): status dot (+ warning
/// indicator), name, status label, directory, last active, hover-only `…`
/// button. Single click selects; double click = Open in Browser (disabled when
/// remote control is inactive); right-click / `…` shows the NSMenu.
struct SessionRowView: View {
    let row: SessionRow
    @ObservedObject var model: AppModel

    @State private var hovering = false
    @StateObject private var menuHost = RowMenuHost()

    private var isSelected: Bool { model.selection == row.id }

    var body: some View {
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
        .frame(height: 36)
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
        )
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
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
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
