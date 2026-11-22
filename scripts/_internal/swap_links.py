"""Lay the install's links down, changing only the ones that move: scripts/install.sh calls it.

Hooks of every agent session on the machine run all the time, and a hook that starts while its link is
gone cannot follow it: it finds its own files under the install folder instead of the clone and breaks.
A link that already points at its place is therefore left untouched. One that moves is made under a
passing name beside its place and renamed over the old one, rather than removed and made again. A real
folder or file standing where a link goes is removed first.

    swap_links.py [--only <folder>] <source> <link> [<source> <link> ...]

With `--only`, a file or a link standing where that folder goes gives way to it, and every other link
directly in the folder is removed afterwards, so a scanner the clone no longer has does not stay behind.
Exit 0 when every link is laid, 1 with the reason otherwise.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def swap(source: Path, link: Path) -> None:
    """Point `link` at `source`: untouched when it already does, else a fresh link renamed over it."""
    if link.is_symlink() and _points_at(link, source):
        return
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


def _points_at(link: Path, source: Path) -> bool:
    """Whether `link` reads as `source`: a link that cannot be read, as another install moves it, does not."""
    try:
        return os.readlink(link) == str(source)
    except OSError:
        return False


def make_folder(folder: Path) -> None:
    """Make `folder` a real folder, in place of a file or a link that stands there."""
    if folder.is_symlink() or (folder.exists() and not folder.is_dir()):
        folder.unlink()
    folder.mkdir(parents=True, exist_ok=True)


def prune(folder: Path, kept: set[Path]) -> None:
    """Remove the links directly in `folder` that are none of `kept`, however their names are spelled."""
    others = [entry for entry in folder.iterdir() if entry.is_symlink() and entry not in kept]
    if not others:
        return
    # A file system that does not tell case apart lists a renamed-over link under the name it had.
    laid = {link.lstat().st_ino for link in kept}
    for entry in others:
        try:
            inode = entry.lstat().st_ino
        except FileNotFoundError:
            continue  # the passing link of another install, renamed into its place since the listing
        if inode not in laid:
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
            make_folder(only)
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
