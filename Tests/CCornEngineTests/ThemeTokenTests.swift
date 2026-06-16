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
    /// attention word all point at the one token; the second amber is gone.
    @Test func attentionAmberIsTheOnlyAmber() {
        #expect(StatusPresentation.waiting.dotFill == StatusPalette.attention)
        #expect(StatusPresentation.needsAuth.symbolColor == StatusPalette.attention)
        #expect(StatusPresentation.noRemote.symbolColor == StatusPalette.attention)
        for amberWorded: StatusPresentation in [.waiting, .needsAuth, .noRemote] {
            #expect(amberWorded.labelColor == StatusPalette.attention)
        }
        // The terminal tier stays red, as the symbol and as the word.
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
    /// AA against the light row background, both the spec's #FAFAFA and the
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

    // MARK: Running green (adaptive faces, per-ground contrast)

    /// Running green: green-600 light face, green-500 dark face, and the
    /// fixed-dark popover resolves the dark face, which is the point.
    @Test func runningGreenResolvesPerAppearance() {
        let color = NSColor(StatusPalette.running)
        #expect(resolvedHex(of: color, appearance: .aqua)
                == StatusPalette.runningLightHex)
        #expect(resolvedHex(of: color, appearance: .darkAqua)
                == StatusPalette.runningDarkHex)
    }

    /// The dot is a graphical UI component: 3:1 per face, each on the grounds
    /// it actually renders over: light face on the light backgrounds, dark
    /// face on the resolved dark window background and the fixed-dark popover.
    /// The dark face is deliberately NOT held to the light grounds: green-500
    /// sits near 2.3:1 on white, which is exactly why it is dark-face only.
    @Test func runningGreenClearsUIComponentContrastPerGround() {
        #expect(contrast(StatusPalette.runningLightHex, 0xFFFFFF) >= 3.0)
        #expect(contrast(StatusPalette.runningLightHex, 0xFAFAFA) >= 3.0)
        #expect(contrast(StatusPalette.runningDarkHex, 0x1E1E1E) >= 3.0)
        #expect(contrast(StatusPalette.runningDarkHex, 0x09090B) >= 3.0)
        if let bg = resolvedHex(of: .windowBackgroundColor, appearance: .darkAqua) {
            #expect(contrast(StatusPalette.runningDarkHex, bg) >= 3.0)
        }
        // The constraint the split exists for:
        #expect(contrast(StatusPalette.runningDarkHex, 0xFFFFFF) < 3.0)
    }

    // MARK: Hollow grey's one home

    /// Stopped outline: fixed grey pair, #8A8A8F on light, zinc-400 on dark,
    /// which is exactly what the fixed-dark popover resolves to, so no
    /// per-surface parameter exists anymore.
    @Test func stoppedOutlineResolvesPerAppearance() {
        let color = NSColor(StatusPalette.stoppedOutline)
        #expect(resolvedHex(of: color, appearance: .aqua)
                == StatusPalette.stoppedOutlineLightHex)
        #expect(resolvedHex(of: color, appearance: .darkAqua)
                == StatusPalette.stoppedOutlineDarkHex)
    }

    /// The stopped ring is a UI component, so its light face needs 3:1 on the
    /// light row backgrounds, pure white and the spec's #FAFAFA. The old
    /// light face (system tertiaryLabelColor, ~#BDBDBD on white) managed only
    /// ~1.6:1 and the ring all but disappeared; that is why it became fixed.
    @Test func stoppedOutlineLightFaceClearsUIComponentContrast() {
        #expect(contrast(StatusPalette.stoppedOutlineLightHex, 0xFFFFFF) >= 3.0)
        #expect(contrast(StatusPalette.stoppedOutlineLightHex, 0xFAFAFA) >= 3.0)
        // The regression this guards against:
        #expect(contrast(0xBDBDBD, 0xFFFFFF) < 3.0)
    }

    // MARK: Working blue (adaptive faces, per-ground contrast)

    /// Working blue: blue-600 light face, blue-500 dark face, and the
    /// fixed-dark popover resolves the dark face, which is the point.
    @Test func workingBlueResolvesPerAppearance() {
        let color = NSColor(StatusPalette.working)
        #expect(resolvedHex(of: color, appearance: .aqua)
                == StatusPalette.workingLightHex)
        #expect(resolvedHex(of: color, appearance: .darkAqua)
                == StatusPalette.workingDarkHex)
    }

    /// Same per-ground floors as the running green: 3:1 per face on the
    /// grounds it actually renders over.
    @Test func workingBlueClearsUIComponentContrastPerGround() {
        #expect(contrast(StatusPalette.workingLightHex, 0xFFFFFF) >= 3.0)
        #expect(contrast(StatusPalette.workingLightHex, 0xFAFAFA) >= 3.0)
        #expect(contrast(StatusPalette.workingDarkHex, 0x1E1E1E) >= 3.0)
        #expect(contrast(StatusPalette.workingDarkHex, 0x09090B) >= 3.0)
        if let bg = resolvedHex(of: .windowBackgroundColor, appearance: .darkAqua) {
            #expect(contrast(StatusPalette.workingDarkHex, bg) >= 3.0)
        }
    }
}
