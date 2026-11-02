#!/usr/bin/env python3
"""The word-list hits in a repository's tracked files that were not there in a known commit.

Called by anon-audit-deep.sh for source 1 when the known findings name a commit (`tree <sha>`):
what stood in the tree then was shown by an earlier audit, and only what came later is red.

    python3 known_tree.py <commit> < <anon-scan output>

Reads anon-scan.sh's hits (`<file>:<line>:<text>`, `<file>!<member>:...` inside an archive,
`<file>:text <n>:...` in a binary) from standard input, in the repository it is run in, and prints
the ones that are new, one per line. A hit is known when its line of text stands in the same file
at the commit, or when the file is as it was at the commit (the only test for a hit that is no line
of text: an archive's member, a run of a binary, an Office document's unpacked part).
"""

from __future__ import annotations

import re
import subprocess
import sys

HIT = re.compile(r"^(?P<label>.+?):(?P<where>\d+|text \d+):(?P<text>.*)$")
OFFICE = (".pptx", ".potx", ".pptm", ".docx", ".dotx", ".docm", ".xlsx", ".xltx", ".xlsm")


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], capture_output=True, check=False)


def unchanged(commit: str, path: str) -> bool:
    """Whether the file in the working tree is the blob the commit holds at that path."""
    then = git("rev-parse", "--verify", "--quiet", f"{commit}:{path}")
    now = git("hash-object", "--", path)
    return then.returncode == 0 and now.returncode == 0 and then.stdout.strip() == now.stdout.strip()


def lines_then(commit: str, path: str) -> set[str]:
    """The lines of text of the file at the commit (none when it was not there)."""
    shown = git("show", f"{commit}:{path}")
    if shown.returncode != 0:
        return set()
    return {line.rstrip("\r") for line in shown.stdout.decode("utf-8", "replace").split("\n")}


def new_hits(commit: str, hits: list[str]) -> list[str]:
    """The hits that were not in the tree at the commit."""
    found = []
    seen: dict[str, set[str]] = {}
    for hit in hits:
        m = HIT.match(hit)
        if not m:
            continue
        label = m.group("label")
        path = label.split("!", 1)[0]
        if unchanged(commit, path):
            continue
        is_line = "!" not in label and m.group("where").isdigit() and not path.lower().endswith(OFFICE)
        if is_line and m.group("text") in seen.setdefault(path, lines_then(commit, path)):
            continue
        found.append(hit)
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: known_tree.py <commit> < <anon-scan output>", file=sys.stderr)
        return 2
    for hit in new_hits(argv[1], sys.stdin.read().splitlines()):
        print(hit)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
