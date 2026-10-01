"""One-time, checksum-verified source transfer for the isolated repair branch."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import lzma
import os
import shutil
import subprocess

EXPECTED = '66b4956a02db3867a6f58f8e622f0c7766bc5df74da295b47f20dce26a4896a7'
BRANCH = 'refs/heads/fix/metadata-only-three-offsets-20261001'
assert os.environ.get('GITHUB_REF') == BRANCH, 'Wrong branch'
root = Path.cwd().resolve()
transfer = root / '.repair-transfer'
chunks = sorted(transfer.glob('chunk-*.bin'))
assert len(chunks) == 6, 'Incomplete transfer'
compressed = b''.join(p.read_bytes() for p in chunks)
assert hashlib.sha256(compressed).hexdigest() == EXPECTED, 'Transfer checksum failed'
payload = json.loads(lzma.decompress(compressed))
assert payload['base'] == 'e1607479c15f0368305f5c69fadd0f75fd582376'

def safe_path(name):
    path = PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts
    assert path.parts and path.parts[0] != '.git'
    target = root / path
    assert not target.is_symlink()
    assert all(not p.is_symlink() for p in target.parents if p != root.parent)
    assert target.resolve().is_relative_to(root)
    return target

lines = []
for name in payload['basePaths']:
    safe_path(name)
    text = subprocess.check_output(['git', 'show', payload['base'] + ':' + name]).decode('utf-8')
    lines.extend(text.splitlines(keepends=True))
assert hashlib.sha256(''.join(lines).encode()).hexdigest() == payload['baseDigest'], 'Base mismatch'
verified = []
for name, entry in payload['files'].items():
    target = safe_path(name)
    pieces = []
    for part in entry['parts']:
        if isinstance(part, str):
            pieces.append(part)
        else:
            start, end = part
            assert 0 <= start <= end <= len(lines)
            pieces.append(''.join(lines[start:end]))
    content = ''.join(pieces).encode('utf-8')
    assert hashlib.sha256(content).hexdigest() == entry['sha256'], name
    assert entry['mode'] in (0o644, 0o755)
    verified.append((name, target, content, entry['mode']))
# GITHUB_TOKEN pushes source only. The authorized connector applies the small
# workflow version update and deletes the temporary workflow in a separate commit.
for name, target, content, mode in verified:
    if name == '.github/workflows/macos.yml':
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    target.chmod(mode)
shutil.rmtree(transfer)
print('Verified', len(verified), 'files; installed source files; workflow update pending connector cleanup.')
