"""The text a SQLite database holds, as units for the private-document scan: corpus-scan.py's
unit_reader calls it for a file of a database suffix that opens with SQLite's header."""

from __future__ import annotations

import shutil
import sqlite3
import tempfile
from pathlib import Path

#: The first bytes of every SQLite 3 database file.
HEADER = b"SQLite format 3\0"
#: What SQLite adds to a database's name for its write-ahead log, kept beside it.
LOG_SUFFIX = "-wal"


def is_database(path: Path) -> bool:
    """Whether the file is a SQLite 3 database, judged by its header rather than its name."""
    try:
        with path.open("rb") as file:
            return file.read(len(HEADER)) == HEADER
    except OSError:
        return False


def log_of(path: Path) -> Path | None:
    """The write-ahead log beside a database when it holds anything, else None. Until SQLite writes
    it back, the newest rows are in the log only."""
    log = path.with_name(path.name + LOG_SUFFIX)
    try:
        return log if log.stat().st_size > 0 else None
    except OSError:
        return None


def database_of(path: Path) -> Path | None:
    """The database a write-ahead log belongs to, or None when the file is no log."""
    if not path.name.endswith(LOG_SUFFIX) or len(path.name) == len(LOG_SUFFIX):
        return None
    return path.with_name(path.name[:-len(LOG_SUFFIX)])


def units(path: Path, scratch: Path) -> list[str]:
    """Every text value of every ordinary table, one unit each, its write-ahead log included. Blobs
    are passed over, and a virtual table (full-text search) is read through the ordinary tables
    that keep its content.

    The database is opened read-only and immutable: reading it writes nothing beside it and waits
    on no lock held by an app that has it open. One with a log beside it is copied with the log
    into a folder of its own under `scratch` and read there, so the log's rows are read too and
    the copy is removed once read. Raises ValueError when the file cannot be read as a database."""
    log = log_of(path)
    if log is None:
        return _read(f"{path.resolve().as_uri()}?mode=ro&immutable=1")
    scratch.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="sqlite.", dir=scratch))
    try:
        copy = folder / path.name
        shutil.copyfile(path, copy)
        shutil.copyfile(log, folder / log.name)
        return _read(f"{copy.as_uri()}?mode=ro")
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def _read(uri: str) -> list[str]:
    """Every text value of every ordinary table of the database the URI opens."""
    try:
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as error:
        raise ValueError(f"not a readable SQLite database ({error})") from None
    # An app may store bytes that are not UTF-8 in a text column: read them as the other documents are.
    connection.text_factory = lambda data: data.decode("utf-8", "replace")
    try:
        tables = [name for (name,) in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' "
            "AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'")]
        found = []
        for table in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            for row in connection.execute(f"SELECT * FROM {quoted}"):
                found += [value for value in row if isinstance(value, str)]
        return found
    except sqlite3.Error as error:
        raise ValueError(f"not a readable SQLite database ({error})") from None
    finally:
        connection.close()
