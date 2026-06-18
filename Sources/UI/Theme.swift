import AppKit
import SwiftUI

// MARK: - Hex colors

extension Color {
    /// 0xRRGGBB. Only for status/popover tokens that are identical in both
    /// appearances; tokens that adapt use Color(lightHex:darkHex:), and
    /// main-window chrome uses semantic colors.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// Appearance-paired solid, only for where exact per-appearance values
    /// are required (§3 "Primary action" and the appearance-adaptive status
    /// tokens). Semantic colors can't express it: Color.primary is ~85%-alpha
    /// labelColor, which filled into a button renders as a washed grey slab.
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: dark ? darkHex : lightHex))
        })
    }
}

/// Status mark colors (docs/CCORN_SPEC.md section 3). Tokens built with
/// Color(lightHex:darkHex:) adapt to appearance (each says why at its
/// declaration); the rest are identical in light and dark.
enum StatusPalette {
    /// Running green, adaptive: green-600 on light; green-500 on dark (and
    /// the popover in dark) so the healthy dot keeps its weight
    /// next to the bright dark-face amber instead of receding. Same hue,
    /// lifted one step. Green-500 is dark-face ONLY: it sits near 2.3:1 on
    /// white and fails the 3:1 UI-component floor there.
    static let runningLightHex: UInt32 = 0x16A34A
    static let runningDarkHex: UInt32 = 0x22C55E
    static let running = Color(lightHex: runningLightHex,
                               darkHex: runningDarkHex)

    /// Working blue, adaptive: blue-600 on light; blue-500 on dark (and
    /// the popover in dark) so working reads active and
    /// separates from the muted stale slate. Same hue, lifted one step.
    static let workingLightHex: UInt32 = 0x2563EB
    static let workingDarkHex: UInt32 = 0x3B82F6
    static let working = Color(lightHex: workingLightHex,
                               darkHex: workingDarkHex)

    /// The ONE attention amber: the waiting dot and its halo, the recoverable
    /// warning triangles (sign in / no remote), and every amber attention
    /// word. Appearance-adaptive because the word is body-size TEXT: on light
    /// it must clear WCAG AA 4.5:1 against the window background. Amber-500
    /// (#F59E0B) and the old waiting #D97706 both sit near 3:1 and fail, so
    /// it darkens to between amber-700 and -800; on dark and the dark
    /// popover the brighter amber reads well (~9:1 on #09090B).
    static let attentionLightHex: UInt32 = 0xA34A0B
    static let attentionDarkHex: UInt32 = 0xF59E0B
    static let attention = Color(lightHex: attentionLightHex,
                                 darkHex: attentionDarkHex)
    /// Stale is muted and recessive on purpose: a desaturated slate, not the
    /// spec's #EA580C, which reads like Crashed at 7px.
    static let stale = Color(hex: 0x64748B)
    static let dead = Color(hex: 0xDC2626)
    /// Unmanaged outline, fixed per spec section 4, same in both appearances.
    static let unmanagedOutline = Color(hex: 0x71717A)
    /// Hollow grey for a stopped session's empty dot, one home for every
    /// surface. Light: fixed #8A8A8F; a 1px ring is a UI component and needs
    /// 3:1 (this is ~3.4:1 on white; the previous tertiaryLabelColor resolved
    /// near #BDBDBD, ~1.6:1, and the ring all but vanished), while staying
    /// lighter than the unmanaged #71717A so stopped remains the quieter of
    /// the two hollow dots. Dark, and therefore the popover in dark:
    /// zinc-400, visibly present, recessive, and a step lighter than the
    /// unmanaged outline so the hierarchy holds there too.
    static let stoppedOutlineLightHex: UInt32 = 0x8A8A8F
    static let stoppedOutlineDarkHex: UInt32 = 0xA1A1AA
    static let stoppedOutline = Color(lightHex: stoppedOutlineLightHex,
                                      darkHex: stoppedOutlineDarkHex)
    /// Grey fill for the import sheet's not-yet-imported dot (5.4 State 2,
    /// "Waiting: muted opacity, grey dot").
    static let importPending = Color.secondary.opacity(0.5)
}

/// Menu-bar popover palette. The popover follows the app appearance (Settings ▸
/// Appearance / the system), so these are appearance-paired hex. The DARK face is
/// byte-identical to the old fixed-dark popover (so system-dark / forced-dark is
/// unchanged); the LIGHT face mirrors each token across the same zinc scale, so
/// the popover reads as a clean light menu when the app is light. Light surfaces
/// land on #FAFAFA, the ground `ThemeTokenTests` already pins the status faces
/// against; `secondaryText` is zinc-500, legible on both, so it needs no pair.
enum PopoverPalette {
    static let background = Color(lightHex: 0xFAFAFA, darkHex: 0x09090B)
    static let rowHover = Color(lightHex: 0xF4F4F5, darkHex: 0x18181B)
    static let divider = Color(lightHex: 0xE4E4E7, darkHex: 0x27272A)
    static let primaryText = Color(lightHex: 0x18181B, darkHex: 0xFAFAFA)
    static let secondaryText = Color(hex: 0x71717A)
    static let footerText = Color(lightHex: 0x52525B, darkHex: 0xA1A1AA)
}

// MARK: - StatusPresentation colors

extension StatusPresentation {
    /// Fill color for the dot states; nil for outline-only and symbol states.
    var dotFill: Color? {
        switch self {
        case .running: return StatusPalette.running
        case .working: return StatusPalette.working
        case .waiting: return StatusPalette.attention
        case .stale: return StatusPalette.stale
        case .stopped, .unmanaged: return nil
        case .noRemote, .needsAuth, .crashed: return nil
        }
    }

    /// Color of the exclamation symbol for the broken tier: amber recoverable,
    /// red terminal. nil for the dot states.
    var symbolColor: Color? {
        switch self {
        case .noRemote, .needsAuth: return StatusPalette.attention
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

/// The Working dot's breath: the dot pulses size (grows and returns) while its
/// brightness eases in the same cycle, so it reads as actively alive. Size is
/// the carrier — it is appearance-independent, so the motion is equally legible
/// on light and dark, where the brightness swing alone fought one scheme or the
/// other (a brighten-only breath washed into a near-white background). Brightness
/// is the secondary cue and is direction-aware (see `BreathPulse`). The motion is
/// a continuous sine driven from a linear phase (no dwell or hold at the trough,
/// unlike easeInOut+autoreverse which parks at the extremes and reads as a
/// flicker), and each row carries a stable phase offset so a list never breathes
/// in unison. The dot grows IN PLACE and returns; it stays distinct from the
/// Waiting halo, which is a separate ring emanating outward from a still dot (the
/// halo stays exclusive to Waiting). Flip to false to cut. Renders only in
/// RowStatusIndicator (live rows); the static StatusMark used in legends/headers
/// stays a plain solid dot.
enum WorkingBreath {
    static let enabled = true
}

/// Shared motion token for the hover wash: the one 0.18s curve every
/// hover-driven background uses: main-window rows, popover rows, the calm
/// disclosure. The layout (0.2s) and presentation (0.25s) standards stay
/// inline at their few deliberate sites (F8: two standards, both sanctioned).
enum Motion {
    static let hover = Animation.easeInOut(duration: 0.18)
}

/// The single status mark every row shows, in a shared fixed-width slot so
/// titles line up across rows and surfaces: a 7px dot for routine states
/// (filled when active, hairline outline for stopped/unmanaged), or the one
/// warning symbol (exclamationmark.triangle.fill, a little larger than the
/// dot) for the broken tier. Never a dot and a symbol together, never any
/// other glyph.
struct StatusMark: View {
    let presentation: StatusPresentation

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
                // 1px ring, not the chrome hairline: at 7px a 0.5px ring is
                // sub-pixel on 1x displays and the dot disappears.
                Circle()
                    .strokeBorder(
                        presentation == .unmanaged
                            ? StatusPalette.unmanagedOutline
                            : StatusPalette.stoppedOutline,
                        lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: Self.slotWidth)
        .accessibilityLabel(presentation.displayName)
        // Distinct identity per presentation so a glyph change (e.g. waiting's
        // amber dot -> crashed's red triangle) CROSSFADES as two whole marks
        // under the call site's .animation(value: presentation). Without it the
        // dot and triangle share one structural slot and SwiftUI interpolates
        // the shared fill, flashing an intermediate red dot before the triangle.
        .id(presentation)
        .transition(.opacity)
    }
}

/// Whether the window hosting a row is actually on screen. Both surfaces keep
/// their SwiftUI trees alive while hidden (the popover panel orders out, the
/// main window closes with isReleasedWhenClosed = false), and a repeatForever
/// mark animation in a hidden tree keeps the render loop ticking every frame:
/// several percent CPU per hidden surface, forever. The window controllers publish
/// visibility through the model into this key; RowStatusIndicator stops its
/// loops when it goes false. Defaults to true so one-off hosts (debug
/// previews) keep motion without wiring.
private struct RowMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var rowMotionEnabled: Bool {
        get { self[RowMotionEnabledKey.self] }
        set { self[RowMotionEnabledKey.self] = newValue }
    }
}

/// Status mark for list rows, plus the two motions. Waiting keeps its slow
/// expanding halo exactly as before: the dot never dims; at any frozen
/// instant the row shows a solid attention dot; the halo ring starts hidden
/// underneath and drifts outward, so the motion is felt on a scan without
/// anything flashing. Working gets the optional brightness breath (see
/// WorkingBreath): the blue dot stays full size and full opacity while its
/// brightness oscillates on a continuous sine, quietly alive, in place, so it
/// stays subordinate to the waiting halo's outward expansion. State changes
/// fade the mark over briefly. Both loops require rowMotionEnabled: when the
/// hosting window leaves the screen the mark is rebuilt at its resting solid
/// state (identity flip, see .id below) and motion restarts on the next show.
struct RowStatusIndicator: View {
    let presentation: StatusPresentation
    /// Stable per-row identifier (the SessionRow id), hashed into a fixed phase
    /// offset so a list of working dots breathes out of sync (see phaseOffset).
    var identity: String = ""

    @Environment(\.rowMotionEnabled) private var motionEnabled
    /// The breath moves the dot AWAY from the surface luminance so the motion
    /// always gains contrast: brighten on a dark surface, darken on a light one.
    /// Read per-surface (resolved scheme), so the always-dark popover keeps
    /// brightening even when the app is forced light. Brightening toward a
    /// near-white background drops the dot to ~3:1 at the breath peak (measured),
    /// which is why the working animation washed out in light mode.
    @Environment(\.colorScheme) private var colorScheme

    @State private var pulsing = false
    /// Linear breath clock: held at 1 while a working row is on screen and
    /// driven 0→1 forever by the repeatForever linear animation below; the
    /// BreathPulse modifier maps it through a sine. 0 at rest.
    @State private var breathPhase: Double = 0

    /// Fraction the dot grows at the breath peak. The base dot is 7px, so each
    /// 1/7 (≈0.143) is +1px of peak diameter: 0.143 → 7px grows to 8px. The
    /// primary, appearance-independent cue (reads on light and dark alike); grows
    /// from rest and returns, never below the base size. Tune in ~0.143 steps to
    /// move the peak ±1px at a time.
    private static let breathScale: Double = 0.143
    /// Peak brightness magnitude layered on top of the size pulse. The SIGN is
    /// chosen per-surface at the call site (brighten on dark, darken on light), so
    /// the color always moves away from the background, never fades into it.
    private static let breathPeak: Double = 0.2
    /// Seconds per full sine cycle: unhurried, so many rows together stay calm,
    /// but quick enough to read as active.
    private static let breathPeriod: Double = 2.4

    /// Deterministic phase offset in [0,1) from the row id, so rows do not
    /// breathe in unison. A small FNV-1a hash, NOT String.hashValue (which is
    /// seeded per process and so is not stable across launches); this is stable
    /// across every render and run for a given id.
    private var phaseOffset: Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Double(hash % 1000) / 1000
    }

    private var isWorking: Bool {
        presentation == .working && WorkingBreath.enabled
    }

    var body: some View {
        StatusMark(presentation: presentation)
            // Working: a size-and-brightness breath. The blue dot is redrawn as an
            // overlay so the pulse touches ONLY the working mark (never other
            // states'): the overlay scales up from the base dot and returns, with
            // its brightness easing in the same sine cycle, driven from a linear
            // phase so it never dwells at the trough the way easeInOut +
            // autoreverse does. The overlay is always ≥ the 7px base, so it fully
            // covers it as it grows; at rest / motion-off the overlay matches the
            // base dot, so a hidden or non-breathing working row is a plain blue
            // dot. The brightness sign is per-surface (brighten on dark, darken on
            // light) so the color moves away from the background on both schemes.
            .overlay {
                if isWorking {
                    Circle()
                        .fill(StatusPalette.working)
                        .frame(width: 7, height: 7)
                        .modifier(BreathPulse(phase: breathPhase,
                                              offset: phaseOffset,
                                              scalePeak: Self.breathScale,
                                              brightnessPeak: colorScheme == .dark
                                                  ? Self.breathPeak
                                                  : -Self.breathPeak))
                        .animation(motionEnabled
                                   ? .linear(duration: Self.breathPeriod).repeatForever(autoreverses: false)
                                   : .easeInOut(duration: 0.2),
                                   value: breathPhase)
                        .transition(.opacity)
                }
            }
            // The halo lives ONLY while waiting, mirroring the working breath's
            // `if isWorking` overlay above: a value write (pulsing = false) does
            // NOT cancel an in-flight repeatForever animator, and identity flips
            // only on visibility (.id below), not on presentation, so an
            // always-present halo kept its loop alive after waiting -> working
            // and the amber ring pulsed on the now-blue dot. Removing the view
            // on exit destroys its animator dead; .transition fades it under the
            // 0.25s presentation crossfade.
            .background {
                if presentation == .waiting {
                    Circle()
                        .stroke(StatusPalette.attention, lineWidth: 1)
                        // The halo tracks the 7px dot, not the wider slot.
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulsing ? 2.6 : 1)
                        .opacity(pulsing ? 0 : 0.5)
                        .animation(motionEnabled
                                   ? .easeOut(duration: 1.8).repeatForever(autoreverses: false)
                                   : nil,
                                   value: pulsing)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: presentation)
            .onAppear {
                // Next tick, never in the insertion transaction: a
                // repeatForever started while row layout is still pending
                // captures the position delta too, and the mark animates
                // between its insertion and settled positions forever.
                DispatchQueue.main.async {
                    syncMotion(presentation: presentation, motionEnabled: motionEnabled)
                }
            }
            // The onChange closure MUST take the changed value from the
            // parameter: the closure runs against the previous body's view
            // struct, so reading the property gives the pre-change value.
            .onChange(of: presentation) {
                syncMotion(presentation: $0, motionEnabled: motionEnabled)
            }
            // Visibility flips swap the mark's IDENTITY, not just its state:
            // a value write does not cancel an in-flight repeatForever
            // animator (measured: the hidden tree kept rendering at the
            // visible rate after pulsing/breathPhase were retargeted to rest),
            // but destroying the view kills its animators dead. The fresh
            // mark starts at rest (@State resets) and its onAppear restarts
            // motion when the window is back. Presentation changes never
            // touch identity, so the 0.25s crossfade above is unaffected.
            .id(motionEnabled)
    }

    private func syncMotion(presentation: StatusPresentation, motionEnabled: Bool) {
        pulsing = motionEnabled && presentation == .waiting
        // Hold the breath clock at 1 (the repeatForever linear animation cycles
        // it 0→1 perpetually) while a working row is on screen; 0 settles it at
        // rest when not working or when the window is hidden.
        breathPhase = (motionEnabled && presentation == .working && WorkingBreath.enabled) ? 1 : 0
    }
}

/// Maps a linearly-advancing phase (0→1, driven by a repeatForever animation)
/// through a sine, so the working dot's size and brightness ease continuously and
/// never dwell at the extremes the way easeInOut + autoreverse parks at them. The
/// phase runs exactly one sine cycle over 0→1, so the repeatForever loop is
/// seamless (sin is identical at phase 0 and 1). Driving both effects off the one
/// `animatableData` phase keeps them in lockstep and smoothly sampled per frame.
/// `offset` (stable per row) desyncs rows. The unit ramp `0.5*(1+s)` runs [0,1],
/// so the dot grows from its base size and returns (never shrinks below it), and
/// the brightness rides [0, brightnessPeak] — the caller passes a positive peak
/// to brighten on dark surfaces, a negative one to darken on light ones, so the
/// color always eases away from the background. At rest (s = -1) both are 0: base
/// size, base blue.
private struct BreathPulse: ViewModifier, Animatable {
    var phase: Double
    let offset: Double
    let scalePeak: Double
    let brightnessPeak: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func body(content: Content) -> some View {
        let s = sin((phase + offset) * 2 * .pi)   // [-1, 1]
        let unit = 0.5 * (1 + s)                   // [0, 1]
        return content
            .scaleEffect(1 + scalePeak * unit)
            .brightness(brightnessPeak * unit)
    }
}

// MARK: - Attention word

/// The short colored word after the title for the states that need the user
/// (Needs input, Sign in, No remote, Crashed), and nothing for the silent
/// states (their word lives in the mark's tooltip). One view shared by the
/// main-window row and the popover row, so the word reads, colors, and fades
/// identically on both surfaces; the fade animates under the row's
/// presentation-scoped animation.
struct AttentionWord: View {
    let presentation: StatusPresentation

    var body: some View {
        if let label = presentation.attentionLabel {
            Text(label)
                .font(.caption)
                .foregroundColor(presentation.labelColor)
                .lineLimit(1)
                .fixedSize()
                .transition(.opacity)
        }
    }
}

// MARK: - Local tag

/// The quiet "Local" caption after the title for sessions launched WITHOUT
/// remote control (`--rc`): no browser/phone access, no per-session URL. It is
/// metadata, not status; it carries no status color (secondary grey only), so
/// the one-mark-per-row and status-is-the-only-color rules hold. Shown only on
/// local rows; remote rows (the default) carry nothing. The color is injected
/// so one view reads correctly on the main window (`.secondary`) and the
/// popover (`PopoverPalette.secondaryText`). Shared by both rows so
/// the tag matches across surfaces, like `AttentionWord`.
struct LocalTag: View {
    let isLocal: Bool
    var color: Color = .secondary

    var body: some View {
        if isLocal {
            Text("Local")
                .font(.caption)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize()
                .help("Local session, no browser or phone access and no per-session URL")
        }
    }
}

// MARK: - Adopt tag

/// The "Take over" tag on an unmanaged discovery row: opening or double-clicking
/// it adopts the session (flow 6.10): CCorn takes over the running session, the
/// user's existing terminal stops working, and the same conversation resumes
/// under CCorn. That consequence belongs in front of the click, so it rides next
/// to the title as a quiet bordered pill, with the full story in the tooltip.
/// Greyscale only (0.5px separator border, secondary text) so the status mark
/// stays the sole color and decoration rules hold; main-window-only, so semantic
/// colors are correct. Caller gates it to unmanaged rows.
struct AdoptTag: View {
    var body: some View {
        Text("Take over")
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
            .help("Not managed by CCorn. Opening adopts it: CCorn takes over the session (your existing terminal stops working) and resumes the conversation, so no work is lost.")
    }
}

// MARK: - Corn mark

/// CCorn's shared brand glyph: the OpenMoji ear-of-corn (`CornGlyph` asset,
/// the same artwork as the app icon, trimmed glyph-only; see
/// design-assets/app-icon/). One bundled vector replaces the system corn emoji
/// everywhere it appears in-app (main-window title bar, popover header,
/// onboarding, empty state) so the in-app mark matches the Dock/app icon
/// exactly. Color art, never a template
/// (that is the menu-bar glyph's job); CC BY-SA 4.0; see Settings ▸ About.
struct CornMark: View {
    var size: CGFloat

    var body: some View {
        Image("CornGlyph")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Primary button

/// Primary-action filled button shared by onboarding, the import sheet, the
/// empty state, and the no-managed hint. Enabled it is the spec's §3 primary
/// action (solid #09090B fill / #FAFAFA text in light, inverted in dark)
/// as an exact pair because a Color.primary fill (85%-alpha labelColor)
/// renders as a dead grey slab. Disabled is a quiet zinc wash with secondary
/// text: visibly disabled, still legible.
struct FilledButton: View {
    let title: String
    var disabled = false
    var fullWidth = false
    var height: CGFloat = 28
    /// Bind this button to the window's default action (Return). The shortcut is
    /// attached to the real `Button` below so the key equivalent fires its
    /// action, and, as the window's default, Return is routed here instead of
    /// to a focused single-line field editor (which would otherwise just
    /// reselect its text on commit). Opt-in: most FilledButtons are not default.
    var isDefault = false
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
        .keyboardShortcut(isDefault ? .defaultAction : nil)
        .animation(.easeInOut(duration: 0.15), value: disabled)
    }
}

// MARK: - Outside-click commit

extension View {
    /// Standard macOS "click-away ends the edit" behaviour for inline
    /// `TextField`s. A `.plain` field (the rename / group editors) or a sheet
    /// field lives inside a custom SwiftUI surface (a `ScrollView`/`LazyVStack`
    /// of tap-gesture rows, a sidebar `List`, a sheet) with no focusable
    /// container to steal first responder, so clicking another row or empty
    /// space leaves the field editor first responder and the edit can only be
    /// ended with Return. Apply this to the hosting window's root: while any
    /// field in the window is editing, a left click outside that field's editor
    /// resigns first responder, which flips the field's `@FocusState` to false.
    /// Editors whose only other commit path is Return pair this with an
    /// `onChange(of:)` focus-loss commit (see SessionRowView / GroupNameField);
    /// sheet fields write their binding live, so resigning is the whole job.
    func endsEditingOnOutsideClick() -> some View {
        background(OutsideClickResigner())
    }
}

/// Installs one window-local left-mouse-down monitor for the lifetime of the
/// view it backs (mirrors the always-on key monitor in MainWindowController).
/// The closure is a no-op unless a text field editor is first responder, so the
/// per-click cost when nothing is being edited is a single cast.
private struct OutsideClickResigner: NSViewRepresentable {
    func makeNSView(context: Context) -> ResignerView { ResignerView() }
    func updateNSView(_ view: ResignerView, context: Context) {}
    static func dismantleNSView(_ view: ResignerView, coordinator: ()) { view.stop() }

    final class ResignerView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stop() : start()
        }

        private func start() {
            guard monitor == nil else { return }
            // Returning the event keeps the click's normal action (selecting the
            // clicked row, pressing a button), so the edit ends AND the click
            // acts, exactly the platform default.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      let editor = window.firstResponder as? NSText else { return event }
                let editorFrame = editor.convert(editor.bounds, to: nil)
                if !editorFrame.contains(event.locationInWindow) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        deinit { stop() }
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
