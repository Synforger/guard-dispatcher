"""Which areas a work folder reaches, and which named roles a session may see and ask.

The entry guard (`area-guard.py`) refuses a read outside what the session's work folder reaches and
names, in the refusal, the roles that could read it instead; the relay between sessions (`peers.py
--roles`) shows a session the roles it may address. A role is a line an area keeps in `roles.txt`
(`corpus-scan.py` `kept_roles`): the name the session working in a folder goes by among the sessions
that read inside that area. Nothing here touches a file: the callers read the settings.
"""

from __future__ import annotations

import fnmatch
from collections.abc import Callable, Iterable
from pathlib import Path

EXEMPT = "_exempt"
NO_AREA = "_outside"

Areas = list[tuple[str, Path]]
Role = tuple[str, Path, str]


def outer(name: str, inner: str, areas: Areas) -> bool:
    """A root of `name` holds a root of `inner` (the company around one of its clients)."""
    return any(n == name and m == inner and r != i and r in i.parents for n, r in areas for m, i in areas)


def innermost(place: Path, areas: Areas) -> set[str]:
    """The areas a place lies in most closely: those whose root holding it is the deepest (a client
    inside the company: the client), `_exempt` and `_outside` left out, and no area whose root an
    `_outside` folder holding the place cuts it off from. Only the roots that hold this place count,
    so two areas that each hold a root of the other elsewhere still leave the place its owner."""
    holding = [(n, r) for n, r in areas if place == r or r in place.parents]
    cut = max((len(r.parts) for n, r in holding if n == NO_AREA), default=0)
    depth: dict[str, int] = {}
    for name, root in holding:
        if name not in (EXEMPT, NO_AREA) and len(root.parts) > cut:
            depth[name] = max(depth.get(name, 0), len(root.parts))
    deepest = max(depth.values(), default=0)
    return {name for name, d in depth.items() if d == deepest}


def reach_from(home: Path, areas: Areas, named: Iterable[str]) -> set[str]:
    """The areas a session working in `home` may read inside: the areas holding the folder, the
    areas around them, and the names the folder's reads file gives (`named`). A name written as a
    glob (`client-*`) reaches every area it matches, so an area made later needs no line of its own."""
    names = {n for n, _ in areas if n not in (EXEMPT, NO_AREA)}
    held = {n for n, r in areas if n in names and (home == r or r in home.parents)}
    around = {n for n in names if any(outer(n, h, areas) for h in held)}
    words = set(named)
    globbed = {n for n in names if any(fnmatch.fnmatchcase(n, w) for w in words)}
    return held | around | words | globbed


def visible(roles: list[Role], seen: set[str], within: Callable[[str, str], bool],
            outward: Iterable[Role] = ()) -> list[Role]:
    """The roles a session that reads inside `seen` may see: those an area it reads inside, or an
    area around one of them, keeps, and the `outward` ones (marked to be shown outside their area)
    after them. `within(name, owner)` says an area lies within another."""
    shown = [role for role in roles if any(within(name, role[2]) for name in seen)]
    return shown + [role for role in outward if role not in shown]


def asked(roles: list[Role], wanted: set[str], reach_of: Callable[[Path], set[str]]) -> list[str]:
    """The names of the roles whose folder reaches every area in `wanted`, in the order kept."""
    names = []
    for name, folder, _ in roles:
        if wanted <= reach_of(folder) and name not in names:
            names.append(name)
    return names
