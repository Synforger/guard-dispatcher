"""Whether the arguments of a `git commit` switch its hooks off, read as git reads them.

area-guard.py hands over the words after `commit` when it walks a command line to its sends
(send_places). The words are read the way git's option parser reads them, so a word that only
looks like a bundle of short options (a property flag in a message: `-PenableN`) is not taken for
`-n`:

- a word of short options is read letter by letter: `-qn` holds `-n`;
- a letter that takes a value takes the rest of the word as that value (`-mnote`), or the next
  word when it ends the word (`-qm note`); a letter whose value is optional (`-S`, `-u`) takes only
  the rest of the word;
- a letter git does not know makes git refuse the whole command (`unknown switch`), so nothing
  after it in that word is read;
- a long option may be shortened to a prefix no other option shares (`--no-verif`);
- `--` ends the options: what follows are paths.
"""

from __future__ import annotations

# Short options of `git commit` that take a value: the rest of the word, or the next word.
VALUED_LETTERS = frozenset("FmcCtU")
# Short options whose value is optional: only the rest of the word is the value.
OPTIONAL_LETTERS = frozenset("Su")
# Short options that take no value.
FLAG_LETTERS = frozenset("qvseaipnoz")
SKIP_LETTER = "n"
# Long options that take the next word as their value, unless written `--name=value`.
VALUED_LONG = (
    "--author", "--cleanup", "--date", "--file", "--fixup", "--inter-hunk-context", "--message",
    "--pathspec-from-file", "--reedit-message", "--reuse-message", "--squash", "--template",
    "--trailer", "--unified",
)
SKIP_LONG = "--no-verify"
# The shortest prefix of `--no-verify` read as it: a shorter one is shared with `--no-verbose`
# (git refuses it as ambiguous), and `--no-ver` is held as well, since refusing it costs nothing.
SKIP_LONG_SHORTEST = len("--no-ver")
# A long option shortened to fewer letters than this after `--` is not read as one of VALUED_LONG.
SHORTEST_LONG_PREFIX = 2


def skips_hooks(arguments: list[str]) -> bool:
    """True when the arguments of `git commit` (the words after `commit`, up to the end of that
    command) hold `-n` or `--no-verify`, so the commit runs without its pre-commit and commit-msg
    hooks."""
    takes_next = False
    for word in arguments:
        if takes_next:
            takes_next = False
            continue
        if word == "--":
            return False
        if word.startswith("--"):
            name, has_value, _ = word.partition("=")
            if is_skip_long(name):
                return True
            takes_next = not has_value and is_valued_long(name)
        elif word.startswith("-") and len(word) > 1:
            skips, takes_next = short_bundle(word[1:])
            if skips:
                return True
    return False


def is_skip_long(name: str) -> bool:
    """`--no-verify`, or a prefix of it git reads as it."""
    return len(name) >= SKIP_LONG_SHORTEST and SKIP_LONG.startswith(name)


def is_valued_long(name: str) -> bool:
    """A long option that takes the next word as its value, written out or shortened."""
    return len(name) - 2 >= SHORTEST_LONG_PREFIX and any(option.startswith(name) for option in VALUED_LONG)


def short_bundle(letters: str) -> tuple[bool, bool]:
    """(whether the bundle holds `-n`, whether its last option takes the next word as its value)."""
    for at, letter in enumerate(letters):
        if letter == SKIP_LETTER:
            return True, False
        if letter in VALUED_LETTERS:
            return False, at == len(letters) - 1
        if letter in OPTIONAL_LETTERS or letter not in FLAG_LETTERS:
            return False, False
    return False, False
