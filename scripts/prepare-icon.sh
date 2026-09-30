#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SOURCE="$PROJECT_DIR/app/Assets/AppIcon.png"
mkdir -p "$PROJECT_DIR/.build"
ICON_STAGE="$(mktemp -d "$PROJECT_DIR/.build/icon.XXXXXX")"
ICON_SET="$ICON_STAGE/AppIcon.iconset"
mkdir -p "$ICON_SET"
for ICON_SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  ICON_DOUBLE=$((ICON_SIZE * 2))
  /usr/bin/sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_SOURCE" --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICON_SET" -o "$PROJECT_DIR/.build/AppIcon.icns"
# The generated iconset is retained under .build for inspection.
