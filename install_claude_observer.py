#!/usr/bin/env python3
"""Install the explicitly authorized quota observer, preserving the prior footer."""
import argparse,json,os,shlex,shutil,tempfile,time
from pathlib import Path
from private_state import secure_state, secure_directory

def atomic(path,data,mode=0o600):
    fd,tmp=tempfile.mkstemp(prefix='.install-',dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as f:f.write(data)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def install(home,source,python="/usr/bin/python3"):
    if not Path(python).is_absolute() or not os.access(python,os.X_OK):
        raise ValueError("Python must be an absolute executable path")
    settings=home/'.claude/settings.json'
    if not settings.parent.is_dir():raise RuntimeError('Claude configuration folder not found; start Claude Code first')
    before=settings.read_bytes() if settings.exists() else None
    data=json.loads(before) if before is not None else {}
    old=data.get('statusLine')
    if old is not None and (not isinstance(old,dict) or old.get('type')!='command' or not isinstance(old.get('command'),str)):
        raise RuntimeError('Expected an existing command status line; no settings changed')
    state=secure_state(home/'Library/Application Support/TokenMonitor')
    target=secure_directory(state/'claude-observer')
    command=shlex.quote(str(python))+' -B -E -s '+shlex.quote(str(target/'claude_statusline.py'))
    original=state/'statusline-original.json'
    if old is not None and old['command']==command:
        if not original.exists():raise RuntimeError('Original footer backup missing; no settings changed')
    else:
        if original.exists():raise RuntimeError('Previous observer configuration exists; inspect before replacing it')
        atomic(original,json.dumps(old).encode())
        atomic(state/('claude-settings-before-observer-'+str(time.time_ns())+'.json'),before or b'{}')
    for name in ['claude_statusline.py','quotas.py','private_state.py']:
        atomic(target/name,(source/name).read_bytes())
    replacement=dict(old or {'type':'command'});replacement['command']=command;data['statusLine']=replacement
    if (settings.read_bytes() if settings.exists() else None)!=before:raise RuntimeError('Settings changed concurrently; not overwritten')
    atomic(settings,(json.dumps(data,indent=2)+'\n').encode(),(settings.stat().st_mode & 0o777) if settings.exists() else 0o600)
    return command
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--home',type=Path,default=Path.home());p.add_argument('--python',default='/usr/bin/python3');a=p.parse_args()
    print(install(a.home,Path(__file__).resolve().parent,a.python))
