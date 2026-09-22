# Token Monitor maintenance

Read README.md, docs/ARCHITECTURE.md, docs/DEVELOPMENT.md and relevant docs/ACCEPTANCE.md checks before changes; verify current source. This is a standalone macOS app;
do not edit Disk Monitor, agent logs, native hooks, or credentials. Global settings
are unchanged except the explicitly authorized Claude status-line observer documented
in docs/USAGE.md. Preserve the prior footer and unrelated settings when maintaining it.

Preserve these contracts:
- Read-only sources. Writes go only to the monitor's own cache/build outputs.
- No conversations in the private metadata cache; no telemetry. Only the authorized Sparkle update flow may contact the network.
- Deduplicate provider messages; never sum cumulative counters or add cached input twice.
- Unknown models and incomplete coverage must remain explicit. Never label an alias
  as an actual model or interpret missing data as proof of zero spending.
- Completed subagents must not appear as separate agents. Preserve their usage in
  parent totals and model breakdowns exactly once. Active-child detail requires lifecycle
  evidence; unknown state must not be presented as confirmed live.
- Agent identity is session-based; public names can be reused. Keep sessions distinct.
- One collector per app refresh; background work only; update UI on the main thread.
- Icon only, native template tint; dark popup; remove event monitors on dismissal.
- Fixture tests must use temporary sources/state. Never edit real provider records.

Run `python3 -m unittest -v test_collector.py test_quotas.py test_privacy.py`, build, and verify signing for runtime
changes. Add regression fixtures for accounting changes. A successful build is not
visual UI verification. Do not invoke Computer Use permissions merely for screenshots.
Preserve a working app/source copy before replacing a used version. Discover and
verify exact process IDs before stopping anything; never use broad kill patterns.
Update docs to reflect behavior. No cleanup/prune operations, login items, or installs
are implicitly authorized by work on this viewer.

Quota snapshots must never be summed or inferred from token spend. Missing/expired
windows are unknown, not zero. Preserve snapshot age and reset countdowns. Changes
to the Claude observer require forwarding and installer regression tests.

- Active is source/session-based; preserve separate same-name sessions and gray Unverified status across all agent views.
- Compaction context sizes/duration are not token spending. Keep the yellow limitation label and never add these metrics to usage totals.
- Retain AppDelegate across app.run; preserve stable autosaveName and user icon placement. isVisible alone does not prove an icon is unobscured.
- Docs-only work does not require app restarts, builds, scans or observer installation.

## Releases

Read [Release policy](docs/RELEASING.md) for stable versioning, signed commits,
required CI checks and installer verification. Use `BUILD_DIR` for isolated builds.
Keep the bundle identity and user preferences stable across upgrades. A ruleset
file is not proof that GitHub enforces it; verify server-side activation separately.
Never label ad-hoc app signatures Apple-notarized.

## Security invariants

Never install an update without signature verification. Keep `SURequireSignedFeed`
and `SUVerifyUpdateBeforeExtraction` enabled, preserve the committed public key,
and never put private signing seeds in source, logs, or PR jobs. Signing secrets are
restricted to the main-only release environment. Preserve 0700/0600 cache privacy
and reject links before changing private-state permissions. Archive extraction must
not write through symbolic links. Run the focused privacy/archive tests plus real
Sparkle tamper-rejection checks after changes in these paths.
