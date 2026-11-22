"""Which words handed to a file of code may name a file the code writes: the judgement of a script that
writes where its arguments say (area-guard.py's kept_by). Pure: it reads no file.

The guard reads a script as the code written into the command, and a word handed to it is no path
that code names. A script given what the agent may not write (the guard's settings, a session's
transcript) is read again with its arguments in place: a shell script's `$1`..`$9`, `$@` and `$*`
are the words (`shell_with_arguments`), a Python file's `sys.argv` is read by code_writes.python.
"""

from __future__ import annotations

import re
import shlex

#: A positional parameter of a shell script, in either spelling: `$1` `${1}` `$@` `${@}` `$*` `${*}`.
SHELL_ARGUMENT = re.compile(r"\$(?:([1-9])|\{([1-9])\}|([@*])|\{([@*])\})")
#: A word that needs no quoting wherever it stands in a command line.
PLAIN_WORD = re.compile(r"[\w@%+=:,./~-]+")


def shell_with_arguments(code: str, words: list[str]) -> str:
    """The shell script with `$1`..`$9` written out as the n-th word (empty when there is none), and
    `$@` and `$*` as all of them."""
    def spelled(word: str) -> str:
        return word if PLAIN_WORD.fullmatch(word) else shlex.quote(word)

    def fill(match: re.Match[str]) -> str:
        number = match.group(1) or match.group(2)
        if number:
            return spelled(words[int(number) - 1]) if int(number) <= len(words) else ""
        return " ".join(spelled(word) for word in words)

    return SHELL_ARGUMENT.sub(fill, code)


def candidates(words: list[str]) -> list[str]:
    """What each word may name: the word, and what follows an `=` in it (`--out=<path>`)."""
    return [part for word in words for part in (word, word.partition("=")[2]) if part]
