#!/bin/bash
set -euo pipefail

# Regenerates iOS app icon PNGs from a single source image.
# Usage:
#   ./scripts/update_icons.sh /path/to/source.png

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/source.png"
  exit 1
fi

SRC_INPUT="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DST_DIR="$PROJECT_DIR/App/SDRApp/Resources"

if [ ! -f "$SRC_INPUT" ]; then
  echo "Error: source image not found: $SRC_INPUT"
  exit 1
fi

mkdir -p "$DST_DIR"

echo "Generating app icons from: $SRC_INPUT"
echo "Output folder: $DST_DIR"

sips -z 60 60   "$SRC_INPUT" --out "$DST_DIR/AppIcon60x60.png" >/dev/null
sips -z 120 120 "$SRC_INPUT" --out "$DST_DIR/AppIcon60x60@2x.png" >/dev/null
sips -z 180 180 "$SRC_INPUT" --out "$DST_DIR/AppIcon60x60@3x.png" >/dev/null
sips -z 76 76   "$SRC_INPUT" --out "$DST_DIR/AppIcon76x76.png" >/dev/null
sips -z 152 152 "$SRC_INPUT" --out "$DST_DIR/AppIcon76x76@2x.png" >/dev/null
sips -z 167 167 "$SRC_INPUT" --out "$DST_DIR/AppIcon83.5x83.5@2x.png" >/dev/null

echo "Done. Generated files:"
ls -1 "$DST_DIR" | grep "^AppIcon"
