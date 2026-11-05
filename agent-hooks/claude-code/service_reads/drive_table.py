"""The Drive files of one list, by id and by name, as the Drive's own search finds them.

Built by asking rclone (`rclone backend query <remote>: "<expression>"`, once for each query of the
list) and kept in the guard's cache, so that the next hook call does not ask again. Used by
drive_lists.py, which decides when a kept table is too old to trust.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

import guard_places
from service_reads.drive_list import DriveList

#: Where the tables sit, under the folder the corpus scan keeps its own tables in.
CACHE_FOLDER_NAME = "drive"
#: How long one rclone query may take before the table counts as not built.
QUERY_TIMEOUT_SECONDS = 30
#: How much of rclone's own error reaches the reason that is shown.
REASON_LENGTH = 160
#: A file the Drive exports with an extension (`Notes.txt` for the document `Notes`).
EXTENSION_LENGTH = 6
#: What rclone writes in a path for a `/` in a file's name.
SLASH_IN_PATH = "／"


class Unreadable(Exception):
    """The table could not be built or read; the message says why in one line."""


@dataclass(frozen=True)
class DriveTable:
    files: dict[str, str]    # id -> name
    fetched_at: float        # when the Drive was asked, in seconds since the epoch

    @classmethod
    def load(cls, drive_list: DriveList) -> DriveTable | None:
        """The table kept for this list, or None when none is kept or it cannot be read."""
        try:
            kept = json.loads(cls.path_of(drive_list).read_text(encoding="utf-8"))
            files = {str(file_id): str(name) for file_id, name in kept["files"].items()}
            return cls(files, float(kept["fetched_at"]))
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return None

    @classmethod
    def fetch(cls, drive_list: DriveList) -> DriveTable:
        """Ask the Drive. Raises Unreadable when rclone is missing, the remote is not there, or a query fails."""
        import shutil
        import subprocess   # loaded where a table is built: most hook calls never get here
        rclone = shutil.which("rclone")
        if rclone is None:
            raise Unreadable("rclone is not installed")
        files: dict[str, str] = {}
        for expression in drive_list.queries:
            command = [rclone, "backend", "query", f"{drive_list.remote}:", expression]
            try:
                done = subprocess.run(command, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                                      timeout=QUERY_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                raise Unreadable(f"rclone did not answer within {QUERY_TIMEOUT_SECONDS}s") from None
            except OSError as error:
                raise Unreadable(f"rclone could not run: {error}") from None
            if done.returncode != 0:
                said = (done.stderr.strip().splitlines() or ["no message"])[-1]
                raise Unreadable(f"rclone could not query {drive_list.remote}: {said[:REASON_LENGTH]}")
            try:
                found = json.loads(done.stdout or "null") or []
            except ValueError:
                raise Unreadable(f"rclone answered for {drive_list.remote} with something that is not JSON") from None
            if not isinstance(found, list):
                raise Unreadable(f"rclone answered for {drive_list.remote} with something that is not a list of files")
            for item in found:
                if isinstance(item, dict) and isinstance(item.get("id"), str):
                    name = str(item.get("name") or "")
                    files[item["id"]] = name
                    # A shortcut is found by its name, but a read names the file it points to, which
                    # the search may not find itself (a document shared to the meeting's guests).
                    target = (item.get("shortcutDetails") or {}).get("targetId")
                    if isinstance(target, str) and target:
                        files.setdefault(target, name)
        return cls(files, time.time())

    @staticmethod
    def path_of(drive_list: DriveList) -> Path:
        """The file that keeps this list's table: one per remote and set of queries."""
        import hashlib
        digest = hashlib.sha256(json.dumps([drive_list.remote, drive_list.queries]).encode()).hexdigest()
        return guard_places.corpus_folder() / CACHE_FOLDER_NAME / f"{digest[:24]}.json"

    def save(self, drive_list: DriveList) -> None:
        """Keep the table for the next call. A cache that cannot be written only costs a query next time."""
        path = self.path_of(drive_list)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(f"{path.name}.{os.getpid()}")
            temporary.write_text(json.dumps({"fetched_at": self.fetched_at, "files": self.files}), encoding="utf-8")
            os.replace(temporary, path)
        except OSError:
            return

    def age_seconds(self) -> float:
        return time.time() - self.fetched_at

    def holds_id(self, file_id: str) -> bool:
        return file_id in self.files

    @staticmethod
    def last_name(path: str) -> str:
        """The name a path (`remote:folder/Notes.txt`) ends in; empty for a remote or a folder alone
        (`remote:`, `remote:folder/`). A `:` in the name is kept: only the first one of a path with no
        folder ends the remote's name."""
        parts = path.rsplit("/", 1)
        return parts[-1] if len(parts) > 1 else path.partition(":")[2]

    def holds_path(self, path: str) -> bool:
        """Whether the last name of a path is the name of a file of the table, with or without the
        extension an export adds. A `/` in a file's name is spelled `／` in an rclone path."""
        name = self.last_name(path)
        stem, dot, extension = name.rpartition(".")
        names = {held.replace("/", SLASH_IN_PATH) for held in self.files.values()}
        return bool(name) and (name in names or (bool(dot) and len(extension) <= EXTENSION_LENGTH and stem in names))
