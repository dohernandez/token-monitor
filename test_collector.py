import datetime as dt
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
import collector as c

class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.db=sqlite3.connect(':memory:');self.db.executescript(c.SCHEMA)
        self.stamp=dt.datetime.now(dt.timezone.utc).isoformat()
    def tearDown(self): self.db.close();self.temp.cleanup()
    def test_active_sessions_distinguish_reused_names_and_dead_processes(self):
        reg=self.root/'.claude/handoff/.registry';reg.parent.mkdir(parents=True)
        reg.write_text('same|repo|main|/p|101|date|old\nsame|repo|main|/p|102|date|new\nwrong|repo|main|/p|103|date|unrelated\n')
        self.assertEqual(c.active_sessions(self.root,{102:'claude',103:'/bin/zsh'}),[dict(source='Claude',session='new',name='same')])
        self.assertEqual(c.active_sessions(self.root,{}),[])
    def test_codex_active_requires_fresh_projection_and_owner(self):
        reg=self.root/'.claude/handoff/.registry';reg.parent.mkdir(parents=True)
        reg.write_text('agent|repo|main|/p|101|date|codex-thread\n')
        path=reg.parent/'codex/thread.status.json';path.parent.mkdir()
        path.write_text(json.dumps(dict(name='agent',pid=101,owner=102,checked_at=1000,running=True,registered=True)))
        procs={101:'/usr/bin/python3',102:'/bin/codex'}
        self.assertEqual(c.active_sessions(self.root,procs,1005),[dict(source='Codex',session='thread',name='agent')])
        self.assertEqual(c.active_sessions(self.root,procs,1020),[])
        self.assertEqual(c.active_sessions(self.root,{101:'/usr/bin/python3'},1005),[])
    def test_compaction_metadata_deduplicates_without_spending(self):
        event=dict(type='system',subtype='compact_boundary',uuid='compact1',timestamp=self.stamp,sessionId='session',compactMetadata=dict(preTokens=900000,postTokens=25000,durationMs=120000))
        for _ in range(2):c.put_compaction(self.db,event,{'session':'session'},'Claude')
        row=c.compaction_snapshot(self.db,1)[0]
        self.assertEqual(row['count'],1);self.assertEqual(row['durationSeconds'],120)
        self.assertEqual(row['beforeTokens'],900000);self.assertEqual(row['afterTokens'],25000)
        self.assertEqual(self.db.execute('select count(*) from events').fetchone()[0],0)
        event['timestamp']='2000-01-01T00:00:00Z';event['uuid']='old'
        c.put_compaction(self.db,event,{'session':'session'},'Claude')
        self.assertEqual(c.compaction_snapshot(self.db,30)[0]['count'],1)
    def test_codex_compaction_usage_not_assumed_cost_and_child_separate(self):
        d=dict(type='compacted',timestamp=self.stamp,payload=dict(compaction_response_id='response',latest_token_usage_record=dict(usage=dict(total_tokens=9999))))
        c.put_compaction(self.db,d,{'session':'codex'},'Codex')
        row=c.compaction_snapshot(self.db,1)[0]
        self.assertEqual(row['count'],1);self.assertIsNone(row['beforeTokens']);self.assertEqual(row['durationsRecorded'],0)
        d=dict(type='system',subtype='compact_boundary',timestamp=self.stamp,uuid='child')
        c.put_compaction(self.db,d,{'session':'parent','subagent':'worker'},'Claude')
        self.assertEqual(set(r['session'] for r in c.compaction_snapshot(self.db,1)),{'codex','parent/worker'})
    def record(self):
        return dict(type='assistant',timestamp=self.stamp,sessionId='session',cwd='/project',message=dict(id='message',model='Model A',usage=dict(input_tokens=10,output_tokens=20,cache_read_input_tokens=30,cache_creation_input_tokens=40)))
    def test_claude_duplicates_and_stream_updates(self):
        d=self.record();c.put(self.db,c.claude(d,{'session':'fallback'}));c.put(self.db,c.claude(d,{'session':'fallback'}))
        d['message']['usage']['output_tokens']=25;c.put(self.db,c.claude(d,{'session':'fallback'}))
        self.assertEqual(self.db.execute('select count(*),sum(inp+out+cr+cw) from events').fetchone(),(1,105))
    def test_partial_line_and_incremental_append(self):
        p=self.root/'session.jsonl';raw=json.dumps(self.record()).encode();p.write_bytes(raw)
        _,pending,_=c.ingest_file(self.db,p,'Claude',10000)
        self.assertTrue(pending);self.assertEqual(self.db.execute('select count(*) from events').fetchone()[0],0)
        with p.open('ab') as f:f.write(b'\n')
        c.ingest_file(self.db,p,'Claude',10000);used,_,_=c.ingest_file(self.db,p,'Claude',10000)
        self.assertEqual(used,0);self.assertEqual(self.db.execute('select count(*) from events').fetchone()[0],1)
    def test_truncation_replay_deduplicates(self):
        p=self.root/'session.jsonl';line=json.dumps(self.record())+'\n';p.write_text(line+line)
        c.ingest_file(self.db,p,'Claude',10000);p.write_text(line);c.ingest_file(self.db,p,'Claude',10000)
        self.assertEqual(self.db.execute('select count(*) from events').fetchone()[0],1)
    def test_codex_counters_models_and_cached_subset(self):
        context={'session':'s','cwd':'/p','model':'A'}
        def record(inp,out,cache):return dict(timestamp=self.stamp,payload=dict(type='token_count',info=dict(total_token_usage=dict(input_tokens=inp,output_tokens=out,cached_input_tokens=cache))))
        a=record(100,20,80);c.put(self.db,c.codex(a,context));self.assertIsNone(c.codex(a,context))
        context['model']='B';c.put(self.db,c.codex(record(150,30,100),context))
        self.assertEqual(self.db.execute('select sum(inp+out+cr+cw) from events').fetchone()[0],180)
        self.assertEqual(self.db.execute("select inp,out,cr from events where model='B'").fetchone(),(30,10,20))
    def test_subagents_do_not_merge_parent_message(self):
        d=self.record();c.put(self.db,c.claude(d,{'session':'s'}));c.put(self.db,c.claude(d,{'session':'s','subagent':'worker'}))
        self.assertEqual(self.db.execute('select count(*) from events').fetchone()[0],2)
    def test_opencode_readonly_and_alias(self):
        p=self.root/'.local/share/opencode/opencode.db';p.parent.mkdir(parents=True)
        src=sqlite3.connect(p)
        src.executescript('CREATE TABLE session(id TEXT,directory TEXT); CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);')
        src.execute('insert into session values (?,?)',('s','/p'))
        d=dict(role='assistant',modelID='default',providerID='proxy',tokens=dict(input=10,output=20,cache=dict(read=30,write=40)))
        now=int(c.time.time()*1000);src.execute('insert into message values (?,?,?,?,?)',('m','s',now,now,json.dumps(d)));src.commit();src.close()
        before=p.read_bytes();c.ingest_opencode(self.db,self.root);c.ingest_opencode(self.db,self.root)
        self.assertEqual(p.read_bytes(),before)
        self.assertEqual(self.db.execute('select model,inp+out+cr+cw from events').fetchone(),('Unresolved · proxy/default',100))
        self.assertEqual(self.db.execute('select count(*) from events').fetchone()[0],1)
    def test_period_and_identity(self):
        c.put(self.db,c.claude(self.record(),{'session':'s'}));self.db.execute('insert into names values (?,?)',('session','genlayer-node-3'))
        view=c.snapshot(self.db,1,[],[],0)
        self.assertEqual(view['rows'][0]['agent'],'genlayer-node-3');self.assertEqual(view['rows'][0]['total'],100)
    def test_missing_sources_are_explicit(self):
        notices,sources,_=c.refresh(self.db,self.root)
        self.assertEqual(len(sources),3);self.assertTrue(all(not s['available'] for s in sources));self.assertEqual(len(notices),3)
    def test_parent_rollup_keeps_completed_spend_without_duplicate_models(self):
        d=self.record();c.put(self.db,c.claude(d,{'session':'s'}))
        c.put(self.db,c.claude(d,{'session':'s','subagent':'agent-child'}))
        c.relation(self.db,'Claude','session/agent-child','session','done',c.time.time())
        view=c.snapshot(self.db,1,[],[],0)
        self.assertEqual(len(view['rows']),1)
        row=view['rows'][0]
        self.assertEqual((row['total'],row['ownTotal'],row['subagentTotal']),(200,100,100))
        self.assertEqual(view['activeChildren'],[])
        self.assertEqual(self.db.execute('SELECT count(*) FROM events').fetchone()[0],2)
    def test_running_then_complete_hides_child_but_keeps_total(self):
        d=self.record();c.put(self.db,c.claude(d,{'session':'s','subagent':'agent-child'}))
        launch=dict(type='user',sessionId='session',timestamp=self.stamp,toolUseResult=dict(agentId='child',status='async_launched'))
        c.claude_lifecycle(self.db,launch,{'session':'session'})
        before=c.snapshot(self.db,1,[],[],0)
        self.assertEqual(len(before['activeChildren']),1)
        end=dict(type='user',sessionId='session',timestamp=self.stamp,message=dict(content=[dict(type='text',text='<task-notification><task-id>child</task-id><status>completed</status></task-notification>')]))
        c.claude_lifecycle(self.db,end,{'session':'session'})
        after=c.snapshot(self.db,1,[],[],0)
        self.assertEqual(after['activeChildren'],[]);self.assertEqual(before['rows'],after['rows'])
        # Re-observing the file path with unknown status cannot resurrect a child.
        c.relation(self.db,'Claude','session/agent-child','session')
        self.assertEqual(c.snapshot(self.db,1,[],[],0)['activeChildren'],[])
    def test_child_only_usage_has_parent_row_and_model_breakdown(self):
        d=self.record();d['message']['model']='B'
        c.put(self.db,c.claude(d,{'session':'s','subagent':'agent-child'}))
        self.db.execute('INSERT INTO names VALUES (?,?)',('session','parent-name'))
        row=c.snapshot(self.db,1,[],[],0)['rows'][0]
        self.assertEqual((row['session'],row['agent'],row['model'],row['ownTotal']),('session','parent-name','B',0))
    def test_codex_parent_and_completion_metadata(self):
        ctx={'session':'child'}
        c.codex_lifecycle(self.db,dict(type='session_meta',payload=dict(id='child',source=dict(subagent=dict(thread_spawn=dict(parent_thread_id='parent'))))),ctx)
        c.codex_lifecycle(self.db,dict(type='event_msg',timestamp=self.stamp,payload=dict(type='task_started')),ctx)
        c.put(self.db,('event','Codex','child','/p','M',c.time.time(),10,20,30,40))
        active=c.snapshot(self.db,1,[],[],0)
        self.assertEqual(active['rows'][0]['session'],'parent');self.assertEqual(len(active['activeChildren']),1)
        c.codex_lifecycle(self.db,dict(type='event_msg',timestamp=self.stamp,payload=dict(type='task_complete')),ctx)
        self.assertEqual(c.snapshot(self.db,1,[],[],0)['activeChildren'],[])
    def test_nested_subagents_roll_up_once(self):
        c.relation(self.db,'OpenCode','child','parent');c.relation(self.db,'OpenCode','grandchild','child')
        for sid in ['parent','child','grandchild']:c.put(self.db,(sid,'OpenCode',sid,'/p','M',c.time.time(),10,0,0,0))
        rows=c.snapshot(self.db,1,[],[],0)['rows']
        self.assertEqual(len(rows),1);self.assertEqual((rows[0]['total'],rows[0]['subagentTotal']),(30,20))
    def test_stale_running_state_not_shown(self):
        then=c.time.time()-600
        c.relation(self.db,'Claude','session/agent-child','session','running',then)
        c.put(self.db,('old','Claude','session/agent-child','/p','M',then,100,0,0,0))
        view=c.snapshot(self.db,7,[],[],0)
        self.assertEqual(view['activeChildren'],[]);self.assertEqual(view['rows'][0]['subagentTotal'],100)
if __name__=='__main__':unittest.main()
