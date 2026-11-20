"""The file of code a command hands to the program that runs it, read as the code it holds.

The guard judges code written into a command (`python3 -c`, `bash -c`, a heredoc fed to an
interpreter): the files it writes, the places it reads, where it sends. A file handed to the same
program is that code one step away, so every reader in area-guard.py and outgoing.py reads it the
same way (`ran`); otherwise writing the code into a file would be a way round every line the guard
keeps:

- an interpreter given a file: `python3 fix.py`, `bash run.sh`, `node x.js`, `ruby`, `perl`, `php`
  (`-f` too), `osascript`, `deno run`, `bun [run]`, after the interpreter's own options;
- a file the shell reads into itself: `source env.sh`, `. env.sh`;
- a file run by its path (`./run.sh`, `scripts/run.sh`, `/abs/run.py`): its `#!` line names the
  program, and a text file with none is run by the shell, as the shell does with it;
- `uv run [options] fix.py`, and `uv run [options] python3 fix.py`.

A relative file is the one in the folder the command stands in when it reaches it (the caller says).
What is not read: a module run by name (`python3 -m pkg`), a program found on PATH by its bare name,
what the code imports or starts in turn, a file larger than MAX_BYTES, and one that is not text (a
compiled AppleScript). Those run unread.
"""

from __future__ import annotations

import os
import re
import shlex
from pathlib import Path

#: The largest file read: a script larger than this is not one an agent wrote for a call.
MAX_BYTES = 512 * 1024
#: How much of the file's head is looked at to tell text from a binary.
SNIFF_BYTES = 8192
#: How much of the first line is read for a `#!` line.
SHEBANG_BYTES = 256

SHELL = re.compile(r"(?:ba|z|da|k)?sh")
PYTHON = re.compile(r"python(?:\d+(?:\.\d+)*)?")

# Per kind of code: the options that take the next word as their value, and the options that hand
# the code some other way (so no file follows). `--` ends the options: the next word is the file.
VALUED = {
    "python": {"-W", "-X", "-Q"},
    "node": {"-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
             "--input-type", "--env-file", "--inspect-port", "--title"},
    "ruby": {"-I", "-r", "-C", "-E", "-F", "--encoding", "--external-encoding", "--internal-encoding"},
    "perl": {"-I", "-M", "-m", "-C"},
    "php": {"-c", "-d", "-z"},
    "osascript": {"-l", "-s"},
    "shell": {"-o", "-O", "+o", "+O", "--rcfile", "--init-file"},
}
CODE_GIVEN = {
    "python": {"-c", "-m", "-"},
    "node": {"-e", "--eval", "-p", "--print", "-", "--test"},
    "ruby": {"-e", "-"},
    "perl": {"-e", "-E", "-"},
    "php": {"-r", "-a", "-"},
    "osascript": {"-e", "-"},
    "shell": {"-s", "-"},
}
# The program name the readers know each kind by (area-guard's code_flags and SHELL_CODE, outgoing's
# INTERPRETERS and SHELLS).
READ_AS = {"python": "python3", "node": "node", "ruby": "ruby", "perl": "perl", "php": "php",
           "osascript": "osascript", "shell": "bash"}
# `uv run` options that take the next word as their value.
UV_VALUED = {"--with", "--with-editable", "--with-requirements", "--python", "-p", "--project", "--directory",
             "--package", "--extra", "--group", "--only-group", "--no-group", "--env-file", "--index",
             "--default-index", "--index-url", "--extra-index-url", "-f", "--find-links", "--config-file",
             "--cache-dir", "--python-platform", "--exclude-newer", "--prerelease", "--resolution",
             "--index-strategy", "--keyring-provider", "--link-mode", "--refresh-package",
             "--reinstall-package", "--upgrade-package", "-P", "--no-binary-package", "--no-build-package",
             "--config-setting", "-C", "--color"}


def ran(words: list[str], here: str) -> tuple[str, str] | None:
    """(the program the readers read the code as, the code) for the file `words` hand to the program
    that runs it, or None when they hand none (see the module's docstring). `words` start at the
    program, past what stands before it (`sudo`, `env`, an assignment); `here` is the folder the
    command stands in."""
    found = _file_run(words, here)
    if found is None:
        return None
    kind, name = found
    text = _text(name, here)
    return None if text is None else (READ_AS[kind], text)


def kind_of(program: str) -> str | None:
    """The kind of code a program runs (a key of VALUED), from its name or path, or None."""
    name = os.path.basename(program)
    if PYTHON.fullmatch(name):
        return "python"
    if SHELL.fullmatch(name):
        return "shell"
    if name in ("node", "deno", "bun"):
        return "node"
    return name if name in ("ruby", "perl", "php", "osascript") else None


def _file_run(words: list[str], here: str) -> tuple[str, str] | None:
    """(kind, the file as written) the command runs, or None."""
    if not words:
        return None
    program, args = words[0], words[1:]
    name = os.path.basename(program)
    if name in ("source", "."):
        return ("shell", args[0]) if args else None
    if name == "uv":
        return _uv_run(args, here)
    if name in ("deno", "bun") and args[:1] == ["run"]:
        args = args[1:]
    if (kind := kind_of(program)) is not None:
        return _after_options(kind, args)
    if "/" in program:
        return _by_its_line(program, here)
    return None


def _after_options(kind: str, args: list[str]) -> tuple[str, str] | None:
    """The file an interpreter of `kind` is handed after its own options, or None when the code
    comes some other way (`-c`, `-m`, standard input)."""
    valued, given = VALUED[kind], CODE_GIVEN[kind]
    at = 0
    while at < len(args):
        word = args[at]
        if word == "--" or (kind == "php" and word == "-f"):
            return (kind, args[at + 1]) if at + 1 < len(args) else None
        option = word.split("=", 1)[0]
        if word in given or option in given:
            return None
        if kind == "shell" and re.fullmatch(r"[-+][A-Za-z]*[cs][A-Za-z]*", word):
            return None                 # `-c` / `-s` among other letters (`-lc`): the code is no file
        if word.startswith("-") or (kind == "shell" and word.startswith("+")):
            at += 2 if option in valued and word == option else 1
            continue
        return kind, word
    return None


def _uv_run(args: list[str], here: str) -> tuple[str, str] | None:
    """`uv run [options] <file or program> ...`: a `.py` file, or what the program after it runs."""
    if args[:1] != ["run"]:
        return None
    rest = args[1:]
    at = 0
    while at < len(rest) and rest[at].startswith("-"):
        if rest[at] == "--":
            at += 1
            break
        at += 2 if rest[at] in UV_VALUED else 1
    rest = rest[at:]
    if not rest:
        return None
    if rest[0].endswith(".py"):
        return "python", rest[0]
    return _file_run(rest, here)


def _by_its_line(program: str, here: str) -> tuple[str, str] | None:
    """A file run by its path: the program its `#!` line names (through `env`, `env -S`, `uv run`), or
    the shell for a file with no `#!` line (the shell runs such a file itself)."""
    try:
        with open(_resolved(program, here), "rb") as file:
            head = file.readline(SHEBANG_BYTES)
    except OSError:
        return None
    if not head.startswith(b"#!"):
        return "shell", program
    try:
        words = shlex.split(head[2:].decode("utf-8", "replace"))
    except ValueError:
        return None
    while words and os.path.basename(words[0]) == "env":
        words = [w for w in words[1:] if w not in ("-S", "--split-string")]
        while words and (words[0].startswith("-") or "=" in words[0]):
            words = words[1:]
    if words[:2] == ["uv", "run"]:
        return "python", program
    kind = kind_of(words[0]) if words else None
    return (kind, program) if kind is not None else None


def _resolved(name: str, here: str) -> Path:
    name = os.path.expanduser(name)
    return Path(name if os.path.isabs(name) else os.path.join(here, name))


def _text(name: str, here: str) -> str | None:
    """The file's text, or None when it is not there, not a file, too large or not text."""
    path = _resolved(name, here)
    try:
        if not path.is_file() or path.stat().st_size > MAX_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:SNIFF_BYTES]:
        return None
    return data.decode("utf-8", "replace")
