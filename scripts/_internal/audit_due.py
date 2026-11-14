"""Whether the scheduled weekly audit is due: weekly-audit.sh --if-due calls it with the folder of the
audit's logs, and runs the audit only when it exits 0.

The audit is scheduled for Sunday 00:00 local time. A machine that was asleep, off or not logged in
at that moment never started it (launchd starts a calendar job only while the job is loaded, and
loads a user's jobs only after the login), so the audit is asked for every hour instead and runs
when no run that finished has started since the last Sunday 00:00. A run that stopped half way (the
machine went down, the process was killed) has not finished, and is run again.

    audit_due.py <log folder>     exit 0 and say why when due, exit 1 and say why when not

GUARD_AUDIT_NOW (`YYYY-MM-DDTHH:MM:SS`, local time) stands in for the clock in tests.
"""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

#: The day and hour of the schedule: Monday is 0, so Sunday is 6.
SCHEDULED_WEEKDAY = 6
SCHEDULED_HOUR = 0
#: The first line of a run and its last, as weekly-audit.sh writes them.
RUN_START = re.compile(r"^=== weekly anon audit: (\d{4}-\d{2}-\d{2}) \((\d{2}:\d{2}:\d{2})\) ===$")
RUN_END = re.compile(r"^=== done: ")


def last_scheduled(now: datetime) -> datetime:
    """The latest scheduled time at or before `now`."""
    days_back = (now.weekday() - SCHEDULED_WEEKDAY) % 7
    moment = (now - timedelta(days=days_back)).replace(hour=SCHEDULED_HOUR, minute=0, second=0, microsecond=0)
    return moment if moment <= now else moment - timedelta(days=7)


def finished_starts(text: str) -> list[datetime]:
    """When each run of one log that reached its last line started (a log holds every run of its day)."""
    starts, started = [], None
    for line in text.splitlines():
        if m := RUN_START.match(line):
            started = datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}")
        elif RUN_END.match(line) and started is not None:
            starts.append(started)
            started = None
    return starts


def last_finished(folder: Path) -> datetime | None:
    """When the latest run that finished started, or None when none has."""
    starts = [s for log in folder.glob("weekly-audit-*.log")
              for s in finished_starts(log.read_text(encoding="utf-8", errors="replace"))]
    return max(starts, default=None)


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: audit_due.py <log folder>", file=sys.stderr)
        return 2
    now_text = os.environ.get("GUARD_AUDIT_NOW")
    now = datetime.fromisoformat(now_text) if now_text else datetime.now()
    due_since = last_scheduled(now)
    finished = last_finished(Path(argv[0]))
    if finished is None:
        print("due: no run has finished yet")
        return 0
    if finished < due_since:
        print(f"due: the last run that finished started {finished:%Y-%m-%d %H:%M}, before {due_since:%Y-%m-%d %H:%M}")
        return 0
    print(f"not due: a run that started {finished:%Y-%m-%d %H:%M} finished, after {due_since:%Y-%m-%d %H:%M}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
