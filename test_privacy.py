import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from private_state import secure_state

class PrivacyTests(unittest.TestCase):
    def test_new_and_existing_state_are_private_without_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);state=root/'state';state.mkdir(mode=0o755)
            db=sqlite3.connect(state/'usage-v1.sqlite')
            db.execute('CREATE TABLE preserved(value TEXT)');db.execute("INSERT INTO preserved VALUES ('keep')");db.commit();db.close()
            (state/'usage-v1.sqlite').chmod(0o644)
            parent_mode=root.stat().st_mode & 0o777
            result=subprocess.run([sys.executable,'-B','collector.py','--home',str(root/'empty-home'),'--state',str(state)],capture_output=True,text=True,umask=0o022)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(state.stat().st_mode & 0o777,0o700)
            for name in ('collector.lock','usage-v1.sqlite'):
                self.assertEqual((state/name).stat().st_mode & 0o777,0o600)
            with sqlite3.connect(state/'usage-v1.sqlite') as db:
                self.assertEqual(db.execute('SELECT value FROM preserved').fetchone()[0],'keep')
            self.assertEqual(root.stat().st_mode & 0o777,parent_mode)

    def test_refuses_symlink_and_hardlink_without_changing_target(self):
        for kind in ('symlink','hardlink'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);state=root/'state';state.mkdir();outside=root/'outside';outside.write_text('keep');outside.chmod(0o644)
                if kind=='symlink':(state/'usage-v1.sqlite').symlink_to(outside)
                else:os.link(outside,state/'usage-v1.sqlite')
                with self.assertRaises((ValueError,OSError)):secure_state(state)
                self.assertEqual(outside.stat().st_mode & 0o777,0o644)
                self.assertEqual(outside.read_text(),'keep')

    def test_new_state_and_legacy_quota_permissions(self):
        from claude_statusline import capture
        import json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);state=root/'state'
            result=subprocess.run([sys.executable,'-B','collector.py','--home',str(root/'empty-home'),'--state',str(state)],capture_output=True,text=True,umask=0o022)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(state.stat().st_mode & 0o777,0o700)
            self.assertEqual((state/'usage-v1.sqlite').stat().st_mode & 0o777,0o600)
            quota=state/'claude-limits';quota.mkdir(mode=0o755);old=quota/'legacy.json';old.write_text('{}');old.chmod(0o644)
            capture(json.dumps({'session_id':'fixture','rate_limits':{}}),state)
            self.assertEqual(quota.stat().st_mode & 0o777,0o700)
            self.assertEqual(old.read_text(),'{}')
            for file in quota.iterdir():self.assertEqual(file.stat().st_mode & 0o777,0o600)
