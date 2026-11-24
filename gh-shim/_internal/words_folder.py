"""The folder whose git settings pick the word list a gh call is scanned with: the clone of the
repository the call sends to. Called by gh-guard.sh before the word scan.

A repository's word list is named by the git settings of its clones (`guard.wordlist`, set by a
conditional include for the folders of an area), so a push is scanned with its own repository's
list. A gh call is scanned the same way: by the repository it sends to (`-R`, `--repo`, `GH_REPO`,
the api path), not by the folder it is typed in.

    words_folder.py <argv file> <folder the call is typed in>

prints one folder, or nothing:

- the folder the call is typed in, when the call names no repository (gh sends to that folder's
  own), when every repository it names is one of that folder's remotes, or when what it sends to
  cannot be told (a gist, a new repository): the scan is what it was before;
- else a clone, inside an area, of every repository it names, when those clones agree on the word
  list;
- nothing, when a repository it names has no clone inside an area or its clones disagree: the call
  is scanned with the operator's whole list (the strictest).

The argv file holds the call's arguments, NUL-separated, as gh-guard writes it for the corpus scan.
corpus-scan.py is loaded from its path because its name, the command the hooks call, is not an
importable one; send-scan.py loads it the same way.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import ModuleType

CORPUS = Path(__file__).resolve().parents[2] / "scanners" / "corpus" / "corpus-scan.py"


def words_folder(argv: list[str], here: Path) -> Path | None:
    """The folder whose git settings pick the call's word list, or None for the operator's whole list."""
    corpus = _corpus_module()
    slugs = corpus.gh_destinations(argv, here)
    if not slugs or slugs <= corpus.remote_repos(here):
        return here
    known = corpus.clones(corpus.load_areas())
    folders: list[Path] = []
    for slug in sorted(slugs):
        clones = [Path(clone) for clone in known.get(slug, [])]
        if not clones:
            return None
        folders += clones
    if len({_word_list(folder) for folder in folders}) != 1:
        return None
    return folders[0]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: words_folder.py <argv file> <folder the call is typed in>", file=sys.stderr)
        return 2
    argv = Path(sys.argv[1]).read_bytes().decode("utf-8", "replace").split("\0")
    if argv[-1:] == [""]:
        argv = argv[:-1]
    folder = words_folder(argv, Path(sys.argv[2]))
    if folder is not None:
        print(folder)
    return 0


def _corpus_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("corpus_scan", CORPUS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _word_list(folder: Path) -> str:
    """The `guard.wordlist` the git settings of `folder` name, or "" when they name none."""
    found = subprocess.run(["git", "-C", str(folder), "config", "--get", "guard.wordlist"],
                           capture_output=True, text=True, check=False)
    return found.stdout.strip()


if __name__ == "__main__":
    sys.exit(main())
