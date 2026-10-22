"""What a child may do: the judgements the entry guard and the registration share.

Pure: no register, no settings, no git. What they need comes in as arguments, so a test can call
each judgement directly. Called by `area-guard.py` (the hook) and by `command.py` (the registration).

A child is held to three things its parent decides at registration:

- the places it writes: a file or a commit inside a git repository passes only inside a place the
  parent declared, or at the child's own note;
- the one it talks to: its parent;
- the areas it holds: the parent's, unless the child mends a tool (`kind_of`).
"""

from __future__ import annotations

import shlex
from pathlib import Path
from typing import Callable, Iterable

AREA_KIND = "area"
TOOL_KIND = "tool"
WRAPPERS = {"env", "sudo", "nohup", "command", "exec", "time"}
MESSAGE_ENDPOINT = "/agent-messages"
DOWNLOADERS = {"curl", "wget"}
GUARD_ENTRY = "area-guard.py"
BREAKS = set(";&|()\n")


def commands(command: str) -> list[list[str]]:
    """The simple commands of a command line, as words. A line that cannot be split is one command
    split on spaces."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        return [command.split()]
    found: list[list[str]] = [[]]
    for token in tokens:
        if token and set(token) <= BREAKS:
            found.append([])
        else:
            found[-1].append(token)
    return [words for words in found if words]


def program_index(words: list[str]) -> int | None:
    """The index of the word that names the program: past assignments, options and wrappers."""
    for index, word in enumerate(words):
        is_assignment = "=" in word and not word.startswith("-") and "/" not in word.split("=", 1)[0]
        if is_assignment or word.startswith("-") or Path(word).name in WRAPPERS:
            continue
        return index
    return None


def runs_registration(command: str) -> bool:
    """Whether a command line runs the guard's child registration (`area-guard.py child add`). The
    client does that, never an agent: an agent that could would write its own declaration."""
    for words in commands(command):
        for index, word in enumerate(words):
            if Path(word).name == GUARD_ENTRY and words[index + 1:index + 3] == ["child", "add"]:
                return True
    return False


def kind_of(places: list[Path], publishes: Callable[[Path], bool]) -> str:
    """`tool` when the child has places and every one is a repository that publishes outside every
    area (so no session that read an area may write it); `area` otherwise."""
    return TOOL_KIND if places and all(publishes(place) for place in places) else AREA_KIND


def _inside(path: Path, place: Path) -> bool:
    return path == place or place in path.parents


def place_refusal(given: dict, files: Iterable[Path], repos: Iterable[Path],
                  repo_root: Callable[[Path], Path | None], note: Path | None) -> str | None:
    """The one-line refusal for a write or a commit outside the places the parent declared, or None.

    `files` are paths the call writes; one inside a git repository must lie inside a declared
    place. `repos` are the repositories a commit, a push or a `gh` call runs in; one passes when a
    declared place and the repository hold one another. A path outside every repository, and the
    child's own `note`, pass."""
    places = [Path(p) for p in given["writes"]]
    shown = ", ".join(str(p) for p in places) or "no place"
    for path in files:
        if (note is not None and path == note) or repo_root(path) is None:
            continue
        if not any(_inside(path, place) for place in places):
            return (f"area-guard: this tab is a child and cannot write {path}: its parent declared {shown}. "
                    f"Ask the parent to declare the place")
    for repo in repos:
        root = repo_root(repo) or repo
        if not any(_inside(root, place) or _inside(place, root) for place in places):
            return (f"area-guard: this tab is a child and cannot commit or send from {root}: its parent "
                    f"declared {shown}. Ask the parent to declare the place")
    return None


def _subcommand(words: list[str], start: int) -> tuple[str | None, list[str]]:
    """The subcommand of `tabs` and the words after it. `--agent-dir` takes a value."""
    index = start
    while index < len(words):
        if words[index] == "--agent-dir":
            index += 2
        elif words[index].startswith("-"):
            index += 1
        else:
            return words[index], words[index + 1:]
    return None, []


def _send_target(words: list[str]) -> str | None:
    """The tab or name a `tabs send` is addressed to: its first word that is no option."""
    return next((word for word in words if not word.startswith("-")), None)


def contact_refusal(given: dict, tool: str, args: dict, command: str,
                    is_parent: Callable[[str], bool], is_own: Callable[[str], bool]) -> str | None:
    """The one-line refusal for a call that reaches a tab or a session other than the parent, or None.

    Reached from a Bash command: `tabs send <to>` (by the tab's id, which must be the parent's),
    and the client's message endpoint called by hand. Reached by name: `SendMessage`, which may
    name the parent's running session or one of the child's own subagents (`is_own`)."""
    parent = given["parent"]
    hint = f"a child tab talks to its parent only ({parent}): send to {parent}, or report with `tabs report`"
    if tool == "SendMessage":
        to = str(args.get("to") or "").strip()
        if to and to != "main" and not is_own(to) and not is_parent(to):
            return f"area-guard: {hint}"
        return None
    if tool != "Bash":
        return None
    for words in commands(command):
        start = program_index(words)
        if start is None:
            continue
        program = Path(words[start]).name
        if program == "tabs":
            subcommand, rest = _subcommand(words, start + 1)
            if subcommand == "send" and _send_target(rest) != parent:
                return f"area-guard: {hint}"
        elif program in DOWNLOADERS and any(MESSAGE_ENDPOINT in word for word in words):
            return f"area-guard: {hint}; the message endpoint is not called by hand"
    return None
