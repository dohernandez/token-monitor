#!/usr/bin/env python3
"""Bundle a checksum-pinned, relocatable Python runtime and its license files."""
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


def safe_members(archive):
    members = archive.getmembers()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'python':
            raise ValueError('Unsafe archive path: ' + member.name)
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError('Unexpected archive member: ' + member.name)
        if member.issym() or member.islnk():
            link = PurePosixPath(member.linkname)
            target = (path.parent / link) if member.issym() else link
            depth = 0
            if link.is_absolute():
                raise ValueError('Absolute archive link')
            for part in target.parts:
                depth += -1 if part == '..' else 0 if part == '.' else 1
                if depth < 1:
                    raise ValueError('Escaping archive link')
            if target.parts[0] != 'python':
                raise ValueError('Archive link outside Python')
    return members


def bundle(resources, cache):
    manifest = json.loads(Path(__file__).with_name('python-runtime.json').read_text())
    entry = manifest['archives'][platform.machine()]
    resources, cache = Path(resources), Path(cache)
    resources.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (entry['sha256'] + '.tar.gz')
    if not archive.exists():
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as file:
            download = Path(file.name)
        try:
            subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--output', str(download), entry['url']], check=True)
            if hashlib.sha256(download.read_bytes()).hexdigest() != entry['sha256']:
                raise ValueError('Python archive checksum mismatch')
            download.replace(archive)
        finally:
            download.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != entry['sha256']:
        raise ValueError('Cached Python archive checksum mismatch; remove it and retry')
    with tempfile.TemporaryDirectory(dir=resources, prefix='.python-') as directory:
        with tarfile.open(archive) as file:
            members = safe_members(file)
            # The pinned archive was validated above, including link destinations.
            file.extractall(directory, members=members, **({'filter': 'fully_trusted'} if sys.version_info >= (3, 12) else {}))
        runtime = Path(directory) / 'python'
        subprocess.run([str(runtime / 'bin/python3'), '-I', '-B', '-c', 'import sqlite3, ssl, json, fcntl; assert sqlite3.connect(":memory:")'], check=True)
        if not list(runtime.glob('**/LICENSE*')):
            raise ValueError('Runtime license files are missing')
        destination = resources / 'python'
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(runtime), str(destination))
    (resources / 'PYTHON-RUNTIME.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    bundle(*sys.argv[1:])
