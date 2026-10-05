#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${PHOTO_EXIFTOOL_LOCK_HELD:-}" != "1" ]]; then
  python3 "$PROJECT_DIR/scripts/with-exiftool-lock.py"
  exit $?
fi
ARCHIVE="$PROJECT_DIR/vendor/exiftool-13.59.tar.gz"
EXPECTED="e1e2ad6c6fbf568afee5993ef8b2b91ab013d21698c9304e079e633ad82776f5"
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ExifTool 壓縮檔 SHA-256 不符；停止建置。" >&2
  exit 1
fi
ENGINE_DEST="$PROJECT_DIR/.build/vendor-exiftool"
PATCH_SHA="$(/usr/bin/shasum -a 256 "$PROJECT_DIR/scripts/patch-worker-eof.pl" | /usr/bin/awk '{print $1}')"
IDENTITY="$EXPECTED:$PATCH_SHA"
# Never replace a valid cache while a test or build is reading its modules.
if [[ ! -L "$ENGINE_DEST" && -f "$ENGINE_DEST/.prepared-identity" && -f "$ENGINE_DEST/exiftool" && -d "$ENGINE_DEST/lib/Image/ExifTool" ]] &&
   [[ "$(cat "$ENGINE_DEST/.prepared-identity")" == "$IDENTITY" ]]; then
  echo "已準備固定版本 ExifTool 13.59；重用現有快取。"
  exit 0
fi
mkdir -p "$PROJECT_DIR/.build"
ENGINE_STAGE="$(mktemp -d "$PROJECT_DIR/.build/exiftool-stage.XXXXXX")"
# Verify the vendored supply chain (not photo contents). Full upstream source
# stays in the build tree for tests; stage-runtime.sh creates the app subset.
/usr/bin/tar -xzf "$ARCHIVE" --strip-components=1 -C "$ENGINE_STAGE"
/usr/bin/perl "$PROJECT_DIR/scripts/patch-worker-eof.pl" "$ENGINE_STAGE/exiftool"
ENGINE_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/perl "$ENGINE_STAGE/exiftool" -config '' -ver)"
if [[ "$ENGINE_VERSION" != "13.59" ]]; then
  echo "ExifTool 版本不符；停止建置。暫存保留於 $ENGINE_STAGE" >&2
  exit 1
fi
printf '%s\n' "$IDENTITY" > "$ENGINE_STAGE/.prepared-identity"
if [[ -L "$ENGINE_DEST" ]]; then
  echo "拒絕替換符號連結：$ENGINE_DEST" >&2
  exit 1
fi
if [[ -d "$ENGINE_DEST" ]]; then
  # This exact path is generated only by this script, never a user data folder.
  /bin/rm -rf -- "$ENGINE_DEST"
fi
/bin/mv "$ENGINE_STAGE" "$ENGINE_DEST"
echo "已驗證並準備 ExifTool 13.59：$ENGINE_DEST"
