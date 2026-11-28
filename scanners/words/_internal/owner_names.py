#!/usr/bin/env python3
"""Takes the destination account's own handle out of the name fields of the commit identities a push
sends, before they are held to the word list.

Called by anon-audit-deep.sh for source 6 of a push range: the lines `dest-known.py authors` writes
(`<name> <<address>> / <name> <<address>>`) come in on stdin and go out on stdout.

    owner_names.py <push URL>

A name field is emptied only when it equals, case included, the owner of a
`git@github.com:<owner>/<repo>` or `https://github.com/<owner>/<repo>` URL: that account's own
repository shows its handle already. The address fields stay as they are, and so does every line when
the URL names no owner this way (another host, a host alias, a local path, no URL) or when a line
does not have the shape above.
"""
from __future__ import annotations

import re
import sys

PUSH_URL = re.compile(
    r"(?:git@github\.com:|https://github\.com/)([A-Za-z0-9][A-Za-z0-9-]*)/[A-Za-z0-9_.-]+/?")
# git keeps `<` and `>` out of names and addresses, so they mark the fields even in a name that
# holds ` / ` itself.
IDENTITIES = re.compile(r"([^<>]*) (<[^<>]*>) / ([^<>]*) (<[^<>]*>)")


def owner_of(url: str) -> str | None:
    """The account or organisation a GitHub push URL sends to, or None."""
    match = PUSH_URL.fullmatch(url)
    return match.group(1) if match else None


def without_owner(line: str, owner: str) -> str:
    """`line` with each name field that is exactly `owner` emptied."""
    match = IDENTITIES.fullmatch(line)
    if not match:
        return line
    author, author_address, committer, committer_address = match.groups()
    author = "" if author == owner else author
    committer = "" if committer == owner else committer
    return f"{author} {author_address} / {committer} {committer_address}"


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write(__doc__ or "")
        return 2
    owner = owner_of(argv[0])
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    if owner:
        text = "\n".join(without_owner(line, owner) for line in text.split("\n"))
    sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
