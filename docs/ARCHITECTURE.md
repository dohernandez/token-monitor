# Token Monitor architecture

Read [Usage and data](USAGE.md) for the full user-facing data contracts and [agent rules](../AGENTS.md) before editing.

## Source map

| File / symbol | Responsibility |
|---|---|
| main.swift / Store | Main-thread published snapshot; one background Python collector; polling and bounded indexing retries |
| main.swift / GroupRow | Parent/subagent model breakdown; session identity and status; compaction panel |
| main.swift / SubscriptionPanel, AlertLegend | Quota reports, window token counts, age/reset display, warning explanation |
| main.swift / AppDelegate | Retained status item, badge, popup and dismissal monitors |
| collector.py | Claude/Codex JSONL and read-only OpenCode adapters, event deduplication, parent links, activity checks, compactions |
| quotas.py | Provider quota normalization and raw-event window sums |
| claude_statusline.py | Whitelisted quota observation and exact forwarding to the original footer |
| install_claude_observer.py | Explicit observer installation, backup and concurrent-change guard |
| test_collector.py, test_quotas.py | Temporary-source accounting and observer regression tests |
| build.sh | Swift compilation, Python resource bundling and ad-hoc signing |

## Persistence and identity

Private state is under `~/Library/Application Support/TokenMonitor/`.
`usage-v1.sqlite` tables: events, files (offset/parser context), names, relations,
metadata (backfill markers), quotas, compactions. `collector.lock` serializes writers.
Source logs and the OpenCode database are read-only. No conversation or compaction
summary text is copied into private state. Metadata still includes paths and IDs;
backups should remain private.

Usage retention is 32 days, with Today / 7 / 30 day views using local midnight.
JSONL imports have a roughly 64 MiB per-invocation budget; incomplete lines retry.
Migration markers trigger one-time bounded replays, with stable IDs preventing
usage duplication. This is additive schema evolution, not a general migration framework.

Identity is provider + session ID, not public agent name. Clearing/reopening with a
new ID creates a separate card. Old usage remains until normal retention expires.
Historic names only exist if observed in the registry. The monitor cannot infer that
an unnamed earlier session belonged to a later named agent.

Parent rollups count each raw event once. Completed child rows disappear but their
spending remains. Active child detail requires recent lifecycle evidence; parent
Active status instead uses registry/process evidence. Claude requires its registered
PID to be Claude; Codex requires a fresh matching bridge projection and live owner.
OpenCode process IDs do not establish individual-session activity: show Unverified.
Activity is a snapshot at collection time, not proof the agent is generating.

## Quotas and compaction

Provider percentages are never calculated from token totals. Quota window token
counts sum raw deduplicated events from reset-minus-duration through report time.
They can include API/other-account usage and omit other machines or missing history.
Overlapping windows are not additive. Old Codex snapshots without duration wait for
a newer report. Expired windows are unknown, never assumed zero.

Yellow warning at 75%, red at 90%; highest unexpired reported warning wins across
providers. Stale reports retain their warning until reset. A separate 30-second
in-memory timer updates badge expiry without an extra collector invocation.

Compactions use Claude compact_boundary and Codex compacted events. Counts, known
durations and latest context sizes are metadata only; embedded Codex usage is not
assumed to be the compaction request's cost. Parent panels exclude child compactions.
OpenCode compactions are unsupported. The yellow panel must say spending is unverified.

## Runtime and known gaps

Refresh defaults to 30 seconds, saved as `refreshSeconds` in `local.darien.tokenmonitor`.
Allowed range: 5–3,600 seconds. History indexing retries in short batches.
Failed collection retains the previous snapshot, including its observed status.

Retain AppDelegate with withExtendedLifetime across app.run. Use a native template
base icon and mouse-transparent badge. The stable autosave name is TokenMonitor-status;
its own preferred position is seeded only when absent. Preserve later user placement.
A live process or status-item isVisible=true is not proof of visible pixels: the notch
or application menu can obscure it. See the recovery guide.

Missing history, source schema changes, stale activity, multiple accounts, arbitrary
paths and unresolved model aliases remain limitations. No billing accuracy claim,
automatic cleanup, launch-at-login, or guaranteed complete 30-day history.

## Distribution runtime

The collector uses `Contents/Resources/python/bin/python3` with `-B -E -s`, ignoring
Python environment variables and user site packages while retaining its bundled
sibling modules. The runtime is downloaded only at build time from the exact
release and SHA-256 in `scripts/python-runtime.json`; its license files are retained.
App runtime makes no new network requests. Bundle IDs and user data locations stay unchanged.
See [Releasing](RELEASING.md) for CI and optional observer setup.
