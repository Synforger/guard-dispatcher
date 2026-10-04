#!/usr/bin/env python3
"""Keep an AI agent from carrying what it read out of an area (Claude Code PreToolUse hook).

Areas are defined in `$GUARD_CONFIG_DIR/areas.txt` (default `~/.config/guard/`), the same file
the private-document scan reads, through the same parser (`scanners/corpus-scan.py`). A session
that reads inside an area is marked with the area's name. A marked session may not write into a
git repository outside its marks, nor commit, push or send through `gh` to a destination outside
them.

- Marking: the target of Read / Grep / Glob, a Bash cwd, an area path named in a Bash command
           (unless the command only checks it: a lone test / [ / stat / realpath / readlink /
           ls -d with every argument literal)
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
- `_outside` folders are in no area, whatever holds them: reading there marks nothing, and a
  marked session may not write a repository there

What a call sends out -- a tool that sends to a service, a `curl` / `wget` with a body -- is
found by `outgoing.py` (next to this file) and judged like a push by `scanners/send-scan.py`: its
payload is scanned against the areas its destination (declared in `destinations.txt`) is outside
of, on every machine.

Separately, and on every machine, a Bash command that switches the guards off or around
(skip variables, `--no-verify`, a hooksPath / exempt setting, clearing the marks, sending from a
repository the hooks do not reach) is refused: the operator types those, the agent does not.

What an order for a send is judged from (`order.py`) is the operator's to write as well: the
agent writes neither `destinations.txt` nor `orders.txt`, nor removes them, nor writes a
session's transcript (`~/.claude*/projects/**/*.jsonl`), through Edit / Write or the shell.

Nothing is printed when a call passes, so nothing lands in the agent's context. A refusal is one
line. Marks are kept in `~/.cache/area-guard/<session_id>.json`, so they outlive compaction.
"""

from __future__ import annotations

import functools
import glob
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
AREAS = CONFIG / "areas.txt"
STATE = Path(os.environ.get("AREA_GUARD_STATE", Path.home() / ".cache/area-guard"))
# The operator's switch: while this file exists the entry guard passes every call. Installing or
# updating the guard leaves it as it is, so switching off holds until the operator removes it.
OFF = CONFIG / "agent-off"
CORPUS = Path(__file__).resolve().parents[2] / "scanners/corpus-scan.py"
SEND_SCAN = Path(__file__).resolve().parents[2] / "scanners/send-scan.py"
EXEMPT = "_exempt"
NO_AREA = "_outside"
READS = {"Read", "Grep", "Glob"}
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
    r = subprocess.run(["git", "-C", str(d), "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    return real(r.stdout.strip()) if r.returncode == 0 else None


def spell_home(command: str) -> str:
    """The command with ~/, $HOME and ${HOME} written out as the home folder."""
    home = str(Path.home())
    text = command.replace("${HOME}", home).replace("$HOME", home)
    return re.sub(r"(?<![\w/])~(?=/)", home, text)


def mentioned_paths(command: str, areas) -> list[Path]:
    """Area paths named in a Bash command (spelled with ~, $HOME, or absolute)."""
    text = spell_home(command)
    found = []
    for _, root in areas:
        for spelling in {str(root), os.path.normpath(str(root))}:
            if spelling in text:
                found.append(root)
    # A path through a shortcut symlink whose target is inside an area counts too
    for token in re.findall(r"(/[^\s'\"|;&<>]+)", text):
        try:
            p = real(token)
        except OSError:
            continue
        if area_of(p, areas):
            found.append(p)
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
# An absolute or home path written inside inline code (not the tail of a relative one).
CODE_PATH = re.compile(r"""(?<![\w./~-])(?:~|/)[^\s'"`;|&<>(),]+""")
# A quoted word of inline code: a relative path is one of these.
CODE_WORD = re.compile(r"""(['"`])([^'"`\s]+)\1""")
GLOB = re.compile(r"[*?\[]")


def code_flags(tool: str) -> set[str]:
    name = "python" if tool.startswith("python") else tool
    return CODE_FLAGS.get(name, set())


def code_paths(code: str, cwd: str) -> list[str]:
    """Every path inline code names: an absolute or home path anywhere in it, and a quoted word
    that reads as a relative path (it holds a `/`, ends in an extension, or names something that
    exists in the command's folder). Whether the code reads or writes it cannot be told."""
    found = CODE_PATH.findall(code)
    for _, word in CODE_WORD.findall(code):
        if word.startswith(("/", "~")) or "://" in word or not word.strip("."):
            continue
        if "/" in word or re.search(r"\.\w{1,8}$", word) or (Path(cwd) / word).exists():
            found.append(word)
    return found


def named(command: str, cwd: str) -> tuple[list[Path], list[Path]]:
    """(paths a Bash command names as a place it writes, paths it names as removed).

    Written: a redirection's target (`>`, `>>`), the files of tee / touch / truncate, the
    destination of cp / mv / install / ln, the existing files sed -i edits, dd's of=, and every
    path inside code written into the command (`python3 -c`, `node -e`, a heredoc or a
    here-string fed to an interpreter), relative ones included: code that reads a file cannot be
    told apart from code that writes it. A shell's `-c` string, and a heredoc fed to a shell, is
    a command line of its own, read the same way. Removed: the files of rm / unlink / rmdir /
    shred, and what mv moves away. A glob stands for the files it matches now. What stands
    before a command (`sudo`, `env`, a variable) is skipped. A script run from a file is not
    read, and neither is a heredoc's body fed to anything else (it is text, not commands)."""
    text = spell_home(command)
    line, fed, pos = [], [], 0
    for line_end, body_end, program in heredocs(text):
        line.append(text[pos:line_end + 1])
        fed.append((os.path.basename(program), text[line_end + 1:body_end]))
        pos = body_end
    line.append(text[pos:])
    lexer = shlex.shlex("".join(line), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = []
    written: list[str] = []
    removed: list[str] = []
    found: tuple[list[Path], list[Path]] = ([], [])
    breaks = outgoing_module().SHELL_BREAK

    def run(tool: str, code: str) -> None:
        """Code handed to a program that runs it."""
        if SHELL_CODE.fullmatch(tool):
            inner = named(code, cwd)
            found[0].extend(inner[0])
            found[1].extend(inner[1])
        elif code_flags(tool):
            written.extend(code_paths(code, cwd))

    def one(words: list[str], stdin: str | None) -> None:
        while words and (ASSIGNMENT.fullmatch(words[0]) or os.path.basename(words[0]) in RUNS_NEXT):
            wrapper = not ASSIGNMENT.fullmatch(words[0])
            words = words[1:]
            while wrapper and words and (words[0].startswith("-") or ASSIGNMENT.fullmatch(words[0])):
                words = words[1:]
        if not words:
            return
        tool, args = os.path.basename(words[0]), words[1:]
        paths = [a for a in args if not a.startswith("-")]
        if tool in CREATES:
            written.extend(paths)
        elif tool in COPIES and len(paths) >= 2:
            written.append(paths[-1])
            if tool in MOVES:
                removed.extend(paths[:-1])
        elif tool in REMOVES:
            removed.extend(paths)
        elif tool in IN_PLACE and any(a.startswith(("-i", "--in-place")) for a in args):
            written.extend(p for p in paths if Path(real(p, cwd)).is_file())
        elif tool == "dd":
            written.extend(a[3:] for a in args if a.startswith("of="))
        shell = bool(SHELL_CODE.fullmatch(tool))
        flags = code_flags(tool)
        for flag, code in zip(args, args[1:]):
            # a shell takes its command line after -c, alone or among other letters (`-lc`)
            if flag in flags or (shell and re.fullmatch(r"-[A-Za-z]*c", flag)):
                run(tool, code)
        if stdin is not None:
            run(tool, stdin)

    words: list[str] = []
    redirect = stdin = None
    for token in tokens:
        if redirect is not None:
            if redirect == "<<<":
                stdin = token
            elif redirect:
                written.append(token)
            redirect = None
            continue
        if token in breaks:
            one(words, stdin)
            words, stdin = [], None
            continue
        if token and set(token) <= set("<>&|") and set(token) & set("<>"):
            if words and words[-1].isdigit():   # the fd of `2>`
                words.pop()
            # `2>&1` names no file; a here-string is the next word, handed to the command
            redirect = "<<<" if token == "<<<" else (">" in token and not token.endswith("&"))
            continue
        words.append(token)
    one(words, stdin)
    for program, body in fed:
        run(program, body)

    def spelled(names: list[str]) -> list[Path]:
        out = []
        for name in names:
            if not name or name in ("-", "/dev/null"):
                continue
            base = os.path.expanduser(name)
            base = base if os.path.isabs(base) else os.path.join(cwd, base)
            out.extend(real(m) for m in (glob.glob(base) if GLOB.search(name) else []) or [base])
        return out

    return spelled(written) + found[0], spelled(removed) + found[1]


def write_targets(command: str, cwd: str) -> list[Path]:
    """Paths a Bash command names as a place it writes (see named)."""
    return named(command, cwd)[0]


# What an order for a send is judged from. The operator writes these; an agent that could would
# make an order itself.
KEPT_SETTINGS = ("destinations.txt", "orders.txt")
TRANSCRIPT = re.compile(r"\.claude[^/]*/projects/.+\.jsonl", re.I)


def same_file(a: Path, b: Path) -> bool:
    """One file under two spellings: a link, or another case on a file system that folds it."""
    try:
        if os.path.samefile(a, b):
            return True
    except OSError:
        pass
    return str(a).casefold() == str(b).casefold()


def kept(path: Path, transcript: str | None) -> str | None:
    """What a path is when the agent may not write it, or None."""
    for name in KEPT_SETTINGS:
        if same_file(path, real(CONFIG / name)):
            return f"the guard's {name}"
    if transcript and same_file(path, real(transcript)):
        return "the session's transcript"
    for home in {Path.home(), real(Path.home())}:
        if home in path.parents and TRANSCRIPT.fullmatch(path.relative_to(home).as_posix()):
            return "a session's transcript"
    return None


def kept_by(command: str, cwd: str, transcript: str | None) -> str | None:
    """What a Bash command writes or removes that the agent may not, or None. Removing a
    setting counts: with no destinations.txt, a destination held to an order is undeclared."""
    written, removed = named(command, cwd)
    for path in written + removed:
        if what := kept(path, transcript):
            return what
    for path in removed:
        for name in KEPT_SETTINGS:
            if path in real(CONFIG / name).parents:
                return f"the folder holding the guard's {name}"
    return None


def bash_marks(command: str, cwd: str, areas) -> list[Path]:
    """What a Bash command reads from: its folder always, and the area paths it names unless
    it only checks them."""
    named = [] if path_only(command) else mentioned_paths(command, areas)
    return [*named, real(cwd)]


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
    here, previous, dirs, subshells = real(cwd), real(cwd), [], []

    def run(argv: list[str]) -> None:
        nonlocal here, previous
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
        if name in ("cd", "pushd"):
            target = next((a for a in args if not a.startswith("-") or a == "-"), None)
            if name == "pushd":
                dirs.append(here)
            new = previous if target == "-" else real(target or str(Path.home()), str(here))
            previous, here = here, new
        elif name == "popd" and dirs:
            previous, here = here, dirs.pop()
        elif name in SHELLS and "-c" in args[:-1]:
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
            subshells.append((here, previous, list(dirs)))
        elif w == ")" and subshells:
            here, previous, dirs = subshells.pop()
    return found


def push_url(repo: Path, named: str | None) -> str:
    """Where `git push` sends: a named remote's push URL, else the upstream, else origin."""
    if named and (":" in named or "/" in named):
        return named
    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout.strip()
    name = named or git("config", f"branch.{git('branch', '--show-current')}.pushRemote") \
        or git("config", "remote.pushDefault") \
        or git("config", f"branch.{git('branch', '--show-current')}.remote") or "origin"
    return git("remote", "get-url", "--push", name)


def destination(target: Path, dest_args: list[str]) -> tuple[Path | None, str | None]:
    """(where a send lands, why that is only a guess). None = outside every area (a public
    repository, say). When the private-document scan cannot answer -- including a time-out, not
    that it found the destination outside every area -- the sending repository stands in, and the
    second element says so (so a deny a guess like this leads to can tell the operator it was one,
    not a real determination)."""
    if not dest_args:
        return target, None
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
                               env={**os.environ, "GUARD_CONFIG_DIR": str(CONFIG)})
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


def allowed(target: Path, marks: set[str], areas) -> bool:
    """Whether a session with these marks may write or send to a place it resolved to (a public or
    personal destination is None and never reaches here). A place in no area passes: the guard stops
    what it knows leaves an area, not what is unlisted. A place in areas passes when it is inside
    every mark and in no other area, but an area around a mark (the company around its client)."""
    if area_of(target, areas) == EXEMPT:
        return True
    held = {n for n, _ in areas if n not in (EXEMPT, NO_AREA) and inside(target, n, areas)}
    if not held:
        return True
    return (all(inside(target, m, areas) for m in marks)
            and all(h in marks or any(outer(h, m, areas) for m in marks) for h in held))


def may_write(target: Path, marks: set[str], areas) -> bool:
    """A marked session may write a file inside a git repository when the repository is allowed
    where it sits, and -- for one in no area -- when what it pushes to is not outside every area
    (a public repository, or one declared outside such as a personal account's)."""
    root = repo_root(target)
    if root is None:
        return True
    if not allowed(target, marks, areas):
        return False
    if area_of(target, areas) is not None:   # inside an area, or the exempt notes
        return True
    url = push_url(root, None)
    return not url or destination(root, ["--dest", url])[0] is not None


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


def config_writes_guard_key(command: str) -> bool:
    """True when any `git config` in the command writes core.hooksPath, guard.scope or
    guard.exemptPrefix. Each invocation is judged on its own words, so a read beside a write
    does not excuse the write."""
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
                skip = True
            elif a.startswith("-"):
                flags.add(a.split("=", 1)[0])
            else:
                positional.append(a)
        verb = positional[:1]
        if flags & CONFIG_WRITES or set(verb) & CONFIG_WRITES:
            return True
        if flags & CONFIG_READS or set(verb) & CONFIG_READS:
            continue
        if len(positional) >= 2:
            return True
    return False


def git_config(repo: Path, *args: str) -> str:
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
    r = subprocess.run(["git", "-C", str(top), "remote"], capture_output=True, text=True)
    return r.returncode != 0 or bool(r.stdout.strip())


def bypass(command: str, cwd: str, areas) -> str | None:
    """Why a command switches the guards off or around, or None. The operator may; the agent may not."""
    expanded = spell_home(command)
    if re.search(r"\b(rm|mv|cp|truncate|tee|touch|ln)\b[^|;&]*\.cache/area-guard|>\s*\S*\.cache/area-guard", expanded):
        return "removes or rewrites the entry guard's marks"
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


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": reason}}, ensure_ascii=False))


def main() -> int:
    event = json.load(sys.stdin)
    if OFF.exists():
        return 0
    areas = load_areas()
    tool, args, cwd = event.get("tool_name", ""), event.get("tool_input", {}), event.get("cwd", os.getcwd())
    session = event.get("session_id", "unknown")
    state = load_state(session) if areas else {"areas": [], "tabs": {}}
    marks = set(state["areas"])
    # Switching the guards off or around is refused even on a machine with no areas
    if tool == "Bash" and (reason := bypass(args.get("command", ""), cwd, areas)):
        deny(f"area-guard: an agent does not switch the guards off or around ({reason}). "
             f"If it is needed, tell the operator why; the operator does it by hand")
        return 0
    written = str(real(args.get("file_path") or args.get("notebook_path") or "", cwd)) if tool in WRITES else ""
    if written.endswith("/agent-off"):
        deny("area-guard: an agent does not switch the entry guard off. If it is needed, tell the operator why")
        return 0
    if tool in WRITES and ".cache/area-guard" in written:
        deny("area-guard: an agent does not rewrite the entry guard's marks")
        return 0
    # What an order for a send is judged from is the operator's to write, on every machine.
    transcript = event.get("transcript_path")
    what = kept(Path(written), transcript) if tool in WRITES else \
        kept_by(args.get("command", ""), cwd, transcript) if tool == "Bash" else None
    if what:
        deny(f"area-guard: an agent does not write or remove {what}: an order for a send is judged from "
             f"it (code written into a command counts as writing every path it names). "
             f"If it needs changing, tell the operator why")
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

    if tool in READS:
        for key in ("file_path", "path", "notebook_path"):
            if args.get(key):
                touched.append(real(args[key], cwd))
    elif tool == "Bash":
        command = args.get("command", "")
        touched += bash_marks(command, cwd, areas)
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
        if marks and not may_write(target, marks, areas):
            deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
                 f"write {target} (areas: {AREAS}). Do it in another session")
            return 0

    new = {a for a in (area_of(p, areas) for p in touched) if a and a != EXEMPT}
    if new - marks:
        state["areas"] = sorted(marks | new)
        save_state(session, state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
