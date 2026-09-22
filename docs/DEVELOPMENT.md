# Token Monitor development and recovery

## Build and validate

Run from the project root, preserving the full build log:

```sh
python3 -m unittest -v test_collector.py test_quotas.py
./build.sh > build.log 2>&1
"build/Token Monitor.app/Contents/MacOS/TokenMonitor" --self-test
codesign --verify --deep --strict "build/Token Monitor.app"
```

Check each exit code; a later passing command does not make an earlier failed build
successful. `--self-test` runs native formatting, quota warning and timer/preference
checks without normal UI launch. Python fixtures use temporary sources/state.
The CLT SwiftBridging workaround belongs only in the project's VFS overlay; never
modify system module maps. Build overwrites the app bundle in place.

## Safe replacement and rollback

1. Copy current main.swift, collector/quotas/observer Python files, build.sh, docs
   and the working app bundle to a private temporary backup outside build/.
2. Before schema or accounting migration, stop the app and back up its private SQLite
   database using SQLite's backup API (not a live copy of only the main DB file).
   Preserve the observer configuration and preferences separately if changing them.
3. Build, run checks and verify signing. Do not launch after any failed check.
4. Use the footer power button to quit. For shell recovery, discover the exact PID
   with pgrep, verify its full executable path via ps, and inspect children. Wait
   for the owned collector or deliberately stop through the app. Never broad-kill.
5. Confirm exit, then launch the exact bundle once:

```sh
open "build/Token Monitor.app" --args --show
```

Opening an existing app may not forward startup arguments. `open -n` may be used
only after confirming the prior instance exited; avoid duplicate monitors.
No automatic installation, login item, credential/config copying, or permissions
changes are part of building. Do not relaunch agents or reinstall the Claude observer
for unrelated UI changes.

For rollback, quit the new app and restore/launch the saved source-matched bundle.
Only restore private state if required, while stopped; doing so loses data collected
after that backup. Never restore an entire old Claude settings file over newer settings.
Observer uninstall restores only the saved original statusLine object, preserving
all unrelated current settings. Detailed observer paths are in the README.

## Missing icon investigation

Check the exact process; a running process does not prove icon visibility. For a
controlled relaunch, pass --diagnostics. It writes a few startup/status-item metadata
lines to `/tmp/TokenMonitor-launch-diagnostic.jsonl` (no usage or conversation data).
Match PID/time; the file can contain old runs. Check button/image, frame and screen.
Compare the frame with NSScreen.auxiliaryTopRightArea on a notched display.

The September 21 incident was resolved by seeding the app's own preferred position
near the right edge and setting a stable autosaveName. The earlier lifetime guard
was a separate hardening change, not sufficient evidence of that incident's cause.
The user confirmed visible icons after repositioning. Command-drag lets the user
choose a new position. Do not reset global menu preferences or other applications.
Preferred-position persistence is an AppKit implementation detail, not a public
positioning API; revalidate when macOS changes.

## Other symptoms

- Quota website and app differ: compare provider report times, not footer check time.
  Polling local files does not force a new provider quota report.
- A quota window vanishes: inspect latest normalized report; a missing field is not
  treated as zero and individual missing windows currently need better placeholders.
- Old agent shows Unverified: compare session ID and registry/process evidence.
- Missing model in one card: check older sessions and Projects/Models before assuming loss.
- Large totals: cache reads are included once; B means billion, not billing cost.
- Partial indexing: wait for bounded batches; do not repeatedly force full replays.
- Compaction cost: not verified; context reduction must never be relabeled spending.
