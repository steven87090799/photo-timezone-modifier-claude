#!/usr/bin/env python3
"""Stage only the Mach-O libraries reachable from the pinned build."""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2]).resolve()
pinned = (Path(__file__).resolve().parent.parent / ".build/vendor-jxl/lib").resolve()
destination.mkdir(parents=True, exist_ok=True)


def output(*args):
    return subprocess.check_output(args, text=True)


def rpaths(image):
    return [line.strip()[5:].split(" (offset", 1)[0]
            for line in output("otool", "-l", str(image)).splitlines()
            if line.strip().startswith("path ") and " (offset " in line]


def set_rpath(image, path):
    for existing in rpaths(image):
        if existing != path:
            subprocess.run(["install_name_tool", "-delete_rpath", existing, str(image)], check=True)
    if path not in rpaths(image):
        subprocess.run(["install_name_tool", "-add_rpath", path, str(image)], check=True)


pending = [app]
copied = set()
while pending:
    image = pending.pop()
    for line in output("otool", "-L", str(image)).splitlines()[1:]:
        reference = line.strip().split(" (", 1)[0]
        if reference.startswith(("/System/Library/", "/usr/lib/")):
            continue
        name = Path(reference).name
        source = pinned / name
        if reference != f"@rpath/{name}" or not source.is_file() or pinned not in source.resolve().parents:
            raise SystemExit(f"Unexpected library reference in {image.name}: {reference}")
        if name in copied:
            continue
        target = destination / name
        shutil.copyfile(source, target)
        target.chmod(0o755)
        set_rpath(target, "@loader_path")
        pending.append(target)
        copied.add(name)
if not copied:
    raise SystemExit("No pinned JPEG XL dylibs were linked.")
set_rpath(app, "@executable_path/../Frameworks/JXL")
print(f"Bundled {len(copied)} pinned runtime dylibs.")
