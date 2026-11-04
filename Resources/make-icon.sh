#!/bin/zsh
# Renders the app icon with the app's own renderer and packs it into Resources/AppIcon.icns.
set -e
cd "${0:A:h}/.."
.build/release/Headroom --make-icon Resources/icon-1024.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "${SET:h}"
echo "made Resources/AppIcon.icns"
