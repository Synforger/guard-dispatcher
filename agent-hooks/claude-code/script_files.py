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
- `uv run [options] fix.py`, and `uv run [options] python3 fix.py`;
- a file an interpreter that takes no file reads its code from on standard input: `bash < run.sh`,
  `cat run.sh | bash`, `python3 - < fix.py` (the caller says which files feed the command: `fed`).

A relative file is the one in the folder the command stands in when it reaches it (the caller says).

What the command line itself writes is read as well (`judging`; written_files), as a second reading
beside the disk's: a file it writes from text it holds, or copies from a source it can name, and then
runs, is read once as the disk holds it and once with what the command writes there added, since a
write may fail and the old file then runs. Nothing a command adds can then take away what the disk's
reading finds. A shell given its code on standard input by a heredoc, a here-string or a pipe from
`cat`, `echo` or `printf` runs that text. A file the command writes in a way that holds no text in
the line (a download, `sed -i`) is read as the disk holds it. Where a reader must decide what the
words themselves are (code the guard cannot read, handed a file), the disk's reading alone decides
(`ran_from_disk`).

What is not read: a module run by name (`python3 -m pkg`), a program found on PATH by its bare name,
a file named only as the command runs (`xargs bash`, `find -exec bash {} +`, a variable the line
does not set), what the code imports or starts in turn, a file larger than MAX_BYTES, and one that
is not text (a compiled AppleScript). Those run unread. A C shell, fish or another shell is read as
Bash: close enough to find the files it names and the commands it runs.
"""

from __future__ import annotations

import os
import re
import shlex
from pathlib import Path

import written_files

#: The largest file read: a script larger than this is not one an agent wrote for a call.
MAX_BYTES = 512 * 1024
#: How much of the file's head is looked at to tell text from a binary.
SNIFF_BYTES = 8192
#: How much of the first line is read for a `#!` line.
SHEBANG_BYTES = 256

SHELL = re.compile(r"(?:ba|z|da|k|c|tc|fi|mk|ok|yash|ash|pdk)?sh")
PYTHON = re.compile(r"python(?:\d+(?:\.\d+)*t?)?")
#: What stands for standard input where an interpreter takes a file.
STDIN = "-"

# Per kind of code: the options that take the next word as their value, and the options that hand
# the code some other way (so no file follows). `--` ends the options: the next word is the file.
VALUED = {
    "python": {"-W", "-X", "-Q", "--check-hash-based-pycs"},
    "node": {"-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
             "--input-type", "--env-file", "--inspect-port", "--title"},
    "ruby": {"-I", "-r", "-C", "-E", "-F", "--encoding", "--external-encoding", "--internal-encoding"},
    "perl": {"-I", "-M", "-m", "-C"},
    "php": {"-c", "-d", "-z"},
    "osascript": {"-l", "-s"},
    "shell": {"-o", "-O", "+o", "+O", "--rcfile", "--init-file"},
}
CODE_GIVEN = {
    "python": {"-c", "-m"},
    "node": {"-e", "--eval", "-p", "--print", "--test"},
    "ruby": {"-e"},
    "perl": {"-e", "-E"},
    "php": {"-r", "-a"},
    "osascript": {"-e"},
    "shell": set(),
}
#: How many copies of copies are followed to the content they put in a file.
COPY_DEPTH = 4

# env's options that take the next word as their value (in a `#!` line through `env -S`).
ENV_VALUED = {"-u", "--unset", "-P", "-C", "--chdir"}
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


_command: tuple[str, str] | None = None
_writes: written_files.Writes | None = None


def judging(command: str, here: str) -> None:
    """Judge the command line `command`, which stands in `here`: what it writes and feeds is read
    with the files it runs (see the module's docstring). One call of a hook judges one command line;
    the writes are read the first time a file is."""
    global _command, _writes
    _command, _writes = (command, here), None


def ran(words: list[str], here: str, fed: list[str] | None = None) -> list[tuple[str, str]]:
    """(the program the readers read the code as, the code) for each reading of the file `words` hand
    to the program that runs it; none when they hand none (see the module's docstring). `words` start
    at the program, past what stands before it (`sudo`, `env`, an assignment); `here` is the folder
    the command stands in; `fed` are the files its standard input comes from (`< f`, `cat f |`), when
    the caller can name them."""
    return [reading[:2] for reading in ran_with_arguments(words, here, fed)]


def ran_with_arguments(words: list[str], here: str,
                       fed: list[str] | None = None) -> list[tuple[str, str, list[str]]]:
    """`ran`, each reading with the words the command hands the code as its arguments (the words after
    the file): the disk's (ran_from_disk), then the one with what the command line writes or feeds,
    where that reads otherwise."""
    disk = ran_from_disk(words, here, fed)
    written = _reading(words, here, fed)
    return [reading for reading in (disk, written if written != disk else None) if reading is not None]


def ran_from_disk(words: list[str], here: str, fed: list[str] | None = None) -> tuple[str, str, list[str]] | None:
    """The reading of the file `words` run as the disk alone holds it, what the command line writes and
    feeds left out, or None when the disk holds no such code."""
    global _command, _writes
    judged = _command, _writes
    _command = _writes = None
    try:
        return _reading(words, here, fed)
    finally:
        _command, _writes = judged


def _reading(words: list[str], here: str, fed: list[str] | None) -> tuple[str, str, list[str]] | None:
    """(the program, the code, its arguments) of the file `words` run, read with the writes of the
    command line being judged, when one is."""
    found = _file_run(words, here)
    if found is None:
        return None
    kind, name, arguments = found
    if name == STDIN or _closes_heredoc(name, here):
        texts = [_text(file, here) for file in fed or []] if fed else _fed_texts(kind)
        text = None if not texts or None in texts else "\n".join(texts)
    else:
        text = _text(name, here)
    return None if text is None else (READ_AS[kind], text, arguments)


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


def _file_run(words: list[str], here: str) -> tuple[str, str, list[str]] | None:
    """(kind, the file as written, the words after it) the command runs, or None."""
    if not words:
        return None
    program, args = words[0], words[1:]
    name = os.path.basename(program)
    if name in ("source", "."):
        return ("shell", args[0], args[1:]) if args else None
    if name == "uv":
        return _uv_run(args, here)
    if name in ("deno", "bun") and args[:1] == ["run"]:
        args = args[1:]
    if (kind := kind_of(program)) is not None:
        return _after_options(kind, args)
    if "/" in program:
        return _by_its_line(program, args, here)
    return None


def _after_options(kind: str, args: list[str]) -> tuple[str, str, list[str]] | None:
    """The file an interpreter of `kind` is handed after its own options (STDIN when it reads its
    code from standard input: no file, `-`, a shell's `-s`), or None when the code comes in a word of
    the command (`-c`, `-e`) or by a module's name (`-m`). The words after the file come with it."""
    valued, given = VALUED[kind], CODE_GIVEN[kind]
    at = 0
    on_stdin = False                    # a shell's `-s` was given: every operand is an argument of the code
    while at < len(args):
        word = args[at]
        if on_stdin and word in ("--", STDIN):
            return kind, STDIN, args[at + 1:]
        if word == "--" or (kind == "php" and word == "-f"):
            return (kind, args[at + 1] if at + 1 < len(args) else STDIN, args[at + 2:])
        if word == STDIN:
            return kind, STDIN, args[at + 1:]
        option = word.split("=", 1)[0]
        if word in given or option in given:
            return None
        if kind == "shell" and re.fullmatch(r"[-+][A-Za-z]*c[A-Za-z]*", word):
            return None                 # `-c` among other letters (`-lc`): the code is a word
        if kind == "shell" and re.fullmatch(r"-[A-Za-z]*s[A-Za-z]*", word):
            on_stdin = True             # `-s`: the code comes on standard input, and more options may follow
            at += 1
            continue
        if word.startswith("-") or (kind == "shell" and word.startswith("+")):
            at += 2 if option in valued and word == option else 1
            continue
        return (kind, STDIN, args[at:]) if on_stdin else (kind, word, args[at + 1:])
    return kind, STDIN, []


def _uv_run(args: list[str], here: str) -> tuple[str, str, list[str]] | None:
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
    if rest[0].endswith(".py") and kind_of(rest[0]) is None:
        return "python", rest[0], rest[1:]
    return _file_run(rest, here)


def _by_its_line(program: str, arguments: list[str], here: str) -> tuple[str, str, list[str]] | None:
    """A file run by its path: the program its `#!` line names (through `env`, `env -S`, `uv run`), or
    the shell for a file with no `#!` line (the shell runs such a file itself)."""
    head = _head(program, here)
    if head is None:
        return None
    if not head.startswith(b"#!"):
        return "shell", program, arguments
    try:
        words = shlex.split(head[2:].decode("utf-8", "replace"))
    except ValueError:
        return None
    while words and os.path.basename(words[0]) == "env":
        words = [w for w in words[1:] if w not in ("-S", "--split-string")]
        while words and (words[0].startswith("-") or "=" in words[0]):
            words = words[2:] if words[0] in ENV_VALUED else words[1:]
    if words[:2] == ["uv", "run"]:
        return "python", program, arguments
    kind = kind_of(words[0]) if words else None
    return (kind, program, arguments) if kind is not None else None


def _resolved(name: str, here: str) -> Path:
    name = os.path.expanduser(name)
    return Path(name if os.path.isabs(name) else os.path.join(here, name))


def _head(name: str, here: str) -> bytes | None:
    """The first line of the file a command runs by its path: a `#!` line the command writes there,
    else the disk's (a text added to the file leaves its first line), else the first line of what the
    command writes. None when there is none."""
    path = _resolved(name, here)
    written = [text.encode("utf-8", "replace").split(b"\n", 1)[0][:SHEBANG_BYTES]
               for text in _written_at(os.path.realpath(path), COPY_DEPTH)]
    if shebang := next((line for line in written if line.startswith(b"#!")), None):
        return shebang
    try:
        with open(path, "rb") as file:
            return file.readline(SHEBANG_BYTES)
    except OSError:
        return written[0] if written else None


def _text(name: str, here: str) -> str | None:
    """The file's text: what the disk holds, then what the command line writes there. None when it
    is not there, not a file, too large or not text, and the command writes nothing there."""
    path = _resolved(name, here)
    texts = [text for text in (_disk_text(path), *_written_at(os.path.realpath(path), COPY_DEPTH)) if text is not None]
    return "\n".join(texts) if texts else None


def _disk_text(path: Path) -> str | None:
    """The file's text on the disk, or None when it is not there, not a file, too large or not text."""
    try:
        if not path.is_file() or path.stat().st_size > MAX_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:SNIFF_BYTES]:
        return None
    return data.decode("utf-8", "replace")


def _command_writes() -> written_files.Writes | None:
    """What the command being judged writes (None when none is being judged), read once."""
    global _writes
    if _writes is None and _command is not None:
        _writes = written_files.of(*_command)
    return _writes


def _written_at(path: str, depth: int) -> list[str]:
    """The texts the command writes at a real path: the text it holds, and the content of each file
    it copies there (what that file holds on the disk, and what the command writes there)."""
    if (writes := _command_writes()) is None:
        return []
    texts = list(writes.texts.get(path, []))
    for source in writes.copies.get(path, []) if depth else []:
        texts += [text for text in (_disk_text(Path(source)), *_written_at(source, depth - 1)) if text is not None]
    return texts


def _closes_heredoc(name: str, here: str) -> bool:
    """Whether a word handed as the file is the word that closes a heredoc of the command, which some
    readers leave after the command the heredoc feeds (`bash <<'EOF'` as `bash EOF`), and no file is."""
    return (writes := _command_writes()) is not None and name in writes.delimiters and _text(name, here) is None


def _fed_texts(kind: str) -> list[str | None]:
    """The texts the command feeds a shell on standard input, for a shell that is handed no file."""
    if kind != "shell" or (writes := _command_writes()) is None:
        return []
    return [text for program, text in writes.fed if kind_of(program) == "shell"]
