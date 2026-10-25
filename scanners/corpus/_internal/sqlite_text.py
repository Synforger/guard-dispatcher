"""The text a SQLite database holds, as units for the private-document scan: corpus-scan.py's
unit_reader calls it for a file of a database suffix that opens with SQLite's header."""

from __future__ import annotations

import sqlite3
from pathlib import Path

#: The first bytes of every SQLite 3 database file.
HEADER = b"SQLite format 3\0"


def is_database(path: Path) -> bool:
    """Whether the file is a SQLite 3 database, judged by its header rather than its name."""
    try:
        with path.open("rb") as file:
            return file.read(len(HEADER)) == HEADER
    except OSError:
        return False


def units(path: Path) -> list[str]:
    """Every text value of every ordinary table, one unit each. Blobs are passed over, and a virtual
    table (full-text search) is read through the ordinary tables that keep its content.

    The file is opened read-only and immutable: reading it writes nothing beside it and waits on no
    lock held by an app that has it open. A write-ahead log beside it is not read.
    Raises ValueError when the file cannot be read as a database."""
    try:
        connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro&immutable=1", uri=True)
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
