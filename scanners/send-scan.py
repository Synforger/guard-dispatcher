#!/usr/bin/env python3
"""Judge a payload sent to a named destination the way a push is judged.

A service or a host has no folder to tell which area it sits in, so where each destination sits
is declared per machine in `$GUARD_CONFIG_DIR/destinations.txt`, one line per destination, the
first match winning:

    <pattern>   <area> | outside | block   [order]

The pattern is a glob over the destination's name: a tool name (`mcp__*drive*`, `Artifact`) or
`host:<host name>` for a network send (`host:*.example.com`). `block` refuses every send to it,
whatever it carries. A line naming an unknown area stops every send until it is fixed.

A third word `order` holds the destination's sends until the operator orders each one: the entry
point that sees the call decides whether it was ordered (agent-hooks' order.py), and the payload
is then judged here as for any destination. Reading through it needs no order. `block order`, an
`order` on a `repo:` line (a push is not a call the operator can be shown) and any other third
word stop every send until the line is fixed.

A destination no line names is undeclared and passes unscanned: the guard stops what it knows
leaves an area, and a server or a service at work (a build machine, an internal API) is not
stopped for being unlisted. What publishes to the internet or to a personal account is outside
every area without a line (DEFAULTS: the Artifact tools, WebFetch, WebSearch and claude.ai's
connectors); a line in the file overrides it.

The pattern `browser:<host>` names the page a browser tool types into (see agent-hooks'
outgoing.py): `browser:*.example.com company`.

The payload is compared by the private-document scan (`corpus-scan.py --dest-area`) with the
areas the destination sits outside of; a destination outside every area also gets the word-list
scan (`anon-scan.sh`), as a public repository does, and one inside an area gets that area's own
word list when the machine keeps one next to the master (`company.txt` beside `master.txt`).

Usage:
    send-scan.py --dest NAME --text FILE [--reading]   exit 0 passes, 1 refuses (one line why), 2 cannot judge
    send-scan.py --where NAME              print where NAME sits: an area, outside, block or undeclared
                                           (followed by ` order` when its sends need one)

Another session of the operator's agents is a destination too, and no line declares it: it sits in
the areas it has read inside, which the entry point that knows the sessions passes
(`--session-areas`, see agent-hooks' peers.py). Its payload gets the private-document scan and no
word list, since only the operator's agents read it:

    send-scan.py --dest NAME --text FILE --session-areas AREAS   AREAS joined by commas, empty for none
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
DESTINATIONS = CONFIG / "destinations.txt"
CORPUS = HERE / "corpus-scan.py"
ANON = HERE / "anon-scan.sh"
# The operator's word lists: master.txt, and one per area that has its own readers (`company.txt`
# for the company, which works under real names but keeps the operator's handles out).
WORD_LISTS = Path(os.environ.get("ANON_TRUTH_PATH", Path.home() / ".config/anon-words/master.txt")).parent
OUTSIDE = "outside"
BLOCK = "block"
UNDECLARED = "undeclared"
ORDER = "order"
# Destinations outside every area with no line in destinations.txt: they publish to the internet
# (a search, a fetched URL) or to the operator's personal account on claude.ai.
DEFAULTS = [("Artifact*", OUTSIDE, False), ("WebFetch", OUTSIDE, False), ("WebSearch", OUTSIDE, False),
            ("mcp__claude_ai_*", OUTSIDE, False)]


# Names for what stays on this machine: a service on the loopback host (`local:<port><path>`) and
# a tmux session typed into (`tmux:<session>`). Nothing leaves the machine through them, so a
# catch-all line (`* outside`) does not reach them: only a line that names the kind does.
ON_THIS_MACHINE = ("local:", "tmux:")


class Broken(Exception):
    """destinations.txt (or areas.txt) cannot be read as written."""


def area_names() -> set[str]:
    spec = importlib.util.spec_from_file_location("corpus_scan", CORPUS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    areas = CONFIG / "areas.txt"
    try:
        return set(module.load_areas(areas)) - module.UNSCANNED if areas.is_file() else set()
    except ValueError as error:
        raise Broken(str(error)) from error


def rules() -> list[tuple[str, str, bool]]:
    """(pattern, where it sits, whether its sends need the operator's order), in the file's order."""
    if not DESTINATIONS.is_file():
        return []
    known = area_names()
    out = []
    for n, line in enumerate(DESTINATIONS.read_text(encoding="utf-8").splitlines(), start=1):
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        if len(words) not in (2, 3) or (words[1] not in (OUTSIDE, BLOCK) and words[1] not in known):
            raise Broken(f"{DESTINATIONS}:{n} is not `<pattern> <area|outside|block> [order]` with a known area")
        ordered = len(words) == 3
        if ordered and words[2] != ORDER:
            raise Broken(f"{DESTINATIONS}:{n} ends with `{words[2]}`: the only third word is `order`")
        if ordered and words[1] == BLOCK:
            raise Broken(f"{DESTINATIONS}:{n} is `block order`: a blocked destination takes no send to order")
        if ordered and words[0].lower().startswith("repo:"):
            raise Broken(f"{DESTINATIONS}:{n} puts `order` on a repository: a push is not held to an order")
        out.append((words[0], words[1], ordered))
    return out


def find(name: str) -> tuple[str, bool]:
    """(where name sits, whether its sends need the operator's order): the first line that matches."""
    kind = next((k for k in ON_THIS_MACHINE if name.lower().startswith(k)), None)
    for pattern, target, ordered in rules() + DEFAULTS:
        if kind and not pattern.lower().startswith(kind):
            continue
        if fnmatch.fnmatchcase(name.lower(), pattern.lower()):
            return target, ordered
    return UNDECLARED, False


def where(name: str) -> str:
    return find(name)[0]


def needs_order(name: str) -> bool:
    return find(name)[1]


def judge(name: str, payload: Path, reading: bool = False) -> tuple[int, str]:
    """(exit status, the line why) for a payload bound for `name`. A reading call to a destination
    blocked for sending is judged as outside every area: reading through it still works."""
    try:
        destination = where(name)
    except Broken as broken:
        return 2, f"{broken}; nothing is sent until it is fixed"
    if destination == UNDECLARED:
        return 0, ""
    if destination == BLOCK and reading:
        destination = OUTSIDE
    if destination == BLOCK:
        return 1, f"{name} is blocked for sending ({DESTINATIONS}); reading through it still works"
    place = "outside every area" if destination == OUTSIDE else f"in {destination}"
    env = {**os.environ, "GUARD_CONFIG_DIR": str(CONFIG)}
    # A destination outside every area gets the operator's word list; one inside an area gets that
    # area's own list when the machine has one (a service the company reads takes real names, not
    # the operator's handles), and none otherwise.
    area_words = WORD_LISTS / f"{destination}.txt" if destination != OUTSIDE else None
    if area_words is not None and area_words.is_file():
        env["ANON_WORDS_FILE"] = str(area_words)
    if (destination == OUTSIDE or env.get("ANON_WORDS_FILE") == str(area_words)) and ANON.is_file():
        try:
            r = subprocess.run(["bash", str(ANON)], capture_output=True, text=True, timeout=60,
                               env={**env, "ANON_SCAN_PATHS": str(payload)})
        except subprocess.TimeoutExpired:
            return 2, (f"not sent to {name}: the word-list scan did not finish within 60s -- refused "
                       f"because it could not be judged in time, not because of what it found")
        except OSError as error:
            return 2, f"not sent to {name}: the word-list scan could not run ({error})"
        if r.returncode != 0:
            return 1, f"not sent to {name} ({place}): it carries a flagged identifier (word list)"
    return documents(name, place, "OUTSIDE" if destination == OUTSIDE else destination, payload, env,
                     f"Replace the text, or declare where it sits in {DESTINATIONS}")


def documents(name: str, place: str, dest_area: str, payload: Path, env: dict, remedy: str) -> tuple[int, str]:
    """The private-document scan of a payload bound for a place in `dest_area` (corpus-scan's
    `--dest-area`: an area, several joined by commas, or OUTSIDE)."""
    try:
        r = subprocess.run(["python3", str(CORPUS), "--text", str(payload), "--dest-area", dest_area],
                           capture_output=True, text=True, timeout=120, env=env)
    except subprocess.TimeoutExpired:
        return 2, (f"not sent to {name}: the private-document scan did not finish within 120s -- "
                   f"refused because it could not be judged in time (often a full walk of the "
                   f"documents), not because of what it found")
    except OSError as error:
        return 2, f"not sent to {name}: the private-document scan could not run ({error})"
    if r.returncode == 1:
        return 1, (f"not sent to {name} ({place}): it carries text from a private area the destination "
                   f"is outside of. {remedy}")
    if r.returncode != 0:
        return 2, f"not sent to {name}: the private-document scan could not judge it"
    return 0, ""


def judge_session(name: str, payload: Path, read_inside: list[str]) -> tuple[int, str]:
    """(exit status, the line why) for a payload bound for another session of the operator's
    agents, which has read inside `read_inside` (none: it sits outside every area).

    The session sits where it has read: text of those areas, and of an area around them, tells
    it nothing new, and it can write only inside them. Text of any other area would be carried
    to wherever that session may write, so it is refused. No word list applies: only the
    operator's agents read the message, and what one of them sends on is judged where it leaves."""
    try:
        known = area_names()
    except Broken as broken:
        return 2, f"{broken}; nothing is sent until it is fixed"
    if stale := sorted(set(read_inside) - known):
        return 2, (f"not sent to {name}: it has read inside {', '.join(stale)}, which {CONFIG / 'areas.txt'} "
                   f"no longer names, so where it sits cannot be judged")
    place = f"a session that has read inside {', '.join(sorted(read_inside))}" if read_inside \
        else "a session that has read inside no area"
    return documents(name, place, ",".join(sorted(read_inside)) or "OUTSIDE", payload,
                     {**os.environ, "GUARD_CONFIG_DIR": str(CONFIG)},
                     "Replace the text with words of your own")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dest", help="the destination's name (a tool name, or host:<name>)")
    parser.add_argument("--text", type=Path, help="a file holding the payload")
    parser.add_argument("--where", metavar="NAME", help="print where NAME sits")
    parser.add_argument("--reading", action="store_true", help="the payload is a reading call's own strings")
    parser.add_argument("--session-areas", metavar="AREAS", help="the destination is another agent session that "
                        "has read inside these areas (joined by commas; empty for none)")
    args = parser.parse_args()
    if args.session_areas is not None:
        if not (args.dest and args.text):
            parser.error("give --dest and --text with --session-areas")
        status, why = judge_session(args.dest, args.text, [n for n in args.session_areas.split(",") if n])
        if why:
            print(f"send-scan: {why}", file=sys.stderr)
        return status
    if args.where:
        try:
            target, ordered = find(args.where)
            print(f"{target} {ORDER}" if ordered else target)
        except Broken as broken:
            print(f"send-scan: {broken}", file=sys.stderr)
            return 2
        return 0
    if not (args.dest and args.text):
        parser.error("give --dest and --text, or --where")
    status, why = judge(args.dest, args.text, args.reading)
    if why:
        print(f"send-scan: {why}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
