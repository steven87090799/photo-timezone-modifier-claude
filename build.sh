#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "此專案只建置 Apple Silicon（arm64）macOS App。" >&2
  exit 1
fi
OS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')"
if (( OS_MAJOR < 27 )); then
  echo "需要 macOS 27 或更新版本；目前為 $(/usr/bin/sw_vers -productVersion)。" >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=27.0

if [[ $# != 0 ]]; then
  echo "用法：./build.sh（僅建置 Apple Silicon／M 系列 App）" >&2
  exit 1
fi
./scripts/prepare-exiftool.sh
python3 ./scripts/prepare-jpegli.py
bash ./scripts/prepare-icon.sh
mkdir -p "$PROJECT_DIR/dist"
# Build outside FileProvider-managed Documents so Finder attributes cannot be
# reattached between xattr cleanup and code signing.
APP_STAGE="$(mktemp -d /tmp/phototimezone-native-build.XXXXXX)"
APP_PATH="$APP_STAGE/相片時區修改器.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

swift build --scratch-path "/private/tmp/PhotoTimezone-build-$UID" -c release --arch arm64 -Xswiftc -Osize
APP_BIN="$(swift build --scratch-path "/private/tmp/PhotoTimezone-build-$UID" -c release --arch arm64 --show-bin-path)/PhotoTimezoneApp"
/bin/cp "$APP_BIN" "$APP_PATH/Contents/MacOS/PhotoTimezoneApp"
APP_ARCHS="$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/PhotoTimezoneApp")"
if [[ "$APP_ARCHS" != "arm64" ]]; then
  echo "App 架構不符：預期 arm64，實際為 $APP_ARCHS" >&2
  exit 1
fi

/bin/cp app/Info.plist "$APP_PATH/Contents/Info.plist"
/bin/cp -R app/Localization/zh-Hant-TW.lproj "$APP_PATH/Contents/Resources/"
./scripts/stage-runtime.sh "$PROJECT_DIR/.build/vendor-exiftool" "$APP_PATH/Contents/Resources/ExifTool"
/bin/cp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/"
/bin/cp -R "$PROJECT_DIR/.build/vendor-jpegli/licenses" "$APP_PATH/Contents/Resources/JpegliLicenses"
/bin/cp -R CompressionWeb "$APP_PATH/Contents/Resources/"
/bin/cp "$PROJECT_DIR/.build/AppIcon.icns" "$APP_PATH/Contents/Resources/"
/usr/bin/strip -x "$APP_PATH/Contents/MacOS/PhotoTimezoneApp"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
# Copied browser assets can inherit Finder provenance/resource-fork attributes,
# which codesign rejects. Clear them only from this disposable staging bundle.
/usr/bin/xattr -cr "$APP_PATH"
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
ZIP_STAGE="$APP_STAGE/PhotoTimezone-macOS-local.zip"
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_STAGE"
ZIP_VERIFY="$(mktemp -d /tmp/phototimezone-zip-verify.XXXXXX)"
/usr/bin/ditto -x -k "$ZIP_STAGE" "$ZIP_VERIFY"
/usr/bin/codesign --verify --strict "$ZIP_VERIFY/相片時區修改器.app"
if [[ "$(/usr/bin/lipo -archs "$ZIP_VERIFY/相片時區修改器.app/Contents/MacOS/PhotoTimezoneApp")" != "arm64" ]]; then
  echo "ZIP 內 App 架構不是 arm64。" >&2
  exit 1
fi
/bin/rm -rf "$ZIP_VERIFY"
FINAL_APP="$PROJECT_DIR/dist/相片時區修改器.app"
FINAL_ZIP="$PROJECT_DIR/dist/PhotoTimezone-macOS.zip"
if [[ -e "$FINAL_ZIP" ]]; then
  /bin/rm -f "$FINAL_ZIP"
fi
/bin/mv "$ZIP_STAGE" "$FINAL_ZIP"
if [[ -e "$FINAL_APP" ]]; then
  # Only replace generated products after the new ZIP passes verification.
  /bin/rm -rf "$FINAL_APP"
fi
/bin/mv "$APP_PATH" "$FINAL_APP"
# FileProvider-managed Documents folders may reattach FinderInfo even after
# this check. The ZIP above was extracted and strictly verified outside it.
/usr/bin/xattr -d com.apple.FinderInfo "$FINAL_APP" 2>/dev/null || true
if ! /usr/bin/codesign --verify --strict "$FINAL_APP"; then
  echo "Documents 的 FileProvider 重新附加了 App 屬性；請使用已驗證的 ZIP。" >&2
fi
/bin/rmdir "$APP_STAGE"
echo "已建立：$FINAL_APP"
echo "已驗證的 ZIP：$FINAL_ZIP"
