#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
./scripts/prepare-exiftool.sh

TEST_DEVELOPER_DIR=""
if command -v xcode-select >/dev/null 2>&1; then TEST_DEVELOPER_DIR="$(xcode-select -p)"; fi
TEST_PLUGIN="$TEST_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

# Use SwiftPM's standard native test path on Apple runners, loading the CLT
# Testing macro plugin when available. Linux uses the Testing-only path.
# Copy/GPS hangs were traced to DestinationPlan's root traversal, not SwiftPM.
if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -f "$TEST_PLUGIN" ]]; then
    swift test -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" "$@"
  else
    swift test "$@"
  fi
else
  swift test --disable-xctest "$@"
fi
