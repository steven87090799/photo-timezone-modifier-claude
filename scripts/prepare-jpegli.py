#!/usr/bin/env python3
"""Build pinned, checksum-verified Jpegli sources. No downloaded binary codec.

Supports macOS and Windows (MSVC). Large source/compiler caches stay in the
system temporary directory; only static archives and notices enter .build.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

root = Path(__file__).resolve().parent.parent
native = root / "NativeJpegli"
lock = json.loads((native / "dependencies.json").read_text())
cmake = shutil.which("cmake")
if not cmake:
    raise SystemExit("需要 CMake 3.20+：macOS 可執行 brew install cmake；Windows 可安裝 CMake + Visual Studio C++。")

toolchain = {"os": platform.platform(), "architecture": platform.machine(),
             "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0]}
if platform.system() == "Darwin":
    toolchain.update({
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "sdk": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(),
        "deploymentTarget": "27.0",
    })
digest = hashlib.sha256(json.dumps(toolchain, sort_keys=True).encode())
for path in sorted(native.iterdir()):
    if path.is_file():
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
digest.update((root / "Sources/JpegliBridge/include/PhotoJpegli.h").read_bytes())
digest.update(Path(__file__).read_bytes())
identity = digest.hexdigest()
stage = root / ".build/vendor-jpegli"
manifest = stage / "component-build.json"
extension = ".lib" if os.name == "nt" else ".a"
names = ("PhotoJpegli", "jpegli-static", "hwy")


def inventory():
    return {path.relative_to(stage).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for folder in ("lib", "licenses", "compatibility")
            for path in sorted((stage / folder).glob("*")) if path.is_file()}


if not stage.is_symlink() and manifest.exists():
    cached = json.loads(manifest.read_text())
    if cached.get("identity") == identity and cached.get("artifacts") == inventory():
        print("Verified pinned native Jpegli cache.")
        raise SystemExit(0)
if stage.is_symlink():
    raise SystemExit("Refusing to replace a linked Jpegli cache.")
cache = root / ".build/jpegli-downloads"
cache.mkdir(parents=True, exist_ok=True)
temporary = tempfile.TemporaryDirectory(prefix="PhotoTimezone-jpegli-")
working = Path(temporary.name)
sources = working / "sources"
sources.mkdir()
for name, pin in lock.items():
    archive = cache / (name + "-" + pin["revision"] + ".tar.gz")
    if not archive.exists():
        url = "https://codeload.github.com/" + pin["repository"] + "/tar.gz/" + pin["revision"]
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != pin["sha256"]:
            raise SystemExit("Source checksum mismatch: " + name)
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as partial:
            partial.write(data)
        Path(partial.name).replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
        raise SystemExit("Cached source checksum mismatch; remove this exact archive and retry: " + str(archive))
    destination = sources / (name + "-" + pin["revision"])
    if not destination.exists():
        unpack = Path(tempfile.mkdtemp(prefix="unpack-", dir=working))
        try:
            with tarfile.open(archive, "r:gz") as tar:
                # Python 3.9 on CLT lacks tarfile's data filter. Reject links,
                # special files and any path escaping this disposable directory.
                for entry in tar.getmembers():
                    target = (unpack / entry.name).resolve()
                    if unpack.resolve() not in target.parents or not (entry.isdir() or entry.isfile()):
                        raise SystemExit("Unsafe archive entry: " + entry.name)
                tar.extractall(unpack)
            children = list(unpack.iterdir())
            if len(children) != 1 or not children[0].is_dir():
                raise SystemExit("Unexpected archive layout: " + name)
            children[0].rename(destination)
        finally:
            shutil.rmtree(unpack)
source = sources / ("jpegli-" + lock["jpegli"]["revision"])
for name in ("highway", "skcms", "libjpeg-turbo"):
    destination = source / "third_party" / name
    expected = sources / (name + "-" + lock[name]["revision"])
    if not (destination / ".phototimezone-revision").exists():
        # Archives contain empty submodule directories. Copy only into those.
        if destination.exists() and any(destination.iterdir()):
            raise SystemExit("Unexpected populated dependency directory: " + str(destination))
        shutil.copytree(expected, destination, dirs_exist_ok=True)
        (destination / ".phototimezone-revision").write_text(lock[name]["revision"])
build = working / "build"
args = [cmake, "-S", str(native), "-B", str(build),
        "-DJPEGLI_SOURCE=" + str(source), "-DCMAKE_BUILD_TYPE=Release"]
env = dict(os.environ)
if platform.system() == "Darwin":
    env.update(ZERO_AR_DATE="1", SOURCE_DATE_EPOCH="0")
    for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "CMAKE_PREFIX_PATH"):
        env.pop(key, None)
    path_flags = f'-ffile-prefix-map="{working}"=. -ffile-prefix-map="{root}"=.'
    args += ["-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0",
             "-DCMAKE_OSX_SYSROOT=" + subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
             "-DCMAKE_C_COMPILER=" + subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip(),
             "-DCMAKE_CXX_COMPILER=" + subprocess.check_output(["xcrun", "--find", "clang++"], text=True).strip(),
             f"-DCMAKE_C_FLAGS={path_flags}", f"-DCMAKE_CXX_FLAGS={path_flags}",
             "-DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON"]
subprocess.run(args, env=env, check=True)
subprocess.run([cmake, "--build", str(build), "--config", "Release", "--target",
                "PhotoJpegli", "photo-jpegli-check", "--parallel", "4"], env=env, check=True)
(stage / "lib").mkdir(parents=True, exist_ok=True)
for name in names:
    prefix = "" if os.name == "nt" else "lib"
    matches = list(build.rglob(prefix + name + extension))
    if len(matches) != 1:
        raise SystemExit("Expected one static archive: " + name)
    shutil.copyfile(matches[0], stage / "lib" / matches[0].name)
licenses = stage / "licenses"
licenses.mkdir(exist_ok=True)
for name, pin in lock.items():
    directory = sources / (name + "-" + pin["revision"])
    for filename in ("LICENSE", "LICENSE.md", "COPYING", "README.ijg"):
        path = directory / filename
        if path.is_file():
            shutil.copyfile(path, licenses / (name + "-" + filename))
shutil.copyfile(native / "dependencies.json", licenses / "dependencies.json")
checks = stage / "compatibility"
checks.mkdir(exist_ok=True)
program = next(build.rglob("photo-jpegli-check.exe" if os.name == "nt" else "photo-jpegli-check"))
subprocess.run([str(program), str(checks)], check=True)
manifest.write_text(json.dumps({"identity": identity, "toolchain": toolchain, "artifacts": inventory()},
                               sort_keys=True, indent=2) + "\n")
temporary.cleanup()
print("Prepared native Jpegli: " + str(stage))
