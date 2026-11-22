"""Lay the install's links down without a moment in which one is missing: scripts/install.sh calls it.

Hooks of every agent session on the machine run all the time, and a hook that starts while its link is
gone cannot follow it: it finds its own files under the install folder instead of the clone and breaks.
Removing a link and making it again leaves that moment open, so each link is made under a passing name
beside its place and renamed over the old one, which the file system does in one step. A real folder or
file standing where a link goes is removed first, as it cannot be renamed over.

    swap_links.py [--only <folder>] <source> <link> [<source> <link> ...]

With `--only`, every other link directly in that folder is removed afterwards, so a scanner the clone no
longer has does not stay behind. Exit 0 when every link is laid, 1 with the reason otherwise.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def swap(source: Path, link: Path) -> None:
    """Point `link` at `source`, renaming a fresh link over whatever link stood there."""
    if link.exists() and not link.is_symlink():
        if link.is_dir():
            shutil.rmtree(link)
        else:
            link.unlink()
    passing = link.with_name(f".{link.name}.new-{os.getpid()}")
    if passing.is_symlink() or passing.exists():
        passing.unlink()
    passing.symlink_to(source)
    os.replace(passing, link)


def prune(folder: Path, kept: set[Path]) -> None:
    """Remove the links directly in `folder` that are not among `kept`."""
    for entry in folder.iterdir():
        if entry.is_symlink() and entry not in kept:
            entry.unlink()


def main(arguments: list[str]) -> int:
    """Read the pairs, lay each link, and prune the folder given with --only."""
    only = None
    if arguments[:1] == ["--only"]:
        if len(arguments) < 2:
            print("swap_links: --only needs a folder", file=sys.stderr)
            return 1
        only, arguments = Path(arguments[1]), arguments[2:]
    if not arguments or len(arguments) % 2:
        print("swap_links: give pairs of <source> <link>", file=sys.stderr)
        return 1
    pairs = [(Path(arguments[at]), Path(arguments[at + 1])) for at in range(0, len(arguments), 2)]
    try:
        if only is not None:
            only.mkdir(parents=True, exist_ok=True)
        for source, link in pairs:
            swap(source, link)
        if only is not None:
            prune(only, {link for _, link in pairs})
    except OSError as error:
        print(f"swap_links: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
