import json,sqlite3,tempfile,time,unittest
from pathlib import Path
import collector,quotas,claude_statusline

class QuotaTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.state=Path(self.temp.name)
        self.db=sqlite3.connect(':memory:');self.db.executescript(collector.SCHEMA);self.now=time.time()
    def tearDown(self):self.db.close();self.temp.cleanup()
    def event(self,stamp,used=25):
        return dict(payload=dict(type='token_count',rate_limits=dict(limit_id='codex',primary=dict(used_percent=used,window_minutes=10080,resets_at=self.now+3600))),timestamp=stamp)
    def test_latest_snapshot_not_summed(self):
        quotas.put_codex(self.db,self.event(self.now,14));quotas.put_codex(self.db,self.event(self.now-100,90));quotas.put_codex(self.db,self.event(self.now,14))
        row=quotas.subscription_snapshot(self.db,self.state,self.now)[0]
        self.assertEqual(row['used'],14);self.assertEqual(row['label'],'7 days');self.assertEqual(row['state'],'current')
    def test_missing_is_unknown(self):
        rows=quotas.subscription_snapshot(self.db,self.state,self.now)
        self.assertEqual(len(rows),2);self.assertTrue(all(r['used'] is None for r in rows))
    def test_stale_and_expired_not_reset_to_zero(self):
        quotas.put_codex(self.db,self.event(self.now-301,67))
        self.assertEqual(quotas.subscription_snapshot(self.db,self.state,self.now)[0]['state'],'stale')
        row=quotas.subscription_snapshot(self.db,self.state,self.now+4000)[0]
        self.assertEqual(row['state'],'expired');self.assertEqual(row['used'],67)
    def test_capture_whitelist_and_zero(self):
        raw=dict(session_id='session',prompt='PRIVATE TEXT',rate_limits=dict(five_hour=dict(used_percentage=0,resets_at=self.now+3600),seven_day=dict(used_percentage=80,resets_at=self.now+7000)))
        claude_statusline.capture(json.dumps(raw),self.state)
        saved=next((self.state/'claude-limits').glob('*.json')).read_text()
        self.assertNotIn('PRIVATE TEXT',saved);self.assertNotIn('session',saved)
        rows=[r for r in quotas.subscription_snapshot(self.db,self.state) if r['source']=='Claude']
        self.assertEqual(len(rows),2);self.assertEqual(rows[0]['used'],0)
    def test_missing_window_and_malformed_input(self):
        self.assertEqual(quotas.windows({'five_hour':{'used_percentage':True,'resets_at':self.now}},'Claude'),[])
        self.assertEqual(quotas.windows({'primary':{'used_percent':float('nan'),'resets_at':self.now,'window_minutes':30}},'Codex'),[])
        claude_statusline.capture(json.dumps(dict(session_id='s',rate_limits={})),self.state)
        rows=quotas.subscription_snapshot(self.db,self.state)
        self.assertTrue(all(r['state']=='unavailable' for r in rows))
    def test_window_tokens_boundaries_provider_and_children(self):
        window=dict(resetsAt=2000,durationSeconds=1000)
        for i,(source,session,stamp) in enumerate([('Claude','parent',999),('Claude','parent',1000),('Claude','parent/child',1500),('Claude','parent',1600),('Codex','other',1400),('Claude','parent',2000)]):
            self.db.execute('INSERT INTO events VALUES (?,?,?,?,?,?,?,?,?,?)',(str(i),source,session,'repo','model',stamp,1,2,3,4))
        row=quotas.window_usage(self.db,'Claude',window,1500,1700)
        self.assertEqual(row['records'],2);self.assertEqual(row['total'],20)
        self.assertEqual([row[k] for k in ['input','output','cacheRead','cacheWrite']],[2,4,6,8])
        self.assertEqual(quotas.window_usage(self.db,'Claude',window,2000,2100)['records'],3)
        self.assertIsNone(quotas.window_usage(self.db,'Claude',dict(resetsAt=2000),1500,1700))
    def test_snapshot_window_usage_and_expiry(self):
        quotas.put_codex(self.db,self.event(self.now,50))
        row=quotas.subscription_snapshot(self.db,self.state,self.now)[0]
        self.assertEqual(row['localUsage']['records'],0)
        self.assertAlmostEqual(row['localUsage']['startsAt'],self.now+3600-7*86400)
        self.assertIsNone(quotas.subscription_snapshot(self.db,self.state,self.now+4000)[0]['localUsage'])
    def test_installer_explicit_interpreter_with_spaces(self):
        import install_claude_observer as installer, sys, shlex
        home=self.state/'new home';(home/'.claude').mkdir(parents=True)
        settings=home/'.claude/settings.json'
        old=dict(statusLine=dict(type='command',command='/bin/cat'),untouched=True)
        settings.write_text(json.dumps(old))
        interpreter=self.state/'Python Runtime'/'python3';interpreter.parent.mkdir();interpreter.symlink_to(sys.executable)
        command=installer.install(home,Path(__file__).parent,str(interpreter))
        self.assertEqual(shlex.split(command)[0],str(interpreter))
        self.assertTrue(json.loads(settings.read_text())['untouched'])
        installer.install(home,Path(__file__).parent,str(interpreter))
        self.assertEqual(json.loads((home/'Library/Application Support/TokenMonitor/statusline-original.json').read_text()),old['statusLine'])

    def test_installer_and_footer_forwarding(self):
        import install_claude_observer as installer,subprocess,os
        home=self.state/'home';(home/'.claude').mkdir(parents=True)
        settings=home/'.claude/settings.json'
        old=dict(statusLine=dict(type='command',command='/bin/cat; exit 7',padding=1),unrelated=dict(enabled=True))
        settings.write_text(json.dumps(old))
        command=installer.install(home,Path(__file__).parent)
        config=json.loads(settings.read_text())
        self.assertEqual(config['unrelated'],old['unrelated']);self.assertEqual(config['statusLine']['padding'],1)
        raw=b'{"session_id":"test","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000}}}'
        result=subprocess.run(['/bin/sh','-c',command],input=raw,capture_output=True,env=dict(os.environ,HOME=str(home)))
        self.assertEqual(result.stdout,raw);self.assertEqual(result.returncode,7)
        self.assertTrue(list((home/'Library/Application Support/TokenMonitor/claude-limits').glob('*.json')))
        installer.install(home,Path(__file__).parent) # Reinstallation does not chain itself.
        original=json.loads((home/'Library/Application Support/TokenMonitor/statusline-original.json').read_text())
        self.assertEqual(original,old['statusLine'])
if __name__=='__main__':unittest.main()
