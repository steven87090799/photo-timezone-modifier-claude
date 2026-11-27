#!/bin/bash
# Called only by the approved release job on a disposable macOS runner.
set -euo pipefail
set +x
[[ "$#" == 2 && "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REF:-}" == refs/heads/main &&
   "${GITHUB_EVENT_NAME:-}" == workflow_dispatch && "${NEXPRESS_RELEASE_CHANNEL:-}" == production ]] || exit 2
: "${MACOS_CERT_P12_BASE64:?missing Developer ID certificate}"
: "${MACOS_CERT_PASSWORD:?missing Developer ID certificate password}"
: "${MACOS_SIGNING_IDENTITY:?missing Developer ID signing identity}"
: "${NOTARY_API_KEY_BASE64:?missing notarization key}"
: "${NOTARY_API_KEY_ID:?missing notarization key ID}"
: "${NOTARY_API_ISSUER:?missing notarization issuer}"
[[ "$MACOS_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || exit 2

umask 077
stage="$(mktemp -d "$RUNNER_TEMP/phototimezone-sign.XXXXXX")"
keychain="$stage/signing.keychain-db"
cleanup() {
    /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
    /bin/rm -rf "$stage"
}
trap cleanup EXIT
project="$(cd "$(dirname "$0")/.." && pwd)"
input="$1"
output="$2"
[[ ! -e "$output" && ! -L "$output" ]] || exit 2
bash "$project/scripts/verify-release-archive.sh" "$input"
/usr/bin/ditto -x -k "$input" "$stage"
app="$stage/相片時區修改器.app"

printf '%s' "$MACOS_CERT_P12_BASE64" | /usr/bin/base64 -D > "$stage/certificate.p12"
printf '%s' "$NOTARY_API_KEY_BASE64" | /usr/bin/base64 -D > "$stage/notary.p8"
pass="$(/usr/bin/openssl rand -hex 32)"
/usr/bin/security create-keychain -p "$pass" "$keychain"
/usr/bin/security unlock-keychain -p "$pass" "$keychain"
/usr/bin/security import "$stage/certificate.p12" -k "$keychain" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$keychain" >/dev/null

sign=(/usr/bin/codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$keychain" --options runtime --timestamp)
for library in "$app"/Contents/Frameworks/JXL/*.dylib; do
    "${sign[@]}" "$library"
done
"${sign[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$stage/submission.zip"
xcrun notarytool submit "$stage/submission.zip" --key "$stage/notary.p8" --key-id "$NOTARY_API_KEY_ID" \
    --issuer "$NOTARY_API_ISSUER" --wait --timeout 25m --output-format json > "$stage/notary-result.json"
python3 - "$stage/notary-result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    result = json.load(file)
if result.get("status") != "Accepted":
    raise SystemExit(f"Apple notarization did not accept the archive ({result.get('id', 'no submission ID')}).")
print(f"Apple notarization accepted {result['id']}")
PY
xcrun stapler staple "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$stage/stapled.zip"
PHOTO_TIMEZONE_REQUIRE_NOTARY=1 bash "$project/scripts/verify-release-archive.sh" "$stage/stapled.zip"
mv "$stage/stapled.zip" "$output"
