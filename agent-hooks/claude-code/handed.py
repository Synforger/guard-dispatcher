"""Files the agent left for the operator to hand to people, judged after the call that left them.

Called by Claude Code after each tool call (PostToolUse, and PostToolUseFailure for a call that
ended in an error). A file tool's write into such a file is judged before it is made
(outgoing.py); every other way of writing one -- a redirection, a copy, a program that writes its
own output -- is only seen once the call has run. So after each call, every file a `file:` line of
destinations.txt names (see send-scan.py) that changed during the call is judged as a send there,
and the agent is told which ones carry what may not reach people. The file stays where it is: the
guard only observes, and the agent rewrites or removes it.

During the call means since the call began (its duration, given by Claude Code, back from now),
or since this session's last call ended if that is earlier: a command left running in the
background writes after its own call has ended. Each change of a file is judged once, by the
first session to see it (`<marks folder>/handed/`), so another session's file is not reported
twice.

This file is the entry point and does its own reading of the folders and of what it judged; where
a file sits and what it may carry are decided by send-scan.py, and a file's text is taken out by
outgoing.py.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import ModuleType

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
import guard_places  # noqa: E402

SEND_SCAN = Path(__file__).resolve().parents[2] / "scanners/destinations/send-scan.py"
OUTGOING = Path(__file__).with_name("outgoing.py")
STATE = guard_places.marks_folder()
OFF = guard_places.setting("agent-off")
# A file's modification time is kept to the second on some file systems, and the hook starts a
# little after the call ends: the call is taken to have begun this much earlier.
SLACK_S = 2.0
# A call whose duration Claude Code does not give is taken to have run this long.
UNTIMED_CALL_S = 600.0
GLOB = re.compile(r"[*?\[]")
SEND_SCAN_TIMEOUT_S = 180


def load(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def roots(patterns: list[str]) -> list[Path]:
    """The folders the patterns reach into: each pattern's path up to its first wildcard."""
    found = set()
    for pattern in patterns:
        path = os.path.expanduser(pattern[len("file:"):])
        fixed = GLOB.split(path, 1)[0]
        # `~/handout/*` reaches into ~/handout, `~/handout/report-*` too, and a pattern with no
        # wildcard names one file, in its folder
        folder = Path(fixed if fixed.endswith("/") else os.path.dirname(fixed) or "/")
        if folder.is_dir():
            found.add(Path(os.path.realpath(folder)))
    return sorted(found)


def changed_files(folders: list[Path], since: float) -> list[tuple[Path, int]]:
    """(file, modification time in ns) of every file under the folders changed since `since`
    (hidden folders and files are passed over)."""
    found = []
    for folder in folders:
        for here, dirs, files in os.walk(folder):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for name in files:
                if name.startswith("."):
                    continue
                path = Path(here) / name
                try:
                    stat = path.stat()
                except OSError:
                    continue
                if stat.st_mtime >= since:
                    found.append((path, stat.st_mtime_ns))
    return found


def record_of(path: Path) -> Path:
    return STATE / "handed" / hashlib.sha256(str(path).encode()).hexdigest()[:24]


def judged_before(path: Path, mtime_ns: int) -> bool:
    """Whether this change of the file was judged already."""
    try:
        return record_of(path).read_text().strip() == str(mtime_ns)
    except OSError:
        return False


def remember(path: Path, mtime_ns: int) -> None:
    """Keep that this change of the file was judged."""
    record = record_of(path)
    try:
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(f"{mtime_ns}\n")
    except OSError:
        pass


def call_began(event: dict, session: str) -> float:
    """When this call began, or this session's last call ended if that is earlier; the session's
    last call is then taken to end now."""
    now = time.time()
    duration_ms = event.get("duration_ms")
    began = now - (duration_ms / 1000 if isinstance(duration_ms, (int, float)) else UNTIMED_CALL_S) - SLACK_S
    stamp = STATE / f"{session}.handed"
    try:
        began = min(began, float(stamp.read_text()) - SLACK_S)
    except (OSError, ValueError):
        pass
    try:
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(f"{now}\n")
    except OSError:
        pass
    return began


def refusal(name: str, path: Path, outgoing: ModuleType) -> str | None:
    """Why the file may not be handed on, or None. A file that is not text (an image, an archive)
    carries no words to judge and passes."""
    text, why = outgoing.file_text(path, SEND_SCAN)
    if text is None:
        return None if why == "not a text file" else f"{name} cannot be scanned ({why})"
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8",
                                     dir=os.environ.get("TMPDIR") or None) as fh:
        fh.write(text)
    try:
        r = subprocess.run(["python3", str(SEND_SCAN), "--dest", name, "--text", fh.name],
                           capture_output=True, text=True, timeout=SEND_SCAN_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return f"{name} could not be judged within {SEND_SCAN_TIMEOUT_S}s"
    finally:
        os.unlink(fh.name)
    if r.returncode == 0:
        return None
    return (r.stderr.strip().splitlines() or ["the send scan refused it"])[-1].removeprefix("send-scan: ")


def main() -> int:
    event = json.load(sys.stdin)
    if OFF.exists():
        return 0
    judged = load(SEND_SCAN, "send_scan")
    if not (patterns := judged.file_patterns()):
        return 0
    since = call_began(event, event.get("session_id") or "unknown")
    outgoing = None
    found = []
    for path, mtime_ns in changed_files(roots(patterns), since):
        name = judged.file_name(path)
        if not judged.file_matches(name, patterns) or judged_before(path, mtime_ns):
            continue
        outgoing = outgoing or load(OUTGOING, "outgoing")
        if why := refusal(name, path, outgoing):
            found.append(why)
        remember(path, mtime_ns)
    if found:
        print(json.dumps({"decision": "block", "reason": (
            "handed: a file left for the operator to hand to people carries what may not reach them. "
            "It stays where it is until it is rewritten or removed:\n" + "\n".join(f"  {why}" for why in found))},
            ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
