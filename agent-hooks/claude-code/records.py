"""Conversation records of Claude Code sessions, as places a read reaches: the entry guard
(`area-guard.py`) reads a record as holding what its session read inside (that session's marks).

Claude Code keeps one record per session under each config folder, whatever the folder the
session worked in: `~/.claude*/projects/<folder>/<session id>.jsonl`, with the records of the
session's own subagents under `<session id>/`. A record holds the words of every file its session
read, so reading it is reading inside the areas that session read inside.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from pathlib import Path

RECORD = re.compile(r"\.claude[^/]*/projects/[^/]+/(?P<session>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                    r"[0-9a-f]{4}-[0-9a-f]{12})(?:\.jsonl|/.+)", re.IGNORECASE)
RECORDS = ".claude*/projects/*/*.jsonl"


def session_of(path: Path, homes: Iterable[Path]) -> str | None:
    """The session whose record `path` is (or lies inside: its subagents' records), or None."""
    for home in homes:
        if home in path.parents and (found := RECORD.fullmatch(path.relative_to(home).as_posix())):
            return found["session"].lower()
    return None


def sessions_under(folder: Path, homes: Iterable[Path]) -> set[str]:
    """The sessions whose records lie under `folder`: what a read of every file under it reads."""
    found = set()
    for home in homes:
        if folder == home or folder in home.parents:
            records = home.glob(RECORDS)
        elif home in folder.parents and folder.relative_to(home).parts[0].startswith(".claude"):
            records = folder.rglob("*.jsonl")
        else:
            continue
        found |= {session for record in records if (session := session_of(record, [home]))}
        if inside := session_of(folder, [home]):
            found.add(inside)
    return found
