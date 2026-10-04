#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "測試基線只支援 Apple Silicon（arm64）macOS。" >&2
  exit 1
fi
OS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')"
if (( OS_MAJOR < 27 )); then
  echo "測試需要 macOS 27 或更新版本；目前為 $(/usr/bin/sw_vers -productVersion)。" >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=27.0

./scripts/prepare-exiftool.sh

# FileProvider may reattach FinderInfo between compilation and codesign.
# Keep executable test products outside Documents; caller can override.
TEST_ARGS=("$@")
if [[ " $* " != *" --scratch-path "* && " $* " != *" --scratch-path="* ]]; then
  TEST_ARGS=(--scratch-path "/private/tmp/PhotoTimezone-tests-$UID" "$@")
fi

TEST_DEVELOPER_DIR="$(xcode-select -p)"
TEST_PLUGIN="$TEST_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

if [[ -f "$TEST_PLUGIN" ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" "${TEST_ARGS[@]}"
else
  swift test "${TEST_ARGS[@]}"
fi
