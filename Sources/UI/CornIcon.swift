import AppKit

/// CCorn's corn-cob mark, drawn in code (no asset pipeline): one stroked
/// outline geometry — tilted cob, kernel-row lines, two husk blades — rendered
/// as a template NSImage for the menu bar. This vector mark exists ONLY for
/// the places a color emoji cannot go (the menu-bar template glyph and,
/// eventually, the app icon); everywhere in-window the brand mark is the corn
/// emoji (review item 3).
///
/// The mark is an OUTLINE on purpose: a filled corn silhouette with no kernel
/// detail is ambiguous at small sizes (it reads as a microphone upright, a
/// rocket tilted — both were flagged in review). The kernel lines are what make
/// it corn, and the tilt keeps it from reading as a mic capsule. At small sizes
/// the kernel cross-lines are dropped so the glyph doesn't smear.
enum CornIcon {
    /// Tilt applied to the whole glyph (tip up-right) within the 100×100,
    /// y-down design space.
    private static let tilt: CGFloat = 32 * .pi / 180

    /// Outline geometry. `crossLines` adds the kernel cross-lines — full detail
    /// for ≥~32px renders; omit below that.
    static func cornPath(in rect: CGRect, crossLines: Bool) -> CGPath {
        let sx = rect.width / 100
        let sy = rect.height / 100
        // Rotate about the design-space center, then scale into rect.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let dx = x - 50, dy = y - 50
            let rx = 50 + dx * cos(tilt) - dy * sin(tilt)
            let ry = 50 + dx * sin(tilt) + dy * cos(tilt)
            return CGPoint(x: rect.minX + rx * sx, y: rect.minY + ry * sy)
        }

        let path = CGMutablePath()

        // Cob outline: tapered toward the tip, rounded base.
        path.move(to: p(50, 10))
        path.addCurve(to: p(65, 48), control1: p(59, 14), control2: p(65, 30))
        path.addCurve(to: p(50, 82), control1: p(65, 66), control2: p(60, 82))
        path.addCurve(to: p(35, 48), control1: p(40, 82), control2: p(35, 66))
        path.addCurve(to: p(50, 10), control1: p(35, 30), control2: p(41, 14))
        path.closeSubpath()

        // Kernel rows: two longitudinal lines following the taper.
        path.move(to: p(44, 13))
        path.addCurve(to: p(44, 80), control1: p(40, 34), control2: p(40, 62))
        path.move(to: p(56, 13))
        path.addCurve(to: p(56, 80), control1: p(60, 34), control2: p(60, 62))

        if crossLines {
            path.move(to: p(36, 36))
            path.addCurve(to: p(64, 36), control1: p(46, 32), control2: p(54, 32))
            path.move(to: p(35, 54))
            path.addCurve(to: p(65, 54), control1: p(46, 50), control2: p(54, 50))
            path.move(to: p(38, 70))
            path.addCurve(to: p(62, 70), control1: p(47, 66), control2: p(53, 66))
        }

        // Husk blades: attach low on the cob, tips sweeping out past the base.
        path.move(to: p(39, 64))
        path.addCurve(to: p(20, 92), control1: p(33, 76), control2: p(26, 86))
        path.addCurve(to: p(46, 86), control1: p(29, 94), control2: p(39, 92))
        path.move(to: p(61, 64))
        path.addCurve(to: p(70, 94), control1: p(67, 76), control2: p(71, 88))
        path.addCurve(to: p(52, 86), control1: p(62, 96), control2: p(56, 92))

        return path
    }

    /// 18×18 template image. macOS tints it for the menu bar appearance.
    static let menuBarImage: NSImage = {
        // flipped: true gives a top-left-origin context, matching the y-down
        // design space of `cornPath`.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(cornPath(in: rect.insetBy(dx: 1, dy: 1), crossLines: false))
            ctx.setStrokeColor(.black)
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CCorn"
        return image
    }()
}
