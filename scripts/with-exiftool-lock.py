#!/usr/bin/env python3
"""Serialize preparation of the shared development ExifTool cache."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
cache = root / '.build'
cache.mkdir(exist_ok=True)
with (cache / '.exiftool-prepare.lock').open('a') as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    environment = dict(os.environ, PHOTO_EXIFTOOL_LOCK_HELD='1')
    raise SystemExit(subprocess.run(['bash', str(root / 'scripts/prepare-exiftool.sh')], env=environment).returncode)
