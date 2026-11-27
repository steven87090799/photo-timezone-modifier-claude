#!/usr/bin/env python3
"""Correct ExifTool 13.64's duplicated base on ISO-BMFF TIFF-form EXIF items."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "lib/Image/ExifTool/QuickTime.pm"
original = path.read_bytes()
anchor = br"""            my $oldBase = $$et{BASE};
            $$et{BASE} += $dirInfo{DataPos};
            $et->ProcessDirectory(\%dirInfo, $subTable, $proc);
            $$et{BASE} = $oldBase;
            delete $$et{DOC_NUM};
"""
replacement = anchor.replace(
    b"            $$et{BASE} += $dirInfo{DataPos};",
    b"            # TIFF-form Exif already received an absolute Base above.\n"
    b"            $$et{BASE} += $dirInfo{DataPos} unless $name eq 'EXIF' and not $moreDirInfo{XiaomiMess};",
)
if original.count(anchor) != 1:
    raise SystemExit("Unexpected ExifTool layout; review the HEIF offset patch.")
path.write_bytes(original.replace(anchor, replacement))
