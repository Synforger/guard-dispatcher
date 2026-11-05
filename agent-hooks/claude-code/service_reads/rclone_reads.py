"""What an `rclone` command line takes from a remote: the remotes it reads, and the file or path each read names.

Called by outgoing.py, which hands the words of an rclone command and gets back one reading call
for each remote: its remote, and the argument that names what it reads, `id` for a command that
takes a Drive file's id (`copyid`, `backend copyid`) and `path` for one that takes a path
(`cat remote:folder/file`). A command that lists a remote names no file and has no argument.
A direction toward a remote (a copy from this machine) is a write and not read here.
"""

from __future__ import annotations

import re

#: Commands whose every remote argument is read.
READS_EVERY_REMOTE = frozenset({"cat", "ls", "lsl", "lsd", "lsf", "lsjson", "tree", "size", "ncdu", "md5sum",
                                "sha1sum", "hashsum", "check", "cryptcheck", "checksum", "mount", "cmount",
                                "nfsmount", "serve", "bisync"})
#: Commands that copy from their first arguments into their last: the last one is written, not read.
COPIES_TO_LAST = frozenset({"copy", "copyto", "sync", "move", "moveto"})
#: Commands that take a Drive file's id after the remote, as `rclone copyid remote: ID dest`.
TAKES_ID = frozenset({"copyid", "moveid"})
#: `rclone backend <command>`: the ones that read a Drive (the rest change settings or list nothing).
BACKEND = "backend"
BACKEND_LISTS = frozenset({"query"})
ROOT_COMMANDS = READS_EVERY_REMOTE | COPIES_TO_LAST | TAKES_ID | {BACKEND}
#: `<remote>:<path>`, the remote named by letters that are no path (`http://host` is no remote).
REMOTE_WORD = re.compile(r"^([^/:\\\-][^/:\\]*):(?!//)")


def remote_of(word: str) -> str | None:
    """The remote a word names (`drive:folder/file` -> `drive`; parameters after a comma, as in
    `drive,root_folder_id=x:`, are not part of the name), or None for a local path or a flag."""
    found = REMOTE_WORD.match(word)
    return found.group(1).split(",", 1)[0] if found else None


def reads(words: list[str]) -> list[tuple[str, dict[str, str]]]:
    """(remote, arguments) for each remote the rclone command `words` reads from; none when it reads none."""
    rest = words[1:]
    verb_at = next((i for i, w in enumerate(rest) if w in ROOT_COMMANDS), None)
    if verb_at is None:
        return []
    verb, after = rest[verb_at], rest[verb_at + 1:]
    if verb == BACKEND:
        verb_at = next((i for i, w in enumerate(after) if not w.startswith("-")), None)
        if verb_at is None or after[verb_at] not in TAKES_ID | BACKEND_LISTS:
            return []
        verb, after = after[verb_at], after[verb_at + 1:]
    if verb in TAKES_ID | BACKEND_LISTS:
        return _by_id(verb, after)
    positional = [w for w in after if not w.startswith("-")]
    sources = positional[:-1] if verb in COPIES_TO_LAST else positional
    return [(remote, {"path": word}) for word in sources if (remote := remote_of(word))]


def _by_id(verb: str, after: list[str]) -> list[tuple[str, dict[str, str]]]:
    """`copyid remote: ID dest` names the file by its id; `backend query remote: expression` lists the remote."""
    for index, word in enumerate(after):
        if (remote := remote_of(word)) is None:
            continue
        if verb not in TAKES_ID:
            return [(remote, {})]
        file_id = next((w for w in after[index + 1:] if not w.startswith("-")), None)
        return [(remote, {"id": file_id} if file_id else {})]
    return []
