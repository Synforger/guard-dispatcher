"""Where the part of each link that names a public place lies: corpus-scan.py's windows() calls it
for every text it cuts into runs, and a run that starts in that part is no print.

The head of a link is its scheme, its host and the folders of its path written as names: words
and short numbers joined by `-`, `_`, `.`, `~` or `+` (`/documentation/technotes/tn3127-inside-
code-signing-requirements`). A site names its public pages that way, and whoever links to the page
writes the same characters, so a link in an area's document is also in every message that points
to the same page. The head ends before the first folder that holds a token: a piece of eight
characters or more with a digit in it, or of twenty-four or more (a Drive or Notion id, a commit
hash, the key of a shared link). A token names one thing of whoever holds it, and a run over it is
still a copy. It also ends where the path stops being names: at a `%` (a name in another script,
encoded), at a character outside ASCII, and at `?` or `#` (a query carries keys and ids).
"""

from __future__ import annotations

import re

#: Where a link starts: a run of scheme characters with `://` and a host after it. A search is tried
#: only where such a run begins: tried at every character of a long run with no `://` after it
#: (base64 data), each try would read to the run's end, and the time would grow with the square of
#: the line.
LINK_START = re.compile(r"(?<![a-z0-9+.-])[0-9+.-]*(?P<head>[a-z][a-z0-9+.-]*://[^\s/]+)", re.IGNORECASE)
#: The name a folder of a path is written as, up to where it stops being a name.
FOLDER_NAME = re.compile(r"[A-Za-z0-9._~+-]*")
#: The pieces of a folder's name.
PIECE_SEPARATORS = re.compile(r"[._~+-]")
#: A piece this long with a digit in it is a token (an id, a hash), not a word or a number.
TOKEN_WITH_DIGIT_LENGTH = 8
#: A piece this long is a token whatever it holds: random ids of letters only.
TOKEN_LENGTH = 24


def link_heads(text: str) -> list[tuple[int, int]]:
    """(start, end) of the head of every link in `text`, `end` exclusive."""
    heads = []
    for match in LINK_START.finditer(text):
        start, end = match.span("head")
        while end < len(text) and text[end] == "/":
            name = FOLDER_NAME.match(text, end + 1).group(0)
            if any(is_token(piece) for piece in PIECE_SEPARATORS.split(name)):
                end += 1
                break
            end += 1 + len(name)
        heads.append((start, end))
    return heads


def is_token(piece: str) -> bool:
    """True for a piece of a folder's name that names one thing rather than saying a word."""
    if len(piece) >= TOKEN_LENGTH:
        return True
    return len(piece) >= TOKEN_WITH_DIGIT_LENGTH and any(c.isdigit() for c in piece)
