#!/bin/bash
# Stage only runtime data; never trim the complete upstream lib module tree.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: stage-runtime.sh EXIFTOOL_SOURCE NEW_DESTINATION' >&2; exit 2; }
SOURCE="$1"
DESTINATION="$2"
[[ -f "$SOURCE/exiftool" && -d "$SOURCE/lib" && -f "$SOURCE/LICENSE" ]] || exit 1
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || { echo 'Destination already exists.' >&2; exit 1; }
mkdir "$DESTINATION"
cp "$SOURCE/exiftool" "$SOURCE/LICENSE" "$SOURCE/README" "$DESTINATION/"
cp -R "$SOURCE/lib" "$DESTINATION/lib"
/usr/bin/perl "$DESTINATION/exiftool" -config '' -ver
