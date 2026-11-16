"""Where a folder of one worktree of a repository stands in another worktree of it.
git-hooks/_internal/staged_places.py asks it where the session's work folder stands in the
worktree a commit is made in.

A tab's work folder is named in the repository's main checkout, and a child it hands work to
commits in a worktree of the same repository beside it (`<project>-wt-<scope>`). The same
folder of the tree is the same tab's there: the work folder is moved to the same place, relative
to the worktree that holds it, in the worktree being committed in.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
from path_forms import resolved  # noqa: E402

#: Seconds `git worktree list` may take.
CALL_TIMEOUT = 10
#: How `git worktree list --porcelain` opens the line of each worktree.
WORKTREE_LINE = "worktree "


def worktree_tops(top: Path) -> list[Path]:
    """Every worktree of the repository whose worktree `top` is, `top` among them; empty when git
    cannot tell."""
    try:
        done = subprocess.run(["git", "-C", str(top), "worktree", "list", "--porcelain"],
                              capture_output=True, text=True, timeout=CALL_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if done.returncode != 0:
        return []
    return [resolved(line[len(WORKTREE_LINE):]) for line in done.stdout.splitlines()
            if line.startswith(WORKTREE_LINE)]


def same_place(folder: Path, top: Path, tops: list[Path]) -> Path:
    """`folder` moved into the worktree `top`: its place relative to the innermost of `tops` that
    holds it. The folder as it is when `top` holds it, or when no worktree does."""
    if folder == top or top in folder.parents:
        return folder
    holding = [t for t in tops if t == folder or t in folder.parents]
    if not holding:
        return folder
    home = max(holding, key=lambda t: len(t.parts))
    return top / folder.relative_to(home)
