#!/usr/bin/env python3
"""Build-time dependencies and stable launcher entrypoints (no credentials)."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path('/opt/olympus')
BIN = ROOT / 'bin'
BIN.mkdir(parents=True, exist_ok=True)


def fetch(url, destination):
    subprocess.run(['curl', '-fsSL', '--retry', '3', '--max-time', '300', url, '-o', str(destination)], check=True)


def unpack(url, binary, destination, checksum=None, strip=False):
    with tempfile.TemporaryDirectory() as temp:
        archive = Path(temp) / 'archive.tar.gz'
        fetch(url, archive)
        if checksum:
            assert hashlib.sha256(archive.read_bytes()).hexdigest() == checksum, 'Archive checksum mismatch'
        with tarfile.open(archive) as tar:
            if binary:
                member = next(m for m in tar.getmembers() if m.isfile() and Path(m.name).name == binary)
                destination.write_bytes(tar.extractfile(member).read())
                destination.chmod(0o755)
            else:
                destination.mkdir(parents=True, exist_ok=True)
                for member in tar.getmembers():
                    if strip:
                        member.name = '/'.join(Path(member.name).parts[1:])
                    if member.name:
                        tar.extract(member, destination, filter='data')


unpack('https://nodejs.org/dist/v24.18.1/node-v24.18.1-linux-x64.tar.gz', None, ROOT / 'node', strip=True)
for name in ('node', 'npm', 'npx', 'corepack'):
    target = Path('/usr/local/bin') / name
    target.unlink(missing_ok=True)
    target.symlink_to(ROOT / 'node/bin' / name)
unpack('https://github.com/astral-sh/uv/releases/download/0.12.2/uv-x86_64-unknown-linux-gnu.tar.gz', 'uv', Path('/usr/local/bin/uv'), 'd66e96b5f1ca3b99806eee283a8125d33a0bd669e6e6d9bc4ab7ffda63c41bf4')
Path('/usr/local/bin/uvx').unlink(missing_ok=True)
unpack('https://github.com/astral-sh/uv/releases/download/0.12.2/uv-x86_64-unknown-linux-gnu.tar.gz', 'uvx', Path('/usr/local/bin/uvx'), 'd66e96b5f1ca3b99806eee283a8125d33a0bd669e6e6d9bc4ab7ffda63c41bf4')
os.environ['UV_PYTHON_INSTALL_DIR'] = str(ROOT / 'python-distributions')
subprocess.run(['uv', 'python', 'install', '3.12'], check=True)
python = subprocess.check_output(['uv', 'python', 'find', '3.12'], text=True).strip()
(ROOT / 'python/bin').mkdir(parents=True, exist_ok=True)
(ROOT / 'python/bin/python3').symlink_to(python)
subprocess.run(['uv', 'venv', '/opt/olympus/supervisor', '--python', python], check=True)
subprocess.run(['uv', 'pip', 'install', '--python', '/opt/olympus/supervisor/bin/python', 'supervisor==4.2.5', 'setuptools==80.9.0'], check=True)
for name in ('supervisorctl', 'supervisord'):
    (Path('/usr/local/bin') / name).symlink_to(ROOT / 'supervisor/bin' / name)
unpack('https://github.com/zellij-org/zellij/releases/download/v0.44.3/zellij-no-web-x86_64-unknown-linux-musl.tar.gz', 'zellij', Path('/usr/local/bin/zellij'))
assert hashlib.sha256(Path('/usr/local/bin/zellij').read_bytes()).hexdigest() == 'a675b0106263113b9cb8f028649bad05c5d2283331fa62b2b36dd275aeaaa4d3'
unpack('https://github.com/filebrowser/filebrowser/releases/download/v2.63.5/linux-amd64-filebrowser.tar.gz', 'filebrowser', Path('/usr/local/bin/filebrowser'), 'b36ad6296db0a749a5adbc792ab5321d11b307106123d44e171b7c158fcca2d9')
release = json.load(urllib.request.urlopen('https://api.github.com/repos/coder/code-server/releases/latest'))
asset = next(a for a in release['assets'] if a['name'].endswith('linux-amd64.tar.gz'))
unpack(asset['browser_download_url'], None, ROOT / 'code-server', asset.get('digest', '').removeprefix('sha256:') or None, strip=True)
Path('/usr/local/bin/code-server').unlink(missing_ok=True)
Path('/usr/local/bin/code-server').symlink_to(ROOT / 'code-server/bin/code-server')
fetch('https://dl.k8s.io/release/v1.35.2/bin/linux/amd64/kubectl', Path('/usr/local/bin/kubectl'))
checksum = urllib.request.urlopen('https://dl.k8s.io/release/v1.35.2/bin/linux/amd64/kubectl.sha256').read().decode().strip()
assert hashlib.sha256(Path('/usr/local/bin/kubectl').read_bytes()).hexdigest() == checksum
Path('/usr/local/bin/kubectl').chmod(0o755)

tools = json.loads((ROOT / 'runtime/tools.json').read_text())
wrappers = {spec['bin']: 'run ' + key for key, spec in tools.items()}
wrappers.update({'olympus-agent-update': 'update', 'olympus-doctor': 'doctor', 'olympus-adopt': 'adopt', 'olympus-rollback': 'rollback'})
for name, command in wrappers.items():
    path = BIN / name
    path.write_text('#!/bin/sh\nexec /usr/bin/python3 /opt/olympus/runtime/olympus-runtime.py ' + command + ' "$@"\n')
    path.chmod(0o755)
for path in (ROOT / 'runtime/bin').iterdir():
    shutil.copy2(path, BIN / path.name)
    (BIN / path.name).chmod(0o755)
