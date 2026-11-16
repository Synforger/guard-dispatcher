"""Which staged paths of a commit lie in another tab's work folder: git-hooks/pre-commit runs it on
every commit an agent's session makes (one whose environment names its work folder).

Several tabs work in one checkout, each in its own folder of it (an agent's tier). A commit made
with `git add -A`, or one that stages a folder, takes what another tab left uncommitted beside its
own: a picture that tab was still working on went out in another tab's commit. The index does not
say which tab staged a change, so a path is judged by the innermost work folder holding it:

- the session's own folder: the session's to commit;
- a folder around it (a tier above) or inside it (a tier below): the session may update those
  tiers' files, and so may the tabs that work there. The commit takes such a path only when its
  command names the file itself (`git commit -- <file>`); a change another tab staged there, or one
  a folder, `-A` or `-a` swept in, stops the commit;
- any other work folder (a tier beside it): another tab's, named or not.

Paths outside every work folder (the files every tab shares) are not judged. A commit made in
another worktree of the repository (a child's, beside the main checkout) judges by the session's
folder moved to the same place in that worktree (worktree_places.py).

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
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "agent-hooks" / "claude-code"))
import guard_places  # noqa: E402
from commit_scope import commit_scope  # noqa: E402
from path_forms import composed, resolved  # noqa: E402

from commit_command import CommitCommand, running_commit  # noqa: E402
from worktree_places import same_place, worktree_tops  # noqa: E402

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


def foreign(paths: list[Path], home: Path, patterns: list[list[str]],
            named: Callable[[], set[Path]]) -> list[tuple[Path, Path, bool]]:
    """(path, the other tier's work folder, whether that tier lies around or inside `home`) for every
    path the commit may not take: one beside `home`, and one around or inside it that the commit
    does not name (`named` is asked only when such a path is staged)."""
    found = []
    names: set[Path] | None = None
    for path in paths:
        folder = owner(path, patterns)
        if folder is None or folder == home:
            continue
        related = folder in home.parents or home in folder.parents
        if related:
            if names is None:
                names = named()
            if path in names:
                continue
        found.append((path, folder, related))
    return found


def named_paths(command: CommitCommand | None) -> set[Path]:
    """The files a commit names after `commit` (as git reads its words), each as a full path."""
    if command is None:
        return set()
    scope = commit_scope(command.arguments)
    if scope is None:
        return set()
    return {composed(resolved(command.folder / pathspec)) for pathspec in scope[1]}


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
    home = resolved(work)
    if home != top and top not in home.parents:
        home = same_place(home, top, worktree_tops(top))
    found = foreign(staged, home, patterns, lambda: named_paths(running_commit()))
    for path, folder, related in found:
        name = path.relative_to(top)
        if related:
            print(f"[pre-commit] {name} lies in the work folder {folder}, a tier above or below this "
                  f"session's ({work}), and the commit does not name it: a tab working there may have "
                  f"staged it. Name the file after `--` if this session changed it, or unstage it with "
                  f"`git restore --staged -- {name}`", file=sys.stderr)
        else:
            print(f"[pre-commit] {name} lies in another tab's work folder {folder} "
                  f"(this session works in {work}): unstage it with "
                  f"`git restore --staged -- {name}`, and commit the paths you wrote by name",
                  file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
