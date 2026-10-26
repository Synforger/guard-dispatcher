"""The paths a line names that lie inside the destination's own areas, taken out before the line is
compared: corpus-scan.py's main calls it for every line it scans, with the folder the line is
written from and the roots of the areas the destination lies in.

A place inside an area is named in that area's own records, and in the records of every area that
speaks of it (the summary of a company names its clients' folders). Writing that name into the
area itself carries nothing it does not hold already. A path naming a place outside those areas, or
one that does not exist, stays in the line and is compared as any other text.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from urllib.parse import unquote

#: A word that holds a slash and no character that ends a path in prose, markup or a command line:
#: `../docs/guide.html` inside `href="..."`, `(~/notes/todo.md)` inside a Markdown link.
PATH_WORD = re.compile(r"[^\s\"'<>()\[\]{}`,;|]*/[^\s\"'<>()\[\]{}`,;|]*")
#: What follows the path itself in a link: a fragment or a query.
LINK_TAIL = re.compile(r"[#?].*$")


def without_own_paths(line: str, base: Path, roots: list[Path]) -> str:
    """The line with every path that names an existing place inside one of `roots` replaced by a
    space. A relative path is read from `base` (the folder of the file the line is in) and from
    HOME (how paths are written in notes); a link's percent-escapes are decoded."""
    if not roots or "/" not in line:
        return line
    real_roots = [root.resolve() for root in roots]
    return PATH_WORD.sub(lambda m: " " if _names_own_place(m.group(0), base, real_roots) else m.group(0), line)


def _names_own_place(word: str, base: Path, roots: list[Path]) -> bool:
    written = LINK_TAIL.sub("", word.removeprefix("file://"))
    for spelling in {written, unquote(written)}:
        if not spelling.strip("/."):
            continue
        expanded = Path(os.path.expandvars(os.path.expanduser(spelling)))
        candidates = [expanded] if expanded.is_absolute() else [base / expanded, Path.home() / expanded]
        for place in candidates:
            try:
                if place.exists() and any(place.resolve().is_relative_to(root) for root in roots):
                    return True
            except (OSError, ValueError):
                continue
    return False
