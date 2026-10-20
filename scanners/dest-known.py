#!/usr/bin/env python3
"""What a push's destination already holds, and the parts of a push range it does not.

A history rewritten to take a word out gives every commit a new hash, colleagues' too. The push
checks choose what goes out by commit hash, so the whole history the destination has carried
all along is checked again as if it were written here, and stops the push. This is the one place
that decides what the destination already holds; every check of a push compares the same way:

  a file          by its blob (the same bytes are already there)
  a commit text   by the text itself
  an author       by the address for the identity check, by name and address for the word scan
                  (a rewrite that changed only the name sends the new name)

What is new after a rewrite (a blob, a text, an address) is checked as before.

    dest-known.py build <dir> <ref>...      write what the refs hold into <dir>
    dest-known.py patch <dir>               a `git log -p --full-index` patch on stdin, without
                                            the files whose blob <dir> holds
    dest-known.py messages <dir> <rev>...   "<sha> <subject>\\n<body>" of the commits whose text
                                            <dir> does not hold
    dest-known.py authors <dir> <rev>...    "<name> <<address>> / <name> <<address>>" of the
                                            commits whose author or committer <dir> does not hold
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

OBJECTS = "objects.txt"
MESSAGES = "messages.txt"
ADDRESSES = "addresses.txt"
IDENTITIES = "identities.txt"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace",
                          check=True).stdout


def text_id(text: str) -> str:
    """A commit text as compared: its digest (the scans read it with git's own decoding)."""
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def commits(*revs: str) -> list[tuple[str, str, str, str, str, str]]:
    """(sha, text, author name, author address, committer name, committer address)."""
    out = git("log", "--format=%x00%H%x00%B%x00%an%x00%ae%x00%cn%x00%ce%x00", *revs).split("\0")
    rows = []
    for i in range(1, len(out) - 6, 7):
        sha, text, an, ae, cn, ce = out[i:i + 6]
        rows.append((sha, text, an, ae, cn, ce))
    return rows


def held(folder: Path, name: str) -> set[str]:
    try:
        return set((folder / name).read_text().split("\n")) - {""}
    except OSError:
        return set()


def build(folder: Path, refs: list[str]) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    objects = git("rev-list", "--objects", *refs).splitlines()
    (folder / OBJECTS).write_text("\n".join(line.split(" ", 1)[0] for line in objects) + "\n")
    rows = commits(*refs)
    (folder / MESSAGES).write_text("\n".join(sorted({text_id(r[1]) for r in rows})) + "\n")
    (folder / ADDRESSES).write_text("\n".join(sorted({a for r in rows for a in (r[3], r[5])})) + "\n")
    (folder / IDENTITIES).write_text("\n".join(sorted({f"{n} <{a}>" for r in rows
                                                        for n, a in ((r[2], r[3]), (r[4], r[5]))})) + "\n")


def patch(folder: Path) -> None:
    known = held(folder, OBJECTS)
    keep = True
    for line in sys.stdin:
        if line.startswith("diff "):
            keep = True
        elif line.startswith("index ") and ".." in line:
            keep = line.split("..", 1)[1].split()[0] not in known
        # the new path (`+++ b/<path>`) is sent with the push whatever the blob holds
        if keep or not line.startswith("+") or line.startswith("+++ "):
            sys.stdout.write(line)


def messages(folder: Path, revs: list[str]) -> None:
    known = held(folder, MESSAGES)
    for sha, text, *_ in commits(*revs):
        if text_id(text) not in known:
            subject, _, body = text.partition("\n")
            sys.stdout.write(f"{sha} {subject}\n{body.strip(chr(10))}\n")


def authors(folder: Path, revs: list[str]) -> None:
    known = held(folder, IDENTITIES)
    for _, _, an, ae, cn, ce in commits(*revs):
        if f"{an} <{ae}>" not in known or f"{cn} <{ce}>" not in known:
            sys.stdout.write(f"{an} <{ae}> / {cn} <{ce}>\n")


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] not in {"build", "patch", "messages", "authors"}:
        sys.stderr.write(__doc__ or "")
        return 2
    command, folder, rest = argv[0], Path(argv[1]), argv[2:]
    if command == "build":
        build(folder, rest)
    elif command == "patch":
        patch(folder)
    elif command == "messages":
        messages(folder, rest)
    else:
        authors(folder, rest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
