#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
./scripts/prepare-exiftool.sh

TEST_DEVELOPER_DIR=""
if command -v xcode-select >/dev/null 2>&1; then TEST_DEVELOPER_DIR="$(xcode-select -p)"; fi
TEST_PLUGIN="$TEST_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TEST_PLUGIN" ]]; then
  # CLT Swift 6.4 can lose automatic Testing macro discovery on incremental
  # rebuilds. Explicit loading uses the same shipped compiler plugin.
  swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" "$@"
else
  swift test --disable-xctest "$@"
fi
