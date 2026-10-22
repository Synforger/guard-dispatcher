"""The commands of `area-guard.py` that answer for children: `child add`, `child check`, `marks`.

The client runs `child check` before it opens a child's tab and `child add` once the tab exists;
an operator runs `marks` to see why a session is held. Called from `area-guard.py` main, which
supplies the judgements that need its areas and git (`Guard`).

    area-guard.py child check --parent TAB [--writes FILE] --text FILE
        judge the task text a parent hands over; prints the kind (`area` or `tool`); exit 0 passes
    area-guard.py child add --child TAB --parent TAB [--writes FILE]
        register the child; prints the kind; exit 0 registered, 1 refused
    area-guard.py marks SESSION
        the areas a session is held to, one per line

FILE lists the places the child may write, one folder per line. A refusal is one line on stderr.
On a machine with no areas, or with the entry guard off, both `child` commands pass and register
nothing.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from children import registry, rules

COMMANDS = {"child", "marks"}


@dataclass(frozen=True)
class Guard:
    """What the commands ask of the entry guard."""
    is_off: Callable[[], bool]
    has_areas: Callable[[], bool]
    own_marks: Callable[[str], set[str]]
    may_write: Callable[[Path, set[str]], bool]
    publishes: Callable[[Path], bool]
    scan: Callable[[Path, set[str]], tuple[int, str]]
    real: Callable[[str], Path]


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="area-guard.py")
    top = parser.add_subparsers(dest="command", required=True)
    child = top.add_parser("child").add_subparsers(dest="action", required=True)
    add = child.add_parser("add")
    add.add_argument("--child", required=True)
    add.add_argument("--parent", required=True)
    add.add_argument("--writes", type=Path)
    check = child.add_parser("check")
    check.add_argument("--parent", required=True)
    check.add_argument("--writes", type=Path)
    check.add_argument("--text", type=Path, required=True)
    top.add_parser("marks").add_argument("session")
    return parser


def _places(file: Path | None, guard: Guard) -> list[Path]:
    if file is None:
        return []
    lines = (line.strip() for line in file.read_text(encoding="utf-8").splitlines())
    return [guard.real(line) for line in lines if line and not line.startswith("#")]


def _refuse(why: str) -> int:
    print(f"area-guard: {why}", file=sys.stderr)
    return 1


def _parent_marks(parent: str, guard: Guard) -> set[str] | None:
    """The areas the parent's latest session is held to, or None when the guard has not seen the tab."""
    session = registry.session_of(parent)
    if session is None:
        return None
    return registry.held_marks(registry.registration_of(parent), guard.own_marks(session))


def _judge(parent: str, places: list[Path], guard: Guard) -> tuple[str, set[str]] | str:
    """(kind, areas the child starts with), or the reason the parent cannot hand over this child."""
    held = _parent_marks(parent, guard)
    if held is None:
        return f"the guard has not seen tab {parent}: a child can be handed over only by a tab that has run here"
    kind = rules.kind_of(places, guard.publishes)
    if kind == registry.TOOL_KIND:
        return kind, set()
    if held:
        for place in places:
            if not guard.may_write(place, held):
                return f"{place} is a place tab {parent} may not write itself, so it cannot be declared for its child"
    return kind, held


def _add(args: argparse.Namespace, guard: Guard) -> int:
    for tab in (args.child, args.parent):
        if not registry.is_tab_id(tab):
            return _refuse(f"{tab!r} is no tab id")
    if guard.is_off() or not guard.has_areas():
        print(registry.AREA_KIND)
        return 0
    places = _places(args.writes, guard)
    judged = _judge(args.parent, places, guard)
    if isinstance(judged, str):
        return _refuse(judged)
    kind, inherited = judged
    registry.add(args.child, args.parent, kind, [str(place) for place in places], sorted(inherited))
    print(kind)
    return 0


def _check(args: argparse.Namespace, guard: Guard) -> int:
    if not registry.is_tab_id(args.parent):
        return _refuse(f"{args.parent!r} is no tab id")
    if guard.is_off() or not guard.has_areas():
        print(registry.AREA_KIND)
        return 0
    judged = _judge(args.parent, _places(args.writes, guard), guard)
    if isinstance(judged, str):
        return _refuse(judged)
    kind, inherited = judged
    status, why = guard.scan(args.text, inherited)
    if status:
        return _refuse(why.removeprefix("peers: "))
    print(kind)
    return 0


def run(argv: list[str], guard: Guard) -> int:
    args = _parser().parse_args(argv)
    if args.command == "marks":
        print("\n".join(sorted(registry.marks_of(args.session, guard.own_marks(args.session)))))
        return 0
    return _add(args, guard) if args.action == "add" else _check(args, guard)
