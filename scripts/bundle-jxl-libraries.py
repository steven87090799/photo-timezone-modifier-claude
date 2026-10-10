#!/usr/bin/env python3
"""Bundle libjxl's Homebrew runtime dylibs so the app has no brew dependency."""
from pathlib import Path
import shutil
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: bundle-jxl-libraries.py APP_EXECUTABLE FRAMEWORKS_DIR")

app = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2]).resolve()
destination.mkdir(parents=True, exist_ok=True)
brew_prefix = Path(subprocess.check_output(["brew", "--prefix"], text=True).strip())
search_roots = [brew_prefix / "opt", brew_prefix / "lib"]


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def dependencies(path: Path) -> list[str]:
    lines = output("otool", "-L", str(path)).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines if line.strip()]


def rpaths(path: Path) -> list[str]:
    lines = output("otool", "-l", str(path)).splitlines()
    result: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for next_line in lines[index + 1:index + 5]:
                stripped = next_line.strip()
                if stripped.startswith("path "):
                    result.append(stripped[5:].split(" (offset", 1)[0])
                    break
    return result


def expand_loader_path(value: str, image: Path, executable: Path) -> Path:
    if value.startswith("@loader_path"):
        return image.parent / value.removeprefix("@loader_path/")
    if value.startswith("@executable_path"):
        return executable.parent / value.removeprefix("@executable_path/")
    return Path(value)


def resolve(image: Path, dependency: str) -> Path:
    candidates: list[Path] = []
    if dependency.startswith("@rpath/"):
        suffix = dependency.removeprefix("@rpath/")
        for entry in rpaths(image):
            candidates.append(expand_loader_path(entry, image, app) / suffix)
        for root in search_roots:
            if root.name == "opt":
                candidates.extend(root.glob(f"*/lib/{suffix}"))
            else:
                candidates.append(root / suffix)
    elif dependency.startswith("@loader_path") or dependency.startswith("@executable_path"):
        candidates.append(expand_loader_path(dependency, image, app))
    elif dependency.startswith("/"):
        candidates.append(Path(dependency))
    for candidate in candidates:
        if candidate.exists():
            resolved = candidate.resolve()
            if resolved.is_file():
                return resolved
    raise SystemExit(f"Cannot resolve libjxl dependency {dependency} used by {image}")


def add_rpath(path: Path, value: str) -> None:
    if value not in rpaths(path):
        subprocess.run(["install_name_tool", "-add_rpath", value, str(path)], check=True)


copied: dict[str, Path] = {}
pending: list[tuple[Path, Path]] = [(app, app)]
while pending:
    source, client = pending.pop()
    for dependency in dependencies(source):
        if dependency.startswith(("/System/Library/", "/usr/lib/")):
            continue
        original = resolve(source, dependency)
        name = Path(dependency).name
        bundled = destination / name
        existing = copied.get(name)
        if existing is not None:
            if existing != original:
                raise SystemExit(f"Conflicting libjxl dylib names for {name}")
        else:
            shutil.copy2(original, bundled)
            # Homebrew marks dylibs read-only. install_name_tool, xattr cleanup,
            # and codesign all need to update the staged copy, never the source.
            bundled.chmod(0o755)
            copied[name] = original
            pending.append((original, bundled))
            subprocess.run(["install_name_tool", "-id", f"@rpath/{name}", str(bundled)], check=True)
            add_rpath(bundled, "@loader_path")
        new_reference = f"@rpath/{name}"
        if dependency != new_reference:
            subprocess.run(["install_name_tool", "-change", dependency, new_reference, str(client)], check=True)

add_rpath(app, "@executable_path/../Frameworks/JXL")

for image in [app, *sorted(destination.glob("*.dylib"))]:
    for dependency in dependencies(image):
        if dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/")):
            continue
        raise SystemExit(f"Unbundled dependency remains in {image}: {dependency}")

print(f"Bundled {len(copied)} libjxl runtime dylibs into {destination}")
