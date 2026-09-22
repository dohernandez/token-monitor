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
  invented zero on expiry. Alerts: yellow >=75%, red >=90%, red priority.
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
