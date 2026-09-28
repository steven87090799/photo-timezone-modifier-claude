#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$ROOT_DIR/src/main.applescript"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_PATH="$OUTPUT_DIR/相片_時區修改器_claude.app"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "找不到 AppleScript 原始碼：$SOURCE_FILE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_PATH" ]]; then
  rm -rf "$APP_PATH"
fi

osacompile -o "$APP_PATH" "$SOURCE_FILE"
echo "已建立：$APP_PATH"
