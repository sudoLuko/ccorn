# App icon attribution

The CCorn app icon is the ear-of-corn glyph from **OpenMoji**, set on a white
rounded tile.

> Emoji artwork from [OpenMoji](https://openmoji.org), the open-source emoji
> and icon project: the [ear-of-corn glyph
> `1F33D`](https://openmoji.org/library/emoji-1F33D/). Licensed under
> [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), and adapted
> here — set on a rounded tile for the app icon, and cropped to a tightened
> viewBox for the in-app glyph.

## Obligations (CC BY-SA 4.0)

- **Attribution**: keep the credit above. It should also appear somewhere
  user-facing (the app's About box and/or the project README).
- **ShareAlike**: the icon *artwork* (this adaptation: OpenMoji corn on a
  tile) is itself licensed CC BY-SA 4.0. This applies to the image only; it
  does **not** change the license of CCorn's source code.

## Source

- Glyph: OpenMoji `1F33D` (ear of corn), color SVG.
- Repo source: `ccorn-appicon-openmoji.svg`
- Master: `ccorn-appicon-openmoji-1024.png`, OpenMoji glyph rendered into a
  1064px box, centered on a 1024² white rounded tile (corner radius 230), sRGB.
  The glyph's ink is ~65% of its render box, so it fills ~67.5% of the canvas
  (was a 760px box / ~48% fill, which read small with heavy padding; the +40%
  bump leaves a ~16% margin inside the rounded tile).
- Regenerate the shipped sizes: run `./make-appicon.sh`. It draws the tile,
  composites the glyph at the size above, and downscales to
  16/32/64/128/256/512/1024 into `Sources/Assets.xcassets/AppIcon.appiconset/`.
  The glyph render box (`GLYPH_BOX`) is the only knob that controls glyph scale.

## In-app glyph (`CornGlyph` asset)

The same OpenMoji glyph, *without* the tile, is the one shared mark for every
in-app surface (brand lockup, onboarding, empty state) via the `CornMark`
SwiftUI view. It is a vector PDF so it stays crisp at every size (15–44pt).

- Source: `ccorn-glyph-inapp.svg`, `ccorn-appicon-openmoji.svg` with its
  viewBox tightened to the glyph's ink bounds + a small uniform margin
  (`viewBox="9.5 11 52.9 52.9"`, ~85% fill) so it centers and reads at the
  same optical weight the corn emoji did.
- Regenerate the asset (needs `librsvg`):
  `rsvg-convert -f pdf -o ../../Sources/Assets.xcassets/CornGlyph.imageset/CornGlyph.pdf ccorn-glyph-inapp.svg`
- Same CC BY-SA 4.0 obligations as the app icon: this is another adaptation of
  the OpenMoji artwork, covered by the attribution already shipped.
