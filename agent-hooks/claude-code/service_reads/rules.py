"""Which areas a reading call to a service reads inside: judged from the lines of the areas'
`reads.txt` (read by the private-document scan, `kept_reads`) and the call alone.

Called by area-guard.py, which counts what this returns as read, as a file read inside those areas
is: a session that may not read there is refused before the call runs.

A line is (destination pattern, area, conditions). The destination is named as the send guard
names it: an MCP tool, `browser:<host>`, `host:<host>`. A condition is an argument of the call and
the shape its value has (`channel_id=C0123*`): a line with conditions sets apart what those values
reach (a channel the company hands to one of its cases), a line with none takes the rest. A call
that gives no value for a condition (a search over every channel) may read where every line of the
destination points, and a call that gives several values (channels) reads where each of them does.
"""

from __future__ import annotations

import fnmatch

Line = tuple[str, str, tuple[tuple[str, str], ...]]


def values(args: dict, key: str) -> list[str] | None:
    """The values a call gives an argument (a list gives several), or None when it gives none."""
    value = args.get(key)
    if value is None or value == "" or value == []:
        return None
    return [str(item) for item in (value if isinstance(value, list) else [value])]


def matches(value: str, shape: str) -> bool:
    return fnmatch.fnmatchcase(value.casefold(), shape.casefold())


def areas_read(lines: list[Line], destination: str, args: dict) -> set[str]:
    """The areas a reading call to `destination` reads inside; none when no line names it."""
    named = [(area, conditions) for pattern, area, conditions in lines if matches(destination, pattern)]
    found: set[str] = set()
    for area, conditions in named:
        given = [(values(args, key), shape) for key, shape in conditions]
        if conditions and all(found_values is None or any(matches(v, shape) for v in found_values)
                              for found_values, shape in given):
            found.add(area)
    # The lines with no conditions take every value no line with conditions claims.
    keys = {key for _, conditions in named for key, _ in conditions}
    shapes = [(key, shape) for _, conditions in named for key, shape in conditions]
    claimed = bool(keys) and all(
        (given := values(args, key)) is not None
        and all(any(k == key and matches(v, shape) for k, shape in shapes) for v in given)
        for key in keys)
    if not claimed:
        found |= {area for area, conditions in named if not conditions}
    return found
