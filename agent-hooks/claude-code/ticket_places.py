"""Where a client keeps the tickets a request travels on between sessions: the one rule for it.

A ticket is a file in a folder named `tickets`, written by the client's backend alone. The rule that
says which folder holds a ticket lives here, so the relay's answer (`peers.py --place-for`,
`--places`) and the entry guard's two lines about it (`area-guard.py`: no direct write into a
place, no listing of every place by an agent) cannot differ.

- no area read: `<platform root>/state/claude-pwa-client/tickets`, a place inside no area;
- areas read that lie one inside the next (a client in its company): the innermost area's
  `<root>/tickets`. When the area has several roots, or that folder is inside a git work tree
  (what a commit or a push would carry out), the area's own settings name the folder in
  `areas/<area>/tickets.txt`: one line, `~` allowed, `#` starts a comment. The folder must lie
  in the area alone and outside every git work tree;
- areas read that do not lie one inside the next (two clients of one company): the place of the
  innermost area around them all (the company). What is written there is judged for a reader of that
  area, so the text of one client is not let into it. When no area lies around them all, no single
  place holds them.

A place has boundaries: the area it lies in most closely and the areas around that one. A place
in no area has none. What may be written into a place is judged as a message to a session that
has read inside exactly those boundaries.

The areas come in as `area_roles.Areas` (name and root); the rule reads only `tickets.txt` and
looks for `.git` above a folder. The two reads of a Bash command at the bottom serve the entry guard.
"""

from __future__ import annotations

import itertools
import os
from pathlib import Path

import area_roles
import guard_places
from path_forms import resolved
from shell_commands import simple_commands

OUTSIDE_FOLDER = "state/claude-pwa-client/tickets"
FOLDER_NAME = "tickets"
DECLARATION = "tickets.txt"
PEERS_PROGRAM = "peers.py"
LIST_PLACES_FLAG = "--places"
SESSION_FLAG = "--session"
#: The options of peers.py that name a session whose reads decide what the program prints (a tickets
#: folder, a role), each with the options one of which must stand with it for that (empty: always).
#: A folder and a role carry the names of the areas the session has read inside.
PRINTS_FOR_SESSION = {"--place-for": (), "--typed-in": ("--place-for",), SESSION_FLAG: (LIST_PLACES_FLAG, "--roles")}
#: Every long option of peers.py, so a shortened one is read as the program's parser reads it.
PEERS_OPTIONS = ("--to", "--text", "--covers", "--typed-in", "--roles", "--folder", "--session", "--place-for",
                 "--to-place", "--covers-place", "--places")

#: The exit status the relay answers with: no single place holds the areas read / cannot be judged.
NO_SINGLE_PLACE = 1
CANNOT_JUDGE = 2


class PlaceError(Exception):
    """No place can be named: `status` is the relay's exit status, `why` the one line to print."""

    def __init__(self, status: int, why: str) -> None:
        super().__init__(why)
        self.status = status
        self.why = why


def area_names(areas: area_roles.Areas) -> set[str]:
    """The names of the areas that hold documents: not the `_exempt` and `_outside` markers."""
    return {name for name, _ in areas if not name.startswith("_")}


def outside_place() -> Path:
    """The place of a ticket that has read inside no area."""
    root = guard_places.platform_root()
    if root is None:
        raise PlaceError(CANNOT_JUDGE, "no platform root is set, so where a ticket sits outside the areas "
                                       f"cannot be told ({guard_places.ROOT_VARIABLE})")
    return resolved(root / OUTSIDE_FOLDER)


def in_work_tree(path: Path) -> bool:
    """Whether a folder (that may not exist yet) lies in a git work tree: a `.git` in it or above it."""
    return any(Path(folder, ".git").exists() for folder in (path, *path.parents))


def declared_folder(area: str) -> str | None:
    """The line of the area's `tickets.txt`, as written, or None when the file or its line is absent."""
    try:
        lines = (guard_places.setting("areas") / area / DECLARATION).read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    return next((line for line in (raw.split("#", 1)[0].strip() for raw in lines) if line), None)


def boundaries(place: Path, areas: area_roles.Areas) -> set[str]:
    """The areas a place lies in most closely, and the areas around them (a client's place: the
    client and its company). A place in no area has none."""
    held = area_roles.innermost(place, areas)
    return held | {name for name in area_names(areas) if any(area_roles.outer(name, inner, areas) for inner in held)}


def _fits(path: Path, area: str, areas: area_roles.Areas) -> bool:
    """A folder that lies in `area` and in no area inside it, and in no git work tree."""
    return area_roles.innermost(path, areas) == {area} and not in_work_tree(path)


def _lies_inside(area: str, other: str, areas: area_roles.Areas) -> bool:
    """`area` lies strictly inside `other`: a root of `other` holds one of its roots, and not the other way round."""
    return area_roles.outer(other, area, areas) and not area_roles.outer(area, other, areas)


def _innermost_of(marks: set[str], areas: area_roles.Areas) -> str:
    """The one area of `marks` that lies inside all the others; when they are not in a line, the innermost
    area around them all (_innermost_around); PlaceError when there is none."""
    for first, second in itertools.combinations(sorted(marks), 2):
        if not (_lies_inside(first, second, areas) or _lies_inside(second, first, areas)):
            if (around := _innermost_around(marks, areas)) is not None:
                return around
            raise PlaceError(NO_SINGLE_PLACE, f"the areas read ({first}, {second}) do not fit in one place: "
                                              f"neither lies inside the other, and no area lies around them all")
    return next(name for name in sorted(marks) if all(name == other or _lies_inside(name, other, areas) for other in marks))


def _innermost_around(marks: set[str], areas: area_roles.Areas) -> str | None:
    """The area that every area of `marks` lies inside (or is) and that lies inside every other such area,
    or None when no area lies around them all."""
    around = [name for name in sorted(area_names(areas))
              if all(name == mark or _lies_inside(mark, name, areas) for mark in marks)]
    return next((name for name in around if all(name == other or _lies_inside(name, other, areas) for other in around)),
                None)


def _declared_place(area: str, areas: area_roles.Areas, why_needed: str) -> Path:
    """The folder `areas/<area>/tickets.txt` names, when it is one the rule accepts."""
    file = guard_places.setting("areas") / area / DECLARATION
    written = declared_folder(area)
    if written is None:
        raise PlaceError(CANNOT_JUDGE, f"{area} has {why_needed}: name a folder of {area} outside any git work "
                                       f"tree in {file} (one line)")
    folder = Path(os.path.expanduser(written))
    if not folder.is_absolute() or not _fits(resolved(folder), area, areas):
        raise PlaceError(CANNOT_JUDGE, f"{file} names {written}, which is not a folder in {area} alone outside "
                                       f"any git work tree")
    return resolved(folder)


def place_for(marks: set[str], areas: area_roles.Areas) -> Path:
    """The place of a ticket opened by a session that has read inside `marks`. Raises PlaceError."""
    marks = {name for name in marks if not name.startswith("_")}
    if not marks:
        return outside_place()
    if stale := sorted(marks - area_names(areas)):
        raise PlaceError(CANNOT_JUDGE, f"{', '.join(stale)} is read inside, but areas.txt no longer names it, so "
                                       f"where the ticket sits cannot be told")
    area = _innermost_of(marks, areas)
    roots = sorted({root for name, root in areas if name == area})
    if len(roots) == 1 and _fits(resolved(roots[0] / FOLDER_NAME), area, areas):
        return resolved(roots[0] / FOLDER_NAME)
    why_needed = ("several roots, or a `tickets` folder inside a git work tree" if len(roots) != 1
                  else f"a `tickets` folder that is not fit for it ({roots[0] / FOLDER_NAME})")
    return _declared_place(area, areas, why_needed)


def all_places(areas: area_roles.Areas) -> list[Path]:
    """Every place the rule gives: the one outside the areas, and the one of each area it can name."""
    places: list[Path] = []
    for marks in [set(), *({name} for name in sorted(area_names(areas)))]:
        try:
            place = place_for(marks, areas)
        except PlaceError:
            continue
        if place not in places:
            places.append(place)
    return places


def holds(place: Path, path: Path) -> bool:
    """Whether `path` is the place or in it, under any spelling: through a link, or in another case
    on a file system that folds it."""
    folded = str(place).casefold()
    return any(spelled == folded or spelled.startswith(folded + os.sep)
               for spelled in (str(path).casefold(), str(resolved(path)).casefold()))


def names_another_session(command: str, own: str) -> str | None:
    """The option of a `peers.py` run in a Bash command that names a session other than `own` where the
    program prints what that session's reads decide (`--place-for <id>`, `--places --session <id>`):
    the folder or role it prints carries the names of the areas that session has read inside, which the
    caller may not have. An option may be shortened as the program's parser allows, and its value may
    follow `=` or stand as the next word."""
    try:
        commands = simple_commands(command)
    except ValueError:      # the shell refuses to run a line it cannot read
        return None
    for run in commands:
        words = [str(word) for word in run.words]
        if not any(os.path.basename(word) == PEERS_PROGRAM for word in words):
            continue
        given: list[tuple[str, str | None]] = []
        for at, word in enumerate(words):
            if not word.startswith("--"):
                continue
            spelled, equals, value = word.partition("=")
            for option in (o for o in PEERS_OPTIONS if len(spelled) >= 3 and o.startswith(spelled)):
                given.append((option, value if equals else (words[at + 1] if at + 1 < len(words) else None)))
        present = {option for option, _ in given}
        for option, value in given:
            if option in PRINTS_FOR_SESSION and value != own and (
                    not PRINTS_FOR_SESSION[option] or present & set(PRINTS_FOR_SESSION[option])):
                return option
    return None


def lists_every_place(command: str) -> bool:
    """Whether a Bash command runs `peers.py --places` with no `--session`: it would print the folder
    of every area's tickets, and a folder is named after the area it sits in. An option may be
    shortened as the program's parser allows (`--sess`)."""
    try:
        commands = simple_commands(command)
    except ValueError:      # the shell refuses to run a line it cannot read
        return False
    for run in commands:
        words = [str(word) for word in run.words]
        if not any(os.path.basename(word) == PEERS_PROGRAM for word in words):
            continue
        options = [word.split("=", 1)[0] for word in words if word.startswith("--")]
        if LIST_PLACES_FLAG in options and not any(len(o) >= 3 and SESSION_FLAG.startswith(o) for o in options):
            return True
    return False
