"""A command line of several lines, read as the shell reads it: each line ends a command.

The guard splits a Bash command into its simple commands with `shlex`, which reads a line break
as a space: `cd /b` on the second line became words of the first line's command, and a relative
name after it was judged from the folder the session started in. The readers of the hooks
(outgoing.py, area-guard.py, children/rules.py) hand the command through `with_line_breaks` first.

A heredoc's body stays as it was: words of the command it feeds, read by whatever reads that
command's input. Only the line break after its closing line ends a command. A body that does not
split into shell words on its own (python with a quote the shell would leave open: `'a\\'b'`) is
kept as its words, each quoted: left as it was, its open quote ran on over the rest of the command
line, and the readers fell back to splitting the whole line on spaces, a commit message among it.
"""

from __future__ import annotations

import re
import shlex

# A heredoc's opening: `<<` or `<<-`, an optional quote and the delimiter (not a `<<<` here-string).
HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][\w.-]*)\2")
# What a line may end with and still go on to the next line: a control operator that waits for
# the command after it, or the opening of a subshell.
CONTINUES = set("&|(;")
# What a comment may follow: it begins a word.
BEFORE_WORD = set(" \t\n;&|()")


def with_line_breaks(command: str) -> str:
    """The command with each line break that ends a command written as `;`.

    A break inside quotes, one escaped with a backslash (the line goes on), one after a control
    operator (`&&`, `|`) and the lines of a heredoc's body are not. A comment is left out up to its
    line break, as the shell leaves it out."""
    out: list[str] = []
    pending: list[tuple[bool, str]] = []        # the heredocs opened on this line: (tabs stripped, delimiter)
    at, size = 0, len(command)
    while at < size:
        char = command[at]
        if char == "'":
            end = command.find("'", at + 1)
            end = size if end < 0 else end + 1
            out.append(command[at:end])
            at = end
        elif char == '"':
            end = at + 1
            while end < size and command[end] != '"':
                end += 2 if command[end] == "\\" else 1
            end = min(end + 1, size)
            out.append(command[at:end])
            at = end
        elif char == "\\":
            if command[at + 1:at + 2] != "\n":
                out.append(command[at:at + 2])
            at += 2
        elif char == "#" and (at == 0 or command[at - 1] in BEFORE_WORD):
            end = command.find("\n", at)
            at = size if end < 0 else end
        elif char == "<" and (m := HEREDOC.match(command, at)) and not command.startswith("<<<", at) \
                and (at == 0 or command[at - 1] != "<"):
            pending.append((bool(m.group(1)), m.group(3)))
            out.append(m.group(0))
            at = m.end()
        elif char == "\n":
            if pending:
                at = _body_end(command, at + 1, pending, out)
                pending = []
                continue
            last = "".join(out).rstrip(" \t")[-1:]
            out.append(" " if not last or last in CONTINUES else " ; ")
            at += 1
        else:
            out.append(char)
            at += 1
    return "".join(out)


def _body_end(command: str, at: int, pending: list[tuple[bool, str]], out: list[str]) -> int:
    """Copy the bodies of the heredocs opened on the line before `at`, each through its closing line,
    as words of that line's command; return where the line after the last closing line begins."""
    for stripped, delimiter in pending:
        tabs = r"\t*" if stripped else ""
        close = re.compile(rf"^{tabs}{re.escape(delimiter)}[ \t]*$", re.M).search(command, at)
        if close is None:
            out.append(" " + as_words(command[at:]))
            return len(command)
        out.append(" " + as_words(command[at:close.start()]) + command[close.start():close.end()])
        at = close.end()
    if at < len(command) and command[at] == "\n":
        out.append(" ; ")
        at += 1
    return at


def as_words(body: str) -> str:
    """A heredoc's body as the shell words it stands for: as it is when it splits into words on its
    own, else each of its words quoted, line by line, so that it opens no quote past its end."""
    lexer = shlex.shlex(body, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        list(lexer)
    except ValueError:
        return "\n".join(" ".join(shlex.quote(word) for word in line.split()) for line in body.split("\n"))
    return body
