#!/usr/bin/env python3
"""Write the actual checked-out source identity, never a cached web asset revision."""
import datetime
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
changed = subprocess.check_output(["git", "diff", "HEAD", "--name-only"], cwd=root, text=True).splitlines()
# CI intentionally stamps the release build number into Info.plist.
dirty = any(path != "app/Info.plist" or not os.environ.get("GITHUB_RUN_ID") for path in changed)
identity = {"revision": revision, "dirty": dirty, "run": os.environ.get("GITHUB_RUN_ID", "local"),
            "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
pathlib.Path(sys.argv[1]).write_text(json.dumps(identity, ensure_ascii=False, indent=2) + "\n")
