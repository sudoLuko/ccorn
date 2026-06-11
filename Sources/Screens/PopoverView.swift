import SwiftUI

/// Menu-bar popover (docs/CCORN_SPEC.md section 5.2): a TRIAGE surface, not a
/// mirror of the dashboard. Sessions that need the user (waiting, sign-in,
/// no-remote, crashed) render as individual rows at the top, worst first; the
/// calm rest collapse behind a single quiet-count disclosure that doubles as
/// the all-clear line when nothing needs attention. Fixed dark zinc
/// regardless of system appearance — hardcoded hex is correct here and only
/// here. 280px wide, 12px padding, branded header with the aggregate mark,
/// footer actions. The split is popover-local: the shared rows sort and the
/// main window's full recency list are untouched.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    private let rowHeight: CGFloat = 32
    private let maxVisibleRows = 8

    /// Calm sessions expanded under the disclosure. Collapsed again on every
    /// open: triage starts from the summary, never from yesterday's state.
    /// The panel keeps this view alive across orderOut/orderFront, so
    /// .onAppear does not refire on reopen — PopoverPanelController posts
    /// `resetTriage` from its close path instead.
    @State private var calmExpanded = false
    @State private var disclosureHovering = false

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
        // The hosting panel is borderless and clear, so the content supplies
        // its own chrome: the rounded clip shapes the window (and its
        // shadow); the hairline keeps the 0.5px-never-1px border rule.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(PopoverPalette.divider, lineWidth: 0.5)
        )
        .onAppear { calmExpanded = false }
        .onReceive(NotificationCenter.default.publisher(for: Self.resetTriage)) { _ in
            // Posted while the panel is hidden; disable animations anyway so
            // a reopen never shows a collapse.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { calmExpanded = false }
        }
        #if DEBUG
        // Scripted stand-in for clicking the calm disclosure
        // (DebugCommandChannel `popovercalm`), so the expanded state can be
        // screenshot-verified.
        .onReceive(NotificationCenter.default.publisher(for: Self.debugToggleCalm)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { calmExpanded.toggle() }
        }
        #endif
    }

    /// Posted by PopoverPanelController after every close (see calmExpanded).
    static let resetTriage = Notification.Name("ccorn.popover.reset-triage")

    #if DEBUG
    static let debugToggleCalm = Notification.Name("ccorn.debug.popover.toggle-calm")
    #endif

    // MARK: Triage split (popover-local)

    /// Sessions that need the user, worst first: the aggregate severity
    /// ladder (crashed > sign-in > no-remote > waiting), recency as tiebreak.
    private var attentionRows: [SessionRow] {
        model.managedRows
            .filter { $0.presentation.needsAttention }
            .sorted { a, b in
                let sa = a.presentation.aggregateSeverity ?? 0
                let sb = b.presentation.aggregateSeverity ?? 0
                if sa != sb { return sa > sb }
                return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
            }
    }

    /// Everything calm, in the shared recency order (shown only expanded).
    private var calmRows: [SessionRow] {
        model.managedRows.filter { !$0.presentation.needsAttention }
    }

    /// Rows currently visible in the list region — drives the scroll cap.
    private var visibleRowCount: Int {
        attentionRows.count
            + (calmRows.isEmpty ? 0 : 1)
            + (calmExpanded ? calmRows.count : 0)
    }

    // MARK: Header (32px)

    private var header: some View {
        HStack(spacing: 8) {
            BrandLockup(textColor: PopoverPalette.primaryText)
            Spacer()
            aggregateMark
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
    }

    /// Worst presentation across all sessions — same resolution as the rows,
    /// so a broken-tier worst shows the exclamation symbol colored by
    /// severity, not a dot. Empty/outline dot when no session has an active
    /// color.
    @ViewBuilder
    private var aggregateMark: some View {
        if let presentation = model.aggregatePresentation {
            StatusMark(presentation: presentation)
        } else {
            Circle()
                .strokeBorder(StatusPalette.stoppedOutline, lineWidth: 1)
                .frame(width: 7, height: 7)
                .frame(width: StatusMark.slotWidth)
        }
    }

    // MARK: Session list

    /// Managed sessions only — the popover is the at-a-glance surface for
    /// *your* sessions. Unmanaged discoveries are ambient context and live in
    /// the main window; here they collapse to a one-line count. Attention
    /// rows plus the collapsed disclosure fit the cap in the common case;
    /// only an expanded calm list (or an unusually long attention set)
    /// scrolls.
    @ViewBuilder
    private var sessionList: some View {
        if model.managedRows.isEmpty {
            Text("No sessions")
                .font(.caption)
                .foregroundColor(PopoverPalette.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight * 2)
        } else if visibleRowCount > maxVisibleRows {
            ScrollView(showsIndicators: false) {
                triageStack
            }
            .frame(height: rowHeight * CGFloat(maxVisibleRows))
        } else {
            triageStack
        }
        if !model.unmanagedRows.isEmpty {
            divider
            discoveredHint
        }
    }

    private var triageStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(attentionRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    divider
                }
                popoverRow(row)
            }
            if !calmRows.isEmpty {
                if !attentionRows.isEmpty {
                    divider
                }
                calmDisclosure
                if calmExpanded {
                    ForEach(calmRows) { row in
                        divider
                        popoverRow(row)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2),
                   value: model.managedRows.map(\.id) + [calmExpanded ? "+" : "-"])
    }

    private func popoverRow(_ row: SessionRow) -> some View {
        PopoverRowView(row: row) {
            model.openInBrowser(row)
            model.closePopover?()
        }
        .frame(height: rowHeight)
    }

    /// One row summarizing the calm set, expandable to the full
    /// recency-ordered list (the DISCOVERED disclosure pattern). With no
    /// attention rows above it, it doubles as the all-clear line.
    private var calmDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                calmExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(PopoverPalette.secondaryText)
                    .rotationEffect(.degrees(calmExpanded ? 90 : 0))
                    .frame(width: StatusMark.slotWidth)
                if attentionRows.isEmpty {
                    Text("All clear")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(PopoverPalette.primaryText)
                    Text("\(calmRows.count) quiet")
                        .font(.caption)
                        .foregroundColor(PopoverPalette.secondaryText)
                } else {
                    Text("\(calmRows.count) quiet")
                        .font(.subheadline)
                        .foregroundColor(PopoverPalette.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity)
            .background(disclosureHovering ? PopoverPalette.rowHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { disclosureHovering = $0 }
        .help(calmExpanded ? "Hide quiet sessions" : "Show quiet sessions")
    }

    /// Quiet pointer to the main window for unmanaged discoveries — the same
    /// word as the main window's DISCOVERED section header; the "not managed"
    /// detail lives in the tooltip on both surfaces.
    private var discoveredHint: some View {
        Button {
            model.closePopover?()
            model.openMainWindow?()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .strokeBorder(StatusPalette.unmanagedOutline, lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .frame(width: StatusMark.slotWidth)
                Text("\(model.unmanagedRows.count) discovered")
                    .font(.caption)
                    .foregroundColor(PopoverPalette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sessions found on this Mac that CCorn doesn't manage yet — open CCorn to import them")
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

/// One popover row: the same single status mark as the main window (dot or
/// warning symbol, fixed slot), name, attention word, last-active. Click
/// anywhere opens the browser (claude.ai/code); hover highlights #18181B.
private struct PopoverRowView: View {
    let row: SessionRow
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RowStatusIndicator(presentation: row.presentation)
                .help(row.statusTooltip)
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(PopoverPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            AttentionWord(presentation: row.presentation)
            Spacer(minLength: 8)
            Text(LastActiveFormat.string(from: row.lastActive))
                .font(.caption)
                .foregroundColor(PopoverPalette.secondaryText)
        }
        .animation(.easeInOut(duration: 0.25), value: row.presentation)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hovering ? PopoverPalette.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
