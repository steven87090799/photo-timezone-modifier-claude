#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
if [[ $# != 0 ]]; then
  echo "用法：./build.sh（僅建置 Apple Silicon／M 系列 App）" >&2
  exit 1
fi
./scripts/prepare-exiftool.sh
bash ./scripts/prepare-icon.sh
mkdir -p "$PROJECT_DIR/dist"
APP_STAGE="$(mktemp -d "$PROJECT_DIR/dist/native-build.XXXXXX")"
APP_PATH="$APP_STAGE/相片時區修改器.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

swift build --build-system native -c release --arch arm64 -Xswiftc -Osize
APP_BIN="$(swift build --build-system native -c release --arch arm64 --show-bin-path)/PhotoTimezoneApp"
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
/bin/cp "$PROJECT_DIR/.build/AppIcon.icns" "$APP_PATH/Contents/Resources/"
/usr/bin/strip -x "$APP_PATH/Contents/MacOS/PhotoTimezoneApp"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
FINAL_APP="$PROJECT_DIR/dist/相片時區修改器.app"
if [[ -e "$FINAL_APP" ]]; then
  # Preserve the previous working app until the new build has succeeded.
  /bin/mv "$FINAL_APP" "$PROJECT_DIR/dist/相片時區修改器.previous-$(/usr/bin/uuidgen).app"
fi
/bin/mv "$APP_PATH" "$FINAL_APP"
/bin/rmdir "$APP_STAGE"
echo "已建立：$FINAL_APP"
