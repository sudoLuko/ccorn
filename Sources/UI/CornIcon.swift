import AppKit
import SwiftUI

/// CCorn's corn-cob mark, drawn in code (no asset pipeline): one silhouette
/// geometry rendered as a template NSImage for the menu bar and as a SwiftUI
/// `Shape` for in-window use, plus an outline `Shape` for the empty state.
/// SF-Symbol-ish weight, no kernels, no texture on the mark
/// (docs/CCORN_SPEC.md section 3, "CCorn Icon").
enum CornIcon {
    /// Filled silhouette in a 100×100, y-down design space: elongated cob
    /// tapering toward the tip, two husk leaves cradling the base with tips
    /// angled up-outward.
    static func markPath(in rect: CGRect) -> CGPath {
        let sx = rect.width / 100
        let sy = rect.height / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        let path = CGMutablePath()

        // Cob body.
        path.move(to: p(50, 8))
        path.addCurve(to: p(71, 47), control1: p(63, 14), control2: p(71, 30))
        path.addCurve(to: p(50, 88), control1: p(71, 65), control2: p(62, 88))
        path.addCurve(to: p(29, 47), control1: p(38, 88), control2: p(29, 65))
        path.addCurve(to: p(50, 8), control1: p(29, 30), control2: p(37, 14))
        path.closeSubpath()

        // Left husk leaf: attached under the base, tip pointing up-left.
        path.move(to: p(50, 88))
        path.addCurve(to: p(14, 56), control1: p(34, 90), control2: p(19, 74))
        path.addCurve(to: p(44, 72), control1: p(24, 62), control2: p(33, 68))
        path.closeSubpath()

        // Right husk leaf, mirrored.
        path.move(to: p(50, 88))
        path.addCurve(to: p(86, 56), control1: p(66, 90), control2: p(81, 74))
        path.addCurve(to: p(56, 72), control1: p(76, 62), control2: p(67, 68))
        path.closeSubpath()

        return path
    }

    /// 18×18 template image. macOS tints it for the menu bar appearance.
    static let menuBarImage: NSImage = {
        // flipped: true gives a top-left-origin context, matching the y-down
        // design space of `markPath`.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(markPath(in: rect.insetBy(dx: 0.5, dy: 0.5)))
            ctx.setFillColor(.black)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CCorn"
        return image
    }()
}

/// The filled corn mark for in-window use (sidebar wordmark). A Shape so the
/// tint is plain SwiftUI `fill` — no template-image tinting quirks.
struct CornMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CornIcon.markPath(in: rect))
    }
}

/// Outline corn cob for the empty state (~48px, stroked, no fill) — the one
/// place CCorn's identity shows (docs/CCORN_SPEC.md section 5.6). Same cob
/// geometry as the mark, with kernel-row lines for personality.
struct CornCobShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()

        // Cob outline.
        path.move(to: p(50, 8))
        path.addCurve(to: p(71, 47), control1: p(63, 14), control2: p(71, 30))
        path.addCurve(to: p(50, 88), control1: p(71, 65), control2: p(62, 88))
        path.addCurve(to: p(29, 47), control1: p(38, 88), control2: p(29, 65))
        path.addCurve(to: p(50, 8), control1: p(29, 30), control2: p(37, 14))
        path.closeSubpath()

        // Two longitudinal lines suggesting kernel rows.
        path.move(to: p(41, 14))
        path.addCurve(to: p(41, 82), control1: p(35, 34), control2: p(35, 62))
        path.move(to: p(59, 14))
        path.addCurve(to: p(59, 82), control1: p(65, 34), control2: p(65, 62))

        // Husk leaves, tips angled up-outward from the base.
        path.move(to: p(48, 86))
        path.addCurve(to: p(14, 56), control1: p(32, 89), control2: p(18, 73))
        path.addCurve(to: p(42, 74), control1: p(23, 61), control2: p(32, 69))
        path.move(to: p(52, 86))
        path.addCurve(to: p(86, 56), control1: p(68, 89), control2: p(82, 73))
        path.addCurve(to: p(58, 74), control1: p(77, 61), control2: p(68, 69))

        return path
    }
}
