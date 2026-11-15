"""Which repositories of this machine the guard does not check: doctor.sh --machine judges every
repository it found with this, and keeps what it prints for the startup screens.

A repository is outside the guard's checks when its own git hooks do not run the guard's (a
`core.hooksPath` of its own), when it opts out (`guard.scope exempt`, or a folder under
`guard.exemptPrefix`), or when it lies in an `_exempt` area and a push to one of its remotes is
compared with no area (a private remote with a clone here and no line in destinations.txt).

    unchecked_repos.py <corpus-scan.py> <the guard's hooks folder>
        stdin: `<area>\\t<repo>` lines (`-` for a repository found outside every area)
        stdout: `outside\\t<area>\\t<repo>\\t<why>` for each repository outside, sorted

The area travels with each line because a repository's path names its area's folders: a screen
shows a session only the lines of the areas it may read (`area-guard.py reach`), as the weekly
audit's findings are read out only by a tab that reads there.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

#: The area a repository lies in when areas.txt names it as exempt.
EXEMPT = "_exempt"
#: What `corpus-scan.py --checked` prints when a push is compared with no area.
NO_AREA_CHECKED = {"", EXEMPT}


def git(repo: Path, *args: str) -> str:
    """One git answer about the repository, without the variables a hook may carry for another."""
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    run = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=environment)
    return run.stdout.strip()


def why_outside(repo: Path, area: str, corpus_scan: str, hooks: Path) -> list[str]:
    """Each reason the guard does not check this repository; none when it does."""
    reasons = []
    own_hooks = git(repo, "config", "--local", "--get", "core.hooksPath")
    if own_hooks and Path(os.path.expanduser(own_hooks)).resolve() != hooks.resolve():
        reasons.append(f"core.hooksPath {own_hooks} runs its own hooks, not the guard's")
    if git(repo, "config", "--get", "guard.scope") == "exempt":
        reasons.append("guard.scope exempt")
    prefix = git(repo, "config", "--get", "guard.exemptPrefix")
    if prefix:
        root = Path(os.path.expanduser(prefix)).resolve()
        if repo.resolve() == root or root in repo.resolve().parents:
            reasons.append("inside guard.exemptPrefix")
    if area == EXEMPT:
        for remote in git(repo, "remote").split():
            url = git(repo, "remote", "get-url", remote)
            checked = subprocess.run(["python3", corpus_scan, "--checked", "--dest", url], cwd=repo,
                                     capture_output=True, text=True).stdout.strip().splitlines()
            if (checked[-1] if checked else "") in NO_AREA_CHECKED:
                reasons.append(f"a push to {remote} is compared with no area")
    return reasons


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: unchecked_repos.py <corpus-scan.py> <hooks folder>  (`<area>\\t<repo>` lines on stdin)",
              file=sys.stderr)
        return 2
    corpus_scan, hooks = argv[0], Path(os.path.expanduser(argv[1]))
    seen: dict[Path, str] = {}
    for line in sys.stdin:
        area, _, repo = line.rstrip("\n").partition("\t")
        if repo and area != "ARCHIVE":
            seen.setdefault(Path(repo).resolve(), area)
    out = [f"outside\t{area}\t{repo}\t{reason}" for repo, area in seen.items()
           for reason in why_outside(repo, area, corpus_scan, hooks)]
    print("\n".join(sorted(out)), end="\n" if out else "")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
