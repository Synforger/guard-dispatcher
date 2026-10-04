#!/usr/bin/env python3
"""Move past Claude Code conversations into the cage of the area they worked in.

Before cages, every conversation of an account lived in one config directory, whichever area
it touched, and the personal cage reads that directory. This moves each conversation that
worked inside an area into that area's cage directory (`<account dir>@<cage>`), where only
that cage (and the cages inside it) can read it; conversations that stayed outside every area
stay where they are.

A conversation worked inside an area when the agent entry guard marked it there
(`~/.cache/area-guard/<session>.json`) or when its record -- or a subagent's -- shows it there:
a working directory, or a path a tool call named (a file it read or wrote, a path in a command),
inside the area.
A path merely printed in a tool's output does not count -- names are visible from every cage,
content is what a cage keeps. Nor does a row written while the conversation ran in a cage (the
entry guard keeps when it did): the cage refused whatever it hid, and the guard marked only what
the session could read. When the areas touched nest (a client inside the company), the
conversation goes to the innermost; when they do not (two clients), it is listed and left.

What moves with a conversation: its record (and the folder of its subagents), its edit backups
(`file-history/`), its environment (`session-env/`), its lines of the prompt history
(`history.jsonl`) and the pastes only those lines refer to (`paste-cache/`). The account's state
file also gives up the entries of folders inside an area (their paths and example files) to
that area's cage. Running conversations are skipped. A rewritten file is replaced only after
its lines add up (kept + moved = before).

A conversation judged to stay is remembered with the size and time of its record, its subagents'
records and its mark (`~/.cache/guard-sort/`), and not read again until one of them changes, so a
launcher can sort before every session at no cost.

Usage:
    sort-sessions.py [--account-dir DIR ...]           print what would move (the default)
    sort-sessions.py [--account-dir DIR ...] --apply   move it
    add --quiet to print only when something moves or is left for a person to decide
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("cage_config", Path(__file__).with_name("cage-config.py"))
cage_config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cage_config)

MARKS = Path(os.environ.get("AREA_GUARD_STATE", Path.home() / ".cache/area-guard"))
CACHE = Path(os.environ.get("GUARD_SORT_CACHE", Path.home() / ".cache/guard-sort"))
DEFAULT = Path(os.path.realpath(Path.home() / ".claude"))
# Keys of a tool call's input that name a path, and those that hold a command line.
PATH_KEYS = ("file_path", "path", "notebook_path", "cwd")
COMMAND_KEYS = ("command",)
TOKEN = re.compile(r"""[^\s'"`;|&()<>]+""")
# Per-conversation folders and files of a config directory (besides the record).
SESSION_DIRS = ("file-history", "session-env")


def state_file(config_dir: Path) -> Path:
    return Path.home() / ".claude.json" if config_dir == DEFAULT else config_dir / ".claude.json"


def running(config_dir: Path) -> set[str]:
    """Conversations whose process is alive (`sessions/<pid>.json`)."""
    alive = set()
    for f in (config_dir / "sessions").glob("*.json"):
        try:
            d = json.loads(f.read_text())
            os.kill(int(d["pid"]), 0)
        except (OSError, ValueError, KeyError, TypeError):
            continue
        alive.add(d.get("sessionId"))
    return alive


class Areas:
    def __init__(self) -> None:
        areas = cage_config.load_areas()
        areas.pop(cage_config.EXEMPT, None)
        self.roots = areas

    def of(self, path: Path) -> str | None:
        """The innermost area holding `path`, or None."""
        holding = [(len(r.parts), n) for n, roots in self.roots.items() for r in roots
                   if cage_config.inside(path, [r])]
        return max(holding)[1] if holding else None

    def around(self, outer: str, inner: str) -> bool:
        """`outer` holds `inner` (every root of `inner` lies inside a root of `outer`)."""
        return all(cage_config.inside(r, self.roots[outer]) for r in self.roots[inner])

    def innermost(self, touched: set[str]) -> str | None:
        """The one area every touched area holds, or None when they do not nest."""
        for a in touched:
            if all(b == a or self.around(b, a) for b in touched):
                return a
        return None


def resolve(token: str, cwd: str | None) -> Path | None:
    token = token.strip()
    if not token or ("/" not in token and not token.startswith("~")) or "://" in token:
        return None
    path = os.path.expanduser(token)
    if not os.path.isabs(path):
        if not cwd:
            return None
        path = os.path.join(cwd, path)
    return Path(os.path.realpath(os.path.normpath(path)))


def when(stamp) -> datetime | None:
    try:
        t = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def caged(row: dict, runs: list[tuple[datetime, datetime]]) -> bool:
    """The row was written in a cage (a row with no time is taken to have been written outside)."""
    t = when(row.get("timestamp")) if row.get("timestamp") else None
    return t is not None and any(since <= t <= last for since, last in runs)


def touched_in(record: Path, areas: Areas, runs: list[tuple[datetime, datetime]] = ()) -> set[str]:
    found: set[str] = set()
    for line in record.open(encoding="utf-8", errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or caged(row, runs):
            continue
        cwd = row.get("cwd")
        if cwd and (a := areas.of(Path(os.path.realpath(cwd)))):
            found.add(a)
        content = (row.get("message") or {}).get("content") if isinstance(row.get("message"), dict) else None
        for item in content if isinstance(content, list) else []:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            args = item.get("input") if isinstance(item.get("input"), dict) else {}
            paths = [args[k] for k in PATH_KEYS if isinstance(args.get(k), str)]
            for k in COMMAND_KEYS:
                if isinstance(args.get(k), str):
                    paths += TOKEN.findall(args[k])
            for p in paths:
                if (path := resolve(p, args.get("cwd") or cwd)) and (a := areas.of(path)):
                    found.add(a)
    return found


def state_of(session: str) -> tuple[set[str], list[tuple[datetime, datetime]]]:
    """The entry guard's marks of a session and its runs in a cage (a bare list is marks only)."""
    try:
        data = json.loads((MARKS / f"{session}.json").read_text())
    except (OSError, ValueError):
        return set(), []
    if isinstance(data, list):
        return set(data), []
    runs = [(a, b) for a, b in ((when(r[0]), when(r[1])) for r in data.get("caged") or []
                                if isinstance(r, list) and len(r) == 2) if a and b]
    return set(data.get("areas") or []), runs


def cage_dir(account: Path, cage: str) -> Path:
    return cage_config.config_dir(cage, account)


def signature(record: Path) -> list:
    """What a judgement of the record depends on: the record, its subagents' records, its mark."""
    def stamp(p: Path) -> list:
        try:
            st = p.stat()
            return [st.st_size, st.st_mtime_ns]
        except OSError:
            return []
    subs = sorted(record.with_suffix("").glob("**/*.jsonl"))
    return [stamp(record), [stamp(s) for s in subs], stamp(MARKS / f"{record.stem}.json")]


def cache_file(account: Path) -> Path:
    return CACHE / (hashlib.sha256(str(account).encode()).hexdigest()[:16] + ".json")


def load_cache(account: Path) -> dict:
    try:
        return json.loads(cache_file(account).read_text())
    except (OSError, ValueError):
        return {}


def save_cache(account: Path, stays: dict) -> None:
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        cache_file(account).write_text(json.dumps(stays))
    except OSError:
        pass  # a cache that cannot be kept only costs a re-read next time


def plan(account: Path, areas: Areas) -> dict:
    alive = running(account)
    known = load_cache(account)
    stays: dict[str, list] = {}
    moves: dict[str, tuple[Path, str]] = {}
    conflicts: dict[str, set[str]] = {}
    skipped: list[str] = []
    stay = 0
    for record in sorted((account / "projects").glob("*/*.jsonl")):
        session = record.stem
        sig = signature(record)
        if known.get(str(record)) == sig:
            stays[str(record)] = sig
            stay += 1
            continue
        marks, runs = state_of(session)
        touched = marks | touched_in(record, areas, runs)
        # A subagent's tool calls are in its own record (`<session>/subagents/...`).
        for sub in sorted(record.with_suffix("").glob("**/*.jsonl")):
            touched |= touched_in(sub, areas, runs)
        touched &= set(areas.roots)
        if not touched:
            stays[str(record)] = sig
            stay += 1
            continue
        if session in alive:
            skipped.append(session)
            continue
        cage = areas.innermost(touched)
        if cage is None:
            conflicts[session] = touched
            continue
        moves[session] = (record, cage)
    state = {}
    try:
        state = json.loads(state_file(account).read_text())
    except (OSError, ValueError):
        pass
    folders = {}
    for folder in (state.get("projects") or {}):
        if (a := areas.of(Path(os.path.realpath(folder)))):
            folders[folder] = a
    save_cache(account, stays)
    return {"moves": moves, "conflicts": conflicts, "skipped": skipped, "stay": stay, "folders": folders}


def write_lines(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".sort-tmp")
    tmp.write_text("".join(lines), encoding="utf-8")
    os.replace(tmp, path)


def split_history(account: Path, moves: dict[str, tuple[Path, str]], apply: bool) -> Counter:
    """Move each moved conversation's lines of `history.jsonl`, and the pastes only they cite."""
    history = account / "history.jsonl"
    if not history.is_file():
        return Counter()
    before = history.read_text(encoding="utf-8").splitlines(keepends=True)
    kept, moved = [], defaultdict(list)
    for line in before:
        try:
            session = json.loads(line).get("sessionId")
        except (ValueError, AttributeError):
            session = None
        if session in moves:
            moved[moves[session][1]].append(line)
        else:
            kept.append(line)
    if len(kept) + sum(map(len, moved.values())) != len(before):
        raise SystemExit(f"sort-sessions: {history} does not add up; nothing rewritten")
    pastes = Counter()
    kept_text = "".join(kept)
    for cage, lines in moved.items():
        text = "".join(lines)
        for paste in (account / "paste-cache").glob("*"):
            if paste.stem in text and paste.stem not in kept_text:
                pastes[cage] += 1
                if apply:
                    dest = cage_dir(account, cage) / "paste-cache" / paste.name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(paste), dest)
        if apply:
            target = cage_dir(account, cage) / "history.jsonl"
            existing = target.read_text(encoding="utf-8").splitlines(keepends=True) if target.is_file() else []
            write_lines(target, existing + lines)
    if apply and moved:
        write_lines(history, kept)
    return Counter({cage: len(lines) for cage, lines in moved.items()}) + Counter(
        {f"{cage} (pastes)": n for cage, n in pastes.items()})


def move_folders(account: Path, folders: dict[str, str], apply: bool) -> None:
    """Hand the state file's entries of folders inside an area to that area's cage."""
    if not folders or not apply:
        return
    path = state_file(account)
    state = json.loads(path.read_text())
    by_cage = defaultdict(dict)
    for folder, cage in folders.items():
        by_cage[cage][folder] = state["projects"].pop(folder)
    for cage, entries in by_cage.items():
        target = state_file(cage_dir(account, cage))
        theirs = json.loads(target.read_text()) if target.is_file() else {}
        theirs.setdefault("projects", {}).update({k: v for k, v in entries.items()
                                                  if k not in theirs["projects"]})
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(theirs, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp = path.with_name(path.name + ".sort-tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def session_targets(account: Path, record: Path, cage: str) -> list[tuple[Path, Path]]:
    dest = cage_dir(account, cage)
    project = record.parent.name
    targets = [(record, dest / "projects" / project / record.name)]
    if (sub := record.with_suffix("")).is_dir():
        targets.append((sub, dest / "projects" / project / sub.name))
    for name in SESSION_DIRS:
        if (src := account / name / record.stem).exists():
            targets.append((src, dest / name / record.stem))
    return targets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--account-dir", action="append", default=[],
                        help="an account's Claude Code config directory (default ~/.claude; repeat)")
    parser.add_argument("--apply", action="store_true", help="move (the default only prints)")
    parser.add_argument("--quiet", action="store_true",
                        help="print only when something moves or is left for a person to decide")
    args = parser.parse_args()
    accounts = [cage_config.expand(a) for a in (args.account_dir or ["~/.claude"])]
    areas = Areas()
    if not areas.roots:
        if not args.quiet:
            print("sort-sessions: no areas on this machine; nothing to sort")
        return 0
    for account in accounts:
        if cage_config.CAGE_MARK in account.name:
            raise SystemExit(f"sort-sessions: {account} is a cage's directory, not an account's")
        p = plan(account, areas)
        if args.quiet and not (p["moves"] or p["conflicts"] or p["folders"]):
            continue
        per_cage = Counter(cage for _, cage in p["moves"].values())
        parts = [f"{p['stay']} stay", *(f"{n} to {c}" for c, n in sorted(per_cage.items()))]
        if p["skipped"]:
            parts.append(f"{len(p['skipped'])} running (skipped)")
        print(f"sort-sessions: {account}: " + ", ".join(parts))
        for session, touched in sorted(p["conflicts"].items()):
            print(f"  left in place (areas do not nest: {', '.join(sorted(touched))}): {session}")
        targets = [t for record, cage in p["moves"].values() for t in session_targets(account, record, cage)]
        if args.apply and (taken := [str(dst) for _, dst in targets if dst.exists()]):
            raise SystemExit("sort-sessions: already in place, nothing moved: " + ", ".join(taken))
        history = split_history(account, p["moves"], args.apply)
        if history:
            print("  history lines: " + ", ".join(f"{n} to {c}" for c, n in sorted(history.items())))
        folders = Counter(p["folders"].values())
        if folders:
            print("  state entries: " + ", ".join(f"{n} to {c}" for c, n in sorted(folders.items())))
        move_folders(account, p["folders"], args.apply)
        if args.apply:
            for src, dst in targets:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), dst)
    if not args.apply and not args.quiet:
        print("(nothing moved: add --apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
