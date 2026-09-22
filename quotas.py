"""Provider-reported subscription windows; never estimated from token totals."""
import json, math, time
from pathlib import Path

def windows(raw,source):
    result=[]
    if not isinstance(raw,dict):return result
    fields=[('five_hour','5 hours',300),('seven_day','7 days',10080)] if source=='Claude' else [('primary',None,None),('secondary',None,None)]
    for key,label,minutes in fields:
        w=raw.get(key)
        if not isinstance(w,dict):continue
        used=w.get('used_percentage') if source=='Claude' else w.get('used_percent')
        reset=w.get('resets_at')
        duration=minutes if source=='Claude' else w.get('window_minutes')
        if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) for v in [used,reset,duration]):continue
        if used<0 or used>100 or reset<=0 or duration<=0:continue
        if label is None:
            label=(str(int(duration/1440))+' days') if duration%1440==0 else (str(int(duration/60))+' hours') if duration%60==0 else str(int(duration))+' minutes'
        result.append(dict(id=key,label=label,used=float(used),resetsAt=float(reset),durationSeconds=float(duration)*60))
    return result

def put_codex(db,d):
    p=d.get('payload') or {}
    if p.get('type')!='token_count' or not isinstance(p.get('rate_limits'),dict):return
    from collector import timestamp
    stamp=timestamp(d.get('timestamp'))
    if stamp<=0:return
    raw=p['rate_limits'];bucket=raw.get('limit_id') or 'codex'
    value=dict(source='Codex',label=raw.get('limit_name') or str(bucket),observed=stamp,windows=windows(raw,'Codex'))
    db.execute('''INSERT INTO quotas VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET
        stamp=excluded.stamp,payload=excluded.payload WHERE excluded.stamp>=stamp''',('codex:'+str(bucket),stamp,json.dumps(value)))

def window_usage(db,source,window,observed,now):
    duration=window.get('durationSeconds')
    if not isinstance(duration,(int,float)) or not math.isfinite(duration) or duration<=0:return None
    start=window['resetsAt']-duration
    end=min(observed,now,window['resetsAt'])
    if start>end:return None
    # Query raw deduplicated events, never parent rollups plus child subtotals.
    row=db.execute("SELECT count(*),coalesce(sum(inp),0),coalesce(sum(out),0),coalesce(sum(cr),0),coalesce(sum(cw),0) FROM events WHERE source=? AND stamp>=? AND stamp<=? AND stamp<?",(source,start,end,window['resetsAt'])).fetchone()
    return dict(records=row[0],input=row[1],output=row[2],cacheRead=row[3],cacheWrite=row[4],total=sum(row[1:]),startsAt=start,through=end)

def subscription_snapshot(db,state,now=None):
    now=time.time() if now is None else now
    observations=[json.loads(row[0]) for row in db.execute('SELECT payload FROM quotas')]
    claude=[]
    for p in (Path(state)/'claude-limits').glob('*.json'):
        try:
            d=json.loads(p.read_text());stamp=d.get('observed')
            if isinstance(stamp,(int,float)) and math.isfinite(stamp) and 0<stamp<=now+60:
                claude.append(dict(source='Claude',label='Subscription',observed=stamp,windows=windows(d.get('rate_limits'),'Claude')))
        except (OSError,ValueError,TypeError):continue
    if claude:observations.append(max(claude,key=lambda d:d['observed']))
    result=[]
    for d in observations:
        if d['observed']>now+60:continue
        for w in d['windows']:
            expired=w['resetsAt']<=now
            result.append(dict(id=d['source']+':'+d['label']+':'+w['id'],source=d['source'],label=w['label']+((' · '+d['label']) if d['source']=='Codex' and d['label']!='codex' else ''),used=w['used'],resetsAt=w['resetsAt'],observed=d['observed'],state='expired' if expired else 'stale' if now-d['observed']>300 else 'current',localUsage=None if expired else window_usage(db,d['source'],w,d['observed'],now)))
    for source in ['Claude','Codex']:
        if not any(r['source']==source for r in result):
            result.append(dict(id=source+':missing',source=source,label='Awaiting provider data',used=None,resetsAt=None,observed=None,state='unavailable'))
    return result
