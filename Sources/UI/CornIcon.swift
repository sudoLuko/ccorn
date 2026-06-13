import AppKit

/// CCorn's menu-bar mark: the "direction K" upright corn pictogram (cob with
/// dotted kernels, husk V, tall leaf), generated in Gemini and processed to a
/// single-color template master. Shipped as `MenuBarCorn.imageset`
/// (`design-assets/corn-glyph/` is the source + regeneration recipe) and always
/// rendered as a template so macOS tints it for the menu-bar appearance.
///
/// History: three rounds of hand-built vector cobs were tried first; at 18px
/// under menu-bar vibrancy the identity has to live in the silhouette, and the
/// upright raster composition keeps what little interior detail survives
/// pixel-aligned. See `design-assets/corn-glyph/README.md`.
enum CornIcon {
    /// Template menu-bar image. The imageset carries the 18pt (@1x/@2x) reps and
    /// a template rendering intent; `isTemplate` is set defensively too.
    static let menuBarImage: NSImage = {
        let image = NSImage(named: "MenuBarCorn")
            ?? NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "CCorn")!
        image.isTemplate = true
        image.accessibilityDescription = "CCorn"
        return image
    }()
}
