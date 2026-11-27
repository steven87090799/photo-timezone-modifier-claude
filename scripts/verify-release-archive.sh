#!/bin/bash
set -euo pipefail
[[ $# = 1 ]] || { echo "Usage: verify-release-archive.sh ZIP" >&2; exit 2; }
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
archived="$1"
stage="$(mktemp -d "${TMPDIR:-/tmp}/phototimezone-archive.XXXXXX")"
trap '/bin/rm -rf "$stage"' EXIT
unzip -tq "$archived"
/usr/bin/ditto -x -k "$archived" "$stage"
app="$stage/相片時區修改器.app"
/usr/bin/codesign --verify --deep --strict "$app"
python3 "$PROJECT_DIR/scripts/verify-app-bundle.py" "$app"
resources="$app/Contents/Resources"
NEXPRESS_ROOT="$resources/CompressionWeb" node "$PROJECT_DIR/CompressionWeb/scripts/check-build-info.mjs"
python3 "$PROJECT_DIR/scripts/dependency-manifest.py" verify "$resources"
if [[ "${PHOTO_TIMEZONE_REQUIRE_NOTARY:-0}" == 1 ]]; then
    /usr/bin/codesign -d --verbose=4 "$app" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:'
    xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute --verbose "$app"
fi
