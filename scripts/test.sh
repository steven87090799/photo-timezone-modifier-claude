#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
./scripts/prepare-exiftool.sh

TEST_DEVELOPER_DIR=""
if command -v xcode-select >/dev/null 2>&1; then TEST_DEVELOPER_DIR="$(xcode-select -p)"; fi
TEST_PLUGIN="$TEST_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

# On Apple runners use SwiftPM's standard test path. --disable-xctest can leave
# swiftpm-testing stuck after a successful build on current macOS/Xcode images.
# Linux keeps the explicit Testing-only path used by the portable validation.
if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -f "$TEST_PLUGIN" ]]; then
    swift test -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" "$@"
  else
    swift test "$@"
  fi
else
  swift test --disable-xctest "$@"
fi
