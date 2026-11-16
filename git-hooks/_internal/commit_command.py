"""The `git commit` a hook runs under: the words after `commit` and the folder its paths are read
from. git-hooks/_internal/staged_places.py asks it which paths the commit names itself.

A hook sees what the commit takes (the index) but not the command that made it: a path the
session named after `--` and a path another tab had staged look the same. The command is read
from the processes above the hook, the nearest one that is `git ... commit`: on Linux from
/proc, on macOS from the kernel's copy of the arguments (sysctl KERN_PROCARGS2, the words as
they were passed, spaces kept) with `ps` for the parent and `lsof` for the folder. The folder is
the one git's parent stands in: git itself has moved to the top of the work tree by then.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import struct
import subprocess
from pathlib import Path
from typing import NamedTuple

#: How many processes above the hook are read before giving up (hook dispatchers sit in between).
MAX_DEPTH = 8
#: sysctl names: CTL_KERN, KERN_PROCARGS2.
CTL_KERN = 1
KERN_PROCARGS2 = 49
#: git options before the subcommand that take the next word as their value.
GIT_VALUED = frozenset({"-c", "--namespace", "--config-env", "--exec-path", "--git-dir", "--work-tree", "--super-prefix"})
#: Seconds a `ps` or `lsof` call may take.
CALL_TIMEOUT = 5


class CommitCommand(NamedTuple):
    """A running `git commit`: the words after `commit`, and where its relative paths start."""

    arguments: list[str]
    folder: Path


def running_commit() -> CommitCommand | None:
    """The `git commit` above this process, or None when there is none or it cannot be read."""
    pid = os.getppid()
    for _ in range(MAX_DEPTH):
        if pid <= 1:
            return None
        words = process_words(pid)
        parent = process_parent(pid)
        if words is not None and (parsed := commit_words(words)) is not None:
            # git moves to the top of the work tree before it runs a hook; the folder the
            # command was typed in is still the one its parent stands in.
            folder = process_folder(parent) if parent is not None else None
            if folder is None:
                return None
            arguments, moves = parsed
            for move in moves:
                folder = folder / move
            return CommitCommand(arguments, folder)
        if parent is None:
            return None
        pid = parent
    return None


def commit_words(words: list[str]) -> tuple[list[str], list[str]] | None:
    """(the words after `commit`, the `-C` folders in order) when the words run `git commit`."""
    if not words or os.path.basename(words[0]) != "git":
        return None
    moves: list[str] = []
    at = 1
    while at < len(words):
        word = words[at]
        if word == "-C" and at + 1 < len(words):
            moves.append(words[at + 1])
            at += 2
        elif word in GIT_VALUED:
            at += 2
        elif word.startswith("-"):
            at += 1
        else:
            return (words[at + 1:], moves) if word == "commit" else None
    return None


def process_words(pid: int) -> list[str] | None:
    """The words a process was started with, or None when they cannot be read."""
    proc = Path(f"/proc/{pid}/cmdline")
    if proc.exists():
        try:
            data = proc.read_bytes()
        except OSError:
            return None
        return [word.decode("utf-8", "surrogateescape") for word in data.split(b"\0")[:-1]]
    return mac_process_words(pid)


def mac_process_words(pid: int) -> list[str] | None:
    """The words of a process on macOS: KERN_PROCARGS2 holds argc, the executable path, padding,
    then argc words, each ended by a NUL."""
    path = ctypes.util.find_library("c")
    if path is None:
        return None
    libc = ctypes.CDLL(path, use_errno=True)
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value < 4:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    data = buffer.raw[:size.value]
    count = struct.unpack_from("i", data)[0]
    rest = data[4:]
    end = rest.find(b"\0")
    if end < 0:
        return None
    while end < len(rest) and rest[end] == 0:
        end += 1
    words = rest[end:].split(b"\0")[:count]
    if len(words) < count:
        return None
    return [word.decode("utf-8", "surrogateescape") for word in words]


def process_parent(pid: int) -> int | None:
    """The parent of a process, or None."""
    stat = Path(f"/proc/{pid}/stat")
    if stat.exists():
        try:
            fields = stat.read_text().rpartition(")")[2].split()
            return int(fields[1])
        except (OSError, IndexError, ValueError):
            return None
    output = call(["ps", "-o", "ppid=", "-p", str(pid)])
    try:
        return int(output.strip()) if output else None
    except ValueError:
        return None


def process_folder(pid: int) -> Path | None:
    """The folder a process stands in, or None."""
    link = Path(f"/proc/{pid}/cwd")
    if Path("/proc/self").exists():
        try:
            return Path(os.readlink(link))
        except OSError:
            return None
    output = call(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
    for line in (output or "").splitlines():
        if line.startswith("n"):
            return Path(line[1:])
    return None


def call(command: list[str]) -> str | None:
    """The standard output of a short command, or None when it fails."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=CALL_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None
