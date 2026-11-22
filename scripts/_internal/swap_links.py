"""Lay the install's links down so that each one is in place and readable at every moment: scripts/install.sh and
scripts/bootstrap-machine.sh call it.

Hooks of every agent session on the machine run all the time, and each of them reads its files through these
links. A link that already points at its place is therefore left untouched. One that moves is made under a
passing name beside its place and renamed over the old one, and the old one stays reachable under another
name for a moment after. A file standing where a link goes gives way to the rename; a real folder there,
or a folder that is to be made, is swapped with a ready one in a single step and only then removed.

    swap_links.py [--only <folder>] [--drop-gone <folder>] <source> <link> [<source> <link> ...]

With `--only`, a file or a link standing where that folder goes gives way to it, and every other link
directly in the folder is removed afterwards, so a scanner the clone no longer has does not stay behind.
With `--drop-gone`, the links directly in that folder whose target no longer exists are removed.
Passing names that an install which has ended left behind are removed too. Those of an install that still
runs are left to it, so that two installs at once both finish.
Exit 0 when every link is laid, 1 with the reason otherwise.
"""

from __future__ import annotations

import ctypes
import os
import re
import shutil
import sys
import time
from pathlib import Path

# How long a replaced link stays reachable under its passing name. Reads of a replaced link that follow
# it while it is renamed away need this much to finish; none failed over 3,400 replacements with it.
PAUSE_SECONDS = 0.02
# The flag of the step that swaps two paths in one go: RENAME_SWAP on macOS, RENAME_EXCHANGE on Linux.
EXCHANGE_FLAG = 2
AT_FDCWD = -100
PASSING_NAME = re.compile(r"^\.(?P<name>.+)\.(?:new|old)-(?P<pid>\d+)$")
FLAGS = ("--only", "--drop-gone")


def swap(source: Path, link: Path, aside: list[Path]) -> None:
    """Point `link` at `source`: untouched when it already does, else a fresh link takes its place in one step."""
    if link.is_symlink() and _points_at(link, source):
        return
    passing = _passing(link, "new")
    _remove(passing)
    passing.symlink_to(source)
    if _is_folder(link):
        if not exchange(passing, link):
            _remove(link)
            os.replace(passing, link)
            return
        aside.append(passing)
        return
    kept = _keep(link)
    os.replace(passing, link)
    if kept is not None:
        aside.append(kept)


def exchange(first: Path, second: Path) -> bool:
    """Swap what stands at two paths in one step; False where the system has no such step or refuses it."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        paths = (os.fsencode(first), os.fsencode(second))
        if hasattr(libc, "renamex_np"):
            return libc.renamex_np(*paths, EXCHANGE_FLAG) == 0
        if hasattr(libc, "renameat2"):
            return libc.renameat2(AT_FDCWD, paths[0], AT_FDCWD, paths[1], EXCHANGE_FLAG) == 0
    except OSError:
        pass
    return False


def make_folder(folder: Path, pairs: list[tuple[Path, Path]], aside: list[Path]) -> None:
    """Make `folder` a real folder holding the links of `pairs`, in place of a file or a link that stands there."""
    if _is_folder(folder):
        return
    passing = _passing(folder, "new")
    _remove(passing)
    passing.mkdir()
    for source, link in pairs:
        (passing / link.name).symlink_to(source)
    if not os.path.lexists(folder):
        try:
            os.rename(passing, folder)
            return
        except OSError:
            _remove(passing)
            if _is_folder(folder):
                return
            raise
    if exchange(passing, folder):
        aside.append(passing)
        return
    _remove(folder)
    os.rename(passing, folder)


def release(aside: list[Path]) -> None:
    """Remove what the replacements put aside, after the pause that lets a read in flight finish."""
    if not aside:
        return
    time.sleep(PAUSE_SECONDS)
    for path in aside:
        _remove(path)


def prune(folder: Path, kept: set[Path]) -> None:
    """Remove the links directly in `folder` that are none of `kept`, however their names are spelled."""
    others = [
        entry
        for entry in folder.iterdir()
        if entry.is_symlink() and entry not in kept and not PASSING_NAME.match(entry.name)
    ]
    if not others:
        return
    # A file system that does not tell case apart lists a renamed-over link under the name it had.
    laid = {link.lstat().st_ino for link in kept}
    for entry in others:
        try:
            inode = entry.lstat().st_ino
        except FileNotFoundError:
            continue  # gone since the listing
        if inode not in laid:
            _remove(entry)


def drop_gone(folder: Path, kept: set[Path]) -> None:
    """Remove the links directly in `folder`, none of `kept`, whose target no longer exists."""
    for entry in folder.iterdir():
        if entry in kept or not entry.is_symlink() or PASSING_NAME.match(entry.name):
            continue
        try:
            os.stat(entry)
        except FileNotFoundError:
            _remove(entry)
        except OSError:
            continue


def clear_leftovers(folder: Path, names: set[str]) -> None:
    """Remove the passing names of `names` in `folder` that an install which has ended left behind."""
    try:
        entries = list(folder.iterdir())
    except (FileNotFoundError, NotADirectoryError):
        return  # no folder there yet, or a file standing in its place
    for entry in entries:
        found = PASSING_NAME.match(entry.name)
        if found and found["name"] in names and not _is_running(int(found["pid"])):
            _remove(entry)


def _passing(path: Path, kind: str) -> Path:
    """The name beside `path` under which this install holds a link ("new") or what it replaced ("old")."""
    return path.with_name(f".{path.name}.{kind}-{os.getpid()}")


def _keep(link: Path) -> Path | None:
    """Hold what stands at `link` under a second name, so that it is not freed while the rename goes over it."""
    kept = _passing(link, "old")
    _remove(kept)
    try:
        os.link(link, kept, follow_symlinks=False)
    except (OSError, NotImplementedError):
        return None  # nothing stands there, or the file system has no second name for it
    return kept


def _is_folder(path: Path) -> bool:
    """Whether `path` is a real folder, not a link to one."""
    return path.is_dir() and not path.is_symlink()


def _remove(path: Path) -> None:
    """Remove whatever stands at `path`, a folder with its content, without following a link; none when gone."""
    try:
        if _is_folder(path):
            shutil.rmtree(path)
        else:
            path.unlink()
    except FileNotFoundError:
        pass


def _is_running(pid: int) -> bool:
    """Whether a process with this pid exists."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _points_at(link: Path, source: Path) -> bool:
    """Whether `link` reads as `source`: a link that cannot be read, as another install moves it, does not."""
    try:
        return os.readlink(link) == str(source)
    except OSError:
        return False


def _lay(pairs: list[tuple[Path, Path]], only: Path | None, gone: Path | None, aside: list[Path]) -> None:
    """Lay every pair, then prune the `only` folder and drop the gone links of the `gone` folder."""
    kept = {link for _, link in pairs}
    owned = {link.name for link in kept} | ({only.name} if only else set())
    for folder in {link.parent for link in kept} | ({only.parent} if only else set()):
        clear_leftovers(folder, owned)
    if only is not None:
        make_folder(only, pairs, aside)
    for source, link in pairs:
        swap(source, link, aside)
    if only is not None:
        prune(only, kept)
    if gone is not None:
        drop_gone(gone, kept)


def main(arguments: list[str]) -> int:
    """Read the flags and the pairs, and lay the links."""
    folders: dict[str, Path] = {}
    while arguments[:1] and arguments[0] in FLAGS:
        if len(arguments) < 2:
            print(f"swap_links: {arguments[0]} needs a folder", file=sys.stderr)
            return 1
        folders[arguments[0]] = Path(arguments[1])
        arguments = arguments[2:]
    if not arguments or len(arguments) % 2:
        print("swap_links: give pairs of <source> <link>", file=sys.stderr)
        return 1
    pairs = [(Path(arguments[at]), Path(arguments[at + 1])) for at in range(0, len(arguments), 2)]
    aside: list[Path] = []
    try:
        try:
            _lay(pairs, folders.get("--only"), folders.get("--drop-gone"), aside)
        finally:
            release(aside)
    except OSError as error:
        print(f"swap_links: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
