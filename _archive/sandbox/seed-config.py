#!/usr/bin/env python3
"""Start a cage's Claude Code config directory from its account's, the first time it is used.

A fresh config directory opens on the first-run screens (text style, folder trust) -- a
session started for a web client or a script would wait there. What the account has already
been through is carried over, and nothing the cage has since chosen is overwritten:

- the first-run and seen-it markers of the account's state file
- the folder-trust answer of each project the account has answered, for the folders the cage
  can read (a folder's path names what is in it: the company cage is not told the clients')
- the account's settings.json, when the cage has none

The cage is the JSON `cage-config.py` prints; a cage that keeps the account's own directory
(personal) has nothing to seed.

Usage: seed-config.py <account config dir> <cage file>
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from fnmatch import fnmatchcase
from pathlib import Path

DEFAULT = Path(os.path.realpath(Path.home() / ".claude"))
# The markers that decide whether the first-run screens and notices show again.
SEEN = ["hasCompletedOnboarding", "lastOnboardingVersion", "lastReleaseNotesSeen",
        "hasSeenAutoDefaultNudge", "installMethod"]


def state_file(config_dir: Path) -> Path:
    """Where Claude Code keeps its state: beside the default directory, inside any other."""
    return Path.home() / ".claude.json" if config_dir == DEFAULT else config_dir / ".claude.json"


def read(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def hidden(folder: str, deny: list[str]) -> bool:
    """The folder is one the cage cannot read: at or under a denied path, or matching a glob."""
    return any(folder == d or folder.startswith(d.rstrip("/") + "/") or fnmatchcase(folder, d) for d in deny)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    account = Path(os.path.realpath(os.path.expanduser(sys.argv[1])))
    cage_spec = read(Path(sys.argv[2]))
    if "env" not in cage_spec:
        print(f"seed-config: {sys.argv[2]} is not a cage printed by cage-config.py", file=sys.stderr)
        return 2
    target = cage_spec["env"].get("CLAUDE_CONFIG_DIR")
    if not target:
        return 0
    cage = Path(os.path.realpath(target))
    if account == cage:
        return 0
    deny = cage_spec.get("sandbox", {}).get("filesystem", {}).get("denyRead", [])

    cage.mkdir(parents=True, exist_ok=True)
    if not (cage / "settings.json").exists() and (account / "settings.json").is_file():
        shutil.copy2(account / "settings.json", cage / "settings.json")

    theirs, path = read(state_file(account)), state_file(cage)
    ours = read(path)
    before = json.dumps(ours, sort_keys=True)
    for key in SEEN:
        if key in theirs and key not in ours:
            ours[key] = theirs[key]
    projects = ours.setdefault("projects", {})
    for folder, answers in theirs.get("projects", {}).items():
        if not isinstance(answers, dict) or not answers.get("hasTrustDialogAccepted") or hidden(folder, deny):
            continue
        if not projects.get(folder, {}).get("hasTrustDialogAccepted"):
            projects.setdefault(folder, {})["hasTrustDialogAccepted"] = True
    if not projects:
        ours.pop("projects")
    if json.dumps(ours, sort_keys=True) != before:
        tmp = path.with_suffix(".json.seed-tmp")
        tmp.write_text(json.dumps(ours, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
