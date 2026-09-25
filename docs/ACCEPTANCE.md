# Token Monitor acceptance checks

Run the automated commands in [Development](DEVELOPMENT.md) for runtime changes.
The last full Python run during development had 26 passing tests; test count is not
an evergreen guarantee. The September 22 documentation review did not rebuild or
retest runtime code. Successful compilation is not visual acceptance.

## Focused automatic checks

- Duplicate/streaming Claude records, Codex cumulative/cache accounting and resets.
- Read-only OpenCode ingestion, unknown models, file truncation and partial lines.
- Parent/subagent rollup, nesting, completion and recent lifecycle visibility.
- Same-name session activity, dead owners, stale/missing Codex projections.
- Latest quotas rather than summed snapshots; stale/expired/missing values.
- Window boundaries, provider separation, child counting, unknown duration.
- Observer forwarding of exact stdin/stdout/exit status and installer preservation.
- Compaction deduplication, date filtering, unknown cost and separate child identity.
- Native B/M formatting, warning thresholds/priority/expiry and timer persistence.

## Manual UI checks after relevant changes

- Footer buttons match Disk Monitor: 22 × 28 point frames, 8 point spacing and 14 point outer padding.
- One visible icon per app; retain native template tint and readable badge.
- Restart preserves user icon placement; notch test requires actual visible UI,
  not only isVisible or a process check.
- Outside click, Escape, deactivation and icon toggle dismiss the popup.
- No automatic first-card expansion; expand/collapse and sorting remain responsive.
- Agents, Models and Projects show exact-session Active/Unverified distinctions;
  active entries first, usage descending within each class. Never merge reused names.
- Parent/subagent totals reconcile; completed children stay hidden, spending retained.
- Models expand to folders; model/project outer cards remain usage-ranked.
- Quotas display their own timestamps/reset, visible local-token caveat and no
  invented zero on expiry. Alerts default to yellow >=75%, red >=90%, with red priority; saved custom thresholds apply everywhere.
- Yellow compaction panel distinguishes metadata from unverified token spending.
- Settings contains the alert legend; Settings/Info hide main navigation, retain
  footer and fixed bottom-right Back. Back restores prior view and discards edits.
- Saved interval survives restart; collection is not duplicated or interrupted by Save.

## Unverified boundaries

No automated pixel/click suite, live mid-collector termination test, end-to-end
account billing reconciliation, complete cross-provider model alias mapping, or
verified OpenCode parent liveness/compaction reporting. Source schemas may evolve.
Do not request Computer Use permissions just for screenshots. Never change live
provider logs to manufacture a fixture.

## Updates and privacy

- Run `SPARKLE_TOOLS=<build-dir>/sparkle python3 -B scripts/test_signatures.py`.
  Valid signed fixtures pass; changed installers, unsigned/changed feeds and wrong
  keys must fail. PR CI repeats this with temporary keys on both architectures.
- Verify cache migration preserves data, sets owner-only modes and rejects links.
- Manually check Settings update controls, automatic preferences across restart,
  update UI from a menu-bar app, and upgrade/relaunch while a measurement is active.
  Signature unit tests do not establish these interactive behaviors.
- The installed v1.0.0 app needs a manual upgrade before it can use in-app updates.

## Sources and subscriptions setup

Settings → Sources & subscriptions detects local clients on first use. Enable usage
for Claude, Codex or OpenCode, choose custom session directories (or an OpenCode
SQLite file), and enable Claude/Codex subscription reports independently. Choices
save immediately in sourceConfiguration UserDefaults. Disabled sources leave the
visible totals and badges; cached history remains under normal retention. Changing
a location does not erase previously collected provider history. These controls
configure local reports, not provider login, billing plans or account identities.

Claude setup explicitly confirms before wrapping ~/.claude/settings.json. Existing
command status lines and unrelated settings are preserved; no existing status line
is also supported, recorded as null in the backup. No live observer is installed
by builds/tests. Setup needed, Waiting for report and Connected (fresh local report)
are distinct states; Connected is not proof of authentication or complete coverage.
Custom Claude usage folders do not relocate observer settings. The observer uses
the app's bundled Python; keep the app at the same location after setup. Disabling
reports hides them but does not uninstall an existing observer.

Handoff is optional and read-only. Turning it off suppresses cached handoff names
and Active evidence, without changing parent/subagent accounting. No registry,
agent instructions, credentials or source logs are edited. Multiple accounts still
cannot be distinguished; reports and token totals are explicitly not account-specific.
OpenCode subscription quotas are unsupported. Older versions ignore source settings.

Acceptance: verify empty-Mac setup, one enabled provider, custom source location,
disabled historical totals/alerts, name fallback without handoff, setup confirmation
cancellation, and first Claude report. Automated fixtures cover config round-trip,
source detection/filtering, parent totals without handoff, and observer installation
with/without a prior status line. Native picker/setup interaction remains manual.

## Configurable subscription alerts

- Settings order: refresh interval, sources/subscriptions, subscription thresholds,
  alert legend directly below thresholds, then App updates last.
- Save valid whole percentages with 1 ≤ yellow < red ≤ 100. Badge, tab dot, quota
  colors and legend update immediately without starting a collection. Restart keeps
  the pair; leaving unsaved edits does not change thresholds.
- Reject equal/reversed/out-of-range values. Native fixtures cover custom boundaries,
  cross-provider priority, stale reports, expired/missing/invalid data, callback
  delivery without timer replacement, persistence, and invalid saved-pair fallback.
- Existing token accounting, source settings and observer configuration are unchanged.

- Subscriptions header has a separate card per provider, listing high-usage windows
  in saved yellow/red threshold colors; one provider’s red warning must not color
  another provider’s yellow card red;
  stale warnings remain labelled until reset, expired/unknown windows do not warn.
- An enabled provider with no recent records shows neutral informational text, without
  suggesting incomplete coverage merely from inactivity. Actual read/parse warnings
  remain warnings. Verify header wrapping and neutral notice contrast visually.

Subscription warning cards show each window’s reset countdown from the provider-reported reset timestamp, refreshed every 30 seconds. Expired windows leave the warning cards; reset times are never inferred from local token usage.
