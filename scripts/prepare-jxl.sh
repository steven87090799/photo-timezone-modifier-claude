#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "JPEG XL 原生編碼器需要 Apple Silicon macOS。" >&2
  exit 1
fi
if ! command -v brew >/dev/null; then
  echo "JPEG XL 原生編碼器需要 Homebrew；請安裝 Homebrew 後執行 brew install jpeg-xl。" >&2
  exit 1
fi
if ! pkg-config --exists libjxl || [[ "$(pkg-config --modversion libjxl)" != "0.12.0" ]]; then
  brew install jpeg-xl
fi
if [[ "$(pkg-config --modversion libjxl)" != "0.12.0" ]]; then
  echo "需要 libjxl 0.12.0；目前找到 $(pkg-config --modversion libjxl)。" >&2
  exit 1
fi

stage="$PROJECT_DIR/.build/vendor-jxl"
licenses="$stage/licenses"
mkdir -p "$licenses"
for component in jpeg-xl highway brotli little-cms2; do
  prefix="$(brew --prefix "$component")"
  [[ -f "$prefix/LICENSE" ]] || { echo "找不到 $component 授權文字。" >&2; exit 1; }
  cp "$prefix/LICENSE" "$licenses/$component-LICENSE"
  if [[ -f "$prefix/PATENTS" ]]; then cp "$prefix/PATENTS" "$licenses/$component-PATENTS"; fi
done
printf 'libjxl %s\n' "$(pkg-config --modversion libjxl)" > "$stage/version.txt"
echo "已驗證並準備原生 libjxl 0.12.0。"
