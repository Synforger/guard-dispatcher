"""Whether a Drive file is on a list an area keeps: the `@<list>` condition of a reads.txt line.

Called by rules.py for each value an `@` condition meets. A list is a file of the area's settings
(drive_list.py); the files on it are those a search of the Drive finds, kept as a table
(drive_table.py). A kept table younger than FRESH_SECONDS is trusted. An older one is trusted for
a file it holds; for a file it does not hold the Drive is asked again, so a document made since
(a meeting that has just ended) is found. When the table cannot be had the answer is yes, and the
reason is kept in `unverified`: a file that cannot be told from a meeting is read as one.
"""

from __future__ import annotations

import re
from pathlib import Path

from service_reads.drive_list import DriveList
from service_reads.drive_table import DriveTable, Unreadable

#: A kept table of this age or less is the Drive's answer; an older one is asked again for a file it lacks.
FRESH_SECONDS = 60
#: The arguments whose value is a path: its last name is compared with the names on the list.
PATH_KEYS = frozenset({"path"})
#: Text the shell makes when the command runs (a substitution or a variable).
RUNTIME_TEXT = re.compile(r"[`$]")


class DriveLists:
    def __init__(self) -> None:
        self.unverified: list[str] = []      # why a call could not be checked, one line each
        self._tables: dict[Path, DriveTable] = {}

    def holds(self, key: str, shape: str, value: str) -> bool:
        """Whether `value` of the argument `key` is on the list `shape` names (`@<path of the list file>`).
        True as well when that cannot be told, with the reason added to `unverified`."""
        path = Path(shape.removeprefix("@"))
        try:
            return self._holds(path, key, value)
        except (Unreadable, ValueError) as error:
            reason = f"the list {path.stem or shape} could not be checked: {error}"
            if reason not in self.unverified:
                self.unverified.append(reason)
            return True

    def _holds(self, path: Path, key: str, value: str) -> bool:
        if RUNTIME_TEXT.search(value):
            raise Unreadable("the file is only known when the command runs")
        if not path.is_absolute() or not path.is_file():
            raise Unreadable("no such list among the area's lists")
        try:
            drive_list = DriveList.parse(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise Unreadable(f"{path.name}: {error}") from None
        named = key in PATH_KEYS
        if named and not DriveTable.last_name(value):
            return False    # a listing of a remote or a folder names no file
        table = self._tables.get(path) or DriveTable.load(drive_list)
        if table is None or (table.age_seconds() > FRESH_SECONDS and not self._in(table, value, named)):
            table = DriveTable.fetch(drive_list)
            table.save(drive_list)
        self._tables[path] = table
        return self._in(table, value, named)

    @staticmethod
    def _in(table: DriveTable, value: str, named: bool) -> bool:
        return table.holds_path(value) if named else table.holds_id(value)
