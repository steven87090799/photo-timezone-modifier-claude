#!/usr/bin/env python3
"""Build the locked native codec sources with the app's deployment target."""
import fcntl
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
lock_bytes = (root / "scripts/native-codecs.json").read_bytes()
components = json.loads(lock_bytes)
if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("原生編碼器建置需要 Apple Silicon macOS。")
if not all(shutil.which(tool) for tool in ("cmake", "pkg-config")):
    raise SystemExit("請先安裝 CMake 和 pkg-config。")

build_root = root / ".build"
stage = build_root / "vendor-jxl"
cache = build_root / "native-codec-downloads"
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
cc = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
cxx = subprocess.check_output(["xcrun", "--find", "clang++"], text=True).strip()
toolchain = {
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
    "clang": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
    "cmake": subprocess.check_output(["cmake", "--version"], text=True).splitlines()[0],
    "architecture": "arm64",
    "deploymentTarget": "27.0",
}
identity = hashlib.sha256(lock_bytes + Path(__file__).read_bytes() +
                          json.dumps(toolchain, sort_keys=True).encode()).hexdigest()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(prefix):
    return {str(path.relative_to(prefix)): digest(path)
            for folder in ("include", "lib", "licenses") for path in (prefix / folder).rglob("*")
            if path.is_file()}


def prepare_archive(component, working):
    name, revision = component["name"], component["revision"]
    archive = cache / f"{name}-{revision}.tar.gz"
    expected = component["sha256"]
    if not archive.exists():
        url = f"https://codeload.github.com/{component['repository']}/tar.gz/{revision}"
        partial = working / archive.name
        with urllib.request.urlopen(url, timeout=90) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output)
        if digest(partial) != expected:
            raise SystemExit(f"來源校驗失敗：{name}")
        partial.replace(archive)
    if digest(archive) != expected:
        raise SystemExit(f"快取校驗失敗：{archive}")
    with tarfile.open(archive) as package:
        members = [member for member in package.getmembers()
                   if not member.issym() or "/tools/benchmark/metrics/" not in member.name]
        if any(not (member.isdir() or member.isfile()) for member in members):
            raise SystemExit(f"無法安全解開來源：{name}")
        roots = {Path(member.name).parts[0] for member in members}
        if len(roots) != 1:
            raise SystemExit(f"來源目錄無效：{name}")
        package.extractall(working, members=members, filter="data")
    return working / roots.pop()


def build_codec(source, working, prefix, settings):
    output = working / (source.name + "-build")
    env = dict(os.environ, PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"), PKG_CONFIG_PATH="",
               ZERO_AR_DATE="1", SOURCE_DATE_EPOCH="0")
    for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "CMAKE_PREFIX_PATH"):
        env.pop(key, None)
    map_path = f'-ffile-prefix-map="{working}"=.'
    args = ["cmake", "-S", str(source), "-B", str(output), "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_C_FLAGS={map_path}", f"-DCMAKE_CXX_FLAGS={map_path}",
            f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_INSTALL_LIBDIR=lib",
            f"-DCMAKE_PREFIX_PATH={prefix}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0", f"-DCMAKE_OSX_SYSROOT={sdk}",
            f"-DCMAKE_C_COMPILER={cc}", f"-DCMAKE_CXX_COMPILER={cxx}",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF", "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
            "-DCMAKE_INSTALL_NAME_DIR=@rpath", "-DBUILD_TESTING=OFF"]
    args.extend(f"-D{key}={value}" for key, value in settings.items())
    subprocess.run(args, env=env, check=True)
    subprocess.run(["cmake", "--build", str(output), "--parallel", "6"], env=env, check=True)
    subprocess.run(["cmake", "--install", str(output)], env=env, check=True)


def prepare():
    manifest = stage / "component-build.json"
    if not stage.is_symlink() and manifest.is_file():
        old = json.loads(manifest.read_text())
        if old.get("identity") == identity and old.get("artifacts") == inventory(stage):
            print("已驗證原生編碼器建置快取。")
            return
    with tempfile.TemporaryDirectory(prefix="native-codecs-", dir=build_root) as temp:
        working = Path(temp)
        prefix = working / "prefix"
        licenses = prefix / "licenses"
        licenses.mkdir(parents=True)
        off = "OFF"
        settings = {
            "highway": dict(HWY_ENABLE_TESTS=off, HWY_ENABLE_EXAMPLES=off, HWY_ENABLE_CONTRIB=off),
            "brotli": dict(BROTLI_DISABLE_TESTS="ON", BROTLI_BUILD_TOOLS=off),
            "little-cms2": dict(LCMS2_BUILD_TESTS=off, LCMS2_BUILD_TOOLS=off),
            "webp": {"WEBP_BUILD_" + name: off for name in
                     ("ANIM_UTILS", "CWEBP", "DWEBP", "GIF2WEBP", "IMG2WEBP", "VWEBP", "WEBPINFO", "LIBWEBPMUX", "WEBPMUX", "EXTRAS")},
            "libjxl": {**{"JPEGXL_ENABLE_" + name: off for name in
                         ("SKCMS", "TOOLS", "BENCHMARK", "EXAMPLES", "SJPEG", "OPENEXR", "JNI", "MANPAGES",
                          "DOXYGEN", "TCMALLOC", "PLUGINS", "VIEWERS", "TRANSCODE_JPEG")},
                       "JPEGXL_FORCE_SYSTEM_HWY": "ON", "JPEGXL_FORCE_SYSTEM_BROTLI": "ON",
                       "JPEGXL_FORCE_SYSTEM_LCMS2": "ON", "CMAKE_DISABLE_FIND_PACKAGE_PNG": "ON",
                       "LCMS2_LIBRARY": prefix / "lib/liblcms2.a", "LCMS2_INCLUDE_DIR": prefix / "include",
                       "HWY_LIBRARY": prefix / "lib/libhwy.a", "HWY_INCLUDE_DIR": prefix / "include",
                       "BROTLI_INCLUDE_DIR": prefix / "include",
                       **{f"BROTLI{name}_LIBRARY": prefix / f"lib/libbrotli{name.lower()}.a"
                          for name in ("ENC", "DEC", "COMMON")}},
        }
        for component in components:
            name = component["name"]
            source = prepare_archive(component, working)
            build_codec(source, working, prefix,
                        dict(settings[name], BUILD_SHARED_LIBS="ON" if name == "libjxl" else off))
            for license_file in component["license"]:
                shutil.copyfile(source / license_file, licenses / f"{name}-{license_file}")
        if stage.is_symlink():
            raise SystemExit(f"拒絕替換符號連結：{stage}")
        manifest = {"identity": identity, "toolchain": toolchain,
                    "components": components, "artifacts": inventory(prefix)}
        (prefix / "component-build.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        if stage.exists():
            shutil.rmtree(stage)
        prefix.rename(stage)


cache.mkdir(parents=True, exist_ok=True)
with (build_root / "vendor-jxl.lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    prepare()
