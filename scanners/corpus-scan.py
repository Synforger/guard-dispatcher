#!/usr/bin/env python3
"""corpus-scan — stop text copied out of private documents from leaving its area.

The word list catches names someone thought to write down. Text copied from a
real document -- a sentence from a slide, a row of a table -- is on no list.
This scanner compares what is about to be sent with the documents themselves.

Areas are defined on this machine only (never in a repository):

    ~/.config/guard/areas.txt
        <name> <path> [<path> ...]     one area per line; nested paths belong
                                       to the innermost area
        _exempt <path> ...             repositories that are never scanned
    ~/.config/guard/patterns/<name>.txt
        one regular expression per line (case-insensitive) for identifiers of
        that area that follow a shape: product codes, client names
    ~/.config/guard/allow.txt          phrases that are fine to send
    ~/.config/guard/background.txt     folders of public text; any run of text
                                       that also appears there is not specific
                                       to an area and is dropped

An area's documents are the Office files (.pptx .docx .xlsx) under its paths,
plus Markdown that lives outside any git repository. Every run of RUN
consecutive characters in them becomes a fingerprint. A line that is sent and
holds the same RUN characters is a hit.

What is checked depends on where the sending repository lives: every area that
does not contain it. A repository inside an area may carry that area's text,
and an area nested inside another (a client inside a company) may carry the
outer one's.

    corpus-scan.py --range <from>..<to>   added lines and messages of a push
    corpus-scan.py --text <file>          one payload (gh-guard)
    corpus-scan.py --refresh              rebuild the fingerprints now
    corpus-scan.py --status               what is configured and how fresh

Exit: 0 clean or not configured, 1 hit, 2 usage / configuration error.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import html
import json
import os
import re
import shlex
import subprocess
import sys
import time
import unicodedata
import zipfile
from array import array
from pathlib import Path

# How many consecutive characters count as copied. Twelve characters of
# Japanese are a phrase; twelve of English are two common words ("machine with"),
# so a run without any Japanese has to be much longer before it means anything.
RUN = int(os.environ.get("GUARD_CORPUS_RUN", "12"))
LATIN_RUN = int(os.environ.get("GUARD_CORPUS_LATIN_RUN", "40"))
JAPANESE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]")
MAX_AGE = int(os.environ.get("GUARD_CORPUS_MAX_AGE", str(6 * 3600)))
BACKGROUND_MAX_AGE = 7 * 24 * 3600
CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
CACHE = Path(os.environ.get("GUARD_CORPUS_CACHE", Path.home() / ".cache/guard-corpus"))
EXEMPT = "_exempt"
OFFICE = {".pptx", ".docx", ".xlsx", ".pptm", ".docm", ".xlsm"}
TEXT_RUN = re.compile(r"<(?:a:|w:)?t(?:\s[^>]*)?>([^<]*)</(?:a:|w:)?t>")
SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "__pycache__", "third_party", "dist", "build",
             "target", ".fetchcontent-cache", "DerivedData", "site-packages", ".gradle", "obj", "bin",
             "Intermediate", "Binaries"}
MAX_FILE = 5_000_000


def say(message: str) -> None:
    print(f"[corpus] {message}", file=sys.stderr)


def expand(path: str) -> Path:
    return Path(os.path.realpath(os.path.expanduser(os.path.expandvars(path))))


def read_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def load_areas() -> dict[str, list[Path]]:
    areas: dict[str, list[Path]] = {}
    for line in read_lines(CONFIG / "areas.txt"):
        parts = shlex.split(line, comments=True)
        if len(parts) >= 2:
            areas.setdefault(parts[0], []).extend(expand(p) for p in parts[1:])
    return areas


def contains(roots: list[Path], path: Path) -> bool:
    return any(path == r or r in path.parents for r in roots)


def normalize(text: str) -> str:
    """Fold width and spacing so a copy is caught however it was re-typed."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text)).strip()


def digest(window: str) -> int:
    return int.from_bytes(hashlib.blake2b(window.encode(), digest_size=8).digest(), "big")


def windows(text: str):
    """Every run that counts as a copy: RUN characters holding Japanese, or LATIN_RUN without."""
    text = normalize(text)
    for i in range(len(text) - RUN + 1):
        short = text[i:i + RUN]
        # A particle after a word of English ("README.md を") is still English.
        if len(JAPANESE.findall(short)) * 2 >= RUN:
            yield short
    for i in range(len(text) - LATIN_RUN + 1):
        long = text[i:i + LATIN_RUN]
        if len(JAPANESE.findall(long[:RUN])) * 2 < RUN:
            yield long


def fingerprints(text: str) -> set[int]:
    return {digest(w) for w in windows(text)}


# --- building an area's fingerprints ------------------------------------------

def office_units(path: Path) -> list[str]:
    units = []
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.endswith(".xml"):
                xml = archive.read(name).decode("utf-8", "replace")
                units += [html.unescape(t) for t in TEXT_RUN.findall(xml)]
    return units


def in_git_worktree(folder: Path, cache: dict[Path, bool]) -> bool:
    if folder not in cache:
        cache[folder] = (folder / ".git").exists() or (
            folder.parent != folder and in_git_worktree(folder.parent, cache))
    return cache[folder]


def documents(roots: list[Path], inner: list[Path]):
    """(path, units) for every document under roots, skipping nested areas."""
    git_cache: dict[Path, bool] = {}
    for root in roots:
        for folder, dirs, files in os.walk(root):
            here = Path(folder)
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")
                       and here / d not in inner]
            for name in files:
                path = here / name
                suffix = path.suffix.lower()
                if name.startswith("~$"):
                    continue
                try:
                    # Office files are measured by their text, not their size: a deck is
                    # mostly images, and its XML parts stay small however large it gets.
                    if suffix in OFFICE:
                        yield path, office_units(path)
                    elif (suffix == ".md" and path.stat().st_size <= MAX_FILE
                          and not in_git_worktree(here, git_cache)):
                        yield path, path.read_text(encoding="utf-8", errors="replace").splitlines()
                except (OSError, zipfile.BadZipFile):
                    continue


def published_texts(parent: Path):
    """Text files of every repository under parent, as published on its remote.

    Only what the remote's default branch already carries -- never the working
    tree, where the leak being prepared would whitelist itself.
    """
    for gitdir in sorted(parent.glob("*/.git")) + sorted(parent.glob("*/*/.git")):
        repo = str(gitdir.parent)
        head = subprocess.run(["git", "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if not head:
            continue
        names = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", head],
                               capture_output=True, text=True).stdout.split("\n")
        for name in names:
            if Path(name).suffix.lower() in {".md", ".rst", ".txt"}:
                blob = subprocess.run(["git", "-C", repo, "show", f"{head}:{name}"], capture_output=True)
                if blob.returncode == 0 and len(blob.stdout) <= MAX_FILE:
                    yield blob.stdout.decode("utf-8", "replace")


def background_prints() -> array:
    """Runs of public text, sorted. Public text changes rarely, so it keeps for a week."""
    cached, source = CACHE / "background.bin", CONFIG / "background.txt"
    if (cached.is_file() and source.is_file() and cached.stat().st_mtime > source.stat().st_mtime
            and time.time() - cached.stat().st_mtime < BACKGROUND_MAX_AGE):
        table = array("Q")
        table.frombytes(cached.read_bytes())
        return table
    prints: set[int] = set()
    for entry in read_lines(source):
        if entry.startswith("published "):
            for text in published_texts(expand(entry.split(None, 1)[1])):
                prints |= fingerprints(text)
            continue
        for folder, dirs, files in os.walk(expand(entry)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
            for name in files:
                path = Path(folder, name)
                if path.suffix.lower() in {".md", ".rst", ".txt"} and path.stat().st_size <= MAX_FILE:
                    prints |= fingerprints(path.read_text(encoding="utf-8", errors="replace"))
    table = array("Q", sorted(prints))
    CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_bytes(table.tobytes())
    return table


def present(table: array, value: int) -> bool:
    at = bisect.bisect_left(table, value)
    return at < len(table) and table[at] == value


def build(areas: dict[str, list[Path]]) -> dict:
    started = time.time()
    public = background_prints()
    allowed: set[int] = set()
    for phrase in read_lines(CONFIG / "allow.txt"):
        allowed |= fingerprints(phrase)
    CACHE.mkdir(parents=True, exist_ok=True)
    summary = {"built": started, "run": [RUN, LATIN_RUN], "areas": {}}
    for name, roots in areas.items():
        if name == EXEMPT:
            continue
        inner = [r for other, rs in areas.items() if other != name for r in rs
                 if any(r != root and root in r.parents for root in roots)]
        prints: set[int] = set()
        count = 0
        for _, units in documents(roots, inner):
            count += 1
            for unit in units:
                prints |= fingerprints(unit)
        prints = {p for p in prints - allowed if not present(public, p)}
        (CACHE / f"{name}.bin").write_bytes(array("Q", sorted(prints)).tobytes())
        summary["areas"][name] = {"documents": count, "fingerprints": len(prints)}
    summary["seconds"] = round(time.time() - started, 1)
    (CACHE / "summary.json").write_text(json.dumps(summary, indent=1))
    return summary


def load(areas: dict[str, list[Path]], refresh: bool) -> dict[str, array]:
    summary_path = CACHE / "summary.json"
    fresh = False
    if summary_path.is_file() and not refresh:
        summary = json.loads(summary_path.read_text())
        fresh = (time.time() - summary["built"] < MAX_AGE and summary["run"] == [RUN, LATIN_RUN]
                 and set(summary["areas"]) == {n for n in areas if n != EXEMPT})
    if not fresh:
        say("rebuilding fingerprints of the private documents (once every few hours)...")
        summary = build(areas)
        say(f"built in {summary['seconds']}s: " + ", ".join(
            f"{n} {a['documents']} documents" for n, a in summary["areas"].items()))
    prints = {}
    for name in summary["areas"]:
        table = array("Q")
        table.frombytes((CACHE / f"{name}.bin").read_bytes())
        prints[name] = table
    return prints


# --- what is being sent -------------------------------------------------------

def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace",
                          check=True).stdout


def outgoing(span: str) -> list[tuple[str, str]]:
    """(where, line) for every added line and message line in a push range."""
    lines = []
    for sha in git("rev-list", span).split():
        for line in git("log", "-1", "--format=%B", sha).splitlines():
            lines.append((f"{sha[:7]} message", line))
        current = "?"
        for line in git("show", "--format=", "-p", "--no-color", "--no-ext-diff", sha).splitlines():
            if line.startswith("+++ "):
                current = line[6:] if line.startswith("+++ b/") else line[4:]
            elif line.startswith("+"):
                lines.append((f"{sha[:7]} {current}", line[1:]))
    return lines


def hit_span(line: str, table: array) -> str | None:
    return next((w for w in windows(line) if present(table, digest(w))), None)


def patterns(name: str) -> list[re.Pattern]:
    compiled = []
    for line in read_lines(CONFIG / "patterns" / f"{name}.txt"):
        try:
            compiled.append(re.compile(line, re.IGNORECASE))
        except re.error as error:
            say(f"patterns/{name}.txt: {line!r} does not compile ({error})")
            sys.exit(2)
    return compiled


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--range", dest="span")
    parser.add_argument("--text", type=Path)
    parser.add_argument("--repo", type=Path, help="where the sending repository lives (default: here)")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args(argv)

    areas = load_areas()
    if not areas:
        say(f"NOT CHECKED — no areas defined in {CONFIG / 'areas.txt'} on this machine")
        return 0
    if args.refresh or args.status:
        if args.refresh:
            load(areas, refresh=True)
        summary = json.loads((CACHE / "summary.json").read_text()) if (CACHE / "summary.json").is_file() else None
        if summary:
            age = (time.time() - summary["built"]) / 3600
            say(f"fingerprints built {age:.1f}h ago (run {summary['run']}): " + ", ".join(
                f"{n} {a['documents']} documents / {a['fingerprints']} runs" for n, a in summary["areas"].items()))
        else:
            say("fingerprints not built yet")
        return 0
    if not (args.span or args.text):
        parser.error("give --range, --text, --refresh or --status")

    here = args.repo or Path(git("rev-parse", "--show-toplevel").strip() if args.span else os.getcwd())
    here = expand(str(here))
    if contains(areas.get(EXEMPT, []), here) and not any(
            contains(rs, here) for n, rs in areas.items() if n != EXEMPT):
        return 0
    checked = [n for n, roots in areas.items() if n != EXEMPT and not contains(roots, here)]
    if not checked:
        return 0

    if args.text:
        lines = [(f"{args.text.name}:{n}", line) for n, line in enumerate(
            args.text.read_text(encoding="utf-8", errors="replace").splitlines(), start=1)]
    else:
        lines = outgoing(args.span)

    prints = load(areas, refresh=False)
    found = []
    for name in checked:
        shapes = patterns(name)
        table = prints.get(name, array("Q"))
        for where, line in lines:
            match = next((m.group(0) for p in shapes if (m := p.search(line))), None)
            what = f"shape {match!r}" if match else None
            if not what and len(table):
                span = hit_span(line, table)
                what = f"text {span!r}" if span else None
            if what:
                found.append(f"{where}: {name} {what} in {normalize(line)[:80]!r}")
    if found:
        say(f"this carries text from a private area that {here} is outside of:")
        for line in found:
            print(f"    {line}", file=sys.stderr)
        say(f"replace it with made-up text, or add a phrase that is fine to {CONFIG / 'allow.txt'}")
        return 1
    say(f"clean ({len(lines)} lines against {', '.join(checked)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
