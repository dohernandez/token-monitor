#!/usr/bin/env python3
"""Read-only source adapters. Only the monitor's private SQLite cache is written."""
import subprocess
import argparse, datetime as dt, fcntl, hashlib, json, os, re, sqlite3, time
from pathlib import Path
from private_state import secure_state
from quotas import put_codex, subscription_snapshot

SCHEMA = '''
CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, source TEXT, session TEXT, project TEXT,
 model TEXT, stamp REAL, inp INTEGER, out INTEGER, cr INTEGER, cw INTEGER);
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode INTEGER, offset INTEGER, context TEXT);
CREATE TABLE IF NOT EXISTS names(session TEXT PRIMARY KEY, name TEXT);
CREATE TABLE IF NOT EXISTS relations(source TEXT, session TEXT, parent TEXT, state TEXT, stamp REAL,
 PRIMARY KEY(source,session));
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT);
CREATE TABLE IF NOT EXISTS compactions(id TEXT PRIMARY KEY,source TEXT,session TEXT,stamp REAL,
 before_tokens INTEGER,after_tokens INTEGER,duration_ms REAL);
CREATE TABLE IF NOT EXISTS quotas(id TEXT PRIMARY KEY,stamp REAL,payload TEXT);
'''
def number(v):
    return max(0, int(v or 0))
def timestamp(v):
    if isinstance(v, (int,float)): return v/1000 if v>10**11 else v
    try: return dt.datetime.fromisoformat(v.replace('Z','+00:00')).timestamp()
    except (ValueError,AttributeError): return 0

def relation(db,source,session,parent,state='unknown',stamp=0):
    if not session or not parent or session==parent:return
    db.execute("""INSERT INTO relations VALUES (?,?,?,?,?) ON CONFLICT(source,session) DO UPDATE SET
      parent=excluded.parent,state=CASE WHEN excluded.stamp>=stamp THEN excluded.state ELSE state END,
      stamp=max(stamp,excluded.stamp)""",(source,session,parent,state,stamp))

def claude_lifecycle(db,d,c):
    parent=d.get('sessionId') or c['session']
    if c.get('subagent'):
        relation(db,'Claude',parent+'/'+c['subagent'],parent)
        return
    result=d.get('toolUseResult')
    stamp=timestamp(d.get('timestamp'))
    if isinstance(result,dict) and result.get('agentId'):
        aid=str(result['agentId']).removeprefix('agent-')
        status=result.get('status')
        state='running' if status=='async_launched' else 'done' if status in ('completed','failed','killed','stopped') else 'unknown'
        relation(db,'Claude',parent+'/agent-'+aid,parent,state,stamp)
    # Only inspect native user/queue task-notification envelopes, never assistant
    # prose or arbitrary model output for lifecycle state.
    if d.get('type') not in ('user','queue-operation'):return
    content=d.get('content') if d.get('type')=='queue-operation' else (d.get('message') or {}).get('content')
    if isinstance(content,list):content='\n'.join(x.get('text','') for x in content if isinstance(x,dict) and x.get('type')=='text')
    if not isinstance(content,str):return
    for block in re.findall(r'<task-notification>(.*?)</task-notification>',content,re.S):
        aid=re.search(r'<task-id>([^<]+)</task-id>',block)
        status=re.search(r'<status>([^<]+)</status>',block)
        if aid and status and status[1] in ('completed','failed','killed','stopped'):
            relation(db,'Claude',parent+'/agent-'+aid[1].removeprefix('agent-'),parent,'done',stamp)


def codex_lifecycle(db,d,c):
    p=d.get('payload') or {}
    if d.get('type')=='session_meta':
        source=p.get('source')
        sub=source.get('subagent') if isinstance(source,dict) else None
        spawn=sub.get('thread_spawn') if isinstance(sub,dict) else None
        if isinstance(spawn,dict) and spawn.get('parent_thread_id'):
            c['parent']=spawn['parent_thread_id'];c['session']=p.get('id') or p.get('session_id') or c['session']
            relation(db,'Codex',c['session'],c['parent'])
    if c.get('parent') and d.get('type')=='event_msg':
        kind=p.get('type')
        state='running' if kind in ('task_started','turn_started') else 'done' if kind in ('task_complete','turn_complete','turn_aborted') else None
        if state:relation(db,'Codex',c['session'],c['parent'],state,timestamp(d.get('timestamp')))


def claude(d, context):
    m=d.get('message') or {}
    if d.get('type')!='assistant' or not isinstance(m,dict) or not m.get('usage') or not m.get('id'): return None
    u=m['usage']; sid=d.get('sessionId') or context['session']
    if context.get('subagent'): sid += '/' + context['subagent']
    return ('claude:'+sid+':'+m['id'], 'Claude', sid, d.get('cwd') or 'Unknown project', m.get('model') or 'Unknown model',
            timestamp(d.get('timestamp')),number(u.get('input_tokens')),number(u.get('output_tokens')),
            number(u.get('cache_read_input_tokens')),number(u.get('cache_creation_input_tokens')))

def codex(d,c):
    p=d.get('payload') or {}
    if d.get('type')=='session_meta':
        c['session']=p.get('id') or p.get('session_id') or c['session']; c['cwd']=p.get('cwd','Unknown project')
    if d.get('type')=='turn_context':
        c['model']=p.get('model','Unknown model'); c['cwd']=p.get('cwd',c.get('cwd','Unknown project'))
    if p.get('type')!='token_count' or not p.get('info'): return None
    info=p['info']; total=info.get('total_token_usage')
    if not total: return None
    fields=['input_tokens','output_tokens','cached_input_tokens','cache_write_input_tokens']
    current=[number(total.get(k)) for k in fields]; previous=c.get('counters',[0]*4)
    if current==previous: return None
    model=c.get('model','Unknown model')
    if any(a<b for a,b in zip(current,previous)):
        c['counter_resets']=c.get('counter_resets',0)+1
        delta=[number((info.get('last_token_usage') or {}).get(k)) for k in fields]
    else: delta=[a-b for a,b in zip(current,previous)]
    if 'counters' not in c and total != info.get('last_token_usage'): model='Unknown model · imported baseline'
    c['counters']=current
    signature=hashlib.sha256(json.dumps([c.get('counter_resets',0),current]).encode()).hexdigest()[:24]
    inp,out,cr,cw=delta
    return ('codex:'+c['session']+':'+signature,'Codex',c['session'],c.get('cwd','Unknown project'),model,
            timestamp(d.get('timestamp')), max(0,inp-cr-cw),out,cr,cw)

def put(db,row):
    if row is None or row[5]<=0: return
    # One provider message can appear several times while it streams. Preserve the
    # greatest reported counter for each category rather than summing duplicates.
    db.execute('''INSERT INTO events VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
      inp=max(inp,excluded.inp),out=max(out,excluded.out),cr=max(cr,excluded.cr),cw=max(cw,excluded.cw)''',row)

def put_compaction(db,d,c,source):
    is_claude=source=='Claude' and d.get('type')=='system' and d.get('subtype')=='compact_boundary'
    is_codex=source=='Codex' and d.get('type')=='compacted'
    if not (is_claude or is_codex):return
    stamp=timestamp(d.get('timestamp'))
    if stamp<=0:return
    sid=d.get('sessionId') or c['session']
    if c.get('subagent'):sid+='/'+c['subagent']
    meta=d.get('compactMetadata') or {} if is_claude else {}
    def metric(key):
        value=meta.get(key)
        return value if not isinstance(value,bool) and isinstance(value,(int,float)) and 0<=value<10**15 else None
    event=d.get('uuid') or (d.get('payload') or {}).get('compaction_response_id') or str(stamp)
    identity=source+':'+sid+':'+str(event)
    db.execute('INSERT OR IGNORE INTO compactions VALUES (?,?,?,?,?,?,?)',(identity,source,sid,stamp,metric('preTokens'),metric('postTokens'),metric('durationMs')))

def compaction_snapshot(db,days):
    cutoff=(dt.datetime.now().replace(hour=0,minute=0,second=0,microsecond=0)-dt.timedelta(days=days-1)).timestamp()
    groups={}
    for source,sid,stamp,before,after,duration in db.execute('SELECT source,session,stamp,before_tokens,after_tokens,duration_ms FROM compactions WHERE stamp>=? ORDER BY stamp',(cutoff,)):
        key=(source,sid)
        item=groups.setdefault(key,dict(source=source,session=sid,count=0,durationSeconds=0,durationsRecorded=0,beforeTokens=None,afterTokens=None,lastAt=stamp))
        item['count']+=1;item['lastAt']=stamp;item['beforeTokens']=before;item['afterTokens']=after
        if duration is not None:item['durationSeconds']+=duration/1000;item['durationsRecorded']+=1
    return list(groups.values())

def ingest_file(db,path,source,budget):
    stat=path.stat(); saved=db.execute('SELECT inode,offset,context FROM files WHERE path=?',(str(path),)).fetchone()
    c={'session':path.stem}
    if 'subagents' in path.parts: c['subagent']=path.stem
    offset=0
    if saved and saved[1]>0 and saved[0]==stat.st_ino and stat.st_size>=saved[1]: offset=saved[1]; c=json.loads(saved[2])
    used=0; invalid=0
    with path.open('rb') as f:
        f.seek(offset)
        while used<budget:
            line=f.readline()
            if not line:break
            if not line.endswith(b'\n'):break # Retry an incomplete final record next time.
            used+=len(line); offset=f.tell()
            try:
                d=json.loads(line)
                if source=='Claude':claude_lifecycle(db,d,c)
                else:
                    codex_lifecycle(db,d,c)
                    put_codex(db,d)
                put(db,claude(d,c) if source=='Claude' else codex(d,c))
                put_compaction(db,d,c,source)
            except (ValueError,TypeError,KeyError,AttributeError): invalid+=1
    db.execute('INSERT OR REPLACE INTO files VALUES (?,?,?,?)',(str(path),stat.st_ino,offset,json.dumps(c)))
    return used,offset<stat.st_size,invalid

def ingest_opencode(db,home,path=None):
    path=path or home/'.local/share/opencode/opencode.db'
    if not path.exists(): return False
    source=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=2)
    try:
        source.execute('PRAGMA query_only=ON')
        columns={r[1] for r in source.execute('PRAGMA table_info(session)')}
        if 'parent_id' in columns:
            for sid,parent in source.execute('SELECT id,parent_id FROM session WHERE parent_id IS NOT NULL'):
                relation(db,'OpenCode',sid,parent)
                recent=source.execute('SELECT data,time_updated FROM message WHERE session_id=? ORDER BY time_created DESC LIMIT 1',(sid,)).fetchone()
                if recent:
                    message=json.loads(recent[0]);timing=message.get('time') or {}
                    # A completed final answer is terminal; tool-calls can finish
                    # while the subagent continues, so they are not terminal here.
                    state='done' if timing.get('completed') and message.get('finish') not in (None,'tool-calls') else 'running' if message.get('role')=='assistant' and not timing.get('completed') else 'unknown'
                    relation(db,'OpenCode',sid,parent,state,timestamp(recent[1]))
        saved=db.execute('SELECT offset FROM files WHERE path=?',(str(path),)).fetchone()
        since=max(0,(saved[0] if saved else 0)-60000)
        latest=since
        for mid,sid,created,updated,raw,cwd in source.execute('''SELECT m.id,m.session_id,m.time_created,m.time_updated,m.data,s.directory
          FROM message m LEFT JOIN session s ON s.id=m.session_id WHERE m.time_updated>=? ORDER BY m.time_updated''',(since,)):
            latest=max(latest,updated)
            d=json.loads(raw)
            if d.get('role')!='assistant' or not d.get('tokens'):continue
            t=d['tokens']; cache=t.get('cache') or {}
            model=d.get('modelID') or 'Unknown model'
            if model=='default':model='Unresolved · '+d.get('providerID','unknown')+'/default'
            put(db,('opencode:'+mid,'OpenCode',sid,cwd or 'Unknown project',model,timestamp(created),
                    number(t.get('input')),number(t.get('output')),number(cache.get('read')),number(cache.get('write'))))
        db.execute('INSERT OR REPLACE INTO files VALUES (?,?,?,?)',(str(path),0,latest,'{}'))
    finally:source.close()
    return True

def active_sessions(home,processes=None,now=None):
    now=time.time() if now is None else now
    if processes is None:
        try:
            output=subprocess.run(['/bin/ps','-axo','pid=,comm='],capture_output=True,text=True,timeout=3,check=True).stdout
            processes={int(p[0]):p[1] for line in output.splitlines() if len(p:=line.strip().split(None,1))==2}
        except (OSError,ValueError,subprocess.SubprocessError):return []
    try:lines=(home/'.claude/handoff/.registry').read_text().splitlines()
    except OSError:return []
    result=[]
    for line in lines:
        parts=line.split('|')
        if len(parts)!=7:continue
        name,_,_,_,pid,_,sid=parts
        try:pid=int(pid)
        except ValueError:continue
        command=Path(processes.get(pid,'')).name.lower()
        if sid.startswith('codex-'):
            sid=sid.removeprefix('codex-')
            try:
                projection=json.loads((home/'.claude/handoff/codex'/ (sid+'.status.json')).read_text())
                age=now-timestamp(projection.get('checked_at'))
                owner=Path(processes.get(projection.get('owner'),'')).name.lower()
                if not (0<=age<=15 and projection.get('pid')==pid and projection.get('name')==name and projection.get('running') and projection.get('registered') and 'python' in command and 'codex' in owner):continue
            except (OSError,ValueError,TypeError):continue
            source='Codex'
        elif sid.startswith('opencode-'):
            # The registry identifies a process, not its individual OpenCode session.
            continue
        elif command=='claude':source='Claude'
        else:continue
        result.append(dict(source=source,session=sid,name=name))
    return result

def refresh(db,home,budget=64*1024*1024,config=None):
    config=config or {}
    enabled=config.get("enabled",["Claude","Codex","OpenCode"])
    source_paths=config.get("paths",{})
    notices=[]; sources=[]; remaining=budget; pending=0
    reg=home/'.claude/handoff/.registry'
    if config.get("handoff",True) and reg.exists():
        for line in reg.read_text().splitlines():
            parts=line.split('|')
            if len(parts)==7:
                sid=parts[6].removeprefix('codex-')
                db.execute('INSERT OR REPLACE INTO names VALUES (?,?)',(sid,parts[0]))
    for source,base in [('Claude',home/'.claude/projects'),('Codex',home/'.codex/sessions')]:
        if source not in enabled: continue
        base=Path(source_paths.get(source) or base).expanduser()
        exists=base.is_dir(); sources.append({'name':source,'available':exists})
        if not exists: notices.append(source+' local records not found');continue
        paths=sorted(base.rglob('*.jsonl'),key=lambda p:p.stat().st_mtime,reverse=True)
        for path in paths:
            # Retain a rolling 30-day view; an active older session is still read from
            # its beginning so cumulative counters and model changes have context.
            if path.stat().st_mtime<time.time()-31*86400:continue
            if remaining<=0: pending+=1;continue
            try:
                used,more,invalid=ingest_file(db,path,source,remaining);remaining-=used
                pending+=int(more)
                if invalid:notices.append(source+': skipped '+str(invalid)+' malformed records')
            except (OSError,sqlite3.Error) as e: notices.append(source+': '+str(e))
    try:
        available=ingest_opencode(db,home,Path(source_paths['OpenCode']).expanduser() if source_paths.get('OpenCode') else None) if 'OpenCode' in enabled else None
        if available is not None:sources.append({'name':'OpenCode','available':available})
        if available is False:notices.append('OpenCode local database not found')
    except (sqlite3.Error,ValueError,OSError) as e:
        sources.append({'name':'OpenCode','available':False});notices.append('OpenCode read failed: '+str(e))
    db.execute('DELETE FROM events WHERE stamp<?',(time.time()-32*86400,))
    db.execute('DELETE FROM compactions WHERE stamp<?',(time.time()-32*86400,))
    db.commit()
    if pending:notices.append('Indexing local history · '+str(pending)+' files remaining')
    return notices,sources,pending

def snapshot(db,days,notices,sources,pending,config=None):
    config=config or {}
    today=dt.datetime.now().replace(hour=0,minute=0,second=0,microsecond=0)
    cutoff=(today-dt.timedelta(days=days-1)).timestamp()
    names=dict(db.execute('SELECT session,name FROM names')) if config.get('handoff',True) else {}
    edges={(source,sid):(parent,state,stamp) for source,sid,parent,state,stamp in db.execute('SELECT * FROM relations')}
    def root_for(source,sid):
        seen=set()
        while (source,sid) in edges and sid not in seen:
            seen.add(sid);sid=edges[source,sid][0]
        # Existing Claude usage already encodes its parent, even before backfill.
        return sid.split('/')[0] if source=='Claude' else sid
    aggregated={};active={}
    rows=[]
    for source,sid,project,model,inp,out,cr,cw,latest in db.execute('''SELECT source,session,project,model,sum(inp),sum(out),sum(cr),sum(cw),max(stamp)
         FROM events WHERE stamp>=? GROUP BY source,session,project,model''',(cutoff,)):
        if source not in config.get("usage",["Claude","Codex","OpenCode"]):continue
        # Claude's local placeholder messages are not model usage. Keep any
        # unexpected nonzero counters visible rather than discarding spending.
        if source=='Claude' and model=='<synthetic>' and all(n==0 for n in (inp,out,cr,cw)):continue
        parent=root_for(source,sid)
        agent=names.get(parent) or source+' · '+parent[:8]
        is_child=sid!=parent
        key=(source,parent,project,model)
        row=aggregated.setdefault(key,dict(source=source,session=parent,agent=agent,project=project,model=model,input=0,output=0,cacheRead=0,cacheWrite=0,total=0,ownTotal=0,subagentTotal=0,latest=0))
        amount=inp+out+cr+cw
        for field,value in [('input',inp),('output',out),('cacheRead',cr),('cacheWrite',cw),('total',amount),('subagentTotal' if is_child else 'ownTotal',amount)]:row[field]+=value
        row['latest']=max(row['latest'],latest)
        edge=edges.get((source,sid))
        # Lifecycle signals are not heartbeats. Require recent evidence rather
        # than showing an old, unterminated launch as active forever.
        if is_child and edge and edge[1]=='running' and time.time()-max(latest,edge[2])<300:
            child=active.setdefault((source,sid),dict(source=source,session=sid,parent=parent,title='Subagent · '+sid.split('/')[-1].removeprefix('agent-')[:12],total=0,models={}))
            child['total']+=amount;child['models'][model]=child['models'].get(model,0)+amount
    rows=list(aggregated.values())
    active_children=[dict(c,models=[dict(model=k,total=v) for k,v in c['models'].items()]) for c in active.values()]
    if any(r['model'].startswith(('Unresolved','Unknown')) for r in rows):notices.append('Some records lack an actual model name; aliases are not guessed.')
    for source in sources:
        latest=db.execute('SELECT max(stamp) FROM events WHERE source=?',(source['name'],)).fetchone()[0]
        if source['available'] and (latest is None or time.time()-latest>86400):
            notices.append(source['name']+': no usage recorded in the last 24 hours. Coverage may be incomplete.')
    return dict(rows=rows,activeChildren=active_children,notices=notices,sources=sources,indexing=pending>0,updated=time.time())

def main():
    p=argparse.ArgumentParser();p.add_argument('--home',type=Path,default=Path.home());p.add_argument('--state',type=Path);p.add_argument('--config',default='{}');p.add_argument('--days',type=int,choices=[1,7,30],default=1);a=p.parse_args()
    config=json.loads(a.config)
    allowed={'Claude','Codex','OpenCode'}
    if not isinstance(config,dict):raise ValueError('Configuration must be an object')
    for key in ['usage','subscriptions']:
        if key in config and (not isinstance(config[key],list) or not all(x in allowed for x in config[key])):raise ValueError('Invalid enabled sources')
    config['enabled']=list(set(config.get('usage',allowed)) | set(config.get('subscriptions',[])))
    os.umask(0o077)  # This dedicated collector process writes only private state.
    state=secure_state(a.state or a.home/'Library/Application Support/TokenMonitor')
    with (state/'collector.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        db=sqlite3.connect(state/'usage-v1.sqlite');db.executescript(SCHEMA)
        if not db.execute("SELECT 1 FROM metadata WHERE key='parent-lifecycle-v1'").fetchone():
            # Replay retained source records once to recover lifecycle metadata.
            # Existing usage IDs make the replay idempotent; no usage is deleted.
            db.execute("UPDATE files SET offset=0,context='{}' WHERE path LIKE '%.jsonl'")
            db.execute("INSERT INTO metadata VALUES ('parent-lifecycle-v1','1')")
            db.commit()
        if not db.execute("SELECT 1 FROM metadata WHERE key='quota-backfill-v1'").fetchone():
            db.execute("UPDATE files SET offset=0,context='{}' WHERE path LIKE ?",(str(a.home/'.codex/sessions')+'/%',))
            db.execute("INSERT INTO metadata VALUES ('quota-backfill-v1','1')")
            db.commit()
        if not db.execute("SELECT 1 FROM metadata WHERE key='compaction-backfill-v1'").fetchone():
            db.execute("UPDATE files SET offset=0,context='{}' WHERE path LIKE '%.jsonl'")
            db.execute("INSERT INTO metadata VALUES ('compaction-backfill-v1','1')")
            db.commit()
        notices,sources,pending=refresh(db,a.home,config=config)
        result=snapshot(db,a.days,notices,sources,pending,config=config)
        result["subscriptions"]=[q for q in subscription_snapshot(db,state) if q["source"] in config.get("subscriptions",["Claude","Codex"])]
        result["activeSessions"]=[row for row in active_sessions(a.home) if row["source"] in config.get("usage",allowed)] if config.get("handoff",True) else []
        result["compactions"]=[row for row in compaction_snapshot(db,a.days) if row["source"] in config.get("usage",allowed)]
        print(json.dumps(result))
        db.close()
if __name__=='__main__':main()
