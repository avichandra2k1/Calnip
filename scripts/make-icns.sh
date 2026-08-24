#!/bin/zsh
# Convert a square PNG (ideally 1024x1024) into Resources/AppIcon.icns.
# usage: scripts/make-icns.sh path/to/icon.png
set -e
SRC="$1"
[[ -f "$SRC" ]] || { echo "usage: $0 icon.png" >&2; exit 1; }
cd "$(dirname "$0")/.."
mkdir -p Resources
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
