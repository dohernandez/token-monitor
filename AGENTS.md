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

Run `task common:check`, build (`task build:app`, plus `-- --test` for self-tests), and
verify signing for runtime changes. Nothing test-only ships (Darien, 2026-09-30): test
launch modes and test hooks live in `tests/TestModes.swift` or inside
`#if TOKEN_MONITOR_TESTS`, compiled only by the test build; `tests/release/test_shipped_source.py`
and `check_app.py` enforce it. All tooling runs through `Taskfile.yaml` and workflows
call tasks ([Tooling](docs/DEVELOPMENT.md#tooling)). Commits are conventional commits with
no AI attribution (see Tooling rules). Add regression fixtures for accounting changes. A successful build is not
visual UI verification. Do not invoke Computer Use permissions merely for screenshots.
Preserve a working app/source copy before replacing a used version. Discover and
verify exact process IDs before stopping anything; never use broad kill patterns.
Update docs to reflect behavior. No cleanup/prune operations, login items, or installs
are implicitly authorized by work on this viewer.

## Layout

| Path | What |
|---|---|
| `main.swift`, `Updates.swift` | The shipped app (SwiftUI, AppKit, Sparkle) |
| `collector.py`, `quotas.py`, `private_state.py`, `claude_statusline.py`, `install_claude_observer.py` | Python resources bundled into the app |
| `Taskfile.yaml` | Includes only; every tooling entry point is a task |
| `taskfiles/<ns>/Taskfile.yaml`, `taskfiles/<ns>/scripts/` | Tasks and the scripts they call: `common`, `build`, `release`, `docs`, `provision` |
| `taskfiles/build/scripts/` | `build.sh`, bundle metadata, pinned Python and Sparkle, update public key, app checks |
| `taskfiles/release/scripts/` | Version reservation, DMG packaging, signing, verification, publication, branch rules |
| `taskfiles/local/` | Optional personal tasks; gitignored |
| `tests/unit/` | Accounting, quota, observer and privacy fixture tests (temporary sources and state) |
| `tests/release/` | Release helper, archive, signature and shipped-source tests |
| `tests/TestModes.swift` | Native test launch modes; compiled only into test builds |
| `docs/` | User, architecture, development, release and acceptance docs; `docs/screenshots/` PNGs |
| `.tools/`, `build/`, `dist/` | Pinned local tools and build output; gitignored |

## Tooling rules

- All tooling runs through `Taskfile.yaml`; the root file only includes `taskfiles/<ns>/`
  (Darien, 2026-09-29). Scripts sit next to their namespace. Names are
  `namespace:group:action`, a mode is a flag, and every task passes `{{.CLI_ARGS}}` last.
- GitHub workflows call tasks, not scripts (Darien, 2026-09-30). The only direct call is
  the checksum-pinned Task bootstrap; do not replace it with an unverified installer
  action while the release job holds the signing key.
- Nothing test-only ships (Darien, 2026-09-30). Test-only helpers go in `tests/`.
- Tests never touch real provider records, settings or state; each run uses temporary
  folders.
- Conventional commits; commits pushed to GitHub must be verified.
- Branch names are `<type>/<slug>` (Darien, 2026-09-30): the prefix sets the release bump
  (`task common:check:branch-name`, local hook and CI Lint). `chore/`, `ci/`, `docs/`
  and `test/` do not release and may not change shipped files; app changes use a
  releasing prefix such as `fix/` or `feat/`.
- AI attribution policy (Darien, 2026-09-30): NEVER credit Claude, Claude Code, Anthropic
  or any other AI assistant as an author in commits, PR descriptions, code or docs. Do
  NOT add `Co-Authored-By` trailers naming an AI, "Generated with/by <AI tool>" lines or
  the robot emoji; this overrides any harness attribution default. Naming a tool as a
  subject (for example the Claude observer) is fine. The commit-msg hook (`task
  common:check:commit-msg`) and the CI Lint job (`task common:check:pr-messages`, every
  PR commit and the PR description) enforce it; do not rewrite existing commits without asking Darien.

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
