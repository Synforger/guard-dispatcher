#!/usr/bin/env python3
"""What a push sends: the one place that decides it.

Every check of a push judges what this file says goes out, and none of them reads the history on
its own. Checks that each chose their own commits judged one push three ways: after a history
rewrite they stopped it one after another, for the same reason.

  which commits   the ones no remote of the destination holds yet, less the tips this push has
                  already scanned; a push over a tip it does not descend from, or of a whole
                  history, is a rewrite
  of a rewrite    what the destination already holds is left out, compared by content: a rewrite
                  gives every commit a new hash, colleagues' too, and the destination has carried
                  them all along
                    a file          by its blob (the same bytes are already there)
                    a commit text   by the text itself
                    an author       by the address for the identity check, by name and address
                                    for the word scan (a rewrite that changed only the name sends
                                    the new name)
                  What the rewrite made new is checked as before.

pre-push fetches the destination once, for a rewrite only, and hands every check the folder
`build` wrote. An empty folder argument means the destination is known to hold nothing more than
its remote-tracking refs say.

    dest-known.py range <remote> <local sha> <remote sha> [^<tip>...]
                                            "rewritten" or "follows", then the revspec of the
                                            commits that go out; nothing when none do
    dest-known.py ranges <remote>           the same for every ref line pre-push reads (on stdin)
                                            together: one revspec of all they send
    dest-known.py build <dir> <ref>...      write what the refs hold into <dir>
    dest-known.py patch <dir> <rev>...      "+++ b/<path>" for every file a commit touches and
                                            "+<line>" for every line it adds to a file whose blob
                                            <dir> does not hold
    dest-known.py messages <dir> <rev>...   "<sha> <subject>\\n<body>" of the commits whose text
                                            <dir> does not hold
    dest-known.py authors <dir> <rev>...    "<name> <<address>> / <name> <<address>>" of the
                                            commits whose author or committer <dir> does not hold
    dest-known.py addresses <dir> <rev>...  the author and committer addresses of the commits no
                                            remote holds, less those <dir> holds
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ZERO = "0" * 40
OBJECTS = "objects.txt"
MESSAGES = "messages.txt"
ADDRESSES = "addresses.txt"
IDENTITIES = "identities.txt"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace",
                          check=True).stdout


def is_commit(sha: str) -> bool:
    return subprocess.run(["git", "rev-parse", "--verify", "-q", f"{sha}^{{commit}}"],
                          capture_output=True).returncode == 0


def text_id(text: str) -> str:
    """A commit text as compared: its digest (the scans read it with git's own decoding)."""
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def commits(*revs: str) -> list[tuple[str, str, str, str, str, str]]:
    """(sha, text, author name, author address, committer name, committer address)."""
    out = git("log", "--format=%x00%H%x00%B%x00%an%x00%ae%x00%cn%x00%ce%x00", *revs).split("\0")
    rows = []
    for i in range(1, len(out) - 6, 7):
        sha, text, an, ae, cn, ce = out[i:i + 6]
        rows.append((sha, text, an, ae, cn, ce))
    return rows


def held(folder: Path | None, name: str) -> set[str]:
    if folder is None:
        return set()
    try:
        return set((folder / name).read_text().split("\n")) - {""}
    except OSError:
        return set()


def push_range(remote: str, local: str, remote_sha: str, scanned: list[str]) -> tuple[bool, str] | None:
    """(rewritten, revspec) of what a pushed ref sends, or None when nothing goes out."""
    if remote_sha == ZERO:
        # A new branch: the commits no tracking ref of the remote reaches. Ranging from the default
        # branch would scan published history forever under a squash-merge flow; commits an earlier
        # ref of this push already scanned count as published.
        lines = git("rev-list", "--boundary", local, *scanned, "--not", f"--remotes={remote}").splitlines()
        if not any(line and not line.startswith("-") for line in lines):
            return None
        bases = sorted({line[1:] for line in lines if line.startswith("-")})
        if len(bases) == 1:
            spec = f"{bases[0]}..{local}"
        elif not bases:
            spec = local                       # nothing reachable is published: the whole history
        else:
            spec = " ".join([local, *(f"^{b}" for b in bases)])
    elif is_commit(remote_sha):
        spec = f"{remote_sha}..{local}"
    else:
        spec = local                           # the old tip is gone here: a rewrite, sent whole
    rewritten = (".." not in spec and "^" not in spec) or (
        remote_sha != ZERO and is_commit(remote_sha)
        and subprocess.run(["git", "merge-base", "--is-ancestor", remote_sha, local],
                           capture_output=True).returncode != 0)
    return rewritten, spec


def push_ranges(remote: str, ref_lines: list[str]) -> tuple[bool, str] | None:
    """(rewritten, revspec) of what all the pushed refs send together, or None when nothing goes out.

    Every commit a ref's own range leaves out is one the destination holds, so leaving out all of
    them at once drops nothing new: the union is each tip less everything any ref leaves out."""
    tips: list[str] = []
    bounds: list[str] = []
    rewritten = False
    for line in ref_lines:
        words = line.split()
        if len(words) != 4 or words[1] == ZERO:
            continue
        decided = push_range(remote, words[1], words[3], [])
        if not decided:
            continue
        rewritten = rewritten or decided[0]
        spec = decided[1]
        if ".." in spec:
            base, tip = spec.split("..", 1)
            spec = f"{tip} ^{base}"
        for word in spec.split():
            if word.startswith("^"):
                bounds.append(word)
            else:
                tips.append(word)
    if not tips:
        return None
    return rewritten, " ".join(dict.fromkeys(tips + bounds))


def history(folder: Path | None, revs: list[str]) -> list[tuple[str, str | None, list[tuple[str, str]], list[str]]]:
    """(sha, text, added lines as (path, line), paths) of each commit of revs, as it is sent: a text
    <folder> holds comes as None, and a file whose blob it holds adds no line.

    One git call for the whole range: each commit comes as \\0<sha>\\0<text>\\0<patch>. --cc gives a
    merge the same patch `git show` would; --full-index names each blob in full."""
    objects, texts = held(folder, OBJECTS), held(folder, MESSAGES)
    log = git("log", "--format=%x00%H%x00%B%x00", "-p", "--cc", "--full-index", "--no-color", "--no-ext-diff",
              *revs)
    parts = log.split("\0")
    rows = []
    for sha, text, patch in zip(parts[1::3], parts[2::3], parts[3::3]):
        added, paths, current, kept = [], [], "?", True
        for line in patch.splitlines():
            if line.startswith("diff "):
                kept = True
            elif line.startswith("index ") and ".." in line:
                kept = line.split("..", 1)[1].split()[0] not in objects
            elif line.startswith("+++ "):
                current = line[6:] if line.startswith("+++ b/") else line[4:]
                paths.append(current)
            elif line.startswith("+") and kept:
                added.append((current, line[1:]))
        rows.append((sha, None if text_id(text) in texts else text, added, paths))
    return rows


def build(folder: Path, refs: list[str]) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    objects = git("rev-list", "--objects", *refs).splitlines()
    (folder / OBJECTS).write_text("\n".join(line.split(" ", 1)[0] for line in objects) + "\n")
    rows = commits(*refs)
    (folder / MESSAGES).write_text("\n".join(sorted({text_id(r[1]) for r in rows})) + "\n")
    (folder / ADDRESSES).write_text("\n".join(sorted({a for r in rows for a in (r[3], r[5])})) + "\n")
    (folder / IDENTITIES).write_text("\n".join(sorted({f"{n} <{a}>" for r in rows
                                                        for n, a in ((r[2], r[3]), (r[4], r[5]))})) + "\n")


def patch(folder: Path | None, revs: list[str]) -> None:
    for _, _, added, paths in history(folder, revs):
        # the path is sent with the push whatever the blob holds
        for path in paths:
            sys.stdout.write(f"+++ b/{path}\n")
        for _, line in added:
            sys.stdout.write(f"+{line}\n")


def messages(folder: Path | None, revs: list[str]) -> None:
    known = held(folder, MESSAGES)
    for sha, text, *_ in commits(*revs):
        if text_id(text) not in known:
            subject, _, body = text.partition("\n")
            sys.stdout.write(f"{sha} {subject}\n{body.strip(chr(10))}\n")


def authors(folder: Path | None, revs: list[str]) -> None:
    known = held(folder, IDENTITIES)
    for _, _, an, ae, cn, ce in commits(*revs):
        if f"{an} <{ae}>" not in known or f"{cn} <{ce}>" not in known:
            sys.stdout.write(f"{an} <{ae}> / {cn} <{ce}>\n")


def addresses(folder: Path | None, revs: list[str]) -> None:
    # Only commits no remote holds yet were made here: a colleague's commit or a workflow's, fetched
    # from the org and pushed on to another remote, has its own right author.
    known = held(folder, ADDRESSES)
    found = {a for _, _, _, ae, _, ce in commits(*revs, "--not", "--remotes") for a in (ae, ce)}
    for address in sorted(found - known):
        sys.stdout.write(f"{address}\n")


def main(argv: list[str]) -> int:
    commands = {"range", "ranges", "build", "patch", "messages", "authors", "addresses"}
    if not argv or argv[0] not in commands or len(argv) < (4 if argv[0] == "range" else 2):
        sys.stderr.write(__doc__ or "")
        return 2
    command = argv[0]
    if command in ("range", "ranges"):
        if command == "range":
            decided = push_range(argv[1], argv[2], argv[3], argv[4:])
        else:
            decided = push_ranges(argv[1], sys.stdin.read().splitlines())
        if decided:
            sys.stdout.write(f"{'rewritten' if decided[0] else 'follows'}\n{decided[1]}\n")
        return 0
    folder, rest = (Path(argv[1]) if argv[1] else None), argv[2:]
    if command == "build":
        if folder is None:
            sys.stderr.write("build needs a folder\n")
            return 2
        build(folder, rest)
    else:
        {"patch": patch, "messages": messages, "authors": authors, "addresses": addresses}[command](folder, rest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
