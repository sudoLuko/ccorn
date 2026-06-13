#!/bin/zsh
# Regenerate the shipped AppIcon.appiconset PNGs from the OpenMoji glyph.
#
# Pipeline (matches docs/app-icon/ICON_CREDITS.md):
#   1. Draw a full-bleed white rounded tile, 1024x1024, corner radius 230,
#      transparent outside the corners (macOS does NOT mask app-icon PNGs, so
#      the rounded tile is baked in here, not applied by the OS).
#   2. Render the OpenMoji ear-of-corn glyph (ccorn-appicon-openmoji.svg) into a
#      GLYPH_BOX x GLYPH_BOX transparent square and composite it dead-centre on
#      the tile. The glyph's ink is ~65% of its render box, so GLYPH_BOX sets the
#      on-canvas glyph size; this is the only knob that controls glyph scale.
#   3. Down-scale that 1024 master (Lanczos) into every shipped size.
#
# GLYPH_BOX history: 760 was the original render box (glyph ink ~48% of canvas,
# which read small with heavy padding). 1064 enlarges the glyph by +40% (ink
# ~67.5% of canvas) while keeping a ~16% margin inside the rounded tile.
set -e
cd "$(dirname $0)"

GLYPH=ccorn-appicon-openmoji.svg
MASTER=ccorn-appicon-openmoji-1024.png      # gitignored 1024 intermediate
DEST=../../Sources/Assets.xcassets/AppIcon.appiconset

CANVAS=1024
RADIUS=230
GLYPH_BOX=1064                              # glyph render box (see header)

# 1+2: tile + centred glyph, built in a single pipeline so the white base stays
# sRGB in memory (a standalone all-white PNG round-trips to grayscale, which
# would desaturate the composited glyph). Force RGBA on write (png:color-type=6).
rsvg-convert -w $GLYPH_BOX -h $GLYPH_BOX "$GLYPH" -o /tmp/ccorn-glyph-render.png
magick -size ${CANVAS}x${CANVAS} xc:none \
  -fill white -draw "roundrectangle 0,0 $((CANVAS-1)),$((CANVAS-1)) $RADIUS,$RADIUS" \
  \( /tmp/ccorn-glyph-render.png \) -gravity center -compose over -composite \
  -colorspace sRGB -define png:color-type=6 "$MASTER"
rm -f /tmp/ccorn-glyph-render.png

# 3: down-scale the master into the shipped sizes.
for px in 16 32 64 128 256 512 1024; do
  if [ "$px" -eq "$CANVAS" ]; then
    cp "$MASTER" "$DEST/icon_$px.png"
  else
    magick "$MASTER" -filter Lanczos -resize ${px}x${px} \
      -colorspace sRGB -define png:color-type=6 "$DEST/icon_$px.png"
  fi
done

echo "regenerated $DEST from $GLYPH (GLYPH_BOX=$GLYPH_BOX)"
