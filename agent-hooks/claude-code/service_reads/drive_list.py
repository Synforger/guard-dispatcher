"""One list of Drive files an area keeps (`areas/<area>/lists/<name>.drive`), read into the remote
that reaches the Drive and the searches that find the files.

A line is `remote <name>` (an rclone remote, once) or `query <Drive search expression>` (once or
more); a line that starts with `#` is a comment. Read by drive_lists.py, which asks the Drive
(drive_table.py) for the files the queries find.
"""

from __future__ import annotations

from typing import NamedTuple

REMOTE_WORD = "remote"
QUERY_WORD = "query"


class DriveList(NamedTuple):
    remote: str
    queries: tuple[str, ...]

    @classmethod
    def parse(cls, text: str) -> DriveList:
        """The list a file's text holds. Raises ValueError, with one line saying what is wrong."""
        remotes: list[str] = []
        queries: list[str] = []
        for number, raw in enumerate(text.splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) < 2 or parts[0] not in (REMOTE_WORD, QUERY_WORD):
                raise ValueError(f"line {number} is not `{REMOTE_WORD} <name>` or `{QUERY_WORD} <expression>`")
            if parts[0] == QUERY_WORD:
                queries.append(parts[1].strip())
                continue
            name = parts[1].strip().removesuffix(":")
            if not name or ":" in name:
                raise ValueError(f"line {number}: `{parts[1].strip()}` is not the name of a remote")
            remotes.append(name)
        if len(remotes) != 1:
            raise ValueError(f"it needs exactly one `{REMOTE_WORD}` line, and has {len(remotes)}")
        if not queries:
            raise ValueError(f"it needs at least one `{QUERY_WORD}` line")
        return cls(remotes[0], tuple(queries))
