"""What a command line writes from text it holds, and what it feeds a program on standard input, for
the readers of a file the command runs.

A command can write a file and run it in the same line (`cat > fix.py <<'EOF' ... EOF`, then
`python3 fix.py`), copy one and run the copy, or hand a shell its code on standard input
(`bash <<'EOF'`). The guard reads a file it runs from the disk (script_files), so what the same
command writes first, and what it feeds a shell, has to be read in its place. This reads the command
line, in order, for:

- the text `cat` (a heredoc or here-string given to it), `echo` and `printf` print, written to a file
  by `>` or `>>`, or through `tee` (`printf` with `%s`, `%b`, `%d` and `%%`; any other conversion
  leaves the text unread);
- a file `cp`, `mv` or `install` puts under another name: its content is the source's, read where
  script_files reads (the disk, and what this command writes first);
- the text a program is fed on standard input: a heredoc, a here-string, or what `cat`, `echo` or
  `printf` print into a pipe to it.

Where a file is, is where the command stands when it writes: `cd`, `pushd`, `popd` and a `( ... )`
subshell move it as the other readers' Standing does (area-guard.py, which cannot be imported from
here), and a variable the line sets to a literal is filled in. The line is cut by shell_commands. A
word or a body the shell fills in as the command runs, with something this line does not set, is not
text this reads. The disk is looked at once: whether a `cp` destination is a folder.

A file is a key of its real path; its texts are all the texts the command writes there. `>` and
`>>` give the same: the readers read what the file holds and what is written, since a write may fail
and the old file then runs.

What is written without text in the line (`curl -o`, `wget -O`, `rsync`, `ditto`, `ln`, `sed -i`, a
copy of something this cannot name, a redirection of any other command's output, `tee` of a pipe it
cannot read) is listed as unread, with how it writes: those files run as the disk holds them.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import NamedTuple

from shell_commands import ASSIGNMENT, PIPES, RUNTIME, VARIABLE, WRITES, Word, _tokens
from shell_lines import HEREDOC

#: The operators that write a command's standard output into a file.
STDOUT_FILES = WRITES - {"<>"}
#: What `printf` is read to print: its conversions of a word (`%s`, `%b`, `%d`, `%i`) and `%%`.
CONVERSION = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?([a-zA-Z%])")
READABLE_CONVERSIONS = frozenset("sbdi%")
ESCAPE = re.compile(r"\\(?:([ntra\\e])|(0[0-7]{0,3})|x([0-9a-fA-F]{1,2}))")
ESCAPED = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "e": "\x1b", "\\": "\\"}
#: The programs that put a file under another name, whose content is the source's.
COPIES = frozenset({"cp", "mv", "install"})
#: The other programs that write a file whose text the line does not hold, with the options that name where it goes.
FETCHES = {"curl": ("-o", "--output"), "wget": ("-O", "--output-document"), "rsync": (), "ditto": (), "ln": ()}
#: The options of `echo` that change what it prints.
ECHO_OPTIONS = re.compile(r"-[neE]+")
#: The options of a copy whose next word is their value, not a file.
COPY_VALUED = frozenset({"-m", "-o", "-g", "-S", "--mode", "--owner", "--group", "--suffix"})
#: The options of a copy that name its folder, so the last operand is not the destination.
COPY_INTO_FOLDER = frozenset({"-t", "--target-directory"})


class Writes(NamedTuple):
    """What a command line writes and feeds (see the module's docstring)."""

    texts: dict[str, list[str]]        # real path -> the texts written there, in the order they are written
    copies: dict[str, list[str]]       # real path -> the real paths whose content is put there
    fed: list[tuple[str, str]]         # (program, the text it is fed on standard input)
    delimiters: frozenset[str]         # the words that close the command's heredocs
    unread: list[tuple[str, str]]      # (how it is written, real path)


class _Step(NamedTuple):
    words: list[Word]
    redirects: list[tuple[str, Word]]   # (operator, file) of its redirections of standard output
    stdin: str | None | bool            # the text fed in; None when the line holds none; False when it is not known


def of(command: str, cwd: str, home: str | None = None) -> Writes:
    """The writes of a command line, standing in `cwd` (see the module's docstring). An unclosed
    quote leaves nothing read: the shell refuses to run such a line."""
    out = Writes({}, {}, [], frozenset(m.group(3) for m in HEREDOC.finditer(command)), [])
    try:
        tokens = _tokens(command)
    except ValueError:
        return out
    place = _Place(cwd)
    values = {"HOME": home or str(Path.home())}
    saved: list[dict[str, str]] = []
    piped: list[str] | None = None          # what the command before a pipe prints
    for step, ended_by in _steps(tokens):
        words = _past_assignments(step.words, values)
        if words and not place.move(os.path.basename(words[0]), words[1:]):
            piped = _written_by(words, step, piped, ended_by, place, values, out)
        else:
            piped = None
        if ended_by == "(":
            saved.append(dict(values))
            place.open()
        elif ended_by == ")":
            values = saved.pop() if saved else values
            place.close()
    return out


def _written_by(words: list[Word], step: _Step, piped: list[str] | None, ended_by: str, place: _Place,
                values: dict[str, str], out: Writes) -> list[str] | None:
    """Take what one command writes and is fed into `out`; the text it prints into a pipe, when it does."""
    program, args = os.path.basename(words[0]), words[1:]
    fed = _fed(step.stdin, piped)
    printed = _printed(program, args, fed, values)
    if fed is not None:
        out.fed.extend((program, text) for text in fed)
    for _, target in step.redirects:
        if (path := _real(target, place.here, values)) is None:
            continue
        if printed is None:
            out.unread.append((program if program in ("echo", "printf", "cat") else "redirect", path))
        else:
            out.texts.setdefault(path, []).extend(printed)
    _file_writes(program, args, fed, place, values, out)
    return printed if ended_by in PIPES and not step.redirects else None


def _steps(tokens: list[tuple]):
    """(the simple command, the operator that ends it) for each simple command of the tokens, in
    order. `(` and `)` end a command too, so the reader can open and close its subshell."""
    words: list[Word] = []
    redirects: list[tuple[str, Word]] = []
    stdin: str | None | bool = None
    piped = False
    at = 0
    while at < len(tokens):
        token = tokens[at]
        if token[0] == "word":
            words.append(token[1])
        elif token[0] == "redirect":
            target = tokens[at + 1] if at + 1 < len(tokens) else None
            if target is not None and target[0] in ("word", "heredoc"):
                at += 1
                operator = token[1]
                if operator in STDOUT_FILES and target[0] == "word":
                    redirects.append((operator, target[1]))
                elif operator in ("<<", "<<-") and target[0] == "heredoc":
                    stdin = _body(target[1][0])
                elif operator == "<<<" and target[0] == "word":
                    stdin = False if target[1].expands else str(target[1]) + "\n"
                elif operator in ("<", "<>"):
                    stdin = False
        elif token[0] in ("control", "break"):
            operator = token[1] if token[0] == "control" else ";"
            yield _Step(words, redirects, False if stdin is None and piped else stdin), operator
            piped = operator in PIPES
            words, redirects, stdin = [], [], None
        at += 1
    yield _Step(words, redirects, False if stdin is None and piped else stdin), ""


def _body(body: Word | None) -> str | bool:
    """The text of a heredoc's body, or False when the shell fills in part of it as the command runs."""
    if body is None or body.expands:
        return False
    return str(body) + "\n"


def _past_assignments(words: list[Word], values: dict[str, str]) -> list[Word]:
    """The words from the program on. A command of assignments only sets the variables whose value is a literal."""
    rest = list(words)
    while rest and ASSIGNMENT.fullmatch(rest[0]):
        rest.pop(0)
    if not rest:
        for word in words:
            name, _, value = word.partition("=")
            filled = _filled(Word(value, expands=word.expands), values)
            if filled is None:
                values.pop(name.rstrip("+"), None)
            else:
                values[name] = filled
    return rest


def _filled(word: str, values: dict[str, str]) -> str | None:
    """The word as the command runs it, or None when it holds what this line does not set."""
    text = str(word)
    if not (word.expands if isinstance(word, Word) else RUNTIME.search(text)):
        return text
    text = VARIABLE.sub(lambda m: values.get(m.group(1) or m.group(2), m.group(0)), text)
    return None if RUNTIME.search(text) else text


def _fed(stdin: str | None | bool, piped: list[str] | None) -> list[str] | None:
    """The texts a command reads from its standard input, or None when the line does not hold them."""
    if isinstance(stdin, str):
        return [stdin]
    return piped if stdin is False and piped is not None else None


def _printed(program: str, args: list[Word], fed: list[str] | None, values: dict[str, str]) -> list[str] | None:
    """The texts a command prints on its standard output when the line holds them, else None."""
    words = [_filled(word, values) for word in args]
    if program == "echo":
        return None if None in words else _echoed([str(w) for w in words])
    if program == "printf":
        return None if None in words or not words else _formatted(str(words[0]), [str(w) for w in words[1:]])
    if program == "cat" and not [a for a in args if a != "-"]:
        return fed
    return None


def _echoed(words: list[str]) -> list[str]:
    """What `echo` prints, in each way a shell prints it: a backslash is kept, and read as an escape."""
    options = 0
    while options < len(words) and ECHO_OPTIONS.fullmatch(words[options]):
        options += 1
    flags = "".join(words[:options])
    text = " ".join(words[options:])
    end = "" if "n" in flags else "\n"
    readings = [text] + ([_unescaped(text)] if "\\" in text and "E" not in flags else [])
    return [reading + end for reading in dict.fromkeys(readings)]


def _formatted(fmt: str, arguments: list[str]) -> list[str] | None:
    """What `printf fmt arguments` prints, or None when a conversion is not one this reads."""
    conversions = [m.group(1) for m in CONVERSION.finditer(fmt)]
    if any(c not in READABLE_CONVERSIONS for c in conversions):
        return None
    takes = len([c for c in conversions if c != "%"])
    rounds = max(1, -(-len(arguments) // takes)) if takes else 1
    given = iter(arguments)

    def fill(match: re.Match) -> str:
        if match.group(1) == "%":
            return "%"
        word = next(given, "")
        return _unescaped(word) if match.group(1) == "b" else word

    return ["".join(CONVERSION.sub(fill, _unescaped(fmt)) for _ in range(rounds))]


def _unescaped(text: str) -> str:
    """The text with the backslash escapes `echo -e` and `printf` read written out."""
    def one(match: re.Match) -> str:
        if match.group(1):
            return ESCAPED[match.group(1)]
        return chr(int(match.group(2), 8) if match.group(2) else int(match.group(3), 16))
    return ESCAPE.sub(one, text)


def _file_writes(program: str, args: list[Word], fed: list[str] | None, place: _Place,
                 values: dict[str, str], out: Writes) -> None:
    """The files a program writes by its own operands: `tee`'s, from its input; a copy's, from its
    source; and those whose text the line does not hold."""
    operands = [a for a in args if not a.startswith("-") or a == "-"]
    if program == "tee":
        for name in operands:
            if (path := _real(name, place.here, values)) is not None:
                if fed is None:
                    out.unread.append(("tee", path))
                else:
                    out.texts.setdefault(path, []).extend(fed)
    elif program in COPIES:
        _copied(program, args, _operands(args), place, values, out)
    elif program in FETCHES:
        options = FETCHES[program]
        names = [args[at + 1] for at, word in enumerate(args[:-1]) if word in options] \
            or ([] if options else operands[-1:])
        out.unread.extend((program, path) for name in names if (path := _real(name, place.here, values)))
    elif program == "sed" and any(a == "--in-place" or re.fullmatch(r"-[A-Za-z]*i.*", a) for a in args):
        out.unread.extend(("sed", path) for name in operands[1:] if (path := _real(name, place.here, values)))


def _operands(args: list[Word]) -> list[Word]:
    """The files a copy is given: its words that are no option and no option's value."""
    operands, skip = [], False
    for word in args:
        if skip:
            skip = False
        elif word in COPY_VALUED:
            skip = True
        elif not word.startswith("-") or word == "-":
            operands.append(word)
    return operands


def _copied(program: str, args: list[Word], operands: list[Word], place: _Place, values: dict[str, str],
            out: Writes) -> None:
    """A copy puts each source's content at the destination (the last operand; under it when it is a folder)."""
    if len(operands) < 2 or any(a in COPY_INTO_FOLDER or a.startswith("--target-directory=") for a in args):
        out.unread.extend((program, path) for name in operands[-1:] if (path := _real(name, place.here, values)))
        return
    destination = _real(operands[-1], place.here, values)
    if destination is None:
        return
    folder = os.path.isdir(destination) or operands[-1].endswith("/")
    for name in operands[:-1]:
        source = _real(name, place.here, values)
        if source is None:
            out.unread.append((program, destination))
            continue
        target = os.path.join(destination, os.path.basename(source)) if folder else destination
        out.copies.setdefault(target, []).append(source)


def _real(name: str, here: str, values: dict[str, str]) -> str | None:
    """The real path a file name written in the command names from `here`, or None when it is only known as the command runs."""
    filled = _filled(name, values)
    if filled is None or (isinstance(name, Word) and name.globs):
        return None
    filled = os.path.expanduser(filled)
    return os.path.realpath(filled if os.path.isabs(filled) else os.path.join(here, filled))


class _Place:
    """Where the command line stands as it is read in order (`cd`, `pushd`, `popd`, a subshell).

    A `cd` to a word that is only known as the command runs leaves the place where it was, as the
    other readers do."""

    def __init__(self, cwd: str) -> None:
        self.here = self.previous = os.path.realpath(cwd)
        self._dirs: list[str] = []
        self._subshells: list[tuple[str, str, list[str]]] = []

    def move(self, program: str, args: list[Word]) -> bool:
        """Follow `cd` / `pushd` / `popd` (True when the command was one of them)."""
        if program in ("cd", "pushd"):
            target = next((a for a in args if not a.startswith("-") or a == "-"), None)
            if target is not None and (RUNTIME.search(target) or target.expands):
                return True
            if program == "pushd":
                self._dirs.append(self.here)
            if target == "-":
                new = self.previous
            else:
                new = os.path.realpath(os.path.join(self.here, os.path.expanduser(target or "~")))
            self.previous, self.here = self.here, new
            return True
        if program == "popd":
            if self._dirs:
                self.previous, self.here = self.here, self._dirs.pop()
            return True
        return False

    def open(self) -> None:
        """A subshell opens: its place is given back when it closes."""
        self._subshells.append((self.here, self.previous, list(self._dirs)))

    def close(self) -> None:
        """A subshell closes."""
        if self._subshells:
            self.here, self.previous, self._dirs = self._subshells.pop()
