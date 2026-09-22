#!/usr/bin/python3
"""Capture only quota fields, then forward unchanged stdin to the prior status line."""
import hashlib,json,os,subprocess,sys,tempfile,time
from pathlib import Path
from private_state import secure_directory, secure_state
from quotas import windows

def capture(raw,state):
    data=json.loads(raw)
    if not isinstance(data,dict):return
    limits=data.get('rate_limits') or {}
    # Normalize and whitelist numeric fields. No transcript, credential, or prompt
    # content is written, even though the status-line payload contains other data.
    normalized={}
    for w in windows(limits,'Claude'):
        normalized[w['id']]=dict(used_percentage=w['used'],resets_at=w['resetsAt'])
    sid=data.get('session_id')
    if not isinstance(sid,str) or not sid:return
    target=secure_directory(secure_state(state)/'claude-limits')
    payload=dict(observed=time.time(),rate_limits=normalized)
    name=hashlib.sha256(sid.encode()).hexdigest()+'.json'
    fd,tmp=tempfile.mkstemp(prefix='.quota-',dir=target)
    try:
        with os.fdopen(fd,'w') as f:json.dump(payload,f)
        os.replace(tmp,target/name)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def main():
    state=Path.home()/'Library/Application Support/TokenMonitor'
    original=json.loads((state/'statusline-original.json').read_text())
    command=original['command'] if original is not None else None
    raw=sys.stdin.buffer.read()
    try:capture(raw,state)
    except Exception:pass # Monitoring must never prevent the existing footer.
    if command is None:return 0
    result=subprocess.run(['/bin/sh','-c',command],input=raw)
    return result.returncode
if __name__=='__main__':sys.exit(main())
