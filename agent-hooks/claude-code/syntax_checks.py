"""Which syntax checks at the head of a Bash call run nothing of the file they name. Called by area-guard.py,
which judges such a check as the reading of that file.

Whether `bash -n run.sh` is a check depends on everything that stands before it: a function or an alias of
the shell's name, a PATH, a file an earlier command put in place. So this is a list of what is allowed,
matched on the text as typed: the call begins with checks, after a `cd` to a folder written out at most,
each a bare or system shell with `-n` (or `-o noexec`) and one file of plain characters. From the first
word of any other form on, nothing is taken for a check.
"""

from __future__ import annotations

import re

_PATH = r"[\w.~/][\w.~/-]*"
_ENTER = re.compile(rf"[ \t\n]*cd[ \t]+{_PATH}[ \t]*(?:&&|;|\n)")
# A check ends the command it is: what could run beside it (`|`, `&`) or write first (`> file`) is none.
_CHECK = re.compile(rf"(?P<lead>[ \t\n]*)(?:/bin/|/usr/bin/)?(?:bash|sh|zsh|dash|ksh)[ \t]+(?:-n|-o[ \t]+noexec)"
                    rf"(?P<file>[ \t]+{_PATH}(?:[ \t]+2>&1)?[ \t]*)(?P<end>\Z|\n|;|&&|\|\|)")


def as_reads(command: str) -> str:
    """`command` with the checks at its head written as `cat <file>`."""
    entered = _ENTER.match(command)
    at = entered.end() if entered else 0
    judged = command[:at]
    while check := _CHECK.match(command, at):
        judged += f"{check['lead']}cat{check['file']}{check['end']}"
        at = check.end()
        if not check["end"] or check["end"] == "||":
            break
    return judged + command[at:]
