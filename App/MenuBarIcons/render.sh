#!/bin/zsh -f
# Render the menu bar template icons (App/Resources/MenuBar*.png, 1x and 2x) from the SVG sources in this folder.
# Needs rsvg-convert (Homebrew librsvg). Black = opaque; macOS tints template images for light and dark menu bars.
set -euo pipefail
cd "${0:A:h}"
for svg in MenuBar*.svg; do
    name=${svg%.svg}
    rsvg-convert -w 18 "$svg" -o "../Resources/$name.png"
    rsvg-convert -w 36 "$svg" -o "../Resources/$name@2x.png"
done
