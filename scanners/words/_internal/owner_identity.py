#!/usr/bin/env python3
"""Takes what the destination account already shows of itself out of the commit identities a push
sends, before they are held to the word list.

Called by anon-audit-deep.sh for source 6 of a push range: the lines `dest-known.py authors` writes
(`<name> <<address>> / <name> <<address>>`) come in on stdin and go out on stdout.

    owner_identity.py <push URL>

The owner is that of a `git@github.com:<owner>/<repo>` or `https://github.com/<owner>/<repo>` URL.
A field is emptied only when the whole of it matches, case included:

    a name       <owner>
    an address   <owner>@users.noreply.github.com
                 <digits>+<owner>@users.noreply.github.com    (the addresses GitHub gives the account)

Every other field stays as it is, and so does every line when the URL names no owner this way
(another host, a host alias, a local path, no URL) or when a line does not have the shape above.
"""
from __future__ import annotations

import re
import sys

PUSH_URL = re.compile(
    r"(?:git@github\.com:|https://github\.com/)([A-Za-z0-9][A-Za-z0-9-]*)/[A-Za-z0-9_.-]+/?")
# git keeps `<` and `>` out of names and addresses, so they mark the fields even in a name that
# holds ` / ` itself.
IDENTITIES = re.compile(r"([^<>]*) <([^<>]*)> / ([^<>]*) <([^<>]*)>")
NOREPLY_DOMAIN = "users.noreply.github.com"


def owner_of(url: str) -> str | None:
    """The account or organisation a GitHub push URL sends to, or None."""
    match = PUSH_URL.fullmatch(url)
    return match.group(1) if match else None


def without_owner(line: str, owner: str) -> str:
    """`line` with each field that is the owner's name or noreply address emptied."""
    match = IDENTITIES.fullmatch(line)
    if not match:
        return line
    noreply = re.compile(rf"(?:[0-9]+\+)?{re.escape(owner)}@{re.escape(NOREPLY_DOMAIN)}")

    def name(field: str) -> str:
        return "" if field == owner else field

    def address(field: str) -> str:
        return "" if noreply.fullmatch(field) else field

    author, author_address, committer, committer_address = match.groups()
    return (f"{name(author)} <{address(author_address)}> / "
            f"{name(committer)} <{address(committer_address)}>")


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
