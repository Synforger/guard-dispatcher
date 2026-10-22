#!/usr/bin/env python3
"""Keep an AI agent from carrying what it read out of an area (Claude Code PreToolUse hook).

Areas are defined in `areas.txt` among the guard's settings (`_common/guard_places.py` holds where:
`~/.config/guard/`, or `<root>/config/guard/boundaries/` under a platform root), the same file
the private-document scan reads, through the same parser (`scanners/corpus/corpus-scan.py`). A session
that reads inside an area is marked with the area's name. A marked session may not write into a
git repository outside its marks, nor commit, push or send through `gh` to a destination outside
them.

- Marking: the target of Read / Grep / Glob, a Bash cwd, an area path a Bash command names
           standing by itself -- a word of the command line, a string of inline code, a line of
           what a program is fed; inside a sentence it is text, which nothing opens (see said) --
           unless the command only checks it: a lone test / [ / stat / realpath / readlink /
           ls -d with every argument literal; a folder on another machine (a `host:<host>:<path>`
           root) that an ssh / scp / rsync names; and a reading call to a service an area's
           `reads.txt` places in it (a mail search, a channel's history, a browser tab at the
           service's site; see service_reads), refused before it runs, like a folder, for a
           session that may not read there
- Refused: Edit / Write / NotebookEdit on a file inside a git repository outside the marks, and
           a Bash command that names one as written (see named);
           a Bash `git commit` / `git push` / sending `gh` call (reads pass) whose destination is
           outside the marks
- Destination: a commit lands in its repository. A push or `gh` call lands in the GitHub
           repository it names, judged by the private-document scan (`corpus-scan.py --where`):
           a public repository is outside every area wherever it is cloned, a private one sits
           where its local clone is, and an unknown one is outside
- Several marks allow writing only inside all of them (company > client means inside the client)
- `_exempt` is never refused (the operator's own notes; their commits are scanned by the hooks)
- A handoff folder (`$GUARD_CONFIG_DIR/handoff.txt`) is where a session leaves notes for the next
  one, whatever it read: an Edit / Write there passes when what it writes holds no copy of a private
  document of an area the folder is outside of (`corpus-scan.py --dest-area`, as a send into the
  folder's area is judged), and a commit in its repository passes when every change there lies in a
  handoff folder and passes the same scan. One line per folder; `~` and `$VARIABLE` / `${VARIABLE}`
  expand from the session's environment, and a line naming a variable the session does not have
  gives no folder (so each session gets its own: `~/notes/$TEAM/journal`). Everything else in the
  area stays refused as above
- `_outside` folders are in no area, whatever holds them: reading there marks nothing, and a
  marked session may not write a repository there

What a call sends out -- a tool that sends to a service, a `curl` / `wget` with a body -- is
found by `outgoing.py` (next to this file) and judged like a push by `scanners/destinations/send-scan.py`: its
payload is scanned against the areas its destination (declared in `destinations.txt`) is outside
of, on every machine.

Separately, and on every machine, a Bash command that switches the guards off or around
(skip variables, `--no-verify`, a hooksPath / exempt setting, clearing the marks, sending from a
repository the hooks do not reach) is refused. Taking a repository's own hooksPath away is not
such a command: the machine's hooks cover the repository again.

What the guard judges from is kept the same way: the agent writes nothing in the guard's settings
folder (`$GUARD_CONFIG_DIR`: where the areas are, what is public, what is fine to send, where a
destination sits, what counts as an order), nor removes it, nor writes a session's transcript
(`~/.claude*/projects/**/*.jsonl`), through Edit / Write or the shell. Reading the settings, and
copying them out, pass. The operator may hand some of the settings to the agent
(`agent-writes.txt`, one name per line, `*` for all): a session that has read inside no area,
counting the call itself, writes those.

Both pass on the operator's yes, with no command for the operator to type (`approval`): the agent
shows the very call in a ```guard block and asks, and the operator's next message says yes
(order.py). It passes only for a session that may read where the call acts: a repository or a
folder inside an area, or a setting of `areas/<area>/`, from a session that reads inside that
area. Rewriting the marks or a transcript never passes: the marks keep areas apart, and a
transcript is what the yes is read from.

A message relayed from a session on another machine holds the session it came into, on every
machine (`order.py`, the `>>` lines of `orders.txt`): until the operator types a message of their
own, only Read / Grep / Glob and a question to the operator run. Whoever sits at the other machine
can have such a message written, so nothing in it moves the agent's hands before the operator has
seen it.

A session may hand work to a child of its own (`children/`): the client registers the child's tab,
and the child is held to the places its parent declared, to the areas its parent had read, and to
talking to its parent only. A child that mends a tool, a repository that publishes outside every
area, starts with nothing but its task.

    area-guard.py child add --child TAB --parent TAB [--writes FILE]
    area-guard.py child check --parent TAB [--writes FILE] --text FILE
    area-guard.py marks SESSION

Nothing is printed when a call passes, so nothing lands in the agent's context. A refusal is one
line. Marks are kept in `<marks>/<session_id>.json` (`~/.cache/area-guard/`, or
`<root>/state/guard/marks/` under a platform root), so they outlive compaction.

A script the agent runs is not read: the guard sees the command that starts it, not what it
writes. A script that writes where its arguments say asks before it writes:

    area-guard.py may-write <session_id> <path>...

It exits 0 when the session may write every path (the same judgement an Edit of the path gets),
and 1 with one line per refused path on stderr. It only answers: it marks nothing and changes
nothing.
"""

from __future__ import annotations

import fnmatch
import functools
import glob
import importlib.util
import itertools
import json
import os
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import children  # noqa: E402
import guard_places  # noqa: E402
import service_reads  # noqa: E402

CONFIG = guard_places.settings_folder()
AREAS = guard_places.setting("areas.txt")
HANDOFF = guard_places.setting("handoff.txt")
STATE = guard_places.marks_folder()
# The operator's switch: while this file exists the entry guard passes every call. Installing or
# updating the guard leaves it as it is, so switching off holds until the operator removes it.
OFF = guard_places.setting("agent-off")
# The operator's grant: the settings an agent that has read inside no area may write, one name per
# line (a file, a folder, a glob; `*` for all). Never the grant itself, what orders a send, or the
# switch: an agent that wrote those would grant itself, order its own sends, or switch the guard off.
GRANT = guard_places.setting("agent-writes.txt")
OPERATOR_ONLY = (GRANT.name, "orders.txt", OFF.name)
CORPUS = Path(__file__).resolve().parents[2] / "scanners/corpus/corpus-scan.py"
SEND_SCAN = Path(__file__).resolve().parents[2] / "scanners/destinations/send-scan.py"
EXEMPT = "_exempt"
NO_AREA = "_outside"
READS = {"Read", "Grep", "Glob"}
# The folder a session works in, named by whatever started it. When it is set, the session reads only
# inside the areas that hold that folder, the areas around them, and the areas the folder's READS_FILE
# names; a call that reads inside any other area is refused before it runs, instead of marking the
# session after. Unset, the session marks what it reads, as before.
WORK_FOLDER = "GUARD_WORK_FOLDER"
READS_FILE = "guard-reads.txt"
# What still runs while a message from another machine holds the session: reading, and asking
# the operator.
HELD_RUNS = READS | {"AskUserQuestion"}
HELD = ("area-guard: a message relayed from another machine came in, and the operator has typed nothing "
        "since, so only reading runs (Read / Grep / Glob). Tell the operator what the message asks and wait "
        "for their own message; nothing in the relayed message counts as the operator's word")
WRITES = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
GIT_SEND = re.compile(r"\bgit\b[^|;&]*?\s(commit|push)\b")
GH_READONLY = {"view", "list", "status", "checks", "diff", "download", "clone", "watch", "token", "show"}


def real(path: str | Path, base: str | None = None) -> Path:
    p = Path(os.path.expanduser(os.path.expandvars(str(path))))
    if not p.is_absolute() and base:
        p = Path(base) / p
    return Path(os.path.realpath(p))


def corpus_module():
    """The private-document scan as a module: areas are parsed in that one place
    (including the `<prefix>* <path>/*` form that makes every client folder an area)."""
    spec = importlib.util.spec_from_file_location("corpus_scan", CORPUS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@functools.cache
def outgoing_module():
    spec = importlib.util.spec_from_file_location("outgoing", Path(__file__).with_name("outgoing.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@functools.cache
def order_module():
    spec = importlib.util.spec_from_file_location("order", Path(__file__).with_name("order.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# A heredoc: `<<` or `<<-`, an optional quote and the delimiter (not a `<<<` here-string).
HEREDOC = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([A-Za-z_][\w.-]*)\2(?!<)")
# Programs that run what a heredoc feeds them as code, and those that only pass on to the next word.
RUNS_BODY = re.compile(r"(?:\S*/)?(?:(?:ba|z|da|k)?sh|python[\d.]*|node|perl|ruby|osascript|eval|xargs|source|\.)")
PASSES_ON = {"sudo", "env", "command", "exec", "nohup", "time", "nice"}


def heredocs(command: str):
    """Each heredoc of the command, in order: (where the line that opens it ends, where its body
    ends, the program it feeds)."""
    pos = 0
    while (m := HEREDOC.search(command, pos)):
        line_end = command.find("\n", m.end())
        if line_end < 0:
            return
        tabs = r"\t*" if m.group(1) else ""
        end = re.compile(rf"^{tabs}{re.escape(m.group(3))}[ \t]*$", re.M).search(command, line_end + 1)
        body_end = end.start() if end else len(command)
        segment = re.split(r"[;&|(\n]", command[:m.start()])[-1].split()
        yield line_end, body_end, next((w for w in segment if "=" not in w and w not in PASSES_ON), "")
        pos = body_end


def strip_heredocs(command: str) -> str:
    """The command without the bodies of its heredocs, unless the program they feed runs them as
    code (a shell, python, ...). A commit message or a file's text written through a heredoc is
    not the command's own words: read as words, `-n` in a message was a `git commit -n`."""
    out, pos = [], 0
    for line_end, body_end, program in heredocs(command):
        out.append(command[pos:body_end] if RUNS_BODY.fullmatch(program) else command[pos:line_end + 1])
        pos = body_end
    out.append(command[pos:])
    return "".join(out)


def shell_words(command: str) -> list[str]:
    """The command's words, split in one place for every judgement (outgoing.shell_words):
    a `;` glued to a word is still a break, and a heredoc's body is not words of the command
    unless the program it feeds runs it (strip_heredocs). Falls back to plain spaces on an
    unclosed quote."""
    command = strip_heredocs(command)
    try:
        return outgoing_module().shell_words(command)
    except ValueError:
        return command.split()


def service_areas(tool: str, args: dict, cwd: str, tabs: dict) -> set[str]:
    """The areas a call to a service reads inside, by the lines the areas keep in `reads.txt`
    (service_reads): a reading MCP call, any call to a browser tab at the site, a curl with no body.
    A call that sends or drafts reads nothing there; its send is judged apart."""
    corpus = corpus_module()
    try:
        lines = corpus.kept_reads(corpus.load_areas(AREAS))
    except Exception:  # noqa: BLE001 — a broken checkout must not stop the agent, as in load_areas
        return set()
    if not lines:
        return set()
    out = outgoing_module()
    if tool == "Bash":
        return {area for send in out.sends(tool, args, cwd, SEND_SCAN, tabs) if send.reading
                for area in service_reads.rules.areas_read(lines, send.dest, {})}
    destination = out.destination_of(tool, args, tabs)
    if destination.startswith("browser:") or (tool.startswith("mcp__") and out.reads_only(tool, args)):
        return service_reads.rules.areas_read(lines, destination, args)
    return set()


def load_areas() -> list[tuple[str, Path]]:
    """(name, real path), longest path first so the innermost area wins. Empty when unreadable."""
    if not AREAS.is_file():
        return []
    try:
        areas = corpus_module().load_areas(AREAS)
    except Exception:  # noqa: BLE001 — a broken checkout must not stop the agent; the push-time scan still refuses
        return []
    out = [(name, real(root)) for name, roots in areas.items() for root in roots]
    return sorted(out, key=lambda a: len(str(a[1])), reverse=True)


@functools.cache
def load_carries() -> dict[str, list[str]]:
    """area -> the names (or globs over names) of the areas whose text a repository inside it may
    hold (the `_carries` lines, read where the scan reads them). Empty when the file cannot be
    read: nothing is carried on a guess."""
    try:
        module = corpus_module()
        return module.load_carries(module.load_areas(AREAS), AREAS)
    except Exception:  # noqa: BLE001 — a broken line refuses the commit in the scan; here it carries nothing
        return {}


def area_of(path: Path, areas) -> str | None:
    for name, root in areas:
        if path == root or root in path.parents:
            return None if name == NO_AREA else name
    return None


def inside(path: Path, name: str, areas) -> bool:
    """A root of name holds path, and no `_outside` folder inside that root holds it too."""
    held = [(n, r) for n, r in areas if path == r or r in path.parents]
    cut = max((len(r.parts) for n, r in held if n == NO_AREA), default=0)
    return any(n == name and len(r.parts) > cut for n, r in held)


def repo_root(path: Path) -> Path | None:
    d = path if path.is_dir() else path.parent
    while not d.exists() and d != d.parent:
        d = d.parent
    import subprocess   # loaded where it is used, here and below: most calls ask git nothing
    r = subprocess.run(["git", "-C", str(d), "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    return real(r.stdout.strip()) if r.returncode == 0 else None


def spell_home(command: str) -> str:
    """The command with ~/, $HOME and ${HOME} written out as the home folder."""
    home = str(Path.home())
    text = command.replace("${HOME}", home).replace("$HOME", home)
    return re.sub(r"(?<![\w/])~(?=/)", home, text)


GLOB = re.compile(r"[*?\[]")
# Where a path begins when a stretch of a command names it by itself: at the start of the stretch,
# or after what joins it to an option, a variable, a remote or an upload (`--file=/a`, `A=/a:/b`,
# `host:/a`, `-d @/a`), a short flag (`-C/a`), a file mode (`</a`) or `file://`.
STANDS = re.compile(r"(?:^|[=:,@]|^-\w|^[<>|+]+|^file://)(?=/)")


def standing(stretch: str) -> list[str]:
    """The paths a stretch of a command names standing by themselves (STANDS), home already written
    out (spell_home). Each is given twice: as far as the stretch runs (a path may hold spaces) and as
    far as its first word, cut at a list separator. A path further inside -- after other words, in the
    middle of a sentence -- is text: nothing opens it, so it is not a name."""
    stretch = stretch.strip()
    if "/" not in stretch:
        return []
    head = stretch.split(None, 1)[0]
    found = []
    for m in STANDS.finditer(head):
        found += [stretch[m.end():], re.split(r"[:,]", head[m.end():], maxsplit=1)[0]]
    return found


# A string literal of inline code, whatever the language: one in triple quotes or backticks may run
# over lines, one in single or double quotes ends on its line (so an apostrophe in a comment does not
# pair with a quote lines below).
STRING = re.compile(r"""(\"{3}|'{3})((?:\\.|(?!\1).)*)\1|(["'])((?:\\.|(?!\3)[^\n])*)\3|`((?:\\.|[^`])*)`""", re.S)
CODE_BREAK = re.compile(r"[\s()\[\]{},;]+")


# A call that joins its arguments into one path, the opening parenthesis included.
PATH_JOINS = re.compile(r"(?:\bos\.path\.join|\bposixpath\.join|\bPure(?:Posix)?Path|\bPath|\.joinpath)\s*\(")
# What tells a string is a template filled in when the code runs: `{name}` in an f-string or a
# format string, `%s` and its kind.
TEMPLATE = re.compile(r"\{[^{}]*\}|%[-+ #0-9.]*[sdrif]")


def _closing(code: str, opening: int) -> int:
    """Where the parenthesis opened at `opening` closes (strings skipped), or -1."""
    depth, pos = 0, opening
    while pos < len(code):
        m = STRING.match(code, pos)
        if m:
            pos = m.end()
            continue
        if code[pos] in "([{":
            depth += 1
        elif code[pos] in ")]}":
            depth -= 1
            if depth == 0:
                return pos
        pos += 1
    return -1


def _joins(code: str) -> tuple[list[str], list[tuple[int, int]]]:
    """The calls of `code` that join their arguments into a path (PATH_JOINS): (the paths that can be
    told, the stretches of code their arguments take). A call whose arguments are all strings names
    the path they join into; one with a variable among them names a path this line cannot know."""
    told, spans = [], []
    for m in PATH_JOINS.finditer(code):
        end = _closing(code, m.end() - 1)
        if end < 0:
            continue
        inside = code[m.end():end]
        spans.append((m.end(), end))
        pieces = [piece.strip() for piece in inside.split(",") if piece.strip()]
        strings = [STRING.fullmatch(piece) for piece in pieces]
        if pieces and all(strings) and not m.group(0).startswith(".joinpath"):
            parts = [next(g for g in (s.group(2), s.group(4), s.group(5)) if g is not None) for s in strings]
            if not any("\n" in part or TEMPLATE.search(part) for part in parts):
                told.append(os.path.join(*parts))
    return told, spans


def _alone(code: str, m: re.Match) -> bool:
    """Whether a string literal stands for a whole path: not one piece glued to another (`H + 'x'`,
    `base / 'x'`, `'%s/x' % H`), not a template filled in when the code runs (an f-string, `{}`)."""
    prefix = re.search(r"[A-Za-z]*$", code[:m.start()]).group(0).lower()
    body = next(g for g in (m.group(2), m.group(4), m.group(5)) if g is not None)
    if "f" in prefix or TEMPLATE.search(body):
        return False
    before, after = code[:m.start() - len(prefix)].rstrip(), code[m.end():].lstrip()
    return not (before.endswith(("+", "/")) or after.startswith(("+", "/", "%")))


def literals(code: str):
    """Inline code as the stretches that can name a file: (text, whether it is a whole string).
    A string literal on one line is one stretch, whole -- unless it is a piece of a path the code
    puts together (`H + 'todo.md'`, `os.path.join(H, 'todo.md')`, an f-string): then it is text,
    since the path it ends up in is not the string. A join of strings alone is given as the path it
    makes. One that runs over lines gives a stretch per line, and the code outside the strings gives
    its words. What is quoted inside a string -- a `name` in a sentence -- is part of that string,
    not a string of the code."""
    told, spans = _joins(code)
    yield from ((path, True) for path in told)
    pos = 0
    for m in STRING.finditer(code):
        yield from ((word, False) for word in CODE_BREAK.split(code[pos:m.start()]) if word)
        body = next(g for g in (m.group(2), m.group(4), m.group(5)) if g is not None)
        if "\n" in body:
            yield from ((line, False) for line in body.splitlines())
        else:
            joined = any(start <= m.start() and m.end() <= end for start, end in spans)
            yield body, not joined and _alone(code, m)
        pos = m.end()
    yield from ((word, False) for word in CODE_BREAK.split(code[pos:]) if word)


def glued(token: str) -> list[str]:
    """Control operators the lexer hands over as one token (`);` `)&&`), one by one."""
    out, rest = [], token
    while rest:
        op = next((o for o in ("&&", "||", ";;", "|&") if rest.startswith(o)), rest[0])
        out.append(op)
        rest = rest[len(op):]
    return out


def stepped_commands(line: str):
    """The simple commands of a command line whose heredoc bodies are taken out, in order:
    (its words, its redirections as (operator, word), its here-string or None, the control operator
    that ends it, "" for the last). `2>&1` names no file and is left out. Raises ValueError on an
    unclosed quote, as `shlex.split` does."""
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    breaks = outgoing_module().SHELL_BREAK
    words: list[str] = []
    redirects: list[tuple[str, str]] = []
    here = operator = None
    for token in list(lexer):
        if operator is not None:
            if operator == "<<<":
                here = token
            elif not operator.endswith("&"):
                redirects.append((operator, token))
            operator = None
        elif token in breaks or (token and set(token) <= set(";&|()")):
            for ended_by in glued(token):
                yield words, redirects, here, ended_by
                words, redirects, here = [], [], None
        elif token and set(token) <= set("<>&|") and set(token) & set("<>"):
            if words and words[-1].isdigit():   # the fd of `2>`
                words.pop()
            operator = token
        else:
            words.append(token)
    yield words, redirects, here, ""


def simple_commands(line: str):
    """stepped_commands without the operator that ends each command."""
    for words, redirects, here, _ in stepped_commands(line):
        yield words, redirects, here


def split_heredocs(text: str) -> tuple[str, list[tuple[str, str]]]:
    """(the command line without the bodies of its heredocs, each body with the program it feeds)."""
    line, fed, pos = [], [], 0
    for line_end, body_end, program in heredocs(text):
        line.append(text[pos:line_end + 1])
        fed.append((os.path.basename(program), text[line_end + 1:body_end]))
        pos = body_end
    line.append(text[pos:])
    return "".join(line), fed


# Builtins that run their words, or the file they are handed, as shell.
RUNS_SHELL = {"eval", "source", "."}
# A command substitution written inside a word: `$( ... )` (one level of parentheses inside) or
# backticks. What is inside is a command line of its own.
SUBSTITUTION = re.compile(r"\$\(((?:[^()]|\([^()]*\))*)\)|`([^`]*)`")
NESTED = 4      # how deep a command line inside a command line is followed


def said(command: str, depth: int = 0):
    """Each stretch of a Bash command that can name a file by itself, home written out:

    - a word of the command line, a redirection's file, and the same inside a command substitution,
      a shell's `-c` string, `eval`, or a heredoc or here-string fed to a shell;
    - a string of code written into the command for an interpreter (`python3 -c`, `node -e`, a
      heredoc or a here-string fed to one), a line of a string that runs over lines, and a word of the
      code outside its strings (literals);
    - a line of a heredoc or here-string fed to anything else: text the program reads, which may
      list files (`xargs cat`, `while read f`).

    A sentence that mentions a path -- a message, a line of a note being written, a replacement
    string -- is one stretch that does not begin with the path, so the path in it names nothing
    (standing). A command line written as one string inside other code (`os.system("cat <path>")`)
    is such a sentence too, and is not read."""
    line, fed = split_heredocs(spell_home(command))

    def handed(tool: str, text: str):
        """What a program is handed to run, or to read."""
        if SHELL_CODE.fullmatch(tool) or tool in RUNS_SHELL:
            if depth < NESTED:
                yield from said(text, depth + 1)
        elif code_flags(tool):
            yield from (stretch for stretch, _ in literals(text))
        else:
            yield from text.splitlines()

    try:
        commands = list(simple_commands(line))
    except ValueError:
        # An unclosed quote: the words cannot be told from the sentences, so every run of the line
        # between spaces and quotes is taken as a word.
        yield from re.split(r"""[\s'"`]+""", line)
        commands = []
    for words, redirects, here in commands:
        yield from (target for _, target in redirects)
        rest = words
        while rest and (ASSIGNMENT.fullmatch(rest[0]) or os.path.basename(rest[0]) in RUNS_NEXT):
            rest = rest[1:]
        tool = os.path.basename(rest[0]) if rest else ""
        shell, flags = bool(SHELL_CODE.fullmatch(tool)), code_flags(tool)
        first = len(words) - len(rest) + 1      # where the tool's own arguments begin
        code = False
        for at, word in enumerate(words):
            if code:                            # the code after `-c` / `-e`: read as what it is
                yield from handed(tool, word)
            else:
                yield word
                for m in SUBSTITUTION.finditer(word) if depth < NESTED else []:
                    yield from said(m.group(1) or m.group(2) or "", depth + 1)
            code = not code and at >= first and (word in flags or (shell and bool(re.fullmatch(r"-[A-Za-z]*c", word))))
        if tool == "eval" and depth < NESTED:
            yield from said(" ".join(rest[1:]), depth + 1)
        if here is not None:
            yield from handed(tool, here)
    for program, body in fed:
        yield from handed(program, body)


# How many of the files a glob matches are looked at (a pattern such as `/*/*/*` matches a disk).
GLOB_MATCHES = 64


def mentioned_paths(command: str, areas) -> list[Path]:
    """Area paths a Bash command names standing by themselves (said, standing): spelled with ~,
    $HOME or absolute, through a shortcut symlink whose target is inside an area, or by a glob
    that matches one (`ls ~/or*` names ~/org)."""
    found = []
    for stretch in said(command):
        for name in standing(stretch):
            try:
                matches = list(itertools.islice(glob.iglob(name), GLOB_MATCHES)) if GLOB.search(name) else []
                paths = [real(match) for match in [name, *matches]]
            except (OSError, ValueError, re.error):
                continue
            found += [path for path in paths if area_of(path, areas)]
    return found


# A command that says whether a path exists and what it is, never what it holds, reads
# nothing when it runs alone: one command, each argument taken literally.
JOINS = re.compile(r"[;&|<>()`\n\r]")      # a second command, pipe, redirect, subshell, substitution
EXPANDS = re.compile(r"[*?\[\]{}$]")       # a glob, brace expansion or variable turns into other paths
ATTRIBUTES_ONLY = {"test", "stat", "realpath", "readlink"}
LS_FLAGS = re.compile(r"-[dlaAhFG1]+|--directory")


def ls_names_only(args: list[str]) -> bool:
    """`ls` prints what a folder holds unless -d makes it print the named paths themselves."""
    flags = [a for a in args if a.startswith("-")]
    return (all(LS_FLAGS.fullmatch(f) for f in flags)
            and any(f == "--directory" or (not f.startswith("--") and "d" in f) for f in flags))


def path_only(command: str) -> bool:
    """True when the command only checks the paths it names (see ATTRIBUTES_ONLY and ls -d).
    Any doubt is False, and then a named area path marks the session."""
    text = spell_home(command)
    if JOINS.search(text):
        return False
    try:
        words = shlex.split(text)
    except ValueError:
        return False
    if words[:1] == ["["]:                     # `[ ... ]` is `test ...`
        if words[-1] != "]":
            return False
        words = ["test", *words[1:-1]]
    if not words or any(EXPANDS.search(a) for a in words[1:]):
        return False
    name, args = words[0], words[1:]
    return name in ATTRIBUTES_ONLY or (name == "ls" and ls_names_only(args))


# Commands that write the files they name, those that remove them, and programs that run code
# written into the command line.
CREATES = {"tee", "touch", "truncate"}
COPIES = {"cp", "mv", "install", "ln", "gcp", "gmv"}
MOVES = {"mv", "gmv"}
REMOVES = {"rm", "unlink", "rmdir", "shred", "trash"}
IN_PLACE = {"sed", "gsed", "perl"}
SHELL_CODE = re.compile(r"(?:ba|z|da|k)?sh")
# The option that hands each interpreter its code.
CODE_FLAGS = {"python": {"-c"}, "node": {"-e", "--eval", "-p", "--print"}, "perl": {"-e", "-E"},
              "ruby": {"-e"}, "bun": {"-e", "--eval"}, "php": {"-r"}, "osascript": {"-e"}}
# What stands before a command and runs it (`sudo tee f`), and a variable set for it (`A=1 cp a b`).
RUNS_NEXT = {"sudo", "env", "command", "exec", "builtin", "nohup", "nice", "time", "caffeinate"}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*")
# Builtins that set the variables written after them, a variable as a word spells it (`$D`, `${D}`),
# and what makes a value one this command line cannot know.
DECLARES = {"export", "local", "declare", "typeset", "readonly"}
VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
UNKNOWN = re.compile(r"[$`]")
# A string of inline code that may be a relative path: one word, with no quote inside.
CODE_WORD = re.compile(r"""[^'"`\s]+""")
# A media type (`application/json`, the value of a header): one of the registered top-level types
# and a subtype (RFC 6838). It names a file only where a folder of that first name is there to hold it.
MEDIA_TYPE = re.compile(r"(?:application|audio|example|font|haptics|image|message|model|multipart|text|video)"
                        r"/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*")


def code_flags(tool: str) -> set[str]:
    name = "python" if tool.startswith("python") else tool
    return CODE_FLAGS.get(name, set())


def code_paths(code: str, cwd: str) -> list[str]:
    """Every path inline code names (literals): an absolute or home path that stands by itself
    (standing), and a whole string that reads as a relative path (one word that holds a `/`, ends
    in an extension, or names something that exists in the command's folder). Whether the code
    reads or writes it cannot be told. A word quoted inside a longer string is that string's text,
    and a media type is a path only when its first name is a folder of the command's folder."""
    found = []
    for text, whole in literals(code):
        found += standing(text)
        if not whole or text.startswith("/") or "://" in text or not text.strip(".") or not CODE_WORD.fullmatch(text):
            continue
        if MEDIA_TYPE.fullmatch(text) and not (Path(cwd) / text.split("/")[0]).is_dir():
            continue
        if "/" in text or re.search(r"\.\w{1,8}$", text) or (Path(cwd) / text).exists():
            found.append(text)
    return found


class Standing:
    """Where a command line stands as it is read in order: `cd`, `pushd` / `popd` move it, and a
    `( ... )` subshell gives the place back when it closes.

    The writes (named), the sends (sends_of) and the recursive reads (recursive_reads) all follow it,
    so a relative name is judged from the same folder by all three."""

    def __init__(self, cwd: str, *, unknown_stays: bool = True) -> None:
        self.here = self.previous = str(real(cwd))
        self.dirs: list[str] = []
        self._subshells: list[tuple[str, str, list[str], object]] = []
        self._unknown_stays = unknown_stays

    def move(self, tool: str, args: list[str]) -> bool:
        """Follow `cd` / `pushd` / `popd` (= True when the command was one of them).

        Where `cd $X` goes cannot be read: with `unknown_stays` the command line is judged where it stood,
        without it the word is taken as written."""
        if tool in ("cd", "pushd"):
            target = next((a for a in args if not a.startswith("-") or a == "-"), None)
            if self._unknown_stays and target is not None and UNKNOWN.search(target):
                return True
            if tool == "pushd":
                self.dirs.append(self.here)
            new = self.previous if target == "-" else str(real(target or str(Path.home()), self.here))
            self.previous, self.here = self.here, new
            return True
        if tool == "popd":
            if self.dirs:
                self.previous, self.here = self.here, self.dirs.pop()
            return True
        return False

    def open(self, carried: object = None) -> None:
        """A subshell opens: remember the place, and whatever else the reader keeps per subshell."""
        self._subshells.append((self.here, self.previous, list(self.dirs), carried))

    def close(self) -> object:
        """A subshell closes: the place it opened at comes back, with what was carried (= None when none is open)."""
        if not self._subshells:
            return None
        self.here, self.previous, self.dirs, carried = self._subshells.pop()
        return carried


def named(command: str, cwd: str) -> tuple[list[Path], list[Path]]:
    """(paths a Bash command names as a place it writes, paths it names as removed).

    Written: a redirection's target (`>`, `>>`), the files of tee / touch / truncate, the
    destination of cp / mv / install / ln, the existing files sed -i edits, dd's of=, and every
    path that code written into the command names (`python3 -c`, `node -e`, a heredoc or a
    here-string fed to an interpreter; see code_paths), relative ones included: code that reads a
    file cannot be told apart from code that writes it. A shell's `-c` string, and a heredoc fed to
    a shell, is a command line of its own, read the same way. Removed: the files of rm / unlink / rmdir /
    shred, and what mv moves away. A glob stands for the files it matches now. What stands
    before a command (`sudo`, `env`, a variable) is skipped. A script run from a file is not
    read, and neither is a heredoc's body fed to anything else (it is text, not commands).

    A relative name is a file of the folder the command stands in when it reaches that word: `cd`,
    `pushd` / `popd` move it and a subshell gives the place back. A variable the command line set to
    a literal before (`D=/a/b; echo x > $D/out`) is written out. Where neither can be read (`cd $X`,
    a value from a substitution), the name is judged as it was written, from where the command stood."""
    line, fed = split_heredocs(spell_home(command))
    try:
        commands = list(stepped_commands(line))
    except ValueError:
        commands = []
    written: list[tuple[str, str]] = []     # (the name as written, the folder the command stood in)
    removed: list[tuple[str, str]] = []
    found: tuple[list[Path], list[Path]] = ([], [])
    standing = Standing(cwd)
    values: dict[str, str] = {}

    def filled(word: str) -> str:
        """The word with the variables this command line set to a literal written out."""
        return VARIABLE.sub(lambda m: values.get(m.group(1) or m.group(2), m.group(0)), word)

    def run(tool: str, code: str, base: str) -> None:
        """Code handed to a program that runs it."""
        if SHELL_CODE.fullmatch(tool):
            inner = named(code, base)
            found[0].extend(inner[0])
            found[1].extend(inner[1])
        elif code_flags(tool):
            written.extend((path, base) for path in code_paths(code, base))

    def one(words: list[str], stdin: str | None) -> None:
        if words and all(ASSIGNMENT.fullmatch(w) for w in words[words[0] in DECLARES:]):
            # `D=/a/b` alone on its command (or after export / local): later words may spell it $D.
            # A value this line cannot know (a substitution, a variable set elsewhere) is forgotten.
            for word in words[words[0] in DECLARES:]:
                name, _, value = word.partition("=")
                value = filled(value)
                if UNKNOWN.search(value):
                    values.pop(name, None)
                else:
                    values[name] = value
            return
        while words and (ASSIGNMENT.fullmatch(words[0]) or os.path.basename(words[0]) in RUNS_NEXT):
            wrapper = not ASSIGNMENT.fullmatch(words[0])
            words = words[1:]
            while wrapper and words and (words[0].startswith("-") or ASSIGNMENT.fullmatch(words[0])):
                words = words[1:]
        if not words:
            return
        tool, args = os.path.basename(words[0]), [filled(a) for a in words[1:]]
        if standing.move(tool, args):
            return
        here = standing.here
        paths = [a for a in args if not a.startswith("-")]
        if tool in CREATES:
            written.extend((p, here) for p in paths)
        elif tool in COPIES and len(paths) >= 2:
            written.append((paths[-1], here))
            if tool in MOVES:
                removed.extend((p, here) for p in paths[:-1])
        elif tool in REMOVES:
            removed.extend((p, here) for p in paths)
        elif tool in IN_PLACE and any(a.startswith(("-i", "--in-place")) for a in args):
            written.extend((p, here) for p in paths if Path(real(p, here)).is_file())
        elif tool == "dd":
            written.extend((a[3:], here) for a in args if a.startswith("of="))
        shell = bool(SHELL_CODE.fullmatch(tool))
        flags = code_flags(tool)
        for flag, code in zip(args, args[1:]):
            # a shell takes its command line after -c, alone or among other letters (`-lc`)
            if flag in flags or (shell and re.fullmatch(r"-[A-Za-z]*c", flag)):
                run(tool, code, here)
        if stdin is not None:
            run(tool, stdin, here)

    # The command line is read in order, following where it stands, as sends_of does for a send:
    # `cd`, `pushd` / `popd` move it and a `( ... )` subshell gives the place back, so
    # `cd /a && echo x > out` writes /a/out and `(cd /a); echo x > out` writes where it started.
    # A heredoc's body is read from where the command it feeds stands (`cd /a && python3 - <<EOF`
    # runs the body in /a), in the order the heredocs open. One the line could not be read for is
    # read from where the command started.
    waiting = list(fed)
    for words, redirects, stdin, ended_by in commands:
        written.extend((filled(target), standing.here) for operator, target in redirects if ">" in operator)
        one(words, stdin)
        for operator, _ in redirects:
            if operator in ("<<", "<<-") and waiting:
                run(*waiting.pop(0), standing.here)
        if ended_by == "(":
            standing.open(dict(values))
        elif ended_by == ")":
            carried = standing.close()
            if carried is not None:
                values = carried
    for program, body in waiting:
        run(program, body, str(real(cwd)))

    def spelled(names: list[tuple[str, str]]) -> list[Path]:
        out = []
        for name, stood in names:
            if not name or name in ("-", "/dev/null"):
                continue
            base = os.path.expanduser(name)
            base = base if os.path.isabs(base) else os.path.join(stood, base)
            out.extend(real(m) for m in (glob.glob(base) if GLOB.search(name) else []) or [base])
        return out

    return spelled(written) + found[0], spelled(removed) + found[1]


def write_targets(command: str, cwd: str) -> list[Path]:
    """Paths a Bash command names as a place it writes (see named)."""
    return named(command, cwd)[0]


# What the guard judges from: the whole of its settings folder, and a session's transcript (an order
# for a send is read from it). They change on the operator's yes (`approval`), a transcript never. An
# agent that could write them on its own would draw an area around what it wants to send, call a
# phrase fine to send, or make an order itself.
SETTINGS_WHY = "what the guard lets through is judged from it"
TRANSCRIPT_WHY = "an order for a send is judged from it"
TRANSCRIPT = re.compile(r"\.claude[^/]*/projects/.+\.jsonl", re.I)


def same_file(a: Path, b: Path) -> bool:
    """One file under two spellings: a link, or another case on a file system that folds it."""
    try:
        if os.path.samefile(a, b):
            return True
    except OSError:
        pass
    return str(a).casefold() == str(b).casefold()


def in_settings(path: Path) -> bool:
    """The guard's settings folder or anything in it, under any spelling: through a link, or in
    another case on a file system that folds it."""
    folders = {str(f).casefold() for f in (CONFIG, real(CONFIG))}
    for spelled in {str(path).casefold(), str(real(path)).casefold()}:
        if any(spelled == folder or spelled.startswith(folder + os.sep) for folder in folders):
            return True
    return False


def settings_name(path: Path) -> str | None:
    """The path inside the settings folder (`patterns/client.txt`), folded to lower case, or None."""
    for folder in {str(CONFIG), str(real(CONFIG))}:
        for spelled in {str(path), str(real(path))}:
            if spelled.casefold().startswith(folder.casefold() + os.sep):
                return guard_places.flat_name(spelled[len(folder) + 1:].casefold())
    return None


def granted(path: Path, marks: set[str]) -> bool:
    """Whether the operator's grant lets an agent with these marks write this path of the settings.

    A line is `<setting>` (a name, a glob, a folder) or `<setting> <area>...`: the first a session
    that has read inside no area writes, the second also a session whose every mark is one of the
    areas named (a glob matches) or lies within one of them (`areas/company/ company hub`: the
    company's own settings, written by the session that gathers the company)."""
    name = settings_name(path)
    if not name or name.split(os.sep)[0] in {n.casefold() for n in OPERATOR_ONLY}:
        return False
    try:
        lines = GRANT.read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    areas = load_areas() if marks else []
    for line in lines:
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        entry = words[0].rstrip("/").casefold()
        if not (entry == "*" or fnmatch.fnmatchcase(name, entry) or name.startswith(entry + os.sep)):
            continue
        owners = words[1:]
        if not marks or (owners and all(
                any(fnmatch.fnmatchcase(m, o) or outer(o, m, areas) for o in owners) for m in marks)):
            return True
    return False


def kept(path: Path, transcript: str | None, marks: set[str] | None = None) -> tuple[str, str] | None:
    """(what a path is, why the agent may not write it), or None. `marks` = the areas the session
    has read inside, this call included (None: not known, and no grant applies)."""
    if in_settings(path):
        if marks is not None and granted(path, marks):
            return None
        if marks and settings_name(path) and granted(path, set()):
            return (f"the guard's settings ({path.name})",
                    f"{SETTINGS_WHY}, and the operator hands it only to a session that has read inside no area "
                    f"(this one has read inside {', '.join(sorted(marks))})")
        return f"the guard's settings ({path.name})", SETTINGS_WHY
    if transcript and same_file(path, real(transcript)):
        return "the session's transcript", TRANSCRIPT_WHY
    for home in {Path.home(), real(Path.home())}:
        if home in path.parents and TRANSCRIPT.fullmatch(path.relative_to(home).as_posix()):
            return "a session's transcript", TRANSCRIPT_WHY
    return None


def kept_by(command: str, cwd: str, transcript: str | None,
            marks: set[str] | None = None) -> tuple[str, str] | None:
    """What a Bash command writes or removes that the agent may not (and why), or None. Removing
    a setting counts: with no destinations.txt a destination held to an order is undeclared, and
    with no areas.txt nothing is an area."""
    written, removed = named(command, cwd)
    for path in written + removed:
        if what := kept(path, transcript, marks):
            return what
    for path in removed:
        if path in real(CONFIG).parents or path in CONFIG.parents:
            return "the folder holding the guard's settings", SETTINGS_WHY
    return None


def bash_marks(command: str, cwd: str, areas) -> list[Path]:
    """What a Bash command reads from: its folder always, the area paths it names unless
    it only checks them, and the roots of the areas inside a folder it reads recursively."""
    named = [] if path_only(command) else mentioned_paths(command, areas)
    return [*named, real(cwd), *roots_under(recursive_reads(command, cwd), areas)]


# The programs that read the contents of every file under the folders they are given. A program
# that lists names only (`ls -R`, `tree`, `du`, a `find` that runs nothing) reads no contents.
GREPS = {"grep", "egrep", "fgrep", "ggrep"}
ALWAYS_RECURSIVE = {"rg", "ag", "ack"}
RECURSIVE_COPIES = {"cp", "rsync", "scp", "zip", "tar", "ditto"}
# Options that take the next word as their value, by program: that word is no folder to read.
VALUED = {
    "grep": {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "--regexp", "--file", "--max-count",
             "--after-context", "--before-context", "--context", "--directories", "--devices"},
    "rg": {"-e", "-f", "-g", "-t", "-T", "-m", "-A", "-B", "-C", "-j", "-M", "-E", "--regexp", "--file",
           "--glob", "--iglob", "--type", "--type-not", "--max-count", "--threads", "--encoding"},
    "find": set(),
    "copy": {"-e", "-f", "-C", "-T", "-x", "--exclude", "--include", "--files-from", "--rsh"},
}
FIND_RUNS = {"-exec", "-execdir", "-ok", "-okdir"}


def _grep_recursive(words: list[str]) -> bool:
    for at, word in enumerate(words):
        if word in ("--recursive", "--dereference-recursive", "--directories=recurse", "--recurse"):
            return True
        if word in ("-d", "--directories") and at + 1 < len(words) and words[at + 1] == "recurse":
            return True
        if re.fullmatch(r"-[A-Za-z]*[rR][A-Za-z]*", word):
            return True
    return False


def _copy_recursive(tool: str, words: list[str]) -> bool:
    if tool in ("rsync", "ditto"):
        return True
    if tool == "tar":
        mode = next((w for w in words if not w.startswith("--")), "")
        return "c" in mode.lstrip("-") or "r" in mode.lstrip("-") or "u" in mode.lstrip("-")
    return any(re.fullmatch(r"-[A-Za-z]*[rRa][A-Za-z]*", w) or w in ("--recursive", "--archive") for w in words)


def _operands(words: list[str], valued: set[str]) -> list[str]:
    """The words of a program's arguments that are no option and no option's value (`--` ends options)."""
    found, skip, ended = [], False, False
    for word in words:
        if skip:
            skip = False
        elif ended or not word.startswith("-") or word == "-":
            found.append(word)
        elif word == "--":
            ended = True
        elif word in valued:
            skip = True
    return found


def _excluded_dirs(words: list[str]) -> list[str]:
    """The folder names `grep --exclude-dir` (and rg's `--glob '!<dir>'`) keeps out of the walk."""
    names = []
    for at, word in enumerate(words):
        if word.startswith("--exclude-dir="):
            names.append(word.split("=", 1)[1])
        elif word == "--exclude-dir" and at + 1 < len(words):
            names.append(words[at + 1])
    return [n.strip("'\"").rstrip("/") for n in names if n]


def recursive_reads(command: str, cwd: str, depth: int = 0) -> list[tuple[Path, list[str]]]:
    """The folders a Bash command reads every file under, each with the folder names its walk
    leaves out: what a recursive grep, rg, a `find` that runs a command on what it finds (or hands
    it to xargs), or a recursive copy is given, and the command's folder when it is given nothing.
    A shell's `-c` string is followed the same way. A relative folder is the one the command stands
    in when it reaches it (= `cd /b && grep -r x .` reads /b; see Standing)."""
    line, _ = split_heredocs(spell_home(command))
    try:
        steps = list(stepped_commands(line))
    except ValueError:
        return []
    found: list[tuple[Path, list[str]]] = []
    standing = Standing(cwd)
    for index, (words, _, _, ended_by) in enumerate(steps):
        found += _walked(words, steps, index, standing, depth)
        if ended_by == "(":
            standing.open()
        elif ended_by == ")":
            standing.close()
    return found


def _walked(words: list[str], steps: list, index: int, standing: Standing, depth: int) -> list[tuple[Path, list[str]]]:
    """The folders one command of a command line reads every file under (see recursive_reads)."""
    rest = words
    while rest and (ASSIGNMENT.fullmatch(rest[0]) or os.path.basename(rest[0]) in RUNS_NEXT):
        rest = rest[1:]
    if not rest:
        return []
    tool, args = os.path.basename(rest[0]), rest[1:]
    if standing.move(tool, args):
        return []
    cwd = standing.here
    ended_by = steps[index][3]
    found: list[tuple[Path, list[str]]] = []
    if SHELL_CODE.fullmatch(tool) and depth < NESTED:
        for at, word in enumerate(args[:-1]):
            if re.fullmatch(r"-[A-Za-z]*c", word):
                found += recursive_reads(args[at + 1], cwd, depth + 1)
                break
        return found
    given: list[str] | None = None
    if tool in GREPS and _grep_recursive(args):
        operands = _operands(args, VALUED["grep"])
        pattern_given = any(w in ("-e", "-f", "--regexp", "--file") or w.startswith(("--regexp=", "--file="))
                            for w in args)
        given = operands if pattern_given else operands[1:]
    elif tool in ALWAYS_RECURSIVE:
        operands = _operands(args, VALUED["rg"])
        pattern_given = any(w in ("-e", "-f", "--regexp", "--file") for w in args)
        given = operands if pattern_given else operands[1:]
    elif tool == "find":
        runs = any(w in FIND_RUNS for w in args)
        piped = ended_by == "|" and index + 1 < len(steps) and steps[index + 1][0][:1] == ["xargs"]
        if runs or piped:
            given = list(itertools.takewhile(lambda w: not w.startswith(("-", "(", "!")), args))
    elif tool in RECURSIVE_COPIES and _copy_recursive(tool, args):
        operands = _operands(args, VALUED["copy"])
        # The last word of cp / rsync / scp / ditto is where it copies to. An archive's name and
        # tar's mode word are no folders, so the folders among tar's and zip's words are what it reads.
        given = operands[:-1] if tool in ("cp", "rsync", "scp", "ditto") else operands
    if given is None:
        return found
    excluded = _excluded_dirs(args)
    for name in given or ["."]:
        folder = real(name, cwd)
        if folder.is_dir():
            found.append((folder, excluded))
    return found


def roots_under(folders: list[tuple[Path, list[str]]], areas) -> list[Path]:
    """The roots of the areas that lie inside the folders given, past the folder names each walk
    leaves out (an area the folder itself is inside is named by the folder already)."""
    found = []
    for folder, excluded in folders:
        for name, root in areas:
            if name in (EXEMPT, NO_AREA) or folder not in root.parents:
                continue
            between = root.relative_to(folder).parts
            if not any(fnmatch.fnmatchcase(part, pattern) for part in between for pattern in excluded):
                found.append(root)
    return found


def remote_marks(command: str, cwd: str) -> set[str]:
    """The areas of the folders on other machines a command names (scp / rsync / ssh): naming one
    marks the session as naming a folder here does."""
    try:
        roots = corpus_module().load_remote_areas(AREAS)
    except Exception:  # noqa: BLE001 — a broken line refuses every send in send-scan; here it marks nothing
        return set()
    if not roots:
        return set()
    found = outgoing_module().remote_paths(command, cwd, SEND_SCAN)
    return {a for host, path in found if (a := corpus_module().remote_area(host, path, roots))}


def upto_break(words: list[str]) -> list[str]:
    breaks = outgoing_module().SHELL_BREAK
    return words[:next((i for i, w in enumerate(words) if w in breaks), len(words))]


# git options that take a value before the subcommand (`git -C dir -c k=v push`).
GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
SHELLS = {"bash", "sh", "zsh", "dash"}
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}", "time"}
WRAPPERS = {"sudo", "env", "command", "exec", "builtin", "nohup", "nice", "caffeinate", "xargs"}


def sends_of(command: str, cwd: str) -> list[tuple[Path, list[str]]]:
    """Every send in a command (git commit / push, a sending gh call) as
    (repository it runs in, arguments naming its destination for corpus-scan).
    A commit stays local, so its arguments are empty.

    The command is read in order, following where it stands: `cd`, `pushd` / `popd` and a
    `( ... )` subshell move it, and each git runs where the command stands at that point, moved
    again by its own `-C`. So `cd a; cd b && git push` pushes from b, and `(cd a); git commit`
    commits where it started. A shell's -c string is read the same way from where it runs."""
    try:
        words = shell_words(command)
    except ValueError:
        return []
    breaks = outgoing_module().SHELL_BREAK
    found: list[tuple[Path, list[str]]] = []
    standing = Standing(cwd, unknown_stays=False)

    def run(argv: list[str]) -> None:
        # Skip what stands before the command: shell keywords (`do git push`), assignments
        # (`FOO=1 git ...`) and commands that run the next one (`sudo`, `env`, `nohup`, ...).
        while argv:
            if argv[0] in KEYWORDS or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", argv[0]):
                argv = argv[1:]
            elif os.path.basename(argv[0]) in WRAPPERS:
                argv = argv[1:]
                while argv and argv[0].startswith("-"):
                    argv = argv[1:]
            else:
                break
        if not argv:
            return
        name, args = os.path.basename(argv[0]), argv[1:]
        if standing.move(name, args):
            return
        here = Path(standing.here)
        if name in SHELLS and "-c" in args[:-1]:
            found.extend(sends_of(args[args.index("-c") + 1], str(here)))
        elif name == "eval" and args:
            found.extend(sends_of(" ".join(args), str(here)))
        elif name == "git":
            repo, i = here, 0
            while i < len(args) and args[i].startswith("-"):
                flag, eq, value = args[i].partition("=")
                if flag in GIT_VALUED and not eq:
                    value, i = (args[i + 1] if i + 1 < len(args) else ""), i + 1
                if flag == "-C" and value:
                    repo = real(value, str(repo))
                elif flag == "--work-tree" and value:
                    repo = real(value, str(here))
                i += 1
            sub, rest = (args[i], args[i + 1:]) if i < len(args) else ("", [])
            if sub == "commit":
                found.append((repo, []))
            elif sub == "push":
                named = next((a for a in rest if not a.startswith("-")), None)
                found.append((repo, ["--dest", push_url(repo, named)]))
        elif name == "gh":
            rest = [a for a in args if not a.startswith("-")]
            if rest[:1] == ["api"]:   # GET by default; it sends only with a body or a method
                sends = any(re.match(r"-[XfF]|--(method|field|raw-field|input)(=|$)", a) for a in args)
            else:
                sends = len(rest) >= 2 and rest[0] != "search" and rest[1] not in GH_READONLY
            if sends:
                found.append((here, ["--gh-argv-inline", *args]))

    def pieces(word: str) -> list[str]:
        """Control operators glued together by the lexer (`);` `)&&`) as separate words."""
        if not word or word in breaks or not set(word) <= set(";&|()"):
            return [word]
        out, rest = [], word
        while rest:
            op = next((o for o in ("&&", "||", ";;", "|&") if rest.startswith(o)), rest[0])
            out.append(op)
            rest = rest[len(op):]
        return out

    current: list[str] = []
    for w in [p for word in words for p in pieces(word)] + [";"]:
        if w not in breaks:
            current.append(w)
            continue
        run(current)
        current = []
        if w == "(":
            standing.open()
        elif w == ")":
            standing.close()
    return found


def push_url(repo: Path, named: str | None) -> str:
    """Where `git push` sends: a named remote's push URL, else the upstream, else origin."""
    if named and (":" in named or "/" in named):
        return named
    import subprocess

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout.strip()
    branch = "" if named else git("branch", "--show-current")
    name = named or git("config", f"branch.{branch}.pushRemote") or git("config", "remote.pushDefault") \
        or git("config", f"branch.{branch}.remote") or "origin"
    return git("remote", "get-url", "--push", name)


def destination(target: Path, dest_args: list[str]) -> tuple[Path | None, str | None]:
    """(where a send lands, why that is only a guess). None = outside every area (a public
    repository, say). When the private-document scan cannot answer -- including a time-out, not
    that it found the destination outside every area -- the sending repository stands in, and the
    second element says so (so a deny a guess like this leads to can tell the operator it was one,
    not a real determination)."""
    if not dest_args:
        return target, None
    import subprocess
    import tempfile   # loaded only for a push or a gh send: most hook calls never get here
    with tempfile.NamedTemporaryFile() as argv_file:
        args = dest_args
        if dest_args[0] == "--gh-argv-inline":
            argv_file.write(b"".join(a.encode() + b"\0" for a in dest_args[1:]))
            argv_file.flush()
            args = ["--gh-argv", argv_file.name]
        try:
            r = subprocess.run(["python3", str(CORPUS), "--where", "--repo", str(target), *args],
                               capture_output=True, text=True, timeout=60,
                               env=dict(os.environ))
        except subprocess.TimeoutExpired:
            return target, "where the destination sits did not finish within 60s, not that it was found outside every area"
        except OSError:
            return target, None
    out = r.stdout.strip().splitlines()[-1:] if r.returncode == 0 else []
    if not out:
        return target, None
    return (None, None) if out[0] == "OUTSIDE" else (real(out[0]), None)


def load_state(session: str) -> dict:
    """A session's marks and the pages its browser tabs were opened at:
    {"areas": [...], "tabs": {tabId: host}}. A bare list is the older file (marks only)."""
    try:
        data = json.loads((STATE / f"{session}.json").read_text())
    except (OSError, ValueError):
        data = []
    if isinstance(data, list):
        return {"areas": sorted(data), "tabs": {}}
    return {"areas": sorted(data.get("areas") or []), "tabs": dict(data.get("tabs") or {})}


def save_state(session: str, state: dict) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / f"{session}.json").write_text(json.dumps(state))


def outer(name: str, inner: str, areas) -> bool:
    """A root of `name` holds a root of `inner` (the company around one of its clients)."""
    return any(n == name and m == inner and r != i and r in i.parents for n, r in areas for m, i in areas)


def carried(target: Path, areas) -> list[str]:
    """The names (or globs) of the areas whose text a repository at this place may hold: what the
    `_carries` lines give the place's own areas, the innermost ones holding it."""
    held = {n for n, _ in areas if n not in (EXEMPT, NO_AREA) and inside(target, n, areas)}
    own = {n for n in held if not any(n != m and outer(n, m, areas) for m in held)}
    lines = load_carries()
    return [pattern for name in sorted(own) for pattern in lines.get(name, ())]


def allowed(target: Path, marks: set[str], areas, held_here: list[str] | tuple = ()) -> bool:
    """Whether a session with these marks may write or send to a place it resolved to (a public or
    personal destination is None and never reaches here). A place in no area passes: the guard stops
    what it knows leaves an area, not what is unlisted. A place in areas passes when it is inside
    every mark and in no other area, but an area around a mark (the company around its client).
    A mark that `held_here` names is one the place may hold the text of (see carried): it does not
    count against the place."""
    if area_of(target, areas) == EXEMPT:
        return True
    held = {n for n, _ in areas if n not in (EXEMPT, NO_AREA) and inside(target, n, areas)}
    if not held:
        return True
    if held_here:
        import fnmatch   # loaded where it is used: most calls carry nothing
        marks = {m for m in marks if not any(fnmatch.fnmatchcase(m, pattern) for pattern in held_here)}
        if not marks:
            return True
    return (all(inside(target, m, areas) for m in marks)
            and all(h in marks or any(outer(h, m, areas) for m in marks) for h in held))


HANDOFF_VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
WRITTEN_TEXT = {"Write": ("content",), "Edit": ("new_string",), "NotebookEdit": ("new_source",)}


@functools.cache
def handoff_folders() -> tuple[Path, ...]:
    """This session's handoff folders: the lines of handoff.txt, `~` and variables expanded from the
    session's environment. A line naming an unset or empty variable, or climbing with `..`, gives none."""
    try:
        lines = HANDOFF.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ()
    out = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        values = [os.environ.get(a or b, "") for a, b in HANDOFF_VARIABLE.findall(line)]
        if not all(values) or any(".." in Path(v).parts for v in values):
            continue
        path = HANDOFF_VARIABLE.sub(lambda m: os.environ[m.group(1) or m.group(2)], line)
        out.append(real(os.path.expanduser(path)))
    return tuple(out)


def handoff_of(target: Path) -> Path | None:
    return next((f for f in handoff_folders() if target == f or f in target.parents), None)


def handoff_refusal(folder: Path, text: str, areas) -> str | None:
    """Why this text may not go into the handoff folder (a copy of a private document of an area the
    folder is outside of), or None. Judged as a send into the folder's innermost areas."""
    held = {n for n, _ in areas if n not in (EXEMPT, NO_AREA) and inside(folder, n, areas)}
    own = sorted(n for n in held if not any(n != m and outer(n, m, areas) for m in held))
    if not own or not text.strip():
        return None
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8",
                                     dir=os.environ.get("TMPDIR") or None) as fh:
        fh.write(text)
    try:
        r = subprocess.run(["python3", str(CORPUS), "--dest-area", ",".join(own), "--text", fh.name],
                           capture_output=True, text=True, timeout=180)
    except (subprocess.TimeoutExpired, OSError):
        return "the private-document scan could not run, so what it holds could not be judged"
    finally:
        os.unlink(fh.name)
    if r.returncode == 0:
        return None
    lines = r.stderr.strip().splitlines() or r.stdout.strip().splitlines() or ["the private-document scan refused it"]
    return lines[-1].removeprefix("corpus-scan: ") + "".join(f"\n  {x.strip()}" for x in lines if x.startswith("    "))


def written_text(tool: str, args: dict) -> str:
    if tool == "MultiEdit":
        return "\n".join(str(e.get("new_string") or "") for e in args.get("edits") or [] if isinstance(e, dict))
    return "\n".join(str(args.get(k) or "") for k in WRITTEN_TEXT.get(tool, ()))


def has_head(repo: Path) -> bool:
    import subprocess
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "-q", "HEAD"],
                          capture_output=True).returncode == 0


def handoff_commit_refusal(repo: Path, areas) -> str | None:
    """Why a commit in this repository is not a handoff (a change outside every handoff folder, or a
    changed text the scan refuses), or None. Every change the commit could take is read: staged,
    unstaged and untracked."""
    import subprocess
    top = repo_root(repo)
    if top is None:
        return "it is not a repository"
    r = subprocess.run(["git", "-C", str(top), "status", "--porcelain", "-z", "--untracked-files=all"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return "git status failed"
    entries = [e for e in r.stdout.split("\0") if e]
    paths, i = [], 0
    while i < len(entries):
        code, name = entries[i][:2], entries[i][3:]
        paths.append(top / name)
        if "R" in code or "C" in code:   # a rename or copy names its source next
            i += 1
            paths.append(top / entries[i])
        i += 1
    folders: dict[Path, list[Path]] = {}
    for path in paths:
        folder = handoff_of(real(path))
        if folder is None:
            return f"{path} is outside every handoff folder"
        folders.setdefault(folder, []).append(path)
    for folder, changed in folders.items():
        diff = subprocess.run(["git", "-C", str(top), "diff", "HEAD", "--", *map(str, changed)],
                              capture_output=True, text=True).stdout if has_head(top) else ""
        text = "\n".join(line[1:] for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++"))
        for path in changed:
            tracked = subprocess.run(["git", "-C", str(top), "ls-files", "--error-unmatch", str(path)],
                                     capture_output=True).returncode == 0
            if path.is_file() and not tracked:
                text += "\n" + path.read_text(encoding="utf-8", errors="replace")
        if why := handoff_refusal(folder, text, areas):
            return why
    return None


def publishes_outside(place: Path, areas) -> bool:
    """Whether the repository at this place, in no area, publishes outside every area: a public
    repository, or one `destinations.txt` declares outside."""
    root = repo_root(place)
    if root is None or area_of(place, areas) is not None:
        return False
    url = push_url(root, None)
    return bool(url) and destination(root, ["--dest", url])[0] is None


def may_write(target: Path, marks: set[str], areas) -> bool:
    """A marked session may write a file inside a git repository when the repository is allowed
    where it sits, and -- for one in no area -- when what it pushes to is not outside every area
    (a public repository, or one declared outside such as a personal account's).

    A repository with no remote, in an area whose `_carries` line names other areas, may hold their
    text: a session that read them writes and commits there. It sends nothing anywhere, and what
    leaves it later (a push once it has a remote, a `gh` call, a message) is judged as before."""
    root = repo_root(target)
    if root is None:
        return True
    if not allowed(target, marks, areas):
        held_here = carried(target, areas)
        if not held_here or has_remote(root) or not allowed(target, marks, areas, held_here):
            return False
    return area_of(target, areas) is not None or not publishes_outside(target, areas)   # in an area, or the exempt notes


BYPASS_ENV = re.compile(r"(?<![\w-])(GH_GUARD_SKIP|GUARD_[A-Z_]+|ANON_WORDS_FILE|HUSKY"
                        r"|GIT_CONFIG_(?:PARAMETERS|COUNT|KEY_\d+|VALUE_\d+|GLOBAL|SYSTEM|NOSYSTEM))=")
GUARD_KEYS = re.compile(r"\b(core\.hookspath|guard\.scope|guard\.exemptprefix)\b", re.I)
GIT_VALUE_FLAGS = {"-m", "-F", "-c", "-C", "--message", "--file", "--author", "--date", "--fixup", "--squash",
                   "--reuse-message", "--reedit-message", "-t", "--template", "--cleanup", "--trailer"}


# `git config` reads with one of these, or with a key alone; it writes with one of the others,
# or with a key and a value. The options in CONFIG_TAKES_VALUE consume the next word.
CONFIG_READS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool",
                "--list", "-l", "get", "list"}
CONFIG_WRITES = {"--unset", "--unset-all", "--add", "--replace-all", "--rename-section", "--remove-section",
                 "--edit", "-e", "set", "unset", "rename-section", "remove-section", "edit"}
CONFIG_TAKES_VALUE = {"-f", "--file", "--blob", "--type", "--default", "--comment", "--value"}
CONFIG_UNSETS = {"--unset", "--unset-all", "unset"}
# Where a write lands other than the repository's own config: the machine's guard itself lives there.
CONFIG_ELSEWHERE = {"--global", "--system", "-f", "--file", "--blob"}
HOOKS_PATH = "core.hookspath"


def returns_to_global_hooks(flags: set[str], positional: list[str]) -> bool:
    """Whether a `git config` takes a repository's own core.hooksPath away and nothing else, so the
    repository falls back to the machine's hooks: the guard covers it again."""
    verb = positional[:1]
    keys = positional[1:] if set(verb) & CONFIG_UNSETS else positional
    return bool((flags | set(verb)) & CONFIG_UNSETS) and not flags & CONFIG_ELSEWHERE \
        and bool(keys) and keys[0].casefold() == HOOKS_PATH


def config_writes_guard_key(command: str) -> bool:
    """True when any `git config` in the command writes core.hooksPath, guard.scope or
    guard.exemptPrefix. Each invocation is judged on its own words, so a read beside a write
    does not excuse the write. Taking a repository's own core.hooksPath away is no such write
    (`returns_to_global_hooks`)."""
    words = shell_words(command)
    start = 0
    for i, w in enumerate(words):
        if w in outgoing_module().SHELL_BREAK:
            start = i + 1
            continue
        if w != "config" or "git" not in words[start:i]:
            continue
        args = upto_break(words[i + 1:])
        if not any(GUARD_KEYS.search(a) for a in args):
            continue
        flags, positional, skip = set(), [], False
        for a in args:
            if skip:
                skip = False
            elif a in CONFIG_TAKES_VALUE:
                flags.add(a)
                skip = True
            elif a.startswith("-"):
                flags.add(a.split("=", 1)[0])
            else:
                positional.append(a)
        verb = positional[:1]
        if returns_to_global_hooks(flags, positional):
            continue
        if flags & CONFIG_WRITES or set(verb) & CONFIG_WRITES:
            return True
        if flags & CONFIG_READS or set(verb) & CONFIG_READS:
            continue
        if len(positional) >= 2:
            return True
    return False


def git_config(repo: Path, *args: str) -> str:
    import subprocess
    return subprocess.run(["git", "-C", str(repo), "config", *args], capture_output=True, text=True).stdout.strip()


def unguarded(repo: Path, scope: bool = True) -> str | None:
    """Why the git hooks do not reach this repository, or None (also when it is not a repository).
    `scope=False` leaves out the operator's own opt-outs (guard.scope, guard.exemptPrefix): they stand
    against the areas, and a machine with none has no area text to keep out of an exempt repository."""
    top = repo_root(repo)
    if top is None:
        return None
    if git_config(top, "--local", "--get", "core.hooksPath"):
        return "the repository overrides core.hooksPath (husky and the like switch the hooks off)"
    armed = git_config(top, "--global", "--get", "core.hooksPath")
    if not armed or not (real(armed, str(top)) / "pre-push").exists():
        return "no global core.hooksPath points at the guard hooks"
    # `--local` does not follow includes, and a worktree config or GIT_CONFIG_* sits outside it too:
    # what git will run is the value it resolves, and that has to be the global one.
    hooks = git_config(top, "--get", "core.hooksPath")
    if not hooks or real(hooks, str(top)) != real(armed, str(top)):
        return "core.hooksPath is set again past the global config (an include, a worktree config or the environment)"
    if not scope:
        return None
    if git_config(top, "--get", "guard.scope") == "exempt":
        return "guard.scope = exempt"
    prefix = git_config(top, "--get", "guard.exemptPrefix")
    if prefix and (top == real(prefix) or real(prefix) in top.parents):
        return "inside guard.exemptPrefix"
    return None


def has_remote(repo: Path) -> bool:
    """Whether the repository names any remote (a push needs one or a URL typed out)."""
    top = repo_root(repo)
    if top is None:
        return False
    import subprocess
    r = subprocess.run(["git", "-C", str(top), "remote"], capture_output=True, text=True)
    return r.returncode != 0 or bool(r.stdout.strip())


def marks_names() -> set[str]:
    """How a path to the folder of marks may be spelled: the usual tails, and this machine's folder itself."""
    return {".cache/area-guard", "state/guard/marks", str(STATE), str(real(STATE))}


MARKS_REWRITE = "removes or rewrites the entry guard's marks"


def setting_area(path: Path) -> str | None:
    """The area a path of the guard's settings belongs to (`areas/<area>/...`), or None."""
    name = settings_name(path)
    parts = name.split(os.sep) if name else []
    return parts[1] if len(parts) > 2 and parts[0] == "areas" else None


def approval(tool: str, args: dict, event: dict, places: list[Path], areas) -> str | None:
    """None when the operator said yes to this very call and every place it acts on lies where
    this session may read; else why it does not pass. The agent shows the call in a ```guard block
    and asks (order.py): the operator answers in the chat, and types no command."""
    reachable = reach(areas)
    acted = {a for p in places if (a := setting_area(p) or area_of(real(p), areas)) and a != EXEMPT}
    if reachable is not None and (beyond := acted - reachable):
        return (f"it acts inside {', '.join(sorted(beyond))}, which this session does not read "
                f"(it works in {work_folder()}). Ask a session that works there")
    why, found = order_module().ordered(tool, args, event, kind=order_module().CHANGE)
    return why or order_module().spend(found, event, STATE)


def bypass(command: str, cwd: str, areas) -> str | None:
    """Why a command switches the guards off or around, or None. It passes on the operator's yes
    (`approval`), but for the marks."""
    expanded = spell_home(command)
    marks = "|".join(re.escape(name) for name in sorted(marks_names()))
    if re.search(rf"\b(rm|mv|cp|truncate|tee|touch|ln)\b[^|;&]*(?:{marks})|>\s*\S*(?:{marks})", expanded):
        return MARKS_REWRITE
    if re.search(r"\b(mv|cp|tee|touch|ln|install)\b[^|;&]*agent-off|>\s*\S*agent-off", expanded):
        return "switches the entry guard off"
    if re.search(r"\b(rm|mv|unlink|ln)\b[^|;&]*\.git-hooks(/agent-hooks)?/?(\s|$|[;&|])", expanded):
        return "removes the guards' installed hooks"
    if config_writes_guard_key(command):
        return "a git config that switches the hooks off"
    sends = sends_of(command, cwd)
    if not sends:
        return None
    if m := BYPASS_ENV.search(command):
        return f"sends with {m.group(1)} set"
    if re.search(r"(^|\s)--no-verify(\s|$)", command):
        return "--no-verify"
    if re.search(r"\bgit\b[^|;&]*\s-c\s*core\.hookspath", command, re.I):
        return "git -c core.hooksPath"
    words = shell_words(command)
    for i, w in enumerate(words):
        if w == "commit":
            after = upto_break(words[i + 1:])
            for j, a in enumerate(after):
                if (re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", a) and not (j and after[j - 1] in GIT_VALUE_FLAGS)):
                    return "git commit -n (= --no-verify)"
    for target, dest_args in sends:
        # A machine with no areas still has the hooks' word scan to keep, so it is held to them too.
        if dest_args[:1] == ["--gh-argv-inline"] or (areas and area_of(target, areas) == EXEMPT):
            continue
        # A commit stays in its repository; with no remote there is nowhere for it to go. A push
        # (to a remote or a URL typed out) is still held to the hooks.
        if not dest_args and not has_remote(target):
            continue
        if reason := unguarded(target, scope=bool(areas)):
            return f"{repo_root(target)}: {reason}"
    return None


def ask(argv: list[str]) -> int:
    """`may-write <session_id> <path>...`: whether the session may write each path, judged as the hook
    judges an Edit of it. For a script that writes where its arguments say -- the hook reads the
    command that starts a script, never the script, and a relative path it is handed resolves where
    the script runs, not where the session stands. A relative path here resolves from the caller's
    working directory. Exit 0: every path may be written (also with the entry guard off, with no
    areas, and for a session with no marks, but for the guard's own settings and a transcript, judged as
    an Edit of them is). Exit 1: one line per refused path on stderr. Exit 2: usage.

    `reach`: the areas a session of `GUARD_WORK_FOLDER` may read inside, one name per line in name
    order; nothing when no work folder is named. Exit 0."""
    if argv[:1] == ["reach"]:
        names = reach(load_areas()) or set()
        if names:
            print("\n".join(sorted(names)))
        return 0
    if len(argv) < 3 or argv[0] != "may-write" or not argv[1]:
        print("usage: area-guard.py may-write <session_id> <path>... | reach", file=sys.stderr)
        return 2
    if OFF.exists():
        return 0
    areas = load_areas()
    marks = set(load_state(argv[1])["areas"]) if areas else set()
    targets = [real(path, os.getcwd()) for path in argv[2:]]
    # What the guard judges from, as an Edit of it is judged, with marks or none.
    kept_here = [(t, what) for t in targets if (what := kept(t, None, marks))]
    for target, (what, why) in kept_here:
        print(f"area-guard: an agent does not write {what}: {why}", file=sys.stderr)
    if not marks:
        return 1 if kept_here else 0
    targets = [t for t in targets if t not in {k for k, _ in kept_here}]
    refused = [t for t in targets if not may_write(t, marks, areas) and handoff_of(t) is None]
    for target in targets:
        if target not in refused and not may_write(target, marks, areas):
            print(f"area-guard: {target} is in a handoff folder: it may be written, and what is written "
                  f"there is scanned for copies of private documents of other areas", file=sys.stderr)
    for target in refused:
        print(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
              f"write {target} (areas: {AREAS}). Do it in another session", file=sys.stderr)
    return 1 if refused or kept_here else 0


def child_guard() -> children.command.Guard:
    """What `child add`, `child check` and `marks` ask of this guard."""
    areas = load_areas()
    peers = outgoing_module().peers_module()
    return children.command.Guard(
        is_off=OFF.exists,
        has_areas=lambda: bool(areas),
        own_marks=lambda session: set(load_state(session)["areas"]),
        may_write=lambda place, marks: may_write(place, marks, areas),
        publishes=lambda place: publishes_outside(place, areas),
        scan=lambda text, marks: peers.scan("session:child", text, sorted(marks)),
        real=real)


def child_refusal(child: dict, tool: str, args: dict, cwd: str, written: str, transcript: str | None) -> str | None:
    """The one-line refusal for a call of a registered child that writes outside the places its
    parent declared, or reaches a tab or a session other than its parent."""
    command = args.get("command", "")
    files = [Path(written)] if tool in WRITES else write_targets(command, cwd) if tool == "Bash" else []
    repos = [target for target, _ in sends_of(command, cwd)] if tool == "Bash" else []
    note = os.environ.get("PWA_NOTE")
    if why := children.rules.place_refusal(child, files, repos, repo_root, real(note) if note else None):
        return why
    peers = outgoing_module().peers_module()
    parent_session = children.registry.session_of(child["parent"])
    return children.rules.contact_refusal(
        child, tool, args, command,
        is_parent=lambda to: parent_session is not None and parent_session in peers.receivers(to),
        is_own=lambda to: peers.subagent(to, transcript))


def work_folder() -> Path | None:
    folder = os.environ.get(WORK_FOLDER)
    return real(folder) if folder else None


def reach(areas) -> set[str] | None:
    """The areas this session may read inside, or None when no work folder is named."""
    home = work_folder()
    if home is None:
        return None
    held = {n for n, r in areas if n not in (EXEMPT, NO_AREA) and (home == r or r in home.parents)}
    around = {n for n, _ in areas if n not in (EXEMPT, NO_AREA) and any(outer(n, h, areas) for h in held)}
    try:
        lines = (home / READS_FILE).read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    named = {w for line in lines for w in line.split("#", 1)[0].split()}
    # A name written as a glob (`client-*`) reaches every area it matches when the call is judged,
    # so an area made later is read without a line of its own
    globbed = {n for n, _ in areas if n not in (EXEMPT, NO_AREA) and any(fnmatch.fnmatchcase(n, w) for w in named)}
    return held | around | named | globbed


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": reason}}, ensure_ascii=False))


def main() -> int:
    if len(sys.argv) > 1:
        if sys.argv[1] in children.command.COMMANDS:
            return children.command.run(sys.argv[1:], child_guard())
        return ask(sys.argv[1:])
    event = json.load(sys.stdin)
    if OFF.exists():
        return 0
    areas = load_areas()
    tool, args, cwd = event.get("tool_name", ""), event.get("tool_input", {}), event.get("cwd", os.getcwd())
    session = event.get("session_id", "unknown")
    # A message from another machine holds the session until the operator types, areas or none.
    if tool not in HELD_RUNS and order_module().held(event.get("transcript_path")):
        deny(HELD)
        return 0
    tab = os.environ.get("PWA_SID")
    if areas:
        children.registry.save_session(tab, session)
    child = children.registry.registration_of(tab) if areas else None
    state = load_state(session) if areas else {"areas": [], "tabs": {}}
    read_marks = set(state["areas"])
    marks = children.registry.held_marks(child, read_marks)
    # Switching the guards off or around is refused even on a machine with no areas, but on the
    # operator's yes to this very call: the marks, which keep areas apart, never.
    if tool == "Bash" and (reason := bypass(args.get("command", ""), cwd, areas)):
        command = args.get("command", "")
        places = [real(cwd), *mentioned_paths(command, areas), *(t for t, _ in sends_of(command, cwd))]
        if reason == MARKS_REWRITE or (why := approval(tool, args, event, places, areas)):
            deny(f"area-guard: an agent does not switch the guards off or around ({reason})"
                 + ("" if reason == MARKS_REWRITE else f": {why}"))
            return 0
    if tool == "Bash" and children.rules.runs_registration(args.get("command", "")):
        deny("area-guard: an agent does not register a child: the client does, once it has opened the child's tab")
        return 0
    written = str(real(args.get("file_path") or args.get("notebook_path") or "", cwd)) if tool in WRITES else ""
    if written.endswith("/agent-off") and (why := approval(tool, args, event, [Path(written)], areas)):
        deny(f"area-guard: an agent does not switch the entry guard off: {why}")
        return 0
    if tool in WRITES and any(name in written for name in marks_names()):
        deny("area-guard: an agent does not rewrite the entry guard's marks")
        return 0
    if (home := work_folder()) is not None:
        own = home / READS_FILE
        targets = [Path(written)] if tool in WRITES else \
            write_targets(args.get("command", ""), cwd) if tool == "Bash" else []
        if any(same_file(t, own) or t == own for t in targets):
            deny(f"area-guard: a session does not widen what it may read: {own} is the operator's, "
                 f"or another session's to write")
            return 0
    # What the guard judges from is the operator's to write, on every machine, but for what the operator
    # grants a session that has read inside no area. The call's own reading counts: marks are kept after it.
    transcript = event.get("transcript_path")
    writer = set(marks)
    if tool == "Bash" and areas and GRANT.is_file():
        command = args.get("command", "")
        writer |= {a for a in (area_of(p, areas) for p in bash_marks(command, cwd, areas)) if a and a != EXEMPT}
        writer |= remote_marks(command, cwd)
    what = kept(Path(written), transcript, writer) if tool in WRITES else \
        kept_by(args.get("command", ""), cwd, transcript, writer) if tool == "Bash" else None
    # The guard's settings change on the operator's yes; a transcript, which judges that yes, never.
    if what:
        is_setting = what[1].startswith(SETTINGS_WHY)
        if tool in WRITES:
            paths = [Path(written)]
        else:
            paths = [p for found in named(args.get("command", ""), cwd) for p in found if in_settings(p)]
        why = approval(tool, args, event, paths or [real(cwd)], areas) if is_setting else None
        if not is_setting or why:
            deny(f"area-guard: an agent does not write or remove {what[0]}: {what[1]} "
                 f"(code written into a command counts as writing every path it names)"
                 + (f": {why}" if why else ""))
            return 0

    if child is not None and (why := child_refusal(child, tool, args, cwd, written, transcript)):
        deny(why)
        return 0

    def private_area(path: Path) -> str | None:
        area = area_of(real(path), areas)
        return area if area != EXEMPT else None

    tabs = state.setdefault("tabs", {})
    if reason := outgoing_module().check(tool, args, cwd, SEND_SCAN, frozenset(marks), private_area, tabs,
                                         event, STATE):
        deny(reason)
        return 0
    # A browser call that opens a tab at a page names that page for the tab's later calls.
    if areas and (host := outgoing_module().opened_host(tool, args)):
        tabs.update({tab: host for tab in outgoing_module().tab_ids(args)})
        save_state(session, state)
    if not areas:
        return 0
    touched: list[Path] = []
    remote: set[str] = set()

    if tool in READS:
        for key in ("file_path", "path", "notebook_path"):
            if args.get(key):
                touched.append(real(args[key], cwd))
        if tool == "Grep":
            # Grep walks the folder it is given (its own folder when none): every area inside it is read.
            folder = real(args.get("path") or cwd, cwd)
            if folder.is_dir():
                touched += roots_under([(folder, [])], areas)
    elif tool == "Bash":
        command = args.get("command", "")
        touched += bash_marks(command, cwd, areas)
        remote = remote_marks(command, cwd)
        for target in write_targets(command, cwd) if marks else []:
            if not may_write(target, marks, areas):
                deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
                     f"write {target} (areas: {AREAS}). Do it in another session")
                return 0
        for target, dest_args in sends_of(command, cwd) if marks else []:
            if area_of(target, areas) == EXEMPT:
                # The operator's own notes: their commits and pushes are scanned by the git hooks.
                continue
            if not dest_args:
                # A commit lands in its repository: judged as writing a file there.
                place, guess_why = target, None
                refused = not may_write(target, marks, areas)
                if refused and handoff_folders():
                    why = handoff_commit_refusal(target, areas)
                    if why is None:
                        refused = False
                    elif repo_root(target) in {repo_root(f) for f in handoff_folders()}:
                        deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so a commit in "
                             f"{repo_root(target)} passes only as a handoff, and it is not one: {why}")
                        return 0
            else:
                place, guess_why = destination(target, dest_args)
                refused = place is None or not allowed(place, marks, areas)
            if refused:
                where = "a public repository or another place outside every area" if place is None \
                    else str(repo_root(place) or place)
                caveat = f" ({guess_why})" if guess_why else ""
                deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
                     f"send to {where}{caveat} (areas: {AREAS}). Do it in another session")
                return 0
    elif tool in WRITES:
        target = real(args.get("file_path") or args.get("notebook_path") or "", cwd)
        if marks and not may_write(target, marks, areas) and (folder := handoff_of(target)):
            if why := handoff_refusal(folder, written_text(tool, args), areas):
                deny(f"area-guard: {target} is in a handoff folder, but what is written there may not hold "
                     f"a copy of another area's private documents: {why}")
            return 0
        if marks and not may_write(target, marks, areas):
            deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
                 f"write {target} (areas: {AREAS}). Do it in another session")
            return 0

    remote |= service_areas(tool, args, cwd, tabs)
    new = {a for a in (area_of(p, areas) for p in touched) if a and a != EXEMPT} | remote
    if (reachable := reach(areas)) is not None and (beyond := new - reachable):
        deny(f"area-guard: this session reads only inside {', '.join(sorted(reachable)) or 'no area'} "
             f"(it works in {work_folder()}), and this call reads inside {', '.join(sorted(beyond))}. "
             f"Ask a session that works there")
        return 0
    if new - marks:
        state["areas"] = sorted(read_marks | new)
        save_state(session, state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
