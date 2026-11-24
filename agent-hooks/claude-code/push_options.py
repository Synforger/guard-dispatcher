"""Whether the arguments of a `git push` force it, and which word is its repository, read as git reads them.

area-guard.py hands over the words after `push` when it walks a command line to its sends
(send_places). The words are read the way git's option parser reads them, so a value that only
looks like an option (`-o -f`, `--repo -f`) is not taken for one:

- a word of short options is read letter by letter: `-uf` holds `-f`;
- a letter that takes a value (`-o`) takes the rest of the word as that value, or the next word
  when it ends the word; a letter git does not know makes git refuse the whole command, so
  nothing after it in that word is read;
- a long option may be shortened to a prefix; a prefix that fits several options is refused by git,
  and is held as a force when one of them is (refusing costs nothing);
- `--force-with-lease` and `--signed` take a value only as `--name=value`, never from the next word;
- `--` ends the options: what follows are the repository and the refspecs, and a refspec that starts
  with `+` forces its ref (`+main`, `+HEAD:refs/heads/x`).
"""

from __future__ import annotations

from typing import Iterator

# Short options of `git push` that take a value: the rest of the word, or the next word.
VALUED_LETTERS = frozenset("o")
# Short options that take no value (`-f` among them).
FLAG_LETTERS = frozenset("vqnfud46")
FORCE_LETTER = "f"
# Long options that take the next word as their value, unless written `--name=value`.
VALUED_LONG = ("--push-option", "--receive-pack", "--repo", "--exec")
# Long options that take a value only when written `--name=value`, and those that take none.
OTHER_LONG = (
    "--all", "--atomic", "--branches", "--delete", "--dry-run", "--follow-tags", "--force",
    "--force-if-includes", "--force-with-lease", "--ipv4", "--ipv6", "--mirror", "--porcelain",
    "--progress", "--prune", "--quiet", "--recurse-submodules", "--set-upstream", "--signed",
    "--tags", "--thin", "--verbose", "--verify",
)
ALL_LONG = (*VALUED_LONG, *OTHER_LONG)
# What forces a push: it may overwrite a ref with a commit that is not its descendant.
FORCING_LONG = ("--force", "--force-if-includes", "--force-with-lease", "--mirror")
FORCING_OPTIONS = (*FORCING_LONG, f"-{FORCE_LETTER}")
NEGATION = "--no-"
# `--no-verify` skips the pre-push hook; git takes a prefix of it down to this length (a shorter one
# fits `--no-verbose` too, and git refuses it as ambiguous; holding it costs nothing).
SKIP_LONG = "--no-verify"
SKIP_LONG_SHORTEST = len("--no-ver")
FORCING_REFSPEC = "+"


def forces(arguments: list[str]) -> str | None:
    """The form that forces a `git push` (the words after `push`, up to the end of that command), as
    one word: `-f`, `--force`, `--force-with-lease`, `--force-if-includes`, `--mirror`, or the
    refspec that starts with `+`. None when nothing forces it."""
    for kind, word in words_of(arguments):
        if (kind == "option" and word in FORCING_OPTIONS) or (kind != "option" and word.startswith(FORCING_REFSPEC)):
            return word
    return None


def skips_hooks(arguments: list[str]) -> bool:
    """True when the words after `push` hold `--no-verify` (or a prefix git reads as it) as an
    option, so the push runs without its pre-push hook. The value of an option and what follows
    `--` are not options."""
    return any(kind == "negation" and len(word) >= SKIP_LONG_SHORTEST and SKIP_LONG.startswith(word)
               for kind, word in words_of(arguments))


def remote(arguments: list[str]) -> str | None:
    """The repository a `git push` names (its first operand), or None when it names none."""
    return next((word for kind, word in words_of(arguments) if kind == "repository"), None)


def words_of(arguments: list[str]) -> Iterator[tuple[str, str]]:
    """Each word of a `git push` as (kind, word): an `option` (a short one as `-f`, a long one
    written out in full), a `negation` as written (`--no-verify`), the `repository` (the first
    operand) or a `refspec` (the operands after it). The value of an option is not a word of its own."""
    takes_next = False
    operands = 0
    options_end = False
    for word in arguments:
        if takes_next:
            takes_next = False
        elif not options_end and word == "--":
            options_end = True
        elif not options_end and word.startswith("--"):
            name, has_value, _ = word.partition("=")
            if name.startswith(NEGATION):
                yield "negation", name
            for found in long_options(name):
                yield "option", found
            takes_next = not has_value and takes_value(name)
        elif not options_end and word.startswith("-") and len(word) > 1:
            letters, takes_next = short_letters(word[1:])
            for letter in letters:
                yield "option", f"-{letter}"
        else:
            operands += 1
            yield ("repository" if operands == 1 else "refspec"), word


def long_options(name: str) -> list[str]:
    """The long options a written name stands for: itself when it is one, else every option it is a
    prefix of (git takes the one it fits alone and refuses a name that fits several). A negation
    (`--no-force-with-lease`) stands for none."""
    if name in ALL_LONG:
        return [name]
    if name.startswith(NEGATION) or name == "--":
        return []
    return [option for option in ALL_LONG if option.startswith(name)]


def takes_value(name: str) -> bool:
    """Whether a long option written without `=` takes the next word as its value: the name must
    stand for one option, and that option must be one that does."""
    fitting = long_options(name)
    return len(fitting) == 1 and fitting[0] in VALUED_LONG


def short_letters(letters: str) -> tuple[list[str], bool]:
    """(the options of a word of short options, whether the last takes the next word as its value)."""
    found: list[str] = []
    for at, letter in enumerate(letters):
        if letter in VALUED_LETTERS:
            return found, at == len(letters) - 1
        if letter not in FLAG_LETTERS:
            break
        found.append(letter)
    return found, False
