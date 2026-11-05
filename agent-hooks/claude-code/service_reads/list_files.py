"""Finds the file each `@<list>` condition of a reads.txt line names.

`corpus-scan.py` reads the lines (`kept_reads`) without saying which area's file each came from, and
a list is kept beside the reads.txt that names it (`areas/<area>/lists/<list>.drive`). Called by
area-guard.py, which hands the lines it gets from the scan together with the lines as they are
kept (`kept_lines`), so that each `@<list>` becomes `@<path of the list file>`.
"""

from __future__ import annotations

import re
from pathlib import Path

from service_reads.rules import Line

LISTS_FOLDER = "lists"
LIST_SUFFIX = ".drive"
LIST_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")


def key_of(line: str) -> Line | None:
    """A line of reads.txt as the scan reads it: (destination, area, conditions), or None when it is too short."""
    words = line.split("#", 1)[0].split()
    if len(words) < 2:
        return None
    return words[0], words[1], tuple((key, shape) for key, _, shape in (w.partition("=") for w in words[2:]))


def located(lines: list[Line], kept: list[tuple[str, Path, str]]) -> list[Line]:
    """`lines` with each `@<list>` shape replaced by `@<the list's file>`: `lists/<list>.drive` beside the
    reads.txt that holds the line (`kept` is `kept_lines("reads.txt", ...)`: owner, file, line). A line
    kept by several areas becomes one line for each. A name that is no list name stays as it is."""
    keepers: dict[Line, list[Path]] = {}
    for _, file, text in kept:
        if (key := key_of(text)) is not None:
            keepers.setdefault(key, []).append(file.parent)
    out: list[Line] = []
    for pattern, area, conditions in lines:
        if not any(shape.startswith("@") for _, shape in conditions):
            out.append((pattern, area, conditions))
            continue
        for folder in keepers.get((pattern, area, conditions)) or [None]:
            out.append((pattern, area, tuple((key, _file_shape(folder, shape)) for key, shape in conditions)))
    return out


def _file_shape(folder: Path | None, shape: str) -> str:
    name = shape.removeprefix("@")
    if folder is None or not shape.startswith("@") or not LIST_NAME.fullmatch(name):
        return shape
    return f"@{folder / LISTS_FOLDER / (name + LIST_SUFFIX)}"
