"""The register of a session's children: which session a tab runs, and what each child was given.

The hook saves the session a tab runs on every call (`save_session`); the client registers a
child once it has opened the child's tab (`command.py`). The entry guard and `peers.py` read both:
the guard to hold a child to the places its parent declared and to the areas its parent had read,
`peers.py` to judge a message to the child by the same areas.

Both live in the guard's state folder, which an agent does not write:

    tabs/<tab>.json       {"session": <the latest session the tab ran>}
    children/<tab>.json   {"parent": <tab>, "kind": "area" | "tool",
                           "writes": [<folder>], "inherited": [<area>]}

A tab is the client's `PWA_SID`: it outlives the session, which is replaced when the tab rolls
over. A child keeps what its parent had read when it was registered, even after the parent's tab
starts a new session.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "_common"))
import guard_places  # noqa: E402

STATE = guard_places.marks_folder()
TABS = STATE / "tabs"
CHILDREN = STATE / "children"
TAB_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
AREA_KIND = "area"
TOOL_KIND = "tool"


def is_tab_id(value: str | None) -> bool:
    return bool(value) and TAB_ID.fullmatch(value) is not None


def _load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    scratch = path.with_name(f"{path.name}.{os.getpid()}")
    scratch.write_text(json.dumps(data), encoding="utf-8")
    os.replace(scratch, path)


def save_session(tab: str | None, session: str) -> None:
    """Remember that this tab runs this session now. Writes only when the session changed."""
    if not is_tab_id(tab):
        return
    path = TABS / f"{tab}.json"
    if _load(path).get("session") != session:
        _save(path, {"session": session})


def session_of(tab: str) -> str | None:
    """The session a tab ran last, or None when the guard has not seen the tab."""
    return _load(TABS / f"{tab}.json").get("session") if is_tab_id(tab) else None


def tab_of(session: str) -> str | None:
    """The tab whose latest session this is, or None."""
    if not TABS.is_dir():
        return None
    for path in sorted(TABS.glob("*.json")):
        if _load(path).get("session") == session:
            return path.stem
    return None


def registration_of(tab: str | None) -> dict | None:
    """What a child was given, or None when the tab is no registered child."""
    if not is_tab_id(tab):
        return None
    data = _load(CHILDREN / f"{tab}.json")
    if not (isinstance(data.get("parent"), str) and isinstance(data.get("writes"), list)
            and isinstance(data.get("inherited"), list)):
        return None
    return data


def add(child: str, parent: str, kind: str, writes: list[str], inherited: list[str]) -> None:
    _save(CHILDREN / f"{child}.json",
          {"parent": parent, "kind": kind, "writes": sorted(writes), "inherited": sorted(inherited)})


def held_marks(given: dict | None, own: set[str]) -> set[str]:
    """The areas a session is held to: what it read itself and, for a child, what its parent had
    read when it was registered."""
    return own | set(given["inherited"]) if given else set(own)


def marks_of(session: str, own: set[str]) -> set[str]:
    """`held_marks` for a session known only by its id."""
    tab = tab_of(session)
    return held_marks(registration_of(tab) if tab else None, own)
