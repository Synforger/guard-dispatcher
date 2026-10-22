"""Where the guard keeps its settings, its marks and its caches: the one table every part of the guard reads.

The hooks and the scanners import it; a shell script asks for one place with
`python3 _common/guard_places.py <name>`, which prints its path.

With `AGENT_PLATFORM_ROOT` set, everything sits under that root, in a folder per job:

    <root>/config/guard/boundaries/   areas.txt, areas/, public.txt, ignore.txt, patterns/
    <root>/config/guard/entry/        agent-writes.txt, agent-off, handoff.txt
    <root>/config/guard/exit/         allow.txt, destinations.txt, orders.txt, words/
    <root>/config/guard/audit/        weekly-audit.conf, known/
    <root>/state/guard/marks/         what each session has read
    <root>/state/guard/audit/         the weekly audit's logs
    <root>/cache/guard/corpus/        the tables of the areas' text

Without it, the guard uses the six places it always has. A variable that names one place
(`GUARD_CONFIG_DIR`, `AREA_GUARD_STATE`, `GUARD_CORPUS_CACHE`, `ANON_TRUTH_PATH`) wins over the root for
that place, so a test or a machine can still point one of them somewhere of its own; with
`GUARD_CONFIG_DIR` the settings keep their one flat folder.

The few lines of command line at the bottom stay in this file: they only print what the table holds.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT_VARIABLE = "AGENT_PLATFORM_ROOT"

#: Each setting by the name it has in the flat folder, and where it sits under `<root>/config/guard/`.
SETTINGS = {
    "areas.txt": "boundaries/areas.txt",
    "areas": "boundaries/areas",
    "background.txt": "boundaries/public.txt",
    "ignore.txt": "boundaries/ignore.txt",
    "patterns": "boundaries/patterns",
    "agent-writes.txt": "entry/agent-writes.txt",
    "agent-off": "entry/agent-off",
    "handoff.txt": "entry/handoff.txt",
    "allow.txt": "exit/allow.txt",
    "destinations.txt": "exit/destinations.txt",
    "orders.txt": "exit/orders.txt",
}
#: The weekly audit's settings by name, and where they sit under `<root>/config/guard/`.
AUDIT_SETTINGS = {
    "weekly-audit.conf": "audit/weekly-audit.conf",
    "known": "audit/known",
}


def platform_root() -> Path | None:
    """The platform's root folder, or None when the guard runs on its own."""
    root = os.environ.get(ROOT_VARIABLE)
    return Path(root).expanduser() if root else None


def setting(name: str) -> Path:
    """One of the guard's settings, by the name it has in the flat folder (`areas.txt`, `patterns`)."""
    if name not in SETTINGS:
        raise KeyError(f"{name!r} is not one of the guard's settings ({', '.join(SETTINGS)})")
    flat = os.environ.get("GUARD_CONFIG_DIR")
    root = platform_root()
    if flat or root is None:
        return Path(flat or Path.home() / ".config/guard") / name
    return root / "config/guard" / SETTINGS[name]


def flat_name(relative: str) -> str:
    """A path inside the settings folder as the flat folder spells it (`entry/agent-writes.txt` → `agent-writes.txt`).

    The operator's grant names settings the flat way, under a root as well; a path with no flat name
    (the word lists, the weekly audit's) keeps its own.
    """
    for name, placed in SETTINGS.items():
        if relative == placed or relative.startswith(placed + "/"):
            return name + relative[len(placed):]
    return relative


def settings_folder() -> Path:
    """The folder that holds every setting of the guard (= what an agent may not write without a grant)."""
    flat = os.environ.get("GUARD_CONFIG_DIR")
    root = platform_root()
    if flat or root is None:
        return Path(flat or Path.home() / ".config/guard")
    return root / "config/guard"


def words_folder() -> Path:
    """The folder of the word lists (= `master.txt`, the operator's, and one per area)."""
    truth = os.environ.get("ANON_TRUTH_PATH")
    root = platform_root()
    if truth or root is None:
        return Path(truth or Path.home() / ".config/anon-words/master.txt").expanduser().parent
    return root / "config/guard/exit/words"


def master_words() -> Path:
    """The operator's word list, the one every other list is synced from (`ANON_TRUTH_PATH` names it directly)."""
    truth = os.environ.get("ANON_TRUTH_PATH")
    return Path(truth).expanduser() if truth else words_folder() / "master.txt"


def audit_setting(name: str) -> Path:
    """One of the weekly audit's settings (`weekly-audit.conf`, `known`)."""
    if name not in AUDIT_SETTINGS:
        raise KeyError(f"{name!r} is not one of the weekly audit's settings ({', '.join(AUDIT_SETTINGS)})")
    root = platform_root()
    if root is None:
        return Path.home() / ".config/guard-dispatcher" / name
    return root / "config/guard" / AUDIT_SETTINGS[name]


def marks_folder() -> Path:
    """Where the entry guard keeps what each session has read."""
    named = os.environ.get("AREA_GUARD_STATE")
    root = platform_root()
    if named or root is None:
        return Path(named or Path.home() / ".cache/area-guard")
    return root / "state/guard/marks"


def audit_logs_folder() -> Path:
    """Where the weekly audit writes its logs."""
    root = platform_root()
    return Path.home() / ".local/state/guard-dispatcher" if root is None else root / "state/guard/audit"


def corpus_folder() -> Path:
    """Where the corpus scan keeps its tables of the areas' text."""
    named = os.environ.get("GUARD_CORPUS_CACHE")
    root = platform_root()
    if named or root is None:
        return Path(named or Path.home() / ".cache/guard-corpus")
    return root / "cache/guard/corpus"


#: What a shell script may ask for, by name.
PLACES = {
    **{name: (lambda name=name: setting(name)) for name in SETTINGS},
    **{name: (lambda name=name: audit_setting(name)) for name in AUDIT_SETTINGS},
    "settings": settings_folder,
    "words": words_folder,
    "master-words": master_words,
    "marks": marks_folder,
    "audit-logs": audit_logs_folder,
    "corpus": corpus_folder,
}


def main(argv: list[str]) -> int:
    if len(argv) != 1 or argv[0] not in PLACES:
        print(f"usage: guard_places.py <{'|'.join(PLACES)}>", file=sys.stderr)
        return 2
    print(PLACES[argv[0]]())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
