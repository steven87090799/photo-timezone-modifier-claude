#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${PHOTO_EXIFTOOL_LOCK_HELD:-}" != "1" ]]; then
  python3 "$PROJECT_DIR/scripts/with-exiftool-lock.py"
  exit $?
fi
ARCHIVE="$PROJECT_DIR/vendor/exiftool-13.64.tar.gz"
EXPECTED="1c890a0324d5ad5aae6e17c1b57c620e420d2846fcfa17bbf34407a5441efbbd"
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ExifTool 壓縮檔 SHA-256 不符；停止建置。" >&2
  exit 1
fi
ENGINE_DEST="$PROJECT_DIR/.build/vendor-exiftool"
PATCH="$PROJECT_DIR/scripts/patch-exiftool-heif.py"
PATCH_SHA="$(/usr/bin/shasum -a 256 "$PATCH" | /usr/bin/awk '{print $1}')"
IDENTITY="$EXPECTED:$PATCH_SHA"
# Validate the cached CLI and every staged module before reusing them.
if [[ ! -L "$ENGINE_DEST" && -f "$ENGINE_DEST/.prepared-identity" && -f "$ENGINE_DEST/.runtime-sha256" ]] &&
   [[ "$(cat "$ENGINE_DEST/.prepared-identity")" == "$IDENTITY" ]] &&
   (cd "$ENGINE_DEST" && /usr/bin/shasum -a 256 -c .runtime-sha256 >/dev/null); then
  echo "已準備固定版本 ExifTool 13.64；重用現有快取。"
  exit 0
fi
mkdir -p "$PROJECT_DIR/.build"
ENGINE_STAGE="$(mktemp -d "$PROJECT_DIR/.build/exiftool-stage.XXXXXX")"
# Verify the vendored supply chain (not photo contents). Full upstream source
# stays in the build tree for tests; stage-runtime.sh creates the app subset.
/usr/bin/tar -xzf "$ARCHIVE" --strip-components=1 -C "$ENGINE_STAGE"
python3 "$PATCH" "$ENGINE_STAGE"
ENGINE_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/perl "$ENGINE_STAGE/exiftool" -config '' -ver)"
if [[ "$ENGINE_VERSION" != "13.64" ]]; then
  echo "ExifTool 版本不符；停止建置。暫存保留於 $ENGINE_STAGE" >&2
  exit 1
fi
(
  cd "$ENGINE_STAGE"
  /usr/bin/shasum -a 256 exiftool LICENSE README
  /usr/bin/find lib -type f -print0 | /usr/bin/xargs -0 /usr/bin/shasum -a 256
) > "$ENGINE_STAGE/.runtime-sha256"
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
echo "已驗證並準備 ExifTool 13.64：$ENGINE_DEST"
