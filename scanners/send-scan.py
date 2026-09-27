#!/usr/bin/env python3
"""Judge a payload sent to a named destination the way a push is judged.

A service or a host has no folder to tell which area it sits in, so where each destination sits
is declared per machine in `$GUARD_CONFIG_DIR/destinations.txt`, one line per destination, the
first match winning:

    <pattern>   <area> | outside | block

The pattern is a glob over the destination's name: a tool name (`mcp__*drive*`, `Artifact`) or
`host:<host name>` for a network send (`host:*.example.com`). `block` refuses every send to it,
whatever it carries. A destination no line names is outside every area: a new service carries
nothing private until it is declared. A line naming an unknown area stops every send until it is
fixed.

The payload is compared by the private-document scan (`corpus-scan.py --dest-area`) with the
areas the destination sits outside of; a destination outside every area also gets the word-list
scan (`anon-scan.sh`), as a public repository does.

Usage:
    send-scan.py --dest NAME --text FILE   exit 0 passes, 1 refuses (one line why), 2 cannot judge
    send-scan.py --where NAME              print where NAME sits: an area, outside or block
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
OUTSIDE = "outside"
BLOCK = "block"


class Broken(Exception):
    """destinations.txt (or areas.txt) cannot be read as written."""


def area_names() -> set[str]:
    spec = importlib.util.spec_from_file_location("corpus_scan", CORPUS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    areas = CONFIG / "areas.txt"
    try:
        return set(module.load_areas(areas)) - {"_exempt"} if areas.is_file() else set()
    except ValueError as error:
        raise Broken(str(error)) from error


def rules() -> list[tuple[str, str]]:
    if not DESTINATIONS.is_file():
        return []
    known = area_names()
    out = []
    for n, line in enumerate(DESTINATIONS.read_text(encoding="utf-8").splitlines(), start=1):
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        if len(words) != 2 or (words[1] not in (OUTSIDE, BLOCK) and words[1] not in known):
            raise Broken(f"{DESTINATIONS}:{n} is not `<pattern> <area|outside|block>` with a known area")
        out.append((words[0], words[1]))
    return out


def where(name: str) -> str:
    for pattern, target in rules():
        if fnmatch.fnmatchcase(name.lower(), pattern.lower()):
            return target
    return OUTSIDE


def judge(name: str, payload: Path) -> tuple[int, str]:
    """(exit status, the line why) for a payload bound for `name`."""
    try:
        destination = where(name)
    except Broken as broken:
        return 2, f"{broken}; nothing is sent until it is fixed"
    if destination == BLOCK:
        return 1, f"{name} is blocked for sending ({DESTINATIONS}); reading through it still works"
    place = "outside every area" if destination == OUTSIDE else f"in {destination}"
    env = {**os.environ, "GUARD_CONFIG_DIR": str(CONFIG)}
    try:
        if destination == OUTSIDE and ANON.is_file():
            r = subprocess.run(["bash", str(ANON)], capture_output=True, text=True, timeout=60,
                               env={**env, "ANON_SCAN_PATHS": str(payload)})
            if r.returncode != 0:
                return 1, f"not sent to {name} ({place}): it carries a flagged identifier (word list)"
        r = subprocess.run(["python3", str(CORPUS), "--text", str(payload), "--dest-area",
                            "OUTSIDE" if destination == OUTSIDE else destination],
                           capture_output=True, text=True, timeout=120, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 2, f"not sent to {name}: the scans could not run ({error})"
    if r.returncode == 1:
        return 1, (f"not sent to {name} ({place}): it carries text from a private area the destination "
                   f"is outside of. Replace the text, or declare where it sits in {DESTINATIONS}")
    if r.returncode != 0:
        return 2, f"not sent to {name}: the private-document scan could not judge it"
    return 0, ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dest", help="the destination's name (a tool name, or host:<name>)")
    parser.add_argument("--text", type=Path, help="a file holding the payload")
    parser.add_argument("--where", metavar="NAME", help="print where NAME sits")
    args = parser.parse_args()
    if args.where:
        try:
            print(where(args.where))
        except Broken as broken:
            print(f"send-scan: {broken}", file=sys.stderr)
            return 2
        return 0
    if not (args.dest and args.text):
        parser.error("give --dest and --text, or --where")
    status, why = judge(args.dest, args.text)
    if why:
        print(f"send-scan: {why}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
