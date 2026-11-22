"""Whether a Bash command is one search that cannot write: area-guard.py asks it of a file that takes added lines only.

The lines of such a file open with `>`, so a search of one holds that mark in quotes, and the split
of a command line reads a lone quoted mark as a redirection.
"""

from __future__ import annotations

import re

SEARCHES = ("grep", "egrep", "fgrep")
#: What could make the line more than one command, or make its quotes read otherwise.
MORE_THAN_WORDS = re.compile(r"[;&|`$#()<\\\n\r]")
QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")


def searches_only(command: str) -> bool:
    """Whether the command is a single grep with no `>` outside its quotes."""
    line = command.strip()
    if line.split(" ", 1)[0] not in SEARCHES or MORE_THAN_WORDS.search(line):
        return False
    outside = QUOTED.sub("_", line)
    return not any(mark in outside for mark in ">'\"")
