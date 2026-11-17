"""The simple commands of a Bash command line, read as the shell runs them.

The hooks judge what a Bash call does from its simple commands: which program runs, with which
words, fed by which standard input (outgoing.py reads every send from them). A command the reader
does not see is a send the guard does not judge, so this reads the line the way Bash does:

- quotes: a `$` inside single quotes is a character, sent as it is written; one outside them, or
  inside double quotes, is filled in by this machine's shell as the command runs (`Word.expands`)
- a command substitution (`$( ... )`, backticks) and a process substitution (`<( ... )`,
  `>( ... )`) is a command line of its own and is read in turn, wherever it stands, inside double
  quotes too; the word that holds one is only known when the command runs
- what stands before the program: shell keywords (`do`, `then`, `!`, `{`), assignments (`A=1`) and
  the programs that run the words after them (`sudo`, `env`, `timeout 10`, `nohup`, `xargs`, ...);
  `eval` and `trap` read their words as a command line, and `find -exec` the words up to its `;`;
  `function f` and `coproc` stand before what they run; the header of `for`, `case` and `select`
  runs nothing
- a name the shell expands into file names (`*`, `?`, `[a]`, `{a,b}`, `{1..3}` outside quotes) is
  marked (`Word.globs`): which files it names is only known when the command runs
- a heredoc's body is the standard input of its command: text, when its delimiter is quoted or it
  holds nothing the shell fills in or changes (a `$`, a backtick, or a backslash before one of
  them, before itself or before a line break)
- control operators glued to a word (`);`), line breaks that end a command, and comments

A file the line feeds a command (`< f`) is named as the line sets its variables to a literal before
(`S=/a; ssh h < $S/x`). One the line writes (`> f`) is only known when it runs.
"""

from __future__ import annotations

import os
import re
import sys
from typing import NamedTuple

# Shell keywords that stand before the program they lead into, and the words that begin or end a
# compound command and run nothing themselves.
LEADS = frozenset({"if", "then", "else", "elif", "do", "while", "until", "!", "{"})
HEADERS = frozenset({"for", "select", "case"})
ENDS = frozenset({"fi", "done", "esac", "}"})
# Programs that run the words after their own options: (options that take a value, how many
# words after the options are theirs before the program).
RUNS_NEXT: dict[str, tuple[frozenset[str], int]] = {
    "sudo": (frozenset({"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-T", "-U", "--user", "--group",
                        "--host", "--prompt", "--close-from", "--chdir", "--role", "--type",
                        "--command-timeout", "--other-user"}), 0),
    "doas": (frozenset({"-u", "-C"}), 0),
    "env": (frozenset({"-u", "--unset", "-C", "--chdir", "-P"}), 0),
    "nohup": (frozenset(), 0),
    "command": (frozenset(), 0),
    "builtin": (frozenset(), 0),
    "exec": (frozenset({"-a"}), 0),
    "time": (frozenset(), 0),
    "nice": (frozenset({"-n", "--adjustment"}), 0),
    "ionice": (frozenset({"-c", "-n", "-p", "--class", "--classdata"}), 0),
    "timeout": (frozenset({"-s", "--signal", "-k", "--kill-after"}), 1),
    "gtimeout": (frozenset({"-s", "--signal", "-k", "--kill-after"}), 1),
    "caffeinate": (frozenset({"-t", "-w"}), 0),
    "stdbuf": (frozenset({"-i", "-o", "-e"}), 0),
    "chronic": (frozenset(), 0),
    "unbuffer": (frozenset(), 0),
    "xargs": (frozenset({"-I", "-n", "-P", "-L", "-s", "-d", "-E", "-a", "-J", "-R", "-S", "--max-args",
                         "--max-procs", "--max-lines", "--max-chars", "--arg-file", "--delimiter",
                         "--replace", "--eof"}), 0),
}
# env's option whose value is a command line of its own.
ENV_SPLIT = frozenset({"-S", "--split-string"})
# xargs's options that name the string it replaces with what it reads.
XARGS_REPLACE = frozenset({"-I", "--replace", "-J"})
# find's actions that run the words after them up to a `;` (or `+`), with `{}` the file found.
FIND_RUNS = frozenset({"-exec", "-execdir", "-ok", "-okdir"})
# Programs that join the words after their options into one command line for a shell: (options
# that take a value, the options that run the words as they are instead, the words that end the
# command). GNU parallel writes what it reads where a `{...}` stands.
JOINS: dict[str, tuple[frozenset[str], frozenset[str], frozenset[str]]] = {
    "watch": (frozenset({"-n", "--interval", "-q", "--equexit"}), frozenset({"-x", "--exec"}), frozenset()),
    "parallel": (frozenset({"-j", "-P", "-S", "-a", "-n", "-N", "-L", "-l", "-C", "-d", "-E", "-I", "--jobs",
                            "--sshlogin", "--arg-file", "--max-args", "--colsep", "--delimiter", "--timeout",
                            "--joblog", "--results", "--tmpdir", "--eof", "--max-replace-args"}),
                 frozenset(), frozenset({":::", "::::", ":::+", "::::+"})),
}
PARALLEL_SLOT = re.compile(r"\{[^{}\s]*\}")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\+?=.*", re.S)
# Control operators and redirections, longest first.
CONTROLS = (";;", "&&", "||", "|&", ";", "|", "&", "(", ")")
REDIRECTS = ("<<<", "<<-", "<<", "<>", "<&", ">>", ">&", ">|", "&>>", "&>", "<", ">")
WRITES = frozenset({">", ">>", ">|", "&>", "&>>", "<>"})
PIPES = frozenset({"|", "|&"})
# Characters that end a word outside quotes.
WORD_END = frozenset(" \t\n;&|()<>")
SPECIAL_PARAMETER = frozenset("@*#?$!-0123456789")
# How deep a command line inside a command line is followed.
NESTED = 4
# What makes a word known only as the command runs, for a word whose quoting is not known, and a
# variable as a word spells it (`$S`, `${S}`).
RUNTIME = re.compile(r"[`$]")
VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
# A pattern the shell expands into file names, in a word's unquoted characters (a quoted or
# filled-in character is a NUL there); the same, for a word whose quoting is not known.
GLOB = re.compile(r"[*?]|\[[^\]\0]+\]|\{[^{}\0]*(?:,|\.\.)[^{}\0]*\}")
# Backslashes the shell takes out of an unquoted heredoc body (before `$`, a backtick, itself or a line break).
BODY_ESCAPE = frozenset("$`\\\n")


class Word(str):
    """A word of a command as the program gets it, with whether this machine's shell fills part of
    it in as the command runs (a variable or a substitution outside single quotes), and whether it
    is a pattern the shell expands into the names of the files that match it."""

    expands: bool
    globs: bool

    def __new__(cls, text: str, *, expands: bool = False, globs: bool = False) -> Word:
        word = super().__new__(cls, text)
        word.expands = expands
        word.globs = globs
        return word


class Command(NamedTuple):
    words: list[Word]
    stdin: tuple[str, str] | None   # ("file", path) / ("text", text) / ("unknown", why)


def expands(word: str) -> bool:
    """Whether a word is only known when the command runs. A word cut out of a Word (an option's
    value after `=`) has lost its quoting, and is judged by its characters."""
    return word.expands if isinstance(word, Word) else bool(RUNTIME.search(word))


def globs(word: str) -> bool:
    """Whether a word names files by a pattern the shell expands. A word cut out of a Word is judged
    by its characters."""
    return word.globs if isinstance(word, Word) else bool(GLOB.search(word))


def simple_commands(line: str, depth: int = 0, values: dict[str, str] | None = None) -> list[Command]:
    """Every simple command the line runs, each command line inside it (a substitution, `eval`,
    `env -S`) read in turn, each starting at its program. `values` are the variables the line
    around this one set to a literal before it. Raises ValueError on an unclosed quote or
    substitution, as the shell refuses to run the line."""
    if depth > NESTED:
        return []
    tokens = _tokens(line)
    out: list[Command] = []
    written = {str(after[1]) for token, after in zip(tokens, tokens[1:])
               if token[0] == "redirect" and token[1] in WRITES and after[0] == "word"}
    values = dict(values or {})
    for words, stdin, inner in _commands(tokens):
        for code in inner:
            out += simple_commands(code, depth + 1, values)
        if words and all(ASSIGNMENT.fullmatch(w) for w in words):
            for word in words:
                name, _, value = word.partition("=")
                if word.expands:
                    values.pop(name.rstrip("+"), None)
                else:
                    values[name] = value
        if stdin and stdin[0] == "named":
            path = VARIABLE.sub(lambda m: values.get(m.group(1) or m.group(2), m.group(0)), stdin[1])
            stdin = ("unknown", "a file named as the command runs") if RUNTIME.search(path) else ("file", path)
        if stdin and stdin[0] == "file" and stdin[1] in written:
            stdin = ("unknown", "a file the command line writes")
        out += _run(words, stdin, depth, values)
    return out


def _run(words: list[Word], stdin: tuple[str, str] | None, depth: int, values: dict[str, str]) -> list[Command]:
    """The command these words run, after the command lines and the commands its leading words hand on."""
    program, lines, nested = _program(words)
    out: list[Command] = []
    for code in lines:
        out += simple_commands(code, depth + 1, values)
    for inner_words in nested if depth < NESTED else []:
        out += _run(inner_words, None, depth + 1, values)
    if program:
        out.append(Command(program, stdin))
    return out


# --- tokens ------------------------------------------------------------------------------------
# A token is ("word", Word), ("control", operator), ("redirect", operator) or ("break",) for a
# line break; a heredoc's redirect is followed by ("heredoc", [body]), filled when its line ends.
# Each command line inside a word or a heredoc body follows it as ("inner", code).

def _tokens(line: str) -> list[tuple]:
    tokens: list[tuple] = []
    inner: list[str] = []
    pending: list[tuple[bool, str, bool, list]] = []   # (tabs stripped, delimiter, quoted, body)
    at, size = 0, len(line)
    word_end = -1
    while at < size:
        char = line[at]
        if char in " \t":
            at += 1
        elif char == "\\" and line[at + 1:at + 2] == "\n":
            at += 2
        elif char == "\n":
            at = _bodies(line, at + 1, pending, inner) if pending else at + 1
            pending = []
            tokens += [*(("inner", code) for code in inner), ("break",)]   # the bodies' command is still open
            inner.clear()
        elif char == "#":
            end = line.find("\n", at)
            at = size if end < 0 else end
        elif char in "<>" and line[at + 1:at + 2] == "(":
            end = _closing(line, at + 2)
            tokens += [("word", Word(line[at:end + 1], expands=True)), ("inner", line[at + 2:end])]
            at = end + 1
        elif (op := next((r for r in REDIRECTS if line.startswith(r, at)), None)) and \
                (char != "&" or op.startswith("&>")):
            if tokens and tokens[-1][0] == "word" and word_end == at and tokens[-1][1].isdigit():
                tokens.pop()   # the fd of `2>`
            at += len(op)
            if op in ("<<", "<<-"):
                while at < size and line[at] in " \t":
                    at += 1
                start = at
                delimiter, at = _word(line, at, [])
                body: list = [None]
                pending.append((op == "<<-", str(delimiter), bool(set(line[start:at]) & set("'\"\\")), body))
                tokens += [("redirect", op), ("heredoc", body)]
            else:
                tokens.append(("redirect", op))
        elif op := next((c for c in CONTROLS if line.startswith(c, at)), None):
            tokens.append(("control", op))
            at += len(op)
        else:
            word, at = _word(line, at, inner)
            tokens += [("word", word), *(("inner", code) for code in inner)]
            inner.clear()
            word_end = at
    return tokens


def _word(line: str, at: int, inner: list[str]) -> tuple[Word, int]:
    """The word that starts at `at`, and where it ends."""
    text: list[str] = []
    bare: list[str] = []   # the unquoted characters, each other one a NUL (GLOB)
    runtime = False
    size = len(line)
    while at < size and line[at] not in WORD_END:
        char = line[at]
        if char == "'":
            end = line.find("'", at + 1)
            if end < 0:
                raise ValueError("No closing quotation")
            part = line[at + 1:end]
            at = end + 1
        elif char == '"':
            part, filled, at = _double(line, at + 1, inner)
            runtime |= filled
        elif char == "\\":
            part = line[at + 1:at + 2] if line[at + 1:at + 2] != "\n" else ""
            at += 2
        elif char == "$":
            part, filled, at = _dollar(line, at, inner, quoted=False)
            runtime |= filled
        elif char == "`":
            part, at = _backticks(line, at, inner)
            runtime = True
        else:
            text.append(char)
            bare.append(char)
            at += 1
            continue
        text.append(part)
        bare.append("\0" * len(part))
    return Word("".join(text), expands=runtime, globs=bool(GLOB.search("".join(bare)))), at


def _double(line: str, at: int, inner: list[str]) -> tuple[str, bool, int]:
    """The text of a double-quoted string whose body starts at `at`, whether the shell fills part
    of it in, and where it ends (past the closing quote)."""
    text: list[str] = []
    runtime = False
    size = len(line)
    while at < size:
        char = line[at]
        if char == '"':
            return "".join(text), runtime, at + 1
        if char == "\\":
            follows = line[at + 1:at + 2]
            if follows in ('$', '`', '"', "\\"):
                text.append(follows)
            elif follows != "\n":
                text.append(line[at:at + 2])
            at += 2
        elif char == "$":
            part, filled, at = _dollar(line, at, inner, quoted=True)
            text.append(part)
            runtime |= filled
        elif char == "`":
            part, at = _backticks(line, at, inner)
            text.append(part)
            runtime = True
        else:
            text.append(char)
            at += 1
    raise ValueError("No closing quotation")


def _dollar(line: str, at: int, inner: list[str], quoted: bool) -> tuple[str, bool, int]:
    """What a `$` at `at` stands for: (its text as written, whether the shell fills it in, where it ends)."""
    follows = line[at + 1:at + 2]
    if line.startswith("$((", at):
        end = _closing(line, at + 2)
        _fills_in(line[at + 3:end - 1], inner)   # a substitution inside the arithmetic runs
        return line[at:end + 1], True, end + 1
    if follows == "(":
        end = _closing(line, at + 2)
        inner.append(line[at + 2:end])
        return line[at:end + 1], True, end + 1
    if follows == "{":
        end = _closing(line, at + 2, opening="{", closing="}")
        _fills_in(line[at + 2:end], inner)   # `${x:-$(cmd)}`: the substitution in a default runs
        return line[at:end + 1], True, end + 1
    if follows == "'" and not quoted:
        end = at + 2
        while end < len(line) and line[end] != "'":
            end += 2 if line[end] == "\\" else 1
        if end >= len(line):
            raise ValueError("No closing quotation")
        return line[at + 2:end], False, end + 1
    if follows == '"' and not quoted:
        part, filled, end = _double(line, at + 2, inner)
        return part, filled, end
    if follows and (follows.isalpha() or follows == "_"):
        end = at + 1
        while end < len(line) and (line[end].isalnum() or line[end] == "_"):
            end += 1
        return line[at:end], True, end
    if follows and follows in SPECIAL_PARAMETER:
        return line[at:at + 2], True, at + 2
    return "$", False, at + 1


def _backticks(line: str, at: int, inner: list[str]) -> tuple[str, int]:
    """The command line of a backtick substitution at `at` (read in turn), and where it ends."""
    end = at + 1
    while end < len(line) and line[end] != "`":
        end += 2 if line[end] == "\\" else 1
    if end >= len(line):
        raise ValueError("No closing backtick")
    inner.append(re.sub(r"\\([`$\\])", r"\1", line[at + 1:end]))
    return line[at:end + 1], end + 1


def _closing(line: str, at: int, opening: str = "(", closing: str = ")") -> int:
    """Where the bracket opened just before `at` closes, past the quotes and brackets inside."""
    depth, size = 1, len(line)
    while at < size:
        char = line[at]
        if char == "\\":
            at += 2
            continue
        if char == "'":
            end = line.find("'", at + 1)
            if end < 0:
                raise ValueError("No closing quotation")
            at = end + 1
            continue
        if char == '"':
            _, _, at = _double(line, at + 1, [])
            continue
        if char == "`":
            _, at = _backticks(line, at, [])
            continue
        if char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return at
        at += 1
    raise ValueError(f"No closing {closing}")


def _bodies(line: str, at: int, pending: list[tuple[bool, str, bool, list]], inner: list[str]) -> int:
    """Read the bodies of the heredocs opened on the line that ended before `at`, each through its
    closing line, into their tokens; return where the line after the last closing line begins."""
    size = len(line)
    for stripped, delimiter, quoted, body in pending:
        lines: list[str] = []
        while at < size:
            end = line.find("\n", at)
            end = size if end < 0 else end
            text = line[at:end].lstrip("\t") if stripped else line[at:end]
            at = min(end + 1, size)
            if text.rstrip(" \t") == delimiter:
                break
            lines.append(text)
        text = "\n".join(lines)
        body[0] = Word(text, expands=False if quoted else _fills_in(text, inner))
    return at


def _fills_in(text: str, inner: list[str]) -> bool:
    """Whether the shell fills part of a text in, or changes it, as it reads an unquoted heredoc
    body (or the inside of `$((...))` and `${...}`); its substitutions are read in turn."""
    runtime, at = False, 0
    while at < len(text):
        char = text[at]
        if char == "\\":
            runtime |= text[at + 1:at + 2] in BODY_ESCAPE and at + 1 < len(text)
            at += 2
        elif char == "$":
            _, filled, at = _dollar(text, at, inner, quoted=True)
            runtime |= filled
        elif char == "`":
            _, at = _backticks(text, at, inner)
            runtime = True
        else:
            at += 1
    return runtime


# --- commands ----------------------------------------------------------------------------------

def _commands(tokens: list[tuple]) -> list[tuple[list[Word], tuple[str, str] | None, list[str]]]:
    """The tokens as (words, standard input, the command lines inside them), one per simple command."""
    out: list[tuple[list[Word], tuple[str, str] | None, list[str]]] = []
    words: list[Word] = []
    inner: list[str] = []
    stdin = None
    piped = False
    at = 0
    while at < len(tokens):
        token = tokens[at]
        if token[0] == "word":
            words.append(token[1])
        elif token[0] == "inner":
            inner.append(token[1])
        elif token[0] == "redirect":
            target = tokens[at + 1] if at + 1 < len(tokens) else None
            if target is not None and target[0] in ("word", "heredoc"):
                at += 1
                stdin = _input(token[1], target) or stdin
        elif token[0] == "break" and not words and stdin is None:
            pass   # a line break after an operator that waits for the command after it
        else:
            operator = token[1] if token[0] == "control" else ";"
            if words or stdin is not None:
                out.append((words, stdin or (("unknown", "a pipe") if piped else None), inner))
                piped, inner = operator in PIPES, []
            elif operator in PIPES:
                piped = True
            words, stdin = [], None
        at += 1
    if words or stdin is not None or inner:
        out.append((words, stdin or (("unknown", "a pipe") if piped else None), inner))
    return out


def _input(operator: str, target: tuple) -> tuple[str, str] | None:
    """The standard input a redirection gives its command, or None when it gives none."""
    if operator in ("<<", "<<-"):
        body = target[1][0]
        return ("unknown", "a heredoc") if body is None or body.expands else ("text", str(body))
    word = target[1]
    if operator == "<<<":
        return ("unknown", "a here-string the shell fills in") if word.expands else ("text", str(word))
    if operator in ("<", "<>"):
        if word.globs:
            return ("unknown", "a file name the shell expands")
        return ("named", str(word)) if word.expands else ("file", str(word))
    return None


def _program(words: list[Word]) -> tuple[list[Word], list[str], list[list[Word]]]:
    """(the words from the program on, the command lines its words hand on to run, the commands
    they hand on as words): past keywords, assignments and the programs that run the next words.
    A compound command's header or end runs nothing; `eval`, `trap` and `env -S` hand on a command
    line, and `find -exec` the words up to its `;`."""
    lines: list[str] = []
    replace: str | None = None
    fed = False
    at = 0
    while at < len(words):
        word = words[at]
        name = os.path.basename(word)
        if word in LEADS or ASSIGNMENT.fullmatch(word):
            at += 1
        elif word == "function":
            at += 2   # `function f { ...; }`: the name, then what the function runs
        elif word == "coproc":
            at += 2 if at + 2 < len(words) and words[at + 2] == "{" else 1   # `coproc NAME { ...; }`
        elif name in RUNS_NEXT:
            valued, positional = RUNS_NEXT[name]
            at += 1
            while at < len(words) and words[at].startswith("-") and words[at] != "-":
                option = words[at]
                at += 1
                if option == "--":
                    break
                takes = valued | (ENV_SPLIT if name == "env" else frozenset())
                flag, value = option, None
                if option.startswith("--") and "=" in option:
                    flag, _, value = option.partition("=")
                elif not option.startswith("--") and option[:2] in takes and len(option) > 2:
                    flag, value = option[:2], option[2:]   # `-I{}`, `-n1`: the value glued to it
                if flag in takes and value is None and at < len(words):
                    value = words[at]
                    at += 1
                if name == "env" and flag in ENV_SPLIT and value is not None:
                    lines.append(value)
                if name == "xargs":
                    replace = value if flag in XARGS_REPLACE else "{}" if flag == "-i" else replace
            at += positional
            fed |= name == "xargs"
        else:
            break
    rest = words[at:]
    if not rest or rest[0] in HEADERS or rest[0] in ENDS:
        return [], lines, []
    name = os.path.basename(rest[0])
    if name in ("eval", "trap"):
        code = rest[1:] if name == "eval" else _trap_action(rest[1:])
        if code and not any(expands(w) for w in code):
            return ([] if name == "eval" else rest), [*lines, " ".join(code)], []
        return rest, lines, []
    if name in JOINS:
        return _joined(name, rest)
    if fed:
        # xargs adds what it reads to the words, or writes it where its replace string stands.
        rest = [Word(w, expands=True) if replace and replace in w else w for w in rest]
        rest += [] if replace else [Word("", expands=True)]
    return rest, lines, _found_runs(rest) if name == "find" else []


def _trap_action(args: list[Word]) -> list[Word]:
    """The command line `trap` sets (its first word after `--`), or none for `-p` / `-l` or a reset."""
    if args[:1] == ["--"]:
        args = args[1:]
    elif args[:1] and args[0].startswith("-") and args[0] != "-":
        return []
    return args[:1] if args and args[0] != "-" else []


def _joined(name: str, words: list[Word]) -> tuple[list[Word], list[str], list[list[Word]]]:
    """watch / parallel: the words after their options are joined into one command line for a
    shell, unless an option runs them as they are (`watch -x`). What parallel writes into a
    `{...}` (or its `-I` string) is only known when it runs."""
    valued, as_words, ends = JOINS[name]
    at, slot, direct = 1, None, False
    while at < len(words) and words[at].startswith("-") and words[at] not in ends:
        option = words[at]
        at += 1
        if option == "--":
            break
        direct |= option in as_words
        if option in valued and at < len(words):
            slot = words[at] if option == "-I" else slot
            at += 1
    end = next((i for i in range(at, len(words)) if words[i] in ends), len(words))
    command = words[at:end]
    if not command:
        return words, [], []
    if name == "parallel":
        marked = [Word(PARALLEL_SLOT.sub("${PARALLEL_ARGUMENT}", w) if not slot else w.replace(slot, "${PARALLEL_ARGUMENT}"))
                  for w in command]
        return words, [] if direct else [" ".join(marked)], []
    return words, [] if direct else [" ".join(command)], [command] if direct else []


def _found_runs(words: list[Word]) -> list[list[Word]]:
    """The commands `find` runs on what it finds (`-exec ... ;`), each `{}` only known when it runs."""
    out: list[list[Word]] = []
    at = 1
    while at < len(words):
        if words[at] in FIND_RUNS:
            end = at + 1
            while end < len(words) and words[end] not in (";", "+"):
                end += 1
            out.append([Word(w, expands=True) if "{}" in w else w for w in words[at + 1:end]])
            at = end
        at += 1
    return out


if __name__ == "__main__":
    # A command line on the first argument: one line per simple command, its words and its input.
    import json
    for command in simple_commands(sys.argv[1]):
        print(json.dumps({"words": list(command.words), "expands": [w.expands for w in command.words],
                          "globs": [w.globs for w in command.words], "stdin": command.stdin}, ensure_ascii=False))
