import SwiftUI

/// Menu-bar popover (docs/CCORN_SPEC.md section 5.2). Fixed dark zinc
/// regardless of system appearance — hardcoded hex is correct here and only
/// here. 280px wide, 12px padding, header with the aggregate dot, session
/// rows, footer actions.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    private let rowHeight: CGFloat = 32
    private let maxVisibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            sessionList
            divider
            footer
        }
        .padding(12)
        .frame(width: 280)
        .background(PopoverPalette.background)
    }

    // MARK: Header (32px)

    private var header: some View {
        HStack(spacing: 8) {
            Text("CCorn")
                .font(.subheadline.weight(.medium))
                .foregroundColor(PopoverPalette.primaryText)
            Spacer()
            aggregateDot
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
    }

    /// Worst state across all sessions; empty/outline dot when no session has
    /// an active color.
    @ViewBuilder
    private var aggregateDot: some View {
        if let state = model.aggregateState {
            StatusDot(state: state, stoppedOutline: PopoverPalette.stoppedOutline)
        } else {
            Circle()
                .strokeBorder(PopoverPalette.stoppedOutline, lineWidth: 0.5)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: Session list

    @ViewBuilder
    private var sessionList: some View {
        if model.rows.isEmpty {
            Text("No sessions")
                .font(.caption)
                .foregroundColor(PopoverPalette.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight * 2)
        } else if model.rows.count > maxVisibleRows {
            ScrollView(showsIndicators: false) {
                rowsStack
            }
            .frame(height: rowHeight * CGFloat(maxVisibleRows))
        } else {
            rowsStack
        }
    }

    private var rowsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    divider
                }
                PopoverRowView(row: row) {
                    model.openInBrowser(row)
                    model.closePopover?()
                }
                .frame(height: rowHeight)
            }
        }
    }

    // MARK: Footer (36px)

    private var footer: some View {
        HStack {
            Button {
                model.newSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundColor(PopoverPalette.footerText)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                model.closePopover?()
                model.openMainWindow?()
            } label: {
                Text("Open CCorn")
                    .font(.caption.weight(.medium))
                    .foregroundColor(PopoverPalette.footerText)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 36)
        .padding(.horizontal, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(PopoverPalette.divider)
            .frame(height: 0.5)
    }
}

/// One popover row: dot, name, last-active. Click anywhere opens the browser
/// (claude.ai/code); hover highlights #18181B.
private struct PopoverRowView: View {
    let row: SessionRow
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: row.state, stoppedOutline: PopoverPalette.stoppedOutline)
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(PopoverPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(LastActiveFormat.string(from: row.lastActive))
                .font(.caption)
                .foregroundColor(PopoverPalette.secondaryText)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hovering ? PopoverPalette.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
