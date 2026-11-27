#!/usr/bin/env python3
"""Measure bundled third-party files and record their locked source provenance."""
import hashlib
import json
from pathlib import Path
import sys

mode, path = sys.argv[1:]
resources = Path(path)
root = Path(__file__).resolve().parent.parent
web = json.loads((root / "scripts/oxipng-lock.json").read_text())


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def fingerprints(folder):
    return {p.relative_to(folder).as_posix(): digest(p) for p in sorted(folder.rglob("*")) if p.is_file()}


if fingerprints((root if mode == "check-web" else resources) / "CompressionWeb/vendor") != web["artifacts"]:
    raise SystemExit("Bundled OxiPNG files do not match the source lock.")
if mode == "check-web":
    print("Verified pinned OxiPNG runtime and licenses.")
    raise SystemExit(0)

files = {}
for folder in ("ExifTool", "JpegliLicenses", "JXLLicenses", "CompressionWeb"):
    actual = fingerprints(resources / folder)
    if not actual:
        raise SystemExit(f"Missing third-party resources: {folder}")
    files.update({f"{folder}/{name}": checksum for name, checksum in actual.items()})
path = resources / "DependencyManifest.json"
native = json.loads((root / "scripts/native-codecs.json").read_text())
jpegli = json.loads((root / "NativeJpegli/dependencies.json").read_text())
exiftool = {
    "name": "ExifTool", "version": "13.64", "revision": "3d7a0538324e9b04aa8930201b007009491321d2",
    "source": "https://github.com/exiftool/exiftool",
    "sha256": "1c890a0324d5ad5aae6e17c1b57c620e420d2846fcfa17bbf34407a5441efbbd",
    "license": "Perl Artistic License or GPL",
    "heifOffsetPatchSHA256": digest(root / "scripts/patch-exiftool-heif.py"),
}
if mode == "write":
    archive = root / "vendor/exiftool-13.64.tar.gz"
    if digest(archive) != exiftool["sha256"]:
        raise SystemExit("ExifTool source archive mismatch.")
    build = root / ".build"
    codec_build = json.loads((build / "vendor-jxl/component-build.json").read_text())
    jpegli_build = json.loads((build / "vendor-jpegli/component-build.json").read_text())
    manifest = {"schemaVersion": 1, "exiftool": exiftool, "png": web, "jpegli": jpegli, "native": native,
                "toolchains": {"native": codec_build["toolchain"], "jpegli": jpegli_build["toolchain"]},
                "nativeBuildArtifacts": codec_build["artifacts"], "jpegliBuildArtifacts": jpegli_build["artifacts"],
                "systemCodecs": ["ImageIO HEIF/AVIF", "Core Image RAW"], "bundledFileSHA256": files}
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
elif mode == "verify":
    manifest = json.loads(path.read_text())
    if (manifest["schemaVersion"] != 1 or manifest["bundledFileSHA256"] != files
            or manifest["png"] != web or manifest["native"] != native
            or manifest["exiftool"] != exiftool or manifest["jpegli"] != jpegli):
        raise SystemExit("Bundled dependency manifest mismatch.")
    print(f"Verified {len(files)} bundled third-party resource hashes.")
else:
    raise SystemExit("Usage: dependency-manifest.py [check-web|write|verify] RESOURCES")
