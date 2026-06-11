import AppKit
import SwiftUI
import Testing

/// Token-hygiene pass: the single appearance-adaptive attention amber (the
/// two-amber split is gone), its WCAG contrast on both appearances, the
/// hollow-grey stopped outline's one home, and the color routing that
/// StatusMark and AttentionWord render.
@Suite struct ThemeTokenTests {

    // MARK: WCAG math (sRGB relative luminance / contrast ratio)

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// RGB hex of a (possibly dynamic) NSColor resolved under an appearance.
    private func resolvedHex(of color: NSColor,
                             appearance name: NSAppearance.Name) -> UInt32? {
        var srgb: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            srgb = color.usingColorSpace(.sRGB)
        }
        guard let srgb else { return nil }
        func byte(_ component: CGFloat) -> UInt32 {
            UInt32((component * 255).rounded())
        }
        return byte(srgb.redComponent) << 16
            | byte(srgb.greenComponent) << 8
            | byte(srgb.blueComponent)
    }

    // MARK: One attention amber

    /// The waiting dot, both recoverable warning triangles, and every amber
    /// attention word all point at the one token — the second amber is gone.
    @Test func attentionAmberIsTheOnlyAmber() {
        #expect(StatusPresentation.waiting.dotFill == StatusPalette.attention)
        #expect(StatusPresentation.needsAuth.symbolColor == StatusPalette.attention)
        #expect(StatusPresentation.noRemote.symbolColor == StatusPalette.attention)
        for amberWorded: StatusPresentation in [.waiting, .needsAuth, .noRemote] {
            #expect(amberWorded.labelColor == StatusPalette.attention)
        }
        // The terminal tier stays red — as the symbol and as the word.
        #expect(StatusPresentation.crashed.symbolColor == StatusPalette.dead)
        #expect(StatusPresentation.crashed.labelColor == StatusPalette.dead)
    }

    /// The token is appearance-adaptive: dark amber on light, bright amber on
    /// dark (and therefore in the fixed-dark popover).
    @Test func attentionAmberResolvesPerAppearance() {
        let color = NSColor(StatusPalette.attention)
        #expect(resolvedHex(of: color, appearance: .aqua)
                == StatusPalette.attentionLightHex)
        #expect(resolvedHex(of: color, appearance: .darkAqua)
                == StatusPalette.attentionDarkHex)
    }

    // MARK: Word contrast (WCAG AA, normal text: 4.5:1)

    /// The attention word is caption-size TEXT, so the light amber must clear
    /// AA against the light row background — both the spec's #FAFAFA and the
    /// real macOS windowBackgroundColor, which is darker. The old #D97706
    /// managed only ~3:1; that is why the light face darkened.
    @Test func lightAttentionWordClearsAAOnLightBackground() {
        #expect(contrast(StatusPalette.attentionLightHex, 0xFAFAFA) >= 4.5)
        if let bg = resolvedHex(of: .windowBackgroundColor, appearance: .aqua) {
            #expect(contrast(StatusPalette.attentionLightHex, bg) >= 4.5)
        }
        // The regression this guards against:
        #expect(contrast(0xD97706, 0xFAFAFA) < 4.5)
    }

    @Test func darkAttentionWordClearsAAOnDarkBackgrounds() {
        // Fixed-dark popover background (#09090B).
        #expect(contrast(StatusPalette.attentionDarkHex, 0x09090B) >= 4.5)
        if let bg = resolvedHex(of: .windowBackgroundColor, appearance: .darkAqua) {
            #expect(contrast(StatusPalette.attentionDarkHex, bg) >= 4.5)
        }
    }

    /// The dot and triangle are UI components, not text: 3:1 is their bar
    /// (both faces clear it with room once AA passes, but pin it explicitly).
    @Test func attentionMarkClearsUIComponentContrast() {
        #expect(contrast(StatusPalette.attentionLightHex, 0xFAFAFA) >= 3.0)
        #expect(contrast(StatusPalette.attentionDarkHex, 0x09090B) >= 3.0)
    }

    // MARK: Hollow grey's one home

    /// Stopped outline: adaptive semantic grey on light, fixed zinc-400 on
    /// dark — which is exactly what the fixed-dark popover resolves to, so
    /// no per-surface parameter exists anymore.
    @Test func stoppedOutlineResolvesPerAppearance() {
        let color = NSColor(StatusPalette.stoppedOutline)
        #expect(resolvedHex(of: color, appearance: .darkAqua) == 0xA1A1AA)
        // Light face matches the system tertiary label (including alpha).
        var expected: NSColor?
        var actual: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            expected = NSColor.tertiaryLabelColor.usingColorSpace(.sRGB)
            actual = color.usingColorSpace(.sRGB)
        }
        #expect(actual != nil)
        #expect(actual == expected)
    }
}
