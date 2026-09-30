#!/usr/bin/env python3
"""Check a commit message: a conventional-commit subject and no AI attribution (AGENTS.md; Darien, 2026-09-30).

Usage:
  python3 taskfiles/common/scripts/check_commit_message.py MSG_FILE

Run by the commit-msg git hook (pre-commit, stage commit-msg). Exit 0 when the message is valid, else 1
with the reason and the fix.

Project tooling (task common:check:commit-message); not part of the shipped app.
"""

import argparse
import re
import sys
from pathlib import Path

TYPES = "build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test"
SUBJECT = re.compile(rf"^({TYPES})(\([a-z0-9._/-]+\))?!?: \S.*$")
AI_ATTRIBUTION = re.compile(
    r"(co-authored-by:.*(claude|anthropic|openai|codex|copilot|gpt))|(generated with \[?claude)|(🤖)", re.I
)


def check(text: str) -> list:
    lines = [ln for ln in text.splitlines() if not ln.startswith("#")]
    errors = []
    subject = lines[0] if lines else ""
    if subject.startswith(("Merge ", 'Revert "', "fixup! ", "squash! ")):
        return errors
    if not SUBJECT.match(subject):
        errors.append(
            f"subject '{subject}' is not a conventional commit: '<type>(<scope>)?: <summary>', type one of {TYPES}"
        )
    if len(subject) > 100:
        errors.append(f"subject is {len(subject)} characters; keep it at 100 or fewer")
    for ln in lines:
        if AI_ATTRIBUTION.search(ln):
            errors.append(f"AI attribution is not allowed in this repo (AGENTS.md): '{ln.strip()}'; remove the line")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description="Check a commit message.")
    ap.add_argument("msg_file")
    a = ap.parse_args()
    errors = check(Path(a.msg_file).read_text())
    for e in errors:
        print(f"commit message: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
