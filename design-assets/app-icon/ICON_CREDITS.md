# App icon attribution

The CCorn app icon is the ear-of-corn glyph from **OpenMoji**, set on a white
rounded tile.

> Emoji artwork from [OpenMoji](https://openmoji.org) — the open-source emoji
> and icon project. Licensed under
> [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## Obligations (CC BY-SA 4.0)

- **Attribution** — keep the credit above. It should also appear somewhere
  user-facing (the app's About box and/or the project README).
- **ShareAlike** — the icon *artwork* (this adaptation: OpenMoji corn on a
  tile) is itself licensed CC BY-SA 4.0. This applies to the image only; it
  does **not** change the license of CCorn's source code.

## Source

- Glyph: OpenMoji `1F33D` (ear of corn), color SVG.
- Repo source: `ccorn-appicon-openmoji.svg`
- Master: `ccorn-appicon-openmoji-1024.png` — OpenMoji glyph rendered at 760px,
  centered on a 1024² white rounded tile (corner radius 230), sRGB.
- Regenerate the shipped sizes: render the master, then downscale to
  16/32/64/128/256/512/1024 into `Sources/Assets.xcassets/AppIcon.appiconset/`.
