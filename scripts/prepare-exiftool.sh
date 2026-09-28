#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$PROJECT_DIR/vendor/exiftool-13.59.tar.gz"
EXPECTED="e1e2ad6c6fbf568afee5993ef8b2b91ab013d21698c9304e079e633ad82776f5"
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ExifTool 壓縮檔 SHA-256 不符；停止建置。" >&2
  exit 1
fi
mkdir -p "$PROJECT_DIR/.build"
ENGINE_STAGE="$(mktemp -d "$PROJECT_DIR/.build/exiftool-stage.XXXXXX")"
# Full, unmodified upstream source and license are retained in the bundle.
/usr/bin/tar -xzf "$ARCHIVE" --strip-components=1 -C "$ENGINE_STAGE"
ENGINE_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/perl "$ENGINE_STAGE/exiftool" -config '' -ver)"
if [[ "$ENGINE_VERSION" != "13.59" ]]; then
  echo "ExifTool 版本不符；停止建置。暫存保留於 $ENGINE_STAGE" >&2
  exit 1
fi
ENGINE_DEST="$PROJECT_DIR/.build/vendor-exiftool"
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
