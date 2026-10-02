#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-$PROJECT_DIR/.build/real-arw-fixtures}"
NAME="ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"
URL="https://raw.pixls.us/data/Sony/ILCE-7M4/$NAME"
EXPECTED_SHA256="cbbd0930c7d8706dff84c68a2004454266e6fd0d8354f5f76a106b5d776e0223"

mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$NAME"
TMP="$DEST_DIR/.$NAME.$$.tmp"
trap 'rm -f "$TMP"' EXIT

verify() {
  local actual
  actual="$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$EXPECTED_SHA256" ]]
}

if [[ -f "$DEST" ]] && verify "$DEST"; then
  printf '%s\n' "$DEST"
  exit 0
fi

rm -f "$DEST" "$TMP"
/usr/bin/curl --fail --location --retry 4 --retry-all-errors --connect-timeout 20   --output "$TMP" "$URL"
verify "$TMP" || {
  echo "Sony ARW fixture SHA-256 驗證失敗。" >&2
  exit 1
}
/bin/mv "$TMP" "$DEST"

# raw.pixls.us publishes uploaded RAW samples under CC0/public-domain terms.
# The fixed filename and SHA-256 make this CI input reproducible.
printf '%s\n' "$DEST"
