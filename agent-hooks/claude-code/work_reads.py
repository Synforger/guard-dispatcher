"""Read the names a work folder's `guard-reads.txt` gives: the areas a session working there may read
beyond the ones holding the folder. The entry guard (`area-guard.py`) and the relay between sessions
(`peers.py`) read it through here."""

from __future__ import annotations

from pathlib import Path

READS_FILE = "guard-reads.txt"


def named(home: Path) -> set[str]:
    """The names written in the folder's reads file (`#` starts a comment); none when it is absent."""
    try:
        lines = (home / READS_FILE).read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()
    return {word for line in lines for word in line.split("#", 1)[0].split()}
