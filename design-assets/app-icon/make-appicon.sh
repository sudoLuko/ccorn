#!/bin/zsh
# Regenerate the shipped AppIcon.appiconset PNGs from the vector source.
# Source of truth: ccorn-appicon.svg (vectorized from the approved Grok
# reference, reference-grok.jpg). The SVG keeps the corn motif and the
# white background in separate groups so the background can be stripped
# for Icon Composer later.
set -e
cd "$(dirname $0)"
dest=../../Sources/Assets.xcassets/AppIcon.appiconset
for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $px -h $px ccorn-appicon.svg -o $dest/icon_$px.png
done
echo "regenerated $dest from ccorn-appicon.svg"
