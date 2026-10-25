#!/usr/bin/env bats
# Behavioural tests for reading a SQLite database as an area's document: text copied out of a
# table must not leave the area, whatever the database file is called among the database suffixes.
#
# Every test builds its own area and databases under $BATS_TEST_TMPDIR, so no operator document is
# ever read. Sentences are made up and long enough to form 12-character runs.

load ../../../_internal/helpers

SCAN="${GUARD_ROOT}/scanners/corpus/corpus-scan.py"
SEND="${GUARD_ROOT}/scanners/destinations/send-scan.py"
CHAT_JA="来週の木曜は駅前の喫茶店で七時に集合しよう"
CHAT_EN="bring the folding chairs and the blue cooler to the lake on sunday"

setup() {
    setup_words
    export GUARD_CORPUS_MAX_AGE=0          # always rebuild: documents change inside a test
    AREA="${BATS_TEST_TMPDIR}/chats"
    mkdir -p "${AREA}" "${GUARD_CONFIG_DIR}"
    printf 'chats %s\n' "${AREA}" > "${GUARD_CONFIG_DIR}/areas.txt"
}

# mk_db <path> <text>... — a database shaped like a chat app's: a table of messages with a text
# column, a number and a blob beside it, one row per <text>.
mk_db() {
    python3 - "$@" <<'PY'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("CREATE TABLE ZMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTIMESTAMP INTEGER, ZTEXT TEXT, ZEXTRA BLOB)")
connection.executemany("INSERT INTO ZMESSAGE (ZTIMESTAMP, ZTEXT, ZEXTRA) VALUES (?, ?, ?)",
                       [(1700000000 + i, text, b"\x00\x01") for i, text in enumerate(sys.argv[2:])])
connection.commit()
connection.close()
PY
}

# mk_wal_db <folder> <name> <text> <newest> — a database in <folder> as an app leaves it while it
# runs: <text> written back into the file, <newest> only in the write-ahead log beside it.
mk_wal_db() {
    python3 - "$@" <<'PY'
import shutil, sqlite3, sys, tempfile
from pathlib import Path
folder, name, text, newest = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
work = Path(tempfile.mkdtemp())
connection = sqlite3.connect(work / name)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("CREATE TABLE ZMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTEXT TEXT)")
connection.execute("INSERT INTO ZMESSAGE (ZTEXT) VALUES (?)", (text,))
connection.commit()
connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
connection.execute("PRAGMA wal_autocheckpoint=0")
connection.execute("INSERT INTO ZMESSAGE (ZTEXT) VALUES (?)", (newest,))
connection.commit()
for suffix in ("", "-wal"):
    shutil.copyfile(work / (name + suffix), folder / (name + suffix))
connection.close()
shutil.rmtree(work)
PY
}

# scan_payload <text> — scan <text> as sent outside every area.
scan_payload() {
    printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/payload.txt"
    run python3 "${SCAN}" --text "${BATS_TEST_TMPDIR}/payload.txt" --dest-area OUTSIDE
}

@test "sqlite: a chat line copied out of a database is caught, the agent's own words pass" {
    mk_db "${AREA}/Line.sqlite" "${CHAT_JA}" "${CHAT_EN}"
    scan_payload "予定: ${CHAT_JA}"
    [ "$status" -eq 1 ]
    scan_payload "${CHAT_EN}"
    [ "$status" -eq 1 ]
    scan_payload "友だちと駅前でお茶 (木曜 19:00)"
    [ "$status" -eq 0 ]
}

@test "sqlite: every database suffix is read, by its header" {
    for suffix in sqlite sqlite3 db db3; do
        rm -f "${AREA}"/*
        mk_db "${AREA}/store.${suffix}" "${CHAT_JA}"
        scan_payload "${CHAT_JA}"
        [ "$status" -eq 1 ] || { echo "not read: .${suffix}"; return 1; }
    done
}

@test "sqlite: a file named like a database that is not one is no database document" {
    printf '%s\n' "${CHAT_JA}" > "${AREA}/notes.db"
    run python3 "${SCAN}" --status
    [ "$status" -eq 0 ]
    [[ "$output" != *"notes.db"* ]]
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 0 ]
}

@test "sqlite: a database past the size of a text document is still read for its text" {
    mk_db "${AREA}/Line.sqlite" "${CHAT_JA}"
    python3 - "${AREA}/Line.sqlite" <<'PY'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("CREATE TABLE ZATTACHMENT (ZDATA BLOB)")
connection.execute("INSERT INTO ZATTACHMENT VALUES (?)", (bytes(6_000_000),))
connection.commit()
connection.close()
PY
    [ "$(stat -f %z "${AREA}/Line.sqlite" 2>/dev/null || stat -c %s "${AREA}/Line.sqlite")" -gt 5000000 ]
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 1 ]
}

@test "sqlite: text that is not UTF-8 and a full-text index do not stop the rest being read" {
    mk_db "${AREA}/Line.sqlite" "${CHAT_JA}"
    python3 - "${AREA}/Line.sqlite" "${CHAT_EN}" <<'PY'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("INSERT INTO ZMESSAGE (ZTEXT) VALUES (CAST(X'fffe41' AS TEXT))")
try:
    connection.execute("CREATE VIRTUAL TABLE search USING fts5(body)")
    connection.execute("INSERT INTO search VALUES (?)", (sys.argv[2],))
except sqlite3.OperationalError:
    connection.execute("CREATE TABLE search (body TEXT)")
    connection.execute("INSERT INTO search VALUES (?)", (sys.argv[2],))
connection.commit()
connection.close()
PY
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 1 ]
    scan_payload "${CHAT_EN}"
    [ "$status" -eq 1 ]
}

@test "sqlite: a damaged database is told as unreadable, and the scan goes on" {
    mk_db "${AREA}/Line.sqlite" "${CHAT_JA}"
    { printf 'SQLite format 3\0'; head -c 4096 /dev/zero | tr '\0' 'x'; } > "${AREA}/broken.sqlite"
    run python3 "${SCAN}" --refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 documents could not be read (see --status)"* ]]
    run python3 "${SCAN}" --status
    [[ "$output" == *"broken.sqlite"* ]]
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 1 ]
}

@test "sqlite: reading a database leaves nothing beside it" {
    mk_db "${AREA}/Line.sqlite" "${CHAT_JA}"
    chmod 500 "${AREA}"
    scan_payload "${CHAT_JA}"
    chmod 700 "${AREA}"
    [ "$status" -eq 1 ]
    [ "$(ls "${AREA}")" = "Line.sqlite" ]
}

@test "sqlite: a row only in the write-ahead log is read too, and nothing is left beside it or in the cache" {
    mk_wal_db "${AREA}" Line.sqlite "${CHAT_EN}" "${CHAT_JA}"
    [ -s "${AREA}/Line.sqlite-wal" ]
    chmod 500 "${AREA}"
    scan_payload "${CHAT_JA}"
    chmod 700 "${AREA}"
    [ "$status" -eq 1 ]
    scan_payload "${CHAT_EN}"
    [ "$status" -eq 1 ]
    [ "$(ls "${AREA}" | tr '\n' ' ')" = "Line.sqlite Line.sqlite-wal " ]
    [ -z "$(ls -A "${GUARD_CORPUS_CACHE}/scratch")" ]
}

@test "sqlite: a database copied again with a newer row in its write-ahead log is read again" {
    mk_wal_db "${AREA}" Line.sqlite "${CHAT_EN}" "最初の行はまだ予定の話をしていない"
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 0 ]
    mk_wal_db "${AREA}" Line.sqlite "${CHAT_EN}" "${CHAT_JA}"
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 1 ]
}

@test "sqlite: the stat fallback sees a change of the log, and a log is read as its database" {
    mk_wal_db "${AREA}" Line.sqlite "${CHAT_EN}" "最初の行はまだ予定の話をしていない"
    printf 'notes\n' > "${AREA}/notes-wal"
    run python3 - "${SCAN}" "${AREA}" "${CHAT_JA}" <<'PY'
import importlib.util, sqlite3, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("c", sys.argv[1])
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
area = Path(sys.argv[2]); db = area / "Line.sqlite"
stamp, _ = c.document(db, c.Repos(), root=area)
index = {str(db): [stamp, "fid", "chats"]}
assert c.stat_changes(index) == ([], []), "unchanged at first"
with (area / "Line.sqlite-wal").open("ab") as log:
    log.write(b"\0" * 4096)
assert c.stat_changes(index)[0] == [db], "a longer log is a change"
assert c.database_read_with(area / "Line.sqlite-wal") == db
assert c.database_read_with(area / "notes-wal") == area / "notes-wal"
print("ALL_OK")
PY
    [[ "$output" == *"ALL_OK"* ]]
}

@test "sqlite: an untracked database in a repository inside the area is the area's" {
    mk_repo_at_area() { mkdir -p "$1" && git -C "$1" init -q; }
    mk_repo_at_area "${AREA}/app"
    mk_db "${AREA}/app/cache.db" "${CHAT_JA}"
    scan_payload "${CHAT_JA}"
    [ "$status" -eq 1 ]
}

@test "sqlite: a calendar entry copied out of a chat is refused at a destination outside the area" {
    mk_db "${AREA}/Line.sqlite" "${CHAT_JA}"
    printf 'mcp__apple-events__*   outside\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
    printf '%s\n' "${CHAT_JA}" > "${BATS_TEST_TMPDIR}/title.txt"
    run python3 "${SEND}" --dest mcp__apple-events__calendar_events --text "${BATS_TEST_TMPDIR}/title.txt"
    [ "$status" -ne 0 ]
    printf '%s\n' "駅前でお茶 (木曜 19:00)" > "${BATS_TEST_TMPDIR}/title.txt"
    run python3 "${SEND}" --dest mcp__apple-events__calendar_events --text "${BATS_TEST_TMPDIR}/title.txt"
    [ "$status" -eq 0 ]
}
