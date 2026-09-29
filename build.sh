#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
./scripts/prepare-exiftool.sh
bash ./scripts/prepare-icon.sh
mkdir -p "$PROJECT_DIR/dist"
APP_STAGE="$(mktemp -d "$PROJECT_DIR/dist/native-build.XXXXXX")"
APP_PATH="$APP_STAGE/相片時區修改器.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

if [[ "$#" -gt 0 ]] && [[ "$1" == "--universal" ]]; then
  swift build --build-system native -c release --arch arm64
  ARM_BIN="$(swift build --build-system native -c release --arch arm64 --show-bin-path)/PhotoTimezoneApp"
  swift build --build-system native -c release --arch x86_64
  INTEL_BIN="$(swift build --build-system native -c release --arch x86_64 --show-bin-path)/PhotoTimezoneApp"
  /usr/bin/lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP_PATH/Contents/MacOS/PhotoTimezoneApp"
elif [[ $# == 0 ]]; then
  swift build --build-system native -c release
  APP_BIN="$(swift build --build-system native -c release --show-bin-path)/PhotoTimezoneApp"
  /bin/cp "$APP_BIN" "$APP_PATH/Contents/MacOS/PhotoTimezoneApp"
else
  echo "用法：./build.sh [--universal]" >&2
  exit 1
fi

/bin/cp app/Info.plist "$APP_PATH/Contents/Info.plist"
/bin/cp -R app/Localization/zh-Hant-TW.lproj "$APP_PATH/Contents/Resources/"
/bin/cp -R "$PROJECT_DIR/.build/vendor-exiftool" "$APP_PATH/Contents/Resources/ExifTool"
/bin/cp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/"
/bin/cp "$PROJECT_DIR/.build/AppIcon.icns" "$APP_PATH/Contents/Resources/"
/bin/cp app/Assets/AppIcon.png "$APP_PATH/Contents/Resources/"
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
