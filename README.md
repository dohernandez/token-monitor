# Token Monitor — draft 01

Native macOS menu bar usage viewer. One icon and a soft dark popup with separate
**Usage** (default) and **Subscriptions** tabs. Usage contains Today / 7 days /
30 days views grouped by agent, model, or project. Expand rows for token categories
and the underlying model/agent breakdown. The information button explains coverage; Quit is the power icon in the footer. Outside click and Escape dismiss the popup.

## Maintenance guides

- [Agent rules](AGENTS.md)
- [Architecture and data contracts](docs/ARCHITECTURE.md)
- [Build, restart, backup and recovery](docs/DEVELOPMENT.md)
- [Acceptance checks and limitations](docs/ACCEPTANCE.md)

## Build, test, run

Requires macOS 15+, Apple Command Line Tools, and `/usr/bin/python3` (Python 3.9+).
No downloaded packages, API keys, network requests, or model calls are needed.
Claude subscription reporting uses the explicitly authorized status-line observer below.

```sh
python3 -m unittest -v test_collector.py test_quotas.py
./build.sh
"build/Token Monitor.app/Contents/MacOS/TokenMonitor" --self-test
codesign --verify --deep --strict "build/Token Monitor.app"
open "build/Token Monitor.app" --args --show
```

`build.sh` compiles SwiftUI/AppKit, bundles the Python collector, and ad-hoc signs
the app. Its project-local SwiftBridging overlay follows the Disk Monitor workaround;
it does not edit system toolchain files. No installer, login item, or notarization.
Quit before replacing/relaunching a running version. Do not kill unrelated processes.

## Data flow

`main.swift`: Store runs one background collector process at a time; all published
state is updated on the main thread. Normal polling defaults to 30 seconds and is configurable in Settings (5–3,600 seconds). History-indexing
batches retry after two seconds. AppDelegate owns the icon and popup event monitors.
The native template icon adapts to menu bar appearance; the popup is explicitly dark.

`collector.py`: reads local sources and caches only numeric usage metadata, IDs,
model names, paths, and observed handoff names in:
`~/Library/Application Support/TokenMonitor/usage-v1.sqlite`.
It does not retain conversation text or modify source logs/configuration. A file lock
serializes collector instances. SQLite transactions preserve offsets and records
across interrupted imports. Sources:

| Client | Source | Counting rule |
|---|---|---|
| Claude | `~/.claude/projects/**/*.jsonl` | Deduplicate session + message ID; retain maximum reported counters for streaming copies. Input, output, cache read/write are separate. |
| Codex | `~/.codex/sessions/**/*.jsonl` | Differences between cumulative counters; unchanged counters ignored. Cached input is a subset of input, subtracted before breakdown. Model from turn context. |
| OpenCode | `~/.local/share/opencode/opencode.db` | Read-only SQLite connection; message IDs deduplicate. Updated records reread with a 60-second overlap. Input/output/cache fields are used directly. |

Reasoning is not added to output again. Provider schemas can change; these rules
reflect records inspected on this machine, not a universal billing specification.
Codex counter resets use last-request usage; an imported baseline without matching
last-request totals has an unknown model. These cases need further validation before
using the app for financial reconciliation.

JSONL imports keep inode, offset, and parser context; incomplete trailing lines retry
later. Truncation/replacement restarts parsing and stable event IDs avoid replay
inflation. Files modified within 31 days are eligible, and each invocation reads
roughly 64 MiB of JSONL (a single line can exceed the budget). Older active sessions
are parsed from the beginning for counter context. Records older than 32 days are
pruned from the private cache. OpenCode reads changed messages without that byte cap.

Date periods begin at local midnight and include today. The source timestamp decides
the day; this is not necessarily the completion time. Initial totals are partial
while indexing. No recent source records triggers an explicit coverage notice.
A found source is not proof of complete coverage or a live client connection.

Agent names are matched from the existing local handoff registry by session ID and
remembered in the private cache. Historical names not observed there fall back to
client + short session ID. Subagent usage is rolled into the root parent session. Expanded parent cards show
Parent usage and Subagent usage; the headline and model breakdown include both once.
Completed subagent rows are hidden, while their usage remains in the parent's subtotal
for the selected period. Individual children appear only when recorded as running
with evidence within five minutes; missing/old lifecycle evidence does not delete spend.

Claude parent links come from subagent log identities and completion notices in parent
logs. OpenCode uses session.parent_id; Codex uses thread_spawn metadata and turn events.
Nested parent links resolve to the root. These are local observations, not a live task
service: long quiet tasks may be hidden and completion can lag until the next refresh.
Existing usage records remain in the private database for accounting and deduplication;
“hide completed” does not delete provider logs or lose historical totals.

An additive schema update adds relations and a migration marker. On the first run,
JSONL offsets are reset once to backfill lifecycle signals. Stable usage IDs prevent
replay inflation. A pre-update cache and app backup is retained outside the project.
The app does not start a handoff listener or change agent instructions.

## Draft boundaries

- Local recorded usage only, not account-wide billing or remaining subscription quota.
- OpenCode `default` stays visibly unresolved; no guessed underlying model.
- No cost estimates, configurable budgets, charts, exports, or login startup yet. Subscription quota bars are provider-reported snapshots, separate from budgets.
- Project grouping uses recorded working directories, so worktrees remain separate.
- Deleted/missing source logs cannot be reconstructed. Nonstandard client log locations
  are not auto-discovered. Missing/old sources may omit activity.
- There is no database migration framework; schema v1 uses its own filename.
- Persistent malformed-record history and full model-alias resolution remain follow-ups.
- Tests cover adapters and accounting boundaries, not automated AppKit visual behavior.

The existing Disk Monitor app is independent and unchanged.

## Subscription windows

`quotas.py` normalizes provider-reported percentages and reset timestamps. Bars do
not derive remaining subscription allowance from token counts. They are independent
of the Today/7 days/30 days token filter. Codex windows use their reported durations,
not an assumed five-hour or weekly schedule. The collector saves the latest report
per Codex limit bucket, so quota snapshots from several sessions are never summed.
An additive table stores them; Codex log offsets are replayed once to backfill.

A snapshot older than five minutes is labeled stale. Once its reset time passes,
the UI hides its percentage/bar and waits for a new report; it never assumes a reset
means 0% used. Countdown updates every 30 seconds while displayed. Missing windows
remain unavailable. No network quota polling or credential access is implemented.
The view reflects the latest locally observed account report; multiple subscription
accounts are not separated in this draft.

Claude Code supplies five-hour and seven-day fields to its status-line command.
`claude_statusline.py` captures only these numeric fields and the observation time,
using a hash of the session ID for atomic per-session files under
`~/Library/Application Support/TokenMonitor/claude-limits/`. It forwards the exact
original stdin bytes to the previous status-line command, preserving its stdout,
stderr, exit status, and other status-line settings. Capture errors do not suppress
the original footer. This observer does not touch transcripts, agent instructions,
credentials, handoff scripts, or inbox listeners.

Installation is explicit via `python3 install_claude_observer.py`. The authorized
installation changes only `statusLine.command` in `~/.claude/settings.json` and
copies the observer into the monitor's Application Support directory. Original
status-line configuration is in `statusline-original.json`; a private full settings
backup is saved as `claude-settings-before-observer-<timestamp>.json`. The installer
checks for concurrent settings changes. Fixture tests verify stdin/output/exit-code
preservation, unrelated settings, and idempotent reinstall.

Claude's bars stay unavailable until a session emits quota data. If a session keeps
using old status-line settings, it may need a settings reload or a later restart;
the monitor does not restart agents. To uninstall the observer, replace only the
`statusLine` object with the saved `statusline-original.json` object, preserving all
other current settings. Do not restore the entire old settings file over later edits.
Keep the observer files until no running session refers to them.

Sources: [Claude status-line fields](https://code.claude.com/docs/en/statusline#rate-limit-usage)
and [Codex rate-limit protocol](https://learn.chatgpt.com/docs/app-server).

Subscription cards, window-specific local token totals and reset countdowns live in Subscriptions; period-filtered token totals,
period selection, agent/model/project grouping, and coverage notices live in Usage.
Quota percentages and bars are yellow at >=75% and red at >=90%, with the normal
accent below 75%. Stale readings retain the color of their last reported usage; the separate stale
label and timestamp communicate freshness. The menu bar warning badge and tab dot use the highest reported level across both providers. Yellow means >=75%, red means >=90%, and red takes priority. Stale warnings remain until their known reset time; the tooltip labels stale reports. Expired or missing windows are unknown and do not create a usage badge. No badge is not proof that every window is available. These warnings never derive from token spend.
Tab switching retains the selected usage period and grouping without a new scan.

Subscriptions has Claude and Codex subtabs, with Claude initially selected. Each
shows only that provider’s windows; the main warning dot still considers both.
Switching provider retains the choice while navigating within the running app and
does not launch an extra refresh.

The Settings alert legend documents these app-specific thresholds; they are not a
claim about Claude Code’s or Codex’s native color schemes. Red takes precedence
over yellow. A lightweight 30-second timer reevaluates badge expiry without reading files or requesting provider data; collection updates it immediately too. The colored, mouse-transparent badge overlaps the native template icon without using another menu bar slot.

## Footer and refresh settings

The right-aligned footer icons are Refresh, Info, Settings, and Quit. Settings saves the
local polling interval under UserDefaults key `refreshSeconds` (default 30 seconds,
range 5–3,600). Saving replaces the timer without interrupting collection. Back
discards unsaved edits; Quit remains available. The interval controls reads of local
records and does not force a provider to publish fresh quota data. Indexing retries
still use bounded batches. The binary `--self-test` verifies preference persistence,
validation, and timer replacement without reading live usage data.

Quit is the rightmost power icon in the persistent footer. On Info and Settings,
Back stays fixed immediately above that footer, right-aligned, outside scrolling
content. Leaving Settings with Back discards unsaved edits.

The binary `--self-test` also checks badge thresholds, cross-provider priority, stale warning retention, expiry, and missing/invalid reports. Badge tooltip and accessibility label identify the provider, window, percentage and stale status.

The footer follows Disk Monitor: a status line (saved usage/subscription reports, reading, partial indexing, or failure), followed by the configured refresh interval and last successful local check time. This check time is not the provider report time; quota cards retain their own timestamps and stale labels. Source coverage remains in Usage notices.

## Agent breakdown

Expanded Agent cards separate Parent usage and Subagent usage. Each section combines matching model names using its existing ownTotal/subagentTotal fields; expanding a model reveals folder attribution. Active subagents are a labeled detail of the subtotal, not extra spend. Completed children stay hidden, with their tokens retained. The separate Models and Projects views retain their own grouping.

## Local tokens in subscription windows

Subscription cards include local input/output/cache totals for each known window, from reset minus reported duration through the quota observation time (not the later collection time). Queries sum deduplicated raw events, so parent and child events count once, independently of the Usage period filter. Expired windows hide these totals. Older stored Codex snapshots without duration wait for a new quota report. Zero matching records means no local records, not zero account usage. Visible caution covers model/cache weighting, missing logs/devices, and overlapping windows. Local totals cannot distinguish subscription-funded from API-funded usage or multiple accounts/buckets; they are provider-wide context, not billing attribution. Indexing may leave totals incomplete.

## Session identity and activity

Agent cards show a green Active badge and sort active sessions first, then descending tokens within each section. Activity is checked each collection via the read-only handoff registry and process table, keyed by exact source/session ID, never public name. Claude requires its registered PID to be a Claude process; Codex also requires a fresh (15s) matching bridge projection and a live Codex owner. Active means open, including idle, not necessarily generating. Unverified sessions have a gray badge; this does not prove closed. OpenCode process-only registry IDs cannot establish individual-session liveness and are labeled Unverified. Existing usage/retention and per-session identity remain unchanged. New sessions appear once they have recorded usage in the selected period.

In Models, expanded agent rows also show verified Active status and their short session ID. Active rows sort first, then descending usage; outer model cards stay ranked by total tokens. The same activity evidence and limitations apply as in Agents.

Status alignment: Agents headers and agent entries within both Models and Projects use one badge component: Active (green) or Unverified (gray). Unverified replaces absent badges; it does not assert termination and covers old sessions, unsupported OpenCode liveness, missing registry/projection, and failed verification. Every agent entry displays source + short session ID, and inner entries sort active first then usage. Projects lists agent names as primary text, with model in the subtitle. Outer model/project totals remain descending. Reusing a public name never transfers status or merges usage; all sessions can be unverified, and every independently verified live session is shown active.

## Number formatting

Token formatting uses B for totals at or above one billion (two decimal places), M for millions, and K for thousands, consistently throughout the app.

The Alert legend now lives in Settings, matching Disk Monitor, and explains menu badge thresholds, priority, stale retention and unknown coverage. Usage/Subscriptions navigation is hidden on Settings and Info; Back restores the prior page/provider selection. The persistent footer and fixed Back remain available.

## Compaction observations

Expanded Agent cards include a yellow Compactions / Limited data panel for the exact parent session and selected period. Claude compact_boundary events supply count, optional duration and last pre/post context size. Codex compacted events supply count only: embedded usage is not assumed to be compaction cost. No compaction metrics are added to token totals. Missing records are not proof of no compaction; OpenCode is not supported. Subagent events remain separate and are not included in the parent panel. Numeric metadata only is stored in the private compactions table; no summary text is retained. A one-time bounded JSONL replay backfills metadata using existing event deduplication, with the normal 32-day retention. Duration totals state how many events reported duration. Token spending is visibly marked not verified.

## Menu bar lifecycle and visibility

AppDelegate must stay strongly retained across the complete NSApplication.run() call using withExtendedLifetime. NSApplication.delegate is weak; losing the delegate also loses its NSStatusItem and can leave an iconless process running. Preserve this lifetime guard in both optimized and debug builds.

Launch with --diagnostics to record startup and status-item geometry in /tmp/TokenMonitor-launch-diagnostic.jsonl. isVisible does not prove unobscured placement; compare the frame with NSScreen.auxiliaryTopRightArea. Diagnostic logging is off normally.

Each status item has a stable app-specific autosaveName. Its own NSStatusItem Preferred Position preference is seeded to 0 only when absent, to start at the right end rather than behind the notch. Subsequent user placement is preserved. This AppKit preference is not a public positioning API and needs rechecking on OS upgrades; precedent: https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/ControlItem/ControlItem.swift . Other apps and global preferences are untouched.
