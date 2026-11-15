"""Which staged paths of a commit lie in another tab's work folder: git-hooks/pre-commit runs it on
every commit an agent's session makes (one whose environment names its work folder).

Several tabs work in one checkout, each in its own folder of it (an agent's tier). A commit made
with `git add -A`, or one that stages a folder, takes what another tab left uncommitted beside its
own: a picture that tab was still working on went out in another tab's commit. A staged path is
another tab's when the innermost work folder holding it is neither this session's folder, nor a
folder around it (a tier above, whose files the session may update), nor one inside it (a tier
below). Paths outside every work folder (the files every tab shares) are not judged.

The work folders are the lines of `work-folders.txt` among the guard's settings: one path pattern
per line, `~` for home, `*` for one folder's name and `**` for any number of folders, `#` starts a
comment. With no file, or no work folder in the environment, nothing is judged.

    staged_places.py <repository top>     staged paths on stdin, NUL-separated, as git prints them
Exit 0 with nothing printed: none is another tab's. Exit 1: one line per path on stderr.
"""

from __future__ import annotations

import fnmatch
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
import guard_places  # noqa: E402
from path_forms import composed, resolved  # noqa: E402

#: The environment variable that names the folder the session works in (set by the agent's launcher).
WORK_FOLDER = "GUARD_WORK_FOLDER"
#: The setting that lists the shapes of the work folders.
WORK_FOLDERS = "work-folders.txt"


def load_patterns(path: Path) -> list[list[str]]:
    """Each line of the settings file as the names of its folders, `~` written out."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    patterns = []
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if line:
            patterns.append(list(composed(os.path.expanduser(line)).parts))
    return patterns


def matches(parts: tuple[str, ...], pattern: list[str]) -> bool:
    """True when a folder's names fit a pattern's names, `**` standing for any number of folders."""
    if not pattern:
        return not parts
    if pattern[0] == "**":
        return any(matches(parts[i:], pattern[1:]) for i in range(len(parts) + 1))
    return bool(parts) and fnmatch.fnmatchcase(parts[0], pattern[0]) and matches(parts[1:], pattern[1:])


def owner(path: Path, patterns: list[list[str]]) -> Path | None:
    """The innermost work folder holding the path, or None."""
    for folder in [path, *path.parents]:
        if any(matches(folder.parts, p) for p in patterns):
            return folder
    return None


def foreign(paths: list[Path], home: Path, patterns: list[list[str]]) -> list[tuple[Path, Path]]:
    """(path, the other tab's work folder) for every path whose innermost work folder is neither
    `home`, nor around it, nor inside it."""
    found = []
    for path in paths:
        folder = owner(path, patterns)
        if folder is None or folder == home or folder in home.parents or home in folder.parents:
            continue
        found.append((path, folder))
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: staged_places.py <repository top>  (staged paths on stdin, NUL-separated)", file=sys.stderr)
        return 2
    work = os.environ.get(WORK_FOLDER)
    patterns = load_patterns(guard_places.setting(WORK_FOLDERS))
    if not work or not patterns:
        return 0
    top = resolved(argv[0])
    staged = [composed(top / name) for name in sys.stdin.read().split("\0") if name]
    found = foreign(staged, resolved(work), patterns)
    for path, folder in found:
        print(f"[pre-commit] {path.relative_to(top)} lies in another tab's work folder {folder} "
              f"(this session works in {work}): unstage it with "
              f"`git restore --staged -- {path.relative_to(top)}`, and commit the paths you wrote by name",
              file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
