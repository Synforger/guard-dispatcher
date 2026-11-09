"""Which changes a `git commit` takes, read from the `git add` and `git commit` of one command line.

area-guard.py lets a marked session commit as a handoff when every change the commit takes lies in
a handoff folder. Counting every change in the working tree refused a journal-only commit for a file
somebody else left deleted. This reads, from the words of each `git add` and of the `git commit`,
what the commit takes besides what is staged already:

- the pathspecs a `git add` names (`git add journal/x`); `-A` / `-u` with no pathspec is everything;
- with `git commit -a`, every change to a tracked file; the pathspecs named on the commit.

None means the words do not tell (an interactive add or commit, a pathspec file): every change in
the working tree then counts, as before.
"""

from __future__ import annotations

import os
from typing import NamedTuple

import commit_options

# `git add` options that stage every change when no pathspec is named.
ADD_EVERYTHING_LETTERS = frozenset("Au")
ADD_EVERYTHING_LONG = ("--all", "--update", "--no-ignore-removal")
# `git add` options whose changes cannot be read from the words (chosen at the prompt, or in a file).
ADD_UNKNOWN_LETTERS = frozenset("ipe")
ADD_UNKNOWN_LONG = ("--interactive", "--patch", "--edit", "--pathspec-from-file")
# `git commit` options whose changes cannot be read from the words.
COMMIT_UNKNOWN_LETTERS = frozenset("p")
COMMIT_UNKNOWN_LONG = ("--interactive", "--patch", "--pathspec-from-file")
COMMIT_ALL_LETTER = "a"
COMMIT_ALL_LONG = ("--all",)
# A long option shortened to fewer letters than this after `--` is not read as any of the above.
SHORTEST_LONG_PREFIX = 3
# Commands that move where the command line stands: an add and the commit may then name different places.
MOVES = frozenset({"cd", "pushd", "popd"})
# git's own options that move it elsewhere, and those that take the next word as their value.
GIT_ELSEWHERE = frozenset({"-C", "--git-dir", "--work-tree"})
GIT_VALUED = frozenset({"-c", "--namespace", "--config-env", "--exec-path"})
SUBSHELL = frozenset({"(", ")"})


class CommitScope(NamedTuple):
    """What a commit takes besides the changes staged before the command runs."""

    added: tuple[str, ...]        # pathspecs a `git add` in the same command stages
    tracked: bool                 # `git commit -a`: every change to a tracked file
    named: tuple[str, ...]        # pathspecs named on the commit


def add_pathspecs(arguments: list[str]) -> list[str] | None:
    """The pathspecs the words after `git add` stage, or None when they stage everything or what
    they stage cannot be read."""
    pathspecs: list[str] = []
    everything = False
    options_end = False
    for word in arguments:
        if options_end or word == "-" or not word.startswith("-"):
            pathspecs.append(word)
        elif word == "--":
            options_end = True
        elif word.startswith("--"):
            name = word.partition("=")[0]
            if matches(name, ADD_UNKNOWN_LONG):
                return None
            everything |= matches(name, ADD_EVERYTHING_LONG)
        else:
            letters = set(word[1:])
            if letters & ADD_UNKNOWN_LETTERS:
                return None
            everything |= bool(letters & ADD_EVERYTHING_LETTERS)
    if everything and not pathspecs:
        return None
    return pathspecs


def commit_scope(arguments: list[str]) -> tuple[bool, list[str]] | None:
    """(whether `-a` takes every tracked change, the pathspecs named on the commit) from the words
    after `git commit`, or None when what it takes cannot be read."""
    tracked = False
    pathspecs: list[str] = []
    takes_next = False
    options_end = False
    for word in arguments:
        if takes_next:
            takes_next = False
        elif options_end or not word.startswith("-") or word == "-":
            pathspecs.append(word)
        elif word == "--":
            options_end = True
        elif word.startswith("--"):
            name, has_value, _ = word.partition("=")
            if matches(name, COMMIT_UNKNOWN_LONG):
                return None
            tracked |= matches(name, COMMIT_ALL_LONG)
            takes_next = not has_value and commit_options.is_valued_long(name)
        else:
            for at, letter in enumerate(word[1:]):
                if letter in COMMIT_UNKNOWN_LETTERS:
                    return None
                if letter == COMMIT_ALL_LETTER:
                    tracked = True
                if letter in commit_options.VALUED_LETTERS:
                    takes_next = at == len(word) - 2
                    break
                if letter in commit_options.OPTIONAL_LETTERS or letter not in commit_options.FLAG_LETTERS:
                    break
    return tracked, pathspecs


def matches(name: str, options: tuple[str, ...]) -> bool:
    """A long option written out, or shortened to a prefix of one of `options`."""
    return len(name) - 2 >= SHORTEST_LONG_PREFIX and any(option.startswith(name) for option in options)


def scope_of(words: list[str], breaks: frozenset[str] | set[str]) -> CommitScope | None:
    """What the one `git commit` of a command line takes besides what is staged, from its words
    (split as the shell splits them, with each control operator in `breaks` a word of its own).
    None when the line does not tell: no commit or several, a git run by another program, an add
    and a commit that may stand in different places (`cd`, a subshell, `git -C`), or an add or a
    commit whose changes cannot be read."""
    commands: list[list[str]] = [[]]
    for word in words:
        if word in SUBSHELL:
            return None
        if word in breaks:
            commands.append([])
        else:
            commands[-1].append(word)
    added: list[str] = []
    commit: tuple[bool, list[str]] | None = None
    seen_commit = False
    for argv in commands:
        if not argv:
            continue
        name = os.path.basename(argv[0])
        if name in MOVES:
            return None
        if name != "git":
            if any("git" in word.split() for word in argv[1:]) or "git" in argv:
                return None
            continue
        arguments, at = argv[1:], 0
        while at < len(arguments) and arguments[at].startswith("-"):
            flag, has_value, _ = arguments[at].partition("=")
            if flag in GIT_ELSEWHERE:
                return None
            at += 2 if flag in GIT_VALUED and not has_value else 1
        sub, rest = (arguments[at], arguments[at + 1:]) if at < len(arguments) else ("", [])
        if sub == "add":
            pathspecs = add_pathspecs(rest)
            if pathspecs is None:
                return None
            added += pathspecs
        elif sub == "commit":
            if seen_commit:
                return None
            seen_commit = True
            commit = commit_scope(rest)
            if commit is None:
                return None
    if commit is None:
        return None
    return CommitScope(tuple(added), commit[0], tuple(commit[1]))
