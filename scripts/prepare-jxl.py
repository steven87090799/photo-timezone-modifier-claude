#!/usr/bin/env python3
"""Build a checksum-pinned libjxl, independent of Homebrew's jpeg-xl version."""
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
revision = 'a7a9c787341cf703dede03c2009fa460cae5e5df'  # libjxl v0.12.0
checksum = '818398895831069902e3677d285054a7d1255b11b221e94c6aaa1cb83b0a3f29'
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('JPEG XL 建置需要 Apple Silicon macOS。')
brew = shutil.which('brew')
cmake = shutil.which('cmake')
if not brew or not cmake:
    raise SystemExit('需要 Homebrew 與 CMake：brew install cmake highway brotli little-cms2')
versions = {}
for package, module in [('highway', 'libhwy'), ('brotli', 'libbrotlienc'), ('little-cms2', 'lcms2')]:
    if subprocess.run(['pkg-config', '--exists', module]).returncode:
        subprocess.run([brew, 'install', package], check=True)
    versions[package] = subprocess.check_output(['pkg-config', '--modversion', module], text=True).strip()
stage = root / '.build/vendor-jxl'
identity = hashlib.sha256((revision + json.dumps(versions, sort_keys=True)).encode() + Path(__file__).read_bytes()).hexdigest()
stamp = stage / 'build-id.txt'
if stamp.exists() and stamp.read_text().strip() == identity and all((stage / 'lib' / name).exists() for name in ['libjxl.dylib', 'libjxl_threads.dylib', 'libjxl_cms.dylib']):
    print('Pinned libjxl 0.12.0 already prepared.')
    raise SystemExit(0)
cache = Path(tempfile.gettempdir()) / ('PhotoTimezone-libjxl-' + str(os.getuid()))
cache.mkdir(exist_ok=True)
archive = cache / (revision + '.tar.gz')
if not archive.exists():
    with urllib.request.urlopen('https://codeload.github.com/libjxl/libjxl/tar.gz/' + revision, timeout=90) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != checksum:
        raise SystemExit('libjxl 來源校驗失敗。')
    partial = archive.with_suffix('.download'); partial.write_bytes(data); partial.replace(archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
    raise SystemExit('libjxl 快取校驗失敗：' + str(archive))
source = cache / ('libjxl-' + revision)
if not source.exists():
    with tarfile.open(archive) as tar:
        regular = []
        for member in tar.getmembers():
            # Upstream includes metric wrapper symlinks; tools are disabled and
            # those links are not extracted or executed.
            if member.issym() and "/tools/benchmark/metrics/" in member.name:
                continue
            target = (cache / member.name).resolve()
            if cache.resolve() not in target.parents or not (member.isdir() or member.isfile()):
                raise SystemExit('Unsafe libjxl archive entry')
            regular.append(member)
        tar.extractall(cache, members=regular)
build = cache / ('build-' + identity[:16])
prefix = subprocess.check_output([brew, '--prefix'], text=True).strip()
args = [cmake, '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_INSTALL_PREFIX=' + str(stage), '-DCMAKE_INSTALL_NAME_DIR=' + str(stage / 'lib'),
        '-DCMAKE_PREFIX_PATH=' + prefix, '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0',
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_TESTING=OFF', '-DJPEGXL_ENABLE_SKCMS=OFF',
        '-DJPEGXL_ENABLE_TOOLS=OFF', '-DJPEGXL_ENABLE_BENCHMARK=OFF', '-DJPEGXL_ENABLE_EXAMPLES=OFF',
        '-DJPEGXL_ENABLE_SJPEG=OFF', '-DJPEGXL_ENABLE_OPENEXR=OFF', '-DJPEGXL_ENABLE_JNI=OFF',
        '-DJPEGXL_ENABLE_MANPAGES=OFF', '-DJPEGXL_ENABLE_DOXYGEN=OFF', '-DJPEGXL_ENABLE_TCMALLOC=OFF',
        '-DJPEGXL_ENABLE_PLUGINS=OFF', '-DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF']
subprocess.run(args, check=True)
subprocess.run([cmake, '--build', str(build), '--parallel', '4'], check=True)
subprocess.run([cmake, '--install', str(build)], check=True)
licenses = stage / 'licenses'; licenses.mkdir(exist_ok=True)
shutil.copy2(source / 'LICENSE', licenses / 'jpeg-xl-LICENSE')
shutil.copy2(source / 'PATENTS', licenses / 'jpeg-xl-PATENTS')
for package in versions:
    package_prefix = Path(subprocess.check_output([brew, '--prefix', package], text=True).strip())
    shutil.copy2(package_prefix / 'LICENSE', licenses / (package + '-LICENSE'))
(stage / 'version.txt').write_text('libjxl 0.12.0 source ' + revision + '\n' + json.dumps(versions, sort_keys=True) + '\n')
stamp.write_text(identity + '\n')
print('Prepared checksum-pinned libjxl 0.12.0.')
