#!/usr/bin/env python3
"""Another agent session as a destination: the Claude Code side.

A message one session sends another is a send like any other: the receiver may write where the
sender may not. Where the receiver sits is not declared anywhere; it is what the entry guard
already keeps: the areas that session has read inside (its marks, `area-guard.py`). A message
is judged against them by `scanners/send-scan.py` (`--session-areas`):

- into a session that has read inside the areas the text comes from (or inside an area within
  them): passes, the receiver learns nothing it could not read;
- into a session that has read less: the text of the areas it has not read is refused, as for a
  push. A message in words of the sender's own passes.

So the same rule covers every pair of sessions, in both directions, with no line to write.

Claude Code keeps one file per running session under each config directory
(`~/.claude*/sessions/<pid>.json`: its id, its name, its process). `SendMessage` names its
receiver by that name; a client that relays messages between sessions (it types them into the
receiver's terminal, or hands them over some other way) names it by the session's id.

    peers.py --to SESSION --text FILE     judge FILE as a message to SESSION (an id or a name)
                                          exit 0 passes, 1 refuses (one line why), 2 cannot judge

A relaying client runs this before it delivers, so every way into it is judged at one place.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

STATE = Path(os.environ.get("AREA_GUARD_STATE", Path.home() / ".cache/area-guard"))
SEND_SCAN = Path(__file__).resolve().parents[2] / "scanners/send-scan.py"
# ` [3fa9c1]` after a name tells two sessions of one name apart; the files do not hold it.
REF = re.compile(r"\s*\[[0-9A-Za-z]+\]\s*$")
SESSION_ID = re.compile(r"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")


def config_dirs() -> list[Path]:
    """Every Claude Code config directory on this machine: one per account the operator runs."""
    found = {Path(p) for p in glob.glob(str(Path.home() / ".claude*")) if Path(p, "sessions").is_dir()}
    if named := os.environ.get("CLAUDE_CONFIG_DIR"):
        found.add(Path(named))
    return sorted(found)


def alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (OSError, TypeError, ValueError):
        return False
    return True


def running() -> list[dict]:
    """The sessions running on this machine, as Claude Code records them."""
    out = []
    for folder in config_dirs():
        for path in sorted((folder / "sessions").glob("*.json")):
            try:
                row = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(row, dict) and row.get("sessionId") and alive(row.get("pid")):
                out.append(row)
    return out


def marks(session: str) -> list[str]:
    """The areas a session has read inside: what the entry guard keeps for it."""
    try:
        data = json.loads((STATE / f"{session}.json").read_text())
    except (OSError, ValueError):
        return []
    return sorted(data if isinstance(data, list) else data.get("areas") or [])


def receivers(to: str) -> list[str]:
    """The ids of the sessions `to` names: an id names itself (running or not: its marks outlive
    it), a name every running session that carries it. None when no session here has the name."""
    to = REF.sub("", to.strip())
    if SESSION_ID.match(to):
        return [to]
    return sorted({row["sessionId"] for row in running() if row.get("name") == to})


def subagent(to: str, transcript: str | None) -> bool:
    """Whether `to` is one of this session's own subagents (by its agent id): a message to it
    stays inside the session."""
    if not transcript or not re.fullmatch(r"[0-9A-Za-z_-]+", to):
        return False
    return (Path(transcript).with_suffix("") / "subagents" / f"agent-{to}.jsonl").is_file()


def judge(to: str, payload: Path) -> tuple[int, str]:
    """(exit status, the line why) for a message to `to`. A name no session here carries is a
    session elsewhere (another machine, the cloud) as far as this machine can tell: it is judged
    as one that has read nothing. Several sessions of one name must each take the message."""
    name = f"session:{REF.sub('', to.strip())}"
    found = receivers(to)
    for areas in [marks(s) for s in found] or [[]]:
        try:
            r = subprocess.run(["python3", str(SEND_SCAN), "--dest", name, "--text", str(payload),
                                "--session-areas", ",".join(areas)],
                               capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return 2, (f"not sent to {name}: the send scan did not finish within 180s -- refused because "
                       f"it could not be judged in time, not because of what it found")
        except OSError:
            return 2, f"not sent to {name}: the send scan could not run"
        if r.returncode != 0:
            why = (r.stderr.strip().splitlines() or ["the send scan refused it"])[-1].removeprefix("send-scan: ")
            if not found:
                why += (". No session running on this machine has that name, so it is taken to be one "
                        "elsewhere; this session's own subagent is named by its agent id")
            return (1 if r.returncode == 1 else 2), why
    return 0, ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--to", required=True, help="the receiving session: its id, or its name")
    parser.add_argument("--text", required=True, type=Path, help="a file holding the message")
    args = parser.parse_args()
    status, why = judge(args.to, args.text)
    if why:
        print(f"peers: {why}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
