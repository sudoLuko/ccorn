import SwiftUI

/// Menu-bar popover (docs/CCORN_SPEC.md section 5.2): a TRIAGE surface, not a
/// mirror of the dashboard. Sessions that need the user (waiting, sign-in,
/// no-remote, crashed) render as individual rows at the top, worst first; the
/// calm rest collapse behind a single quiet-count disclosure that doubles as
/// the all-clear line when nothing needs attention. Fixed dark zinc
/// regardless of system appearance; hardcoded hex is correct here and only
/// here. 280px wide, 12px padding, branded header with the aggregate mark,
/// footer actions. The split is popover-local: the shared rows sort and the
/// main window's full recency list are untouched.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    private let rowHeight: CGFloat = 32
    private let maxVisibleRows = 8

    /// The aggregate header mark renders at 9px vs the 7px row-dot standard
    /// (StatusMark's internal dot), applied as a scaleEffect so only this
    /// summary mark grows (see `header`).
    private static let aggregateMarkScale: CGFloat = 9.0 / 7.0

    /// Calm sessions expanded under the disclosure. Persisted, not transient
    /// view state, so it survives the panel's orderOut/orderFront: once the
    /// user expands or collapses it, the popover reopens in that same state.
    /// The default is folded, so an untouched user still opens to the summary;
    /// only an explicit toggle moves it off the calm-folded default. Backed
    /// by UserDefaults like the main window's DISCOVERED disclosure
    /// (`discoveredSectionCollapsed`), so the choice also outlives a restart.
    @AppStorage("popoverCalmExpanded") private var calmExpanded = false
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
        // Pin the content to the TOP and let the dark fill grow to whatever
        // height the panel currently is. The panel frame is animated top-
        // anchored (PopoverPanelController.applyPreferredSize), so the popover
        // must unroll and retract from the BOTTOM only. Without this the
        // hosting view (pinned to all four panel edges) hands the content the
        // window's animating height; mid-animation that differs from the
        // content's natural height, so SwiftUI CENTERS it; the header drifts
        // up while the footer falls down, and the gap below the fill briefly
        // exposes the desktop. Filling from a top alignment keeps the header
        // fixed and the fill always covering the panel.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PopoverPalette.background)
        // The hosting panel is borderless and clear, so the content supplies
        // its own chrome: the rounded clip shapes the window (and its
        // shadow); the hairline keeps the 0.5px-never-1px border rule.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(PopoverPalette.divider, lineWidth: 0.5)
        )
        // The panel orders out but this tree stays alive: the row marks gate
        // their repeatForever motion on the panel's actual visibility.
        .environment(\.rowMotionEnabled, model.popoverOnScreen)
        #if DEBUG
        // Scripted stand-in for clicking the calm disclosure
        // (DebugCommandChannel `popovercalm`), so the expanded state can be
        // screenshot-verified.
        .onReceive(NotificationCenter.default.publisher(for: Self.debugToggleCalm)) { _ in
            // Match the real button: snap the state, let the panel wipe animate.
            calmExpanded.toggle()
        }
        #endif
    }

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

    /// Rows currently visible in the list region; drives the scroll cap.
    private var visibleRowCount: Int {
        attentionRows.count
            + (calmRows.isEmpty ? 0 : 1)
            + (calmExpanded ? calmRows.count : 0)
    }

    // MARK: Header (32px)

    private var header: some View {
        HStack(spacing: 8) {
            // Brand mark only; the popover is summoned from the menu-bar corn,
            // so the wordmark is redundant here; the lone glyph reads cleaner.
            CornMark(size: 18)
            Spacer()
            aggregateMark
                // The aggregate is the popover's one summary mark; size it up
                // from the 7px row-dot standard toward the corn glyph so its
                // working breath reads at a glance. A scaleEffect (not a native
                // resize) scales the dot, its breath, and the halo together and
                // keeps this a header-local tweak; the shared StatusMark /
                // RowStatusIndicator 7px dot every other surface depends on is
                // untouched. scaleEffect does not grow the layout frame, so the
                // mark stays in its slot and only overflows it visually (it sits
                // alone at the trailing edge with room to spare).
                .scaleEffect(Self.aggregateMarkScale)
                // Crossfade worst-presentation swaps like the row marks do
                // (F5); the mark sits in a fixed 14pt slot, so no layout
                // moves with it.
                .animation(.easeInOut(duration: 0.25),
                           value: model.aggregatePresentation)
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
    }

    /// Worst presentation across all sessions, same resolution as the rows,
    /// so a broken-tier worst shows the exclamation symbol colored by
    /// severity, not a dot. Empty/outline dot when no session has an active
    /// color. Uses the full RowStatusIndicator (not the static StatusMark) so
    /// the aggregate mark carries the same motions the rows do: the working
    /// brightness breath and the waiting halo. The popover's rowMotionEnabled
    /// environment (set on the whole tree above) gates it, so it stops when the
    /// panel is off screen just like the rows. A constant identity gives it a
    /// stable, fixed breath phase; it is the lone aggregate, so there is no
    /// unison to avoid.
    @ViewBuilder
    private var aggregateMark: some View {
        if let presentation = model.aggregatePresentation {
            RowStatusIndicator(presentation: presentation, identity: "aggregate")
        } else {
            Circle()
                .strokeBorder(StatusPalette.stoppedOutline, lineWidth: 1)
                .frame(width: 7, height: 7)
                .frame(width: StatusMark.slotWidth)
        }
    }

    // MARK: Session list

    /// Managed sessions only; the popover is the at-a-glance surface for
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
            ForEach(Array(attentionRows.enumerated()), id: \.element.listID) { index, row in
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
                    ForEach(calmRows, id: \.listID) { row in
                        divider
                        popoverRow(row)
                    }
                }
            }
        }
        // The DISPLAYED sequence, not the managed set (F1): a tier crossing
        // moves an id between the two sub-arrays, so the row's move between
        // sections animates, while within-section state flips (running ->
        // working) change nothing and stay quiet. Severity reorders inside the
        // attention section animate too. The calm expand/collapse is
        // deliberately NOT in this value: its height change is animated by the
        // panel-frame wipe alone, so the calm rows are revealed/hidden by the
        // growing/shrinking panel instead of fading on a second, competing
        // timeline (which made expand look unfinished).
        .animation(.easeInOut(duration: 0.2),
                   value: attentionRows.map(\.listID) + calmRows.map(\.listID))
    }

    private func popoverRow(_ row: SessionRow) -> some View {
        PopoverRowView(row: row) {
            model.openSession(row)
            model.closePopover?()
        }
        .frame(height: rowHeight)
    }

    /// One row summarizing the calm set, expandable to the full
    /// recency-ordered list (the DISCOVERED disclosure pattern). With no
    /// attention rows above it, it doubles as the all-clear line.
    private var calmDisclosure: some View {
        Button {
            // Snap the disclosure state. The panel-frame animation
            // (PopoverPanelController.applyPreferredSize) is the ONLY thing
            // that animates the height; it unrolls/retracts the rows from the
            // bottom. Animating the rows here too put two 0.2s animations in
            // conflict on expand (rows fading/sliding in while the panel wiped
            // open); collapse hid it behind the shrinking fill, expand did not.
            calmExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(PopoverPalette.secondaryText)
                    .rotationEffect(.degrees(calmExpanded ? 90 : 0))
                    // Rotate the chevron smoothly without re-animating the row
                    // layout (which the panel wipe now owns).
                    .animation(.easeInOut(duration: 0.2), value: calmExpanded)
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
        .animation(Motion.hover, value: disclosureHovering)
        .help(calmExpanded ? "Hide quiet sessions" : "Show quiet sessions")
    }

    /// Quiet pointer to the main window for unmanaged discoveries, the same
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
        .help("Sessions found on this Mac that CCorn doesn't manage yet. Open CCorn to import them")
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
/// anywhere opens the session, in Terminal or the browser per the Settings
/// preference (5.5), via model.openSession; hover highlights #18181B.
private struct PopoverRowView: View {
    let row: SessionRow
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RowStatusIndicator(presentation: row.presentation, identity: row.id)
                .help(row.statusTooltip)
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(PopoverPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            LocalTag(isLocal: row.isLocal, color: PopoverPalette.secondaryText)
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
        .animation(Motion.hover, value: hovering)
        .onTapGesture(perform: action)
    }
}
