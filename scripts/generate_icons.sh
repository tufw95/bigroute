#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT_DIR/Assets/BigrouteIcon.svg"
PNG="$ROOT_DIR/Assets/BigrouteIcon.png"
ICNS="$ROOT_DIR/Assets/Bigroute.icns"
WORK_DIR="$(mktemp -d)"
ICONSET="$WORK_DIR/Bigroute.iconset"

trap 'rm -R "$WORK_DIR"' EXIT
mkdir -p "$ICONSET"

sips -s format png "$MASTER" --out "$PNG" >/dev/null

make_icon() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$PNG" --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Generated $PNG and $ICNS"
