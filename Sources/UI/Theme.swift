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
}

/// Status dot colors — semantic only, identical in light and dark
/// (docs/CCORN_SPEC.md section 3).
enum StatusPalette {
    static let running = Color(hex: 0x16A34A)
    static let working = Color(hex: 0x2563EB)
    static let waiting = Color(hex: 0xD97706)
    static let stale = Color(hex: 0xEA580C)
    static let dead = Color(hex: 0xDC2626)
    /// Warning indicator (remote control inactive) — same yellow as waiting.
    static let warning = Color(hex: 0xD97706)
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

// MARK: - SessionState presentation

extension SessionState {
    /// Fill color for the 7px dot; nil for the outline-only states (stopped,
    /// unmanaged, and needsAuth, which renders as a thick yellow ring — the
    /// attention color in a distinct shape, "hollow" because nothing can run
    /// until the user signs in).
    var dotFill: Color? {
        switch self {
        case .running: return StatusPalette.running
        case .working: return StatusPalette.working
        case .waiting: return StatusPalette.waiting
        case .stale: return StatusPalette.stale
        case .dead: return StatusPalette.dead
        case .needsAuth, .stopped, .unmanaged: return nil
        }
    }

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .working: return "Working"
        case .waiting: return "Waiting for input"
        case .needsAuth: return "Sign-in required"
        case .stale: return "Stale"
        case .dead: return "Crashed"
        case .stopped: return "Stopped"
        case .unmanaged: return "Not managed by CCorn"
        }
    }

    /// Color for textual state labels: matches the dot for active states,
    /// muted for the achromatic ones.
    var labelColor: Color {
        if self == .needsAuth { return StatusPalette.waiting }
        return dotFill ?? (self == .unmanaged ? StatusPalette.unmanagedOutline : Color.secondary)
    }

    /// Short label shown next to the session name for the states that need
    /// the user (the dot alone says "what", the label says "act"). Calm
    /// states stay dot-only; their word lives in the tooltip.
    var attentionLabel: String? {
        switch self {
        case .waiting: return "Needs input"
        case .needsAuth: return "Sign in"
        case .dead: return "Crashed"
        case .running, .working, .stale, .stopped, .unmanaged: return nil
        }
    }
}

// MARK: - Status dot

/// The 7px status dot (docs/CCORN_SPEC.md section 4): filled circle for active
/// states, hairline outline for stopped (context-tinted) and unmanaged
/// (#71717A), and a thick yellow ring for needsAuth — same attention hue as
/// Waiting, unmistakably different shape.
struct StatusDot: View {
    let state: SessionState
    /// Outline color for the stopped state — semantic separator in the main
    /// window, a fixed zinc in the popover.
    var stoppedOutline: Color = Color(.separatorColor)

    var body: some View {
        Group {
            if let fill = state.dotFill {
                Circle().fill(fill)
            } else if state == .needsAuth {
                Circle().strokeBorder(StatusPalette.waiting, lineWidth: 2)
            } else {
                Circle().strokeBorder(
                    state == .unmanaged ? StatusPalette.unmanagedOutline : stoppedOutline,
                    lineWidth: 0.5)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(state.displayName)
    }
}

/// Status indicator for list rows: the StatusDot, with a slow expanding halo
/// while the session waits on the user. The dot itself never dims — at any
/// frozen instant the row shows a solid attention dot; the halo ring starts
/// hidden underneath it and drifts outward, so the motion is felt on a scan
/// without anything flashing. State changes fade the dot over briefly.
struct RowStatusIndicator: View {
    let state: SessionState
    var stoppedOutline: Color = Color(.separatorColor)

    @State private var pulsing = false

    var body: some View {
        StatusDot(state: state, stoppedOutline: stoppedOutline)
            .background(
                Circle()
                    .stroke(StatusPalette.waiting, lineWidth: 1)
                    .scaleEffect(pulsing ? 2.6 : 1)
                    .opacity(state == .waiting ? (pulsing ? 0 : 0.5) : 0)
                    .animation(state == .waiting
                               ? .easeOut(duration: 1.8).repeatForever(autoreverses: false)
                               : nil,
                               value: pulsing)
            )
            .animation(.easeInOut(duration: 0.25), value: state)
            .onAppear { pulsing = state == .waiting }
            .onChange(of: state) { newState in
                pulsing = newState == .waiting
            }
            .help(state.displayName)
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
