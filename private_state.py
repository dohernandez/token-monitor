"""Owner-only monitor state. Reject final-path links; preserve shared parent modes."""
import os
import stat
from pathlib import Path


def secure_file(path):
    path = Path(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError('Private state must be an owned regular file: ' + str(path))
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


def secure_directory(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(fd).st_uid != os.getuid():
            raise ValueError('Private state directory has a different owner')
        os.fchmod(fd, 0o700)
    finally:
        os.close(fd)
    return path


def secure_state(path):
    path = secure_directory(path)
    for name in ('usage-v1.sqlite', 'usage-v1.sqlite-wal', 'usage-v1.sqlite-shm',
                 'usage-v1.sqlite-journal', 'collector.lock', 'statusline-original.json'):
        secure_file(path / name)
    for backup in path.glob('claude-settings-before-observer-*.json'):
        secure_file(backup)
    quota = path / 'claude-limits'
    if quota.exists() or quota.is_symlink():
        secure_directory(quota)
        for report in quota.glob('*.json'):
            secure_file(report)
    return path
