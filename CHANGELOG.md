# Changelog

## Unreleased

- Check branch names in CI and a local hook, because the branch prefix sets the release bump.
- Reject AI attribution in commit messages (commit-msg hook) and, in a new CI Lint job, in every PR commit and the PR description.
- Move scripts into `taskfiles/<ns>/scripts/` and tests into `tests/unit/` and `tests/release/`.
- Run all project tooling through `Taskfile.yaml` namespaces; CI installs a checksum-pinned Task and calls tasks only. Add pre-commit hooks for lint, task CLI arguments, fast tests and conventional commit messages.
- Keep native test launch modes (`--self-test`, `--updater-self-test`, `--diagnostics`, `--show`) out of release builds; they compile only with `TEST_BUILD=1`.
- Add signed Sparkle updates, manual checking and optional automatic updates.
- Enforce owner-only cache permissions while preserving saved data.
- Reject unsafe archive links and duplicate entries when bundling Python.

## 1.0.0

First stable release of Token Monitor.

- Preserve the accepted menu bar dashboard, alerts, saved settings and measurements.
- Show the bundle version instead of a draft label.
- Add separate Apple Silicon and Intel DMG builds for macOS 15+.
- Validate PRs and generate versioned downloads automatically after merge.
- Document the intended main-branch rules and current GitHub plan restriction.
- Bundle a pinned Python runtime; keep Claude quota observer setup optional.

Downloads are ad-hoc signed; Apple notarization is not configured.
