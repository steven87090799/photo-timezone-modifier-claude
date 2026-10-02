#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "用法：$0 <A原始檔> <B本App處理後> <C_ON1由B匯出> [C0_ON1由A匯出]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/prepare-exiftool.sh" >/dev/null
EXIF="$ROOT/.build/vendor-exiftool/exiftool"

A="$1"; B="$2"; C="$3"; C0="${4:-}"
for f in "$A" "$B" "$C"; do
  [[ -f "$f" ]] || { echo "找不到檔案：$f" >&2; exit 2; }
done
if [[ -n "$C0" && ! -f "$C0" ]]; then
  echo "找不到 C0：$C0" >&2
  exit 2
fi

tag() {
  local file="$1" name="$2"
  /usr/bin/perl "$EXIF" -config "" -s3 "-$name" "$file" 2>/dev/null | /usr/bin/sed -n '1p'
}

A_DTO="$(tag "$A" DateTimeOriginal)"
B_DTO="$(tag "$B" DateTimeOriginal)"
C_DTO="$(tag "$C" DateTimeOriginal)"
B_O="$(tag "$B" OffsetTimeOriginal)"
B_D="$(tag "$B" OffsetTimeDigitized)"
B_M="$(tag "$B" OffsetTime)"

fail=0
if [[ -z "$A_DTO" || -z "$B_DTO" || -z "$C_DTO" ]]; then
  echo "FAIL：A/B/C 必須都能讀到 DateTimeOriginal。"
  fail=1
fi
if [[ "$A_DTO" != "$B_DTO" ]]; then
  echo "FAIL：A → B 的 DateTimeOriginal 被改變：A=$A_DTO B=$B_DTO"
  fail=1
else
  echo "PASS：A → B 拍攝鐘點完全一致：$B_DTO"
fi
for pair in "OffsetTimeOriginal:$B_O" "OffsetTimeDigitized:$B_D" "OffsetTime:$B_M"; do
  name="${pair%%:*}"; value="${pair#*:}"
  if [[ ! "$value" =~ ^[+-][0-9][0-9]:[0-9][0-9]$ ]]; then
    echo "FAIL：B 缺少或無法讀取 $name：$value"
    fail=1
  else
    echo "PASS：B $name=$value"
  fi
done
if [[ "$B_DTO" != "$C_DTO" ]]; then
  echo "FAIL：ON1 從 B 匯出後 DateTimeOriginal 發生位移：B=$B_DTO C=$C_DTO"
  fail=1
else
  echo "PASS：ON1 B → C 沒有平移拍攝鐘點：$C_DTO"
fi

if [[ -n "$C0" ]]; then
  C0_DTO="$(tag "$C0" DateTimeOriginal)"
  echo "BASELINE：A=$A_DTO"
  echo "BASELINE：C0(ON1由未補時區A匯出)=$C0_DTO"
  if [[ "$C0_DTO" != "$A_DTO" ]]; then
    echo "OBSERVED：未補時區基線在 ON1 匯出後有時間差；B→C 結果以上方 PASS/FAIL 為準。"
  else
    echo "OBSERVED：此測試檔在未補時區基線也沒有發生時間位移。"
  fi
fi

echo "注意：ON1 匯出通常會重新編碼，這個 acceptance 不要求 B/C HASH 相同。"
exit "$fail"
