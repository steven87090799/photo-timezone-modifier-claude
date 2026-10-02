#!/bin/bash
set -euo pipefail

if [[ $# != 4 ]]; then
  cat >&2 <<'EOF'
用法：
  ./scripts/verify-on1-acceptance.sh A原檔 B補時區檔 C_ON1匯出B C0_ON1匯出A

A  = untouched source
B  = PhotoTimezone 處理後的檔案
C  = ON1 Photo RAW 匯出 B
C0 = ON1 Photo RAW 匯出 A（基準）
EOF
  exit 2
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
./scripts/prepare-exiftool.sh >/dev/null
TOOL="$PROJECT_DIR/.build/vendor-exiftool/exiftool"
A="$1"; B="$2"; C="$3"; C0="$4"

for f in "$A" "$B" "$C" "$C0"; do
  [[ -f "$f" ]] || { echo "找不到檔案：$f" >&2; exit 2; }
done

tag() {
  /usr/bin/perl "$TOOL" -config "" -charset filename=UTF8 -s3 "-EXIF:$1" "$2" | /usr/bin/tr -d '\r'
}

valid_offset() {
  [[ "$1" =~ ^[-+](0[0-9]|1[0-4]):[0-5][0-9]$ ]] || return 1
  if [[ "$1" == -* ]]; then
    local h="${1:1:2}" m="${1:4:2}"
    (( 10#$h < 12 || (10#$h == 12 && 10#$m == 0) ))
  else
    local h="${1:1:2}" m="${1:4:2}"
    (( 10#$h < 14 || (10#$h == 14 && 10#$m == 0) ))
  fi
}

for dateTag in DateTimeOriginal CreateDate ModifyDate; do
  av="$(tag "$dateTag" "$A")"
  bv="$(tag "$dateTag" "$B")"
  if [[ "$av" != "$bv" ]]; then
    echo "FAIL：PhotoTimezone 處理前後 $dateTag 改變：'$av' → '$bv'" >&2
    exit 1
  fi
done

for offsetTag in OffsetTimeOriginal OffsetTimeDigitized OffsetTime; do
  value="$(tag "$offsetTag" "$B")"
  if ! valid_offset "$value"; then
    echo "FAIL：B 的 $offsetTag 缺少或超出 UTC-12:00～+14:00：'$value'" >&2
    exit 1
  fi
done

b_capture="$(tag DateTimeOriginal "$B")"
c_capture="$(tag DateTimeOriginal "$C")"
a_capture="$(tag DateTimeOriginal "$A")"
c0_capture="$(tag DateTimeOriginal "$C0")"

if [[ -z "$b_capture" || -z "$c_capture" ]]; then
  echo "FAIL：B 或 C 缺少 DateTimeOriginal，無法驗證 ON1 時差。" >&2
  exit 1
fi
if [[ "$b_capture" != "$c_capture" ]]; then
  echo "FAIL：ON1 匯出 B 後拍攝鐘點改變：'$b_capture' → '$c_capture'" >&2
  exit 1
fi

printf '\n%-5s | %-19s | %-6s | %-6s | %-6s\n' "檔案" "DateTimeOriginal" "OrigTZ" "DigTZ" "ModTZ"
printf '%s\n' '------------------------------------------------------------------------'
for pair in "A:$A" "B:$B" "C:$C" "C0:$C0"; do
  label="${pair%%:*}"; file="${pair#*:}"
  printf '%-5s | %-19s | %-6s | %-6s | %-6s\n'     "$label" "$(tag DateTimeOriginal "$file")"     "$(tag OffsetTimeOriginal "$file")" "$(tag OffsetTimeDigitized "$file")" "$(tag OffsetTime "$file")"
done

echo
echo "PASS：A→B 的 DateTimeOriginal/CreateDate/ModifyDate 未平移，B 三個 EXIF 時區合法，ON1 的 B→C DateTimeOriginal 未發生時差。"
if [[ -n "$a_capture" && -n "$c0_capture" && "$a_capture" != "$c0_capture" ]]; then
  echo "INFO：未補時區的基準 A→C0 發生鐘點差：'$a_capture' → '$c0_capture'。"
else
  echo "INFO：A→C0 基準未觀察到 DateTimeOriginal 位移；仍保留 C0 供版本/設定比較。"
fi
