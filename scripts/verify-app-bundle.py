#!/usr/bin/env python3
"""Check deployment targets, imported libraries and release identity."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
contents = app / "Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
target = "27.0"
if info["LSMinimumSystemVersion"] != target:
    raise SystemExit(f"App minimum version must be {target}.")
identity = json.loads((contents / "Resources/BuildIdentity.json").read_text())
if expected := os.environ.get("NEXPRESS_BUILD_REVISION"):
    if expected != identity["revision"]:
        raise SystemExit("App revision does not match the checkout.")
if os.environ.get("NEXPRESS_RELEASE_CHANNEL") == "production" and identity["dirty"]:
    raise SystemExit("Production packaging requires a clean CI checkout.")

macho_magic = {bytes.fromhex(value) for value in
               ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
images = []
for path in contents.rglob("*"):
    if path.is_symlink():
        raise SystemExit(f"Unexpected symlink in bundle: {path.relative_to(app)}")
    if path.is_file():
        with path.open("rb") as stream:
            if stream.read(4) in macho_magic:
                images.append(path)

executable = contents / "MacOS" / info["CFBundleExecutable"]
frameworks = contents / "Frameworks/JXL"
if executable not in images:
    raise SystemExit("The bundle executable has the wrong format.")

for image in sorted(images):
    def output(tool, option):
        return subprocess.check_output([tool, option, str(image)], text=True)

    if output("lipo", "-archs").strip() != "arm64":
        raise SystemExit(f"Architecture mismatch: {image.name}")
    build = output("vtool", "-show-build")
    platforms = re.findall(r"^\s*platform\s+(\w+)", build, re.M)
    minimums = re.findall(r"^\s*minos\s+([\d.]+)", build, re.M)
    if platforms != ["MACOS"] or len(minimums) != 1:
        raise SystemExit(f"Missing macOS build version: {image.name}")
    if tuple(map(int, minimums[0].split("."))) > (27, 0, 0):
        raise SystemExit(f"{image.name} requires macOS {minimums[0]}.")
    allowed_rpath = "@executable_path/../Frameworks/JXL" if image == executable else "@loader_path"
    actual_rpaths = re.findall(r"^\s*path (.+) \(offset \d+\)$", output("otool", "-l"), re.M)
    if actual_rpaths != [allowed_rpath]:
        raise SystemExit(f"Unexpected runtime search path in {image.name}: {actual_rpaths}")
    for line in output("otool", "-L").splitlines()[1:]:
        reference = line.strip().split(" (", 1)[0]
        if reference.startswith(("/System/Library/", "/usr/lib/")):
            continue
        name = Path(reference).name
        if reference != f"@rpath/{name}" or frameworks / name not in images:
            raise SystemExit(f"Unbundled runtime dependency in {image.name}: {reference}")
    print(f"{image.relative_to(app)} arm64 macOS {minimums[0]}")
