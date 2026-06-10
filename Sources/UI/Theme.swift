import AppKit
import SwiftUI

// MARK: - Hex colors

extension Color {
    /// 0xRRGGBB. Only for the status palette (same in light/dark) and the
    /// menu-bar popover (fixed dark). Main-window chrome uses semantic colors.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// Appearance-paired solid, only for where the spec names an exact pair
    /// (§3 "Primary action"). Semantic colors can't express it: Color.primary
    /// is ~85%-alpha labelColor, which filled into a button renders as a
    /// washed grey slab.
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: dark ? darkHex : lightHex))
        })
    }
}

/// Status mark colors — semantic only, identical in light and dark
/// (docs/CCORN_SPEC.md section 3, with two review revisions: stale is recolored
/// out of the red/orange family, and the broken tier gets an amber symbol).
enum StatusPalette {
    static let running = Color(hex: 0x16A34A)
    static let working = Color(hex: 0x2563EB)
    static let waiting = Color(hex: 0xD97706)
    /// Stale is muted and recessive on purpose — a desaturated slate, not the
    /// spec's #EA580C, which reads like Crashed at 7px.
    static let stale = Color(hex: 0x64748B)
    static let dead = Color(hex: 0xDC2626)
    /// Broken-tier symbol amber (recoverable: sign in / no remote). Brighter
    /// than the waiting yellow so it stays apart from both that dot and the
    /// red (terminal) symbol at small sizes.
    static let amber = Color(hex: 0xF59E0B)
    /// Unmanaged outline — fixed per spec section 4, same in both appearances.
    static let unmanagedOutline = Color(hex: 0x71717A)
}

/// Menu-bar popover palette — the popover is fixed dark regardless of system
/// appearance, so hardcoded hex is correct here (and only here).
enum PopoverPalette {
    static let background = Color(hex: 0x09090B)
    static let rowHover = Color(hex: 0x18181B)
    static let divider = Color(hex: 0x27272A)
    static let primaryText = Color(hex: 0xFAFAFA)
    static let secondaryText = Color(hex: 0x71717A)
    static let footerText = Color(hex: 0xA1A1AA)
    /// Outline for a stopped session's empty dot — the spec's section-4 value
    /// (#E4E4E7 border only), which it states without a dark-mode adaptation.
    static let stoppedOutline = Color(hex: 0xE4E4E7)
}

// MARK: - StatusPresentation colors

extension StatusPresentation {
    /// Fill color for the dot states; nil for outline-only and symbol states.
    var dotFill: Color? {
        switch self {
        case .running: return StatusPalette.running
        case .working: return StatusPalette.working
        case .waiting: return StatusPalette.waiting
        case .stale: return StatusPalette.stale
        case .stopped, .unmanaged: return nil
        case .noRemote, .needsAuth, .crashed: return nil
        }
    }

    /// Color of the exclamation symbol for the broken tier: amber recoverable,
    /// red terminal. nil for the dot states.
    var symbolColor: Color? {
        switch self {
        case .noRemote, .needsAuth: return StatusPalette.amber
        case .crashed: return StatusPalette.dead
        case .running, .working, .waiting, .stale, .stopped, .unmanaged: return nil
        }
    }

    /// Color for the short word after the title: matches the mark.
    var labelColor: Color {
        symbolColor ?? dotFill
            ?? (self == .unmanaged ? StatusPalette.unmanagedOutline : Color.secondary)
    }
}

// MARK: - Status mark

/// KEEP-OR-CUT (review item 1, "Process"): subtle breath on the Working dot —
/// a slow scale+opacity oscillation of the dot itself, NOT an expanding halo
/// (the halo stays exclusive to Waiting). Flip to false to cut.
enum WorkingBreath {
    static let enabled = true
}

/// The single status mark every row shows, in a shared fixed-width slot so
/// titles line up across rows and surfaces: a 7px dot for routine states
/// (filled when active, hairline outline for stopped/unmanaged), or the one
/// warning symbol — exclamationmark.triangle.fill, a little larger than the
/// dot — for the broken tier. Never a dot and a symbol together, never any
/// other glyph.
struct StatusMark: View {
    let presentation: StatusPresentation
    /// Outline color for the stopped state — semantic separator in the main
    /// window, a fixed zinc in the popover.
    var stoppedOutline: Color = Color(.separatorColor)

    /// Width of the status slot on every surface (the symbol is the widest mark).
    static let slotWidth: CGFloat = 14

    var body: some View {
        Group {
            if let symbolColor = presentation.symbolColor {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(symbolColor)
            } else if let fill = presentation.dotFill {
                Circle()
                    .fill(fill)
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .strokeBorder(
                        presentation == .unmanaged
                            ? StatusPalette.unmanagedOutline : stoppedOutline,
                        lineWidth: 0.5)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: Self.slotWidth)
        .accessibilityLabel(presentation.displayName)
    }
}

/// Status mark for list rows, plus the two motions. Waiting keeps its slow
/// expanding halo exactly as before: the dot never dims — at any frozen
/// instant the row shows a solid attention dot; the halo ring starts hidden
/// underneath and drifts outward, so the motion is felt on a scan without
/// anything flashing. Working gets the optional breath (see WorkingBreath).
/// State changes fade the mark over briefly.
struct RowStatusIndicator: View {
    let presentation: StatusPresentation
    var stoppedOutline: Color = Color(.separatorColor)

    @State private var pulsing = false
    @State private var breathing = false

    var body: some View {
        StatusMark(presentation: presentation, stoppedOutline: stoppedOutline)
            .scaleEffect(breathing ? 1.18 : 1)
            .opacity(breathing ? 0.7 : 1)
            .animation(presentation == .working && WorkingBreath.enabled
                       ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                       : .easeInOut(duration: 0.2),
                       value: breathing)
            .background(
                Circle()
                    .stroke(StatusPalette.waiting, lineWidth: 1)
                    // The halo tracks the 7px dot, not the wider slot.
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulsing ? 2.6 : 1)
                    .opacity(presentation == .waiting ? (pulsing ? 0 : 0.5) : 0)
                    .animation(presentation == .waiting
                               ? .easeOut(duration: 1.8).repeatForever(autoreverses: false)
                               : nil,
                               value: pulsing)
            )
            .animation(.easeInOut(duration: 0.25), value: presentation)
            .onAppear {
                // Next tick, never in the insertion transaction: a
                // repeatForever started while row layout is still pending
                // captures the position delta too, and the mark animates
                // between its insertion and settled positions forever.
                DispatchQueue.main.async { syncMotion() }
            }
            .onChange(of: presentation) { _ in syncMotion() }
    }

    private func syncMotion() {
        pulsing = presentation == .waiting
        breathing = presentation == .working && WorkingBreath.enabled
    }
}

// MARK: - Primary button

/// Primary-action filled button shared by onboarding, the import sheet, the
/// empty state, and the no-managed hint. Enabled it is the spec's §3 primary
/// action — solid #09090B fill / #FAFAFA text in light, inverted in dark —
/// as an exact pair because a Color.primary fill (85%-alpha labelColor)
/// renders as a dead grey slab. Disabled is a quiet zinc wash with secondary
/// text: visibly disabled, still legible.
struct FilledButton: View {
    let title: String
    var disabled = false
    var fullWidth = false
    var height: CGFloat = 28
    let action: () -> Void

    private static let fill = Color(lightHex: 0x09090B, darkHex: 0xFAFAFA)
    private static let text = Color(lightHex: 0xFAFAFA, darkHex: 0x09090B)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(disabled ? Color.secondary : Self.text)
                .padding(.horizontal, 14)
                .frame(height: height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(disabled ? Color.primary.opacity(0.06) : Self.fill)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(.easeInOut(duration: 0.15), value: disabled)
    }
}

// MARK: - Timestamps

/// Short relative timestamp in the style of the list-rows reference
/// ("now", "5m ago", "3h ago", "2d ago", "Jun 5").
enum LastActiveFormat {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static func string(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        return dayFormatter.string(from: date)
    }
}
