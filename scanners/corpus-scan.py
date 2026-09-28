#!/usr/bin/env python3
"""corpus-scan — stop text copied out of private documents from leaving its area.

The word list catches names someone thought to write down. Text copied from a
real document -- a sentence from a slide, a row of a table -- is on no list.
This scanner compares what is about to be sent with the documents themselves.

Areas are defined on this machine only (never in a repository):

    ~/.config/guard/areas.txt
        <name> <path> [<path> ...]     one area per line; nested paths belong
                                       to the innermost area
        <prefix>* <path>/* ...         one area per sub-folder of <path>, named
                                       <prefix><folder> (= a client folder made
                                       tomorrow is an area from the moment it exists)
        _exempt <path> ...             repositories that are never scanned
    ~/.config/guard/patterns/<name>.txt
        one regular expression per line (case-insensitive) for identifiers of
        that area that follow a shape: product codes, client names
    ~/.config/guard/allow.txt          phrases that are fine to send
    ~/.config/guard/ignore.txt         folders inside an area that hold no documents
                                       of it (an external corpus, build logs)
    ~/.config/guard/background.txt     folders of public text and code; whatever
                                       also appears there is not specific to an
                                       area and is dropped

An area's documents are everything under its paths that holds its words:

    prose  Office (.pptx .docx .xlsx, read from their XML), PDF (pdftotext),
           Markdown -- every run of RUN consecutive characters holding Japanese,
           or LATIN_RUN without, is a print
    rows   CSV, TSV, plain text -- every whole row of at least that length is a
           print, and one copied row is a hit
    lines  every other file a git repository there tracks (= its code and its
           Markdown) -- every whole line of at least that length is a print, and
           CODE_LINES consecutive copied lines are a hit (a lone common line --
           an import, an idiom -- is written by the same people everywhere)

Inside a repository only what it tracks counts (untracked output and vendored
third-party folders do not). A sent line is a hit when it holds a prose run or
is a whole printed row, and a block of CODE_LINES sent lines is a hit when each
is a whole printed line. Prints are kept per document and reused while the
document is unchanged; documents changed since the last look are found through
Spotlight and added at once. When Spotlight cannot answer (disabled, an area it
does not index, or inside a sandbox that can still list the area's folder) the
size and modification time each document's print was built from are compared
with what `stat` gives now instead, and only the folders whose modification time
moved are listed again (a file created, removed or renamed changes its folder's
time): a document edited, deleted or created since the last look is caught at
once without walking everything. A full walk still comes at least every six
hours (MAX_AGE). Only one process at a time walks or writes the
fingerprints (a lock file in the cache); the rest use what is already there
rather than wait or walk beside it.

What is checked depends on where the text is going: every area that does not
contain the destination. A repository inside an area may carry that area's
text, and an area nested inside another (a client inside a company) may carry
the outer one's.

The destination is the GitHub repository being sent to, not the folder the
command was typed in -- a pull request opened from inside a client folder onto
a public repository leaves the client all the same:

    public on GitHub                 outside every area, whatever folder its clone is in
    private, with a local clone      where that clone lives
    private, no clone on this machine, or visibility unknown
                                     outside every area (fail-closed)
    not on GitHub (a local path, another host)
                                     where the sending repository lives

    corpus-scan.py --range <from>..<to> [--dest <url>]   a push (pre-push passes the push URL;
                                          several bases come as "<to> ^<from> ^<from>")
    corpus-scan.py --text <file> --gh-argv <file>        one gh payload (gh-guard)
    corpus-scan.py --where [--dest <url> | --gh-argv <file>]
                                          print where the destination lives, or OUTSIDE
    corpus-scan.py --refresh              rebuild the fingerprints now
    corpus-scan.py --update               bring the fingerprints up to date (the changed documents,
                                          everything when a full walk is due)
    corpus-scan.py --status               what is configured and how fresh, naming each area and
                                          each document that could not be read, and why (for the
                                          operator)
    corpus-scan.py --summary              the same in counts, grouped by why, naming nothing (for
                                          output that an agent or a log reads: doctor, bootstrap)

Inside a sandbox that cannot open some area (a session caged by sandbox/), nothing is walked
and nothing cached is rewritten: the text is compared with the prints last built outside, an
area whose folder cannot be listed is taken from the areas those prints were built for, and an
area with no prints at all is a refusal. Run --update outside before entering the sandbox.

Exit: 0 clean or not configured, 1 hit, 2 usage / configuration error.
"""

from __future__ import annotations

import argparse
import bisect
import contextlib
import fcntl
import hashlib
import heapq
import html
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import unicodedata
import zipfile
from array import array
from collections import Counter
from pathlib import Path

# How many consecutive characters count as copied. Twelve characters of
# Japanese are a phrase; twelve of English are two common words ("machine with"),
# so a run without any Japanese has to be much longer before it means anything.
RUN = int(os.environ.get("GUARD_CORPUS_RUN", "12"))
LATIN_RUN = int(os.environ.get("GUARD_CORPUS_LATIN_RUN", "40"))
# How many consecutive whole lines of an area's code or data a sent file has to hold to be a hit.
CODE_LINES = int(os.environ.get("GUARD_CORPUS_CODE_LINES", "2"))
JAPANESE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]")
MAX_AGE = int(os.environ.get("GUARD_CORPUS_MAX_AGE", str(6 * 3600)))
BACKGROUND_MAX_AGE = 7 * 24 * 3600
CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
CACHE = Path(os.environ.get("GUARD_CORPUS_CACHE", Path.home() / ".cache/guard-corpus"))
EXEMPT = "_exempt"
OFFICE = {".pptx", ".docx", ".xlsx", ".pptm", ".docm", ".xlsm"}
TEXT = {".md", ".csv", ".tsv", ".txt"}
LOCKFILES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "poetry.lock", "uv.lock",
             "Gemfile.lock", "composer.lock", "go.sum"}
GENERATED = {".pbxproj", ".xcscheme", ".xcworkspacedata", ".storyboard", ".xib", ".plist", ".csproj", ".sln",
             ".vcxproj", ".filters", ".meta", ".uproject", ".uplugin"}
# Folders of a repository that hold someone else's code: public text, not the area's.
VENDORED = {"vendor", "vendors", "external", "extern", "third_party", "thirdparty", "third-party", "3rdparty"}
# Raised whenever a change to reading or printing makes the kept prints of an unchanged document wrong.
PRINT_FORMAT = 3
DOCS = CACHE / "docs"
INDEX = DOCS / "index.json"
# Every folder the last full walk went through, with its modification time: a file created, removed
# or renamed in a folder changes that folder's time, so the stat fallback of catch_up() finds new
# documents by listing only the folders whose time moved.
FOLDERS = DOCS / "folders.json"
# Past this many changed documents since the last full walk, walk again instead of growing the delta.
MAX_DELTA = 200
# One PDF's extractor gets far less than the judgement's own budget (send-scan.py's 120s for the
# whole scan): a single huge attachment must not eat that budget, so it is marked unreadable
# instead, on its own, well before the outer timeout could fire.
PDF_TIMEOUT = int(os.environ.get("GUARD_CORPUS_PDF_TIMEOUT", "30"))
TEXT_RUN = re.compile(r"<(?:a:|w:)?t(?:\s[^>]*)?>([^<]*)</(?:a:|w:)?t>")
SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "__pycache__", "third_party", "dist", "build",
             "target", ".fetchcontent-cache", "DerivedData", "site-packages", ".gradle", "obj", "bin",
             "Intermediate", "Binaries"}
MAX_FILE = 5_000_000
# A repository turned public is caught within this many seconds of the change.
VISIBILITY_TTL = int(os.environ.get("GUARD_VISIBILITY_TTL", "600"))
CLONES_TTL = 3600
OUTSIDE = "OUTSIDE"
GITHUB_URL = [
    re.compile(r"^(?:[a-z+]+://)?(?:[^@/]+@)?github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", re.I),
    # an ssh host alias (`git@github-work:owner/repo`) still lands on github.com
    re.compile(r"^(?:ssh://)?git@github[\w.-]*[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", re.I),
    re.compile(r"^([\w.-]+)/([\w.-]+)$"),
]
GH_API_REPO = re.compile(r"^/?repos/([\w.-]+)/([\w.-]+)")
COMMENT_MARKS = re.compile(r"^\s*(?:#+|//+|/\*+|\*+|--|;+|%+|<!--|'''|\"\"\")\s*|\s*(?:\*/|-->)\s*$")


def say(message: str) -> None:
    print(f"[corpus] {message}", file=sys.stderr)


def atomic_write(path: Path, data: bytes | str) -> None:
    """Write the whole of `path` at once: a temporary file next to it, then one rename. A reader
    never opens a half-written file, and two writers racing (one lost the lock between the check
    and the write) leave the last one's version whole, never a mix of both."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data.encode() if isinstance(data, str) else data)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


@contextlib.contextmanager
def lock_file(wait: bool):
    """The one lock a build or a catch-up takes, so several processes never write the same cache
    files at once: only the holder walks or writes; the rest read what is already there.

    Non-blocking unless `wait` (nothing usable exists yet, so there is nothing to fall back to,
    and this run must be the one that builds it). A process that loses a non-blocking race yields
    False having touched nothing -- it goes on to use whatever is already on disk."""
    CACHE.mkdir(parents=True, exist_ok=True)
    with open(CACHE / "build.lock", "a+") as fh:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def unreadable_reason(entry) -> str | None:
    """The reason an old-format entry (a bare path, from before this had one) or a new one
    ([path, reason]) carries, or None."""
    return entry[1] if isinstance(entry, list) and len(entry) > 1 else None


def unreadable_line(unreadable: list) -> str:
    """--summary / doctor's one line for documents that could not be read: how many, and how many
    for each reason (a time-out, a missing extractor, its exit code, ...) -- never which ones."""
    counts = Counter(unreadable_reason(e) or "could not be read" for e in unreadable)
    detail = ", ".join(f"{reason}: {n}" for reason, n in sorted(counts.items()))
    return f"{len(unreadable)} documents could not be read (see --status): {detail}"


def areas_count(names) -> str:
    """How many areas, without their names: a line printed on every push or `gh` call lands in
    whatever reads the output -- an agent's conversation, a CI log -- and an area's name names
    what it holds. A refusal still names the area, for the operator to act on."""
    n = len(names)
    return f"{n} area" + ("" if n == 1 else "s")


def expand(path: str) -> Path:
    return Path(os.path.realpath(os.path.expanduser(os.path.expandvars(path))))


def read_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def load_areas(source: Path | None = None) -> dict[str, list[Path]]:
    """Areas by name. A line whose name holds `*` and whose paths end in `/*` makes one
    area per sub-folder (`client-* /srv/company/clients/*` -> `client-acme` for `clients/acme`),
    so a folder created tomorrow is guarded from the moment it exists. A path already
    named on an explicit line keeps that line's name."""
    explicit: dict[str, list[Path]] = {}
    templates: list[tuple[str, list[Path]]] = []
    for line in read_lines(source or CONFIG / "areas.txt"):
        parts = shlex.split(line, comments=True)
        if len(parts) < 2:
            continue
        # A relative path would resolve against wherever the scan runs -- an `_exempt .` would
        # exempt every folder. A line that is not a definition is a broken file, not a pass.
        if bad := [p for p in parts[1:] if not p.startswith(("/", "~", "$"))]:
            raise ValueError(f"areas.txt: {line!r} names {bad[0]!r}, not an absolute or ~ path")
        if "*" in parts[0]:
            templates.append((parts[0], [expand(p[:-2]) for p in parts[1:] if p.endswith("/*")]))
        else:
            explicit.setdefault(parts[0], []).extend(expand(p) for p in parts[1:])
    areas = dict(explicit)
    named = {r for roots in explicit.values() for r in roots}
    for template, parents in templates:
        for parent in parents:
            try:
                children = [c for c in sorted(parent.iterdir()) if c.is_dir() and not c.name.startswith(".")]
            except (FileNotFoundError, NotADirectoryError):
                children = []
            except OSError:
                children = built_children(template, parent)
            for child in children:
                child = expand(str(child))
                if child not in named:
                    areas.setdefault(template.replace("*", child.name), []).append(child)
    return areas


def built_children(template: str, parent: Path) -> list[Path]:
    """The sub-folders of `parent` the prints were built for, when this process cannot list it."""
    prefix, suffix = template.split("*", 1)
    summary = built_summary()
    if summary is None:
        raise ValueError(f"cannot list {parent} here and no prints were built where it can be "
                         f"read: run corpus-scan.py --update outside the sandbox")
    return sorted(parent / n[len(prefix):len(n) - len(suffix)] for n in summary["areas"]
                  if n.startswith(prefix) and n.endswith(suffix) and len(n) > len(prefix) + len(suffix))


def built_summary() -> dict | None:
    try:
        return json.loads((CACHE / "summary.json").read_text())
    except (OSError, ValueError):
        return None


def sealed(areas: dict[str, list[Path]]) -> list[str]:
    """Areas this process cannot open: it runs in a sandbox, and may only use what was built outside."""
    shut = []
    for name, roots in areas.items():
        if name == EXEMPT:
            continue
        for root in roots:
            try:
                with os.scandir(root):
                    pass
            except (FileNotFoundError, NotADirectoryError):
                continue
            except OSError:
                shut.append(name)
                break
    return shut


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


def line_print(line: str, kind: str = "line") -> int | None:
    """One print for a whole line of code ("line") or a row of data ("row"), long enough to mean
    something on its own (the same bar as a run: 12 characters holding Japanese, 40 without).
    Code is copied line by line, and printing every run of every line would hold hundreds of
    millions of values. The kinds are kept apart: a row is one hit, code takes CODE_LINES."""
    text = normalize(line)
    if len(text) >= LATIN_RUN or (len(text) >= RUN and len(JAPANESE.findall(text)) * 2 >= len(text)):
        return digest(f"\0{kind}\0" + text)
    return None


# --- building an area's fingerprints ------------------------------------------

def office_units(path: Path) -> list[str]:
    units = []
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.endswith(".xml"):
                xml = archive.read(name).decode("utf-8", "replace")
                units += [html.unescape(t) for t in TEXT_RUN.findall(xml)]
    return units


def join_wrapped(lines: list[str]) -> list[str]:
    """A PDF breaks a sentence wherever the page ran out of width. Paragraphs are rejoined --
    without a space between two Japanese characters, with one otherwise -- so a sentence
    copied out whole still holds the runs the page split."""
    paragraphs, current = [], ""
    for line in lines:
        line = line.strip()
        if not line:
            if current:
                paragraphs.append(current)
            current = ""
            continue
        glue = "" if current and JAPANESE.match(current[-1]) and JAPANESE.match(line[0]) else " "
        current = f"{current}{glue}{line}" if current else line
    if current:
        paragraphs.append(current)
    return paragraphs


def pdf_units(path: Path) -> list[str]:
    run = subprocess.run(["pdftotext", "-q", "-enc", "UTF-8", str(path), "-"], capture_output=True,
                         timeout=PDF_TIMEOUT)
    if run.returncode != 0:
        raise OSError(f"pdftotext exited {run.returncode}")
    return join_wrapped(run.stdout.decode("utf-8", "replace").splitlines())


def text_units(path: Path) -> list[str]:
    data = path.read_bytes()
    if b"\0" in data[:8192]:          # binary under a text name
        return []
    return data.decode("utf-8", "replace").splitlines()


def unit_reader(path: Path, tracked: bool):
    """(kind, read) for a file, or None when it is not a document. kind "runs" prints every run
    of prose (Office, PDF, Markdown outside repositories); kind "rows" prints whole rows of data
    (CSV, TSV, plain text); kind "lines" prints whole lines of code (every other file a repository
    tracks, its Markdown included), which is what an agent most easily copies."""
    suffix, name = path.suffix.lower(), path.name
    if name.startswith("~$") or name in LOCKFILES or suffix in {".lock", ".map"} or name.endswith(".min.js"):
        return None
    # Public boilerplate: license texts, and project files an IDE writes from its own template.
    if name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")) or suffix in GENERATED:
        return None
    if suffix in OFFICE:
        # Office files are measured by their text, not their size: a deck is
        # mostly images, and its XML parts stay small however large it gets.
        return "runs", lambda: office_units(path)
    if suffix == ".pdf":
        return "runs", lambda: pdf_units(path)
    if suffix == ".md" and not tracked:
        return "runs", lambda: text_units(path)
    # Markdown a repository tracks documents its code, in the words its authors use everywhere:
    # it is matched by the line, like the code, not by the run like a slide.
    if suffix in TEXT - {".md"}:
        return "rows", lambda: text_units(path)
    if suffix == ".md" or tracked:
        return "lines", lambda: text_units(path)
    return None


class Repos:
    """Which repository a file belongs to, and what that repository tracks (asked once per repository)."""

    def __init__(self) -> None:
        self.names: dict[Path, set[str]] = {}

    def of(self, folder: Path) -> Path | None:
        return next((p for p in [folder, *folder.parents] if (p / ".git").exists()), None)

    def tracked(self, repo: Path) -> set[str]:
        if repo not in self.names:
            out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True).stdout
            self.names[repo] = {n.decode("utf-8", "replace") for n in out.split(b"\0") if n}
        return self.names[repo]

    def reader(self, path: Path, repo: Path | None | bool = False, root: Path | None = None):
        """unit_reader for a file, applying the repository rule: inside a repository only what it
        tracks, minus vendored code (= untracked output and third-party copies are not its documents).
        Office files and PDFs count wherever they sit. `repo` may be passed when already known.

        Only a repository that lies inside the area (`root`) is the area's. One that holds the area
        from outside -- an agent's own state tree with a folder for the company -- keeps its notes,
        not the area's documents: only its Office files and PDFs are read."""
        if repo is False:
            repo = self.of(path.parent)
        if repo is not None and root is not None and not (repo == root or root in repo.parents):
            return unit_reader(path, tracked=False) if path.suffix.lower() in OFFICE | {".pdf"} else None
        if repo is not None and path.suffix.lower() not in OFFICE | {".pdf"}:
            relative = str(path.relative_to(repo))
            if relative not in self.tracked(repo) or any(p.lower() in VENDORED for p in Path(relative).parts[:-1]):
                return None
        return unit_reader(path, tracked=repo is not None)


def document(path: Path, repos: Repos, repo: Path | None | bool = False, root: Path | None = None):
    """(stamp, (kind, read)) for a document, or None. The stamp changes whenever the content may have."""
    reader = repos.reader(path, repo, root)
    if reader is None:
        return None
    try:
        st = path.stat()
    except OSError:
        return None
    if not path.is_file() or (st.st_size > MAX_FILE and path.suffix.lower() not in OFFICE | {".pdf"}):
        return None
    # How a document is read is part of its stamp: prints made the old way are never reused.
    return f"{PRINT_FORMAT}:{reader[0]}:{st.st_mtime_ns}:{st.st_size}", reader


def documents(roots: list[Path], inner: list[Path], ignored: list[Path], repos: Repos,
              folders: dict | None = None):
    """(path, stamp, read) for every document under roots, skipping nested areas and ignored folders.
    Every folder walked goes into `folders` with its modification time (for catch_up())."""
    for root in roots:
        repo_of = {root: repos.of(root)}     # a folder's repository is its own, or its parent's
        for folder, dirs, files in os.walk(root):
            here = Path(folder)
            if here != root:
                repo_of[here] = here if (here / ".git").exists() else repo_of[here.parent]
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")
                       and here / d not in inner and here / d not in ignored]
            if folders is not None:
                with contextlib.suppress(OSError):
                    folders[folder] = here.stat().st_mtime_ns
            for name in files:
                found = document(here / name, repos, repo_of[here], root)
                if found:
                    yield (here / name, *found)


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
            if not name:
                continue
            blob = subprocess.run(["git", "-C", repo, "show", f"{head}:{name}"], capture_output=True)
            if blob.returncode == 0 and len(blob.stdout) <= MAX_FILE and b"\0" not in blob.stdout[:8192]:
                yield name, blob.stdout.decode("utf-8", "replace")


def public_prints(name: str, text: str) -> set[int]:
    """What a public file makes unremarkable: every run of its prose, every line of its code."""
    prints = {v for line in text.splitlines() if (v := line_print(line)) is not None}
    if (Path(name).suffix.lower() in {".md", ".rst", ".txt"}
            or Path(name).name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE"))):
        # A license reads the same however each copy wraps its lines, so its runs are kept too.
        prints |= fingerprints(text)
    return prints


def background_prints() -> array:
    """Runs of public text, sorted. Public text changes rarely, so it keeps for a week."""
    # The format is in the name: public text read another way is never mistaken for the old table.
    cached, source = CACHE / f"background-{PRINT_FORMAT}.bin", CONFIG / "background.txt"
    if (cached.is_file() and source.is_file() and cached.stat().st_mtime > source.stat().st_mtime
            and time.time() - cached.stat().st_mtime < BACKGROUND_MAX_AGE):
        table = array("Q")
        table.frombytes(cached.read_bytes())
        return table
    prints: set[int] = set()
    for entry in read_lines(source):
        if entry.startswith("published "):
            for name, text in published_texts(expand(entry.split(None, 1)[1])):
                prints |= public_prints(name, text)
            continue
        for folder, dirs, files in os.walk(expand(entry)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
            for name in files:
                path = Path(folder, name)
                try:
                    if path.stat().st_size > MAX_FILE or path.is_symlink():
                        continue
                    data = path.read_bytes()
                except OSError:
                    continue
                if b"\0" not in data[:8192]:
                    prints |= public_prints(name, data.decode("utf-8", "replace"))
    table = array("Q", sorted(prints))
    atomic_write(cached, table.tobytes())
    return table


def present(table: array, value: int) -> bool:
    at = bisect.bisect_left(table, value)
    return at < len(table) and table[at] == value


def read_table(path: Path) -> array:
    table = array("Q")
    if path.is_file():
        table.frombytes(path.read_bytes())
    return table


def inner_roots(areas: dict[str, list[Path]], name: str) -> list[Path]:
    return [r for other, rs in areas.items() if other != name for r in rs
            if any(r != root and root in r.parents for root in areas[name])]


def area_of_path(areas: dict[str, list[Path]], path: Path) -> str | None:
    """The innermost area holding path (= the one whose root is longest)."""
    best = max(((len(r.parts), n) for n, rs in areas.items() for r in rs if path == r or r in path.parents),
               default=None)
    return best[1] if best else None


def document_prints(path: Path, stamp: str, read, known: dict, index: dict, area: str) -> tuple[bool, str | None]:
    """Make sure one document's runs are on disk; reuse them while its stamp holds.
    (False, why) = unreadable, why said plainly enough that --status / --summary can group by it
    without naming the document (a time-out, a missing extractor, or its exit code)."""
    key = str(path)
    fid = hashlib.sha1(key.encode()).hexdigest()
    cached = known.get(key)
    if not (cached and cached[0] == stamp and (DOCS / f"{fid}.bin").is_file()):
        kind, reader = read
        try:
            units = reader()
        except subprocess.TimeoutExpired:
            return False, "timed out"
        except FileNotFoundError:
            return False, "the extractor is not installed"
        except zipfile.BadZipFile:
            return False, "not a valid Office document"
        except (OSError, ValueError) as error:
            return False, str(error) or error.__class__.__name__
        prints: set[int] = set()
        for unit in units:
            if kind == "runs":
                prints |= fingerprints(unit)
            elif (value := line_print(unit, "row" if kind == "rows" else "line")) is not None:
                prints.add(value)
        atomic_write(DOCS / f"{fid}.bin", array("Q", sorted(prints)).tobytes())
    index[key] = [stamp, fid, area]
    return True, None


def merged(fids: list[str], allowed: set[int], public: array) -> array:
    """The union of many documents' sorted runs, minus what is fine to send or public."""
    out, last = array("Q"), None
    for value in heapq.merge(*(read_table(DOCS / f"{f}.bin") for f in fids)):
        if value != last and value not in allowed and not present(public, value):
            out.append(value)
        last = value
    return out


def build(areas: dict[str, list[Path]], full: bool = True) -> dict:
    """_build_locked, but only one process at a time walks and writes: the lock is taken first, and
    a process that cannot take it right away uses the summary already on disk instead of waiting or
    walking beside whoever holds it. Waiting is only worth it when there is nothing on disk yet to
    fall back to (a fresh machine, or the cache wiped by --refresh)."""
    have_index = (CACHE / "summary.json").is_file()
    with lock_file(wait=not have_index) as acquired:
        if acquired:
            return _build_locked(areas, full)
    existing = built_summary()
    if existing is not None:
        return existing
    # have_index was true a moment ago and yet nothing is there now, and the non-blocking try
    # above lost the race anyway: vanishingly rare, and waiting properly is the safe way out.
    with lock_file(wait=True):
        return _build_locked(areas, full)


def _build_locked(areas: dict[str, list[Path]], full: bool) -> dict:
    """Walk every area and reuse the runs of every document whose stamp holds. A full build merges
    each area's table anew; otherwise the documents that changed go to the area's delta table and
    the merge waits until the delta grows past MAX_DELTA (= a walk costs the walk, not the merge).
    A document gone from disk stays in the table until the next full build (= the safe side)."""
    started = time.time()
    public = background_prints()
    allowed: set[int] = set()
    for phrase in read_lines(CONFIG / "allow.txt"):
        allowed |= fingerprints(phrase)
    DOCS.mkdir(parents=True, exist_ok=True)
    old = json.loads(INDEX.read_text()) if INDEX.is_file() else {}
    previous = json.loads((CACHE / "summary.json").read_text()) if (CACHE / "summary.json").is_file() else {}
    index: dict = {}
    ignored = [expand(p) for p in read_lines(CONFIG / "ignore.txt")]
    repos = Repos()
    summary = {"built": started, "checked": started, "run": [RUN, LATIN_RUN], "areas": {}, "unreadable": []}
    folders: dict = {}
    for name, roots in areas.items():
        if name == EXEMPT:
            continue
        fids, changed = [], []
        for path, stamp, read in documents(roots, inner_roots(areas, name), ignored, repos, folders):
            key = str(path)
            fresh = key not in old or old[key][0] != stamp or old[key][2] != name
            ok, why = document_prints(path, stamp, read, old, index, name)
            if not ok:
                summary["unreadable"].append([key, why])
                continue
            fids.append(index[key][1])
            if fresh or (not full and old[key][-1] == "delta"):
                index[key].append("delta")
                changed.append(index[key][1])
        base = CACHE / f"{name}.bin"
        keep_base = (not full and base.is_file() and name in previous.get("areas", {})
                     and len(changed) <= MAX_DELTA)
        if keep_base:
            atomic_write(CACHE / f"{name}.delta.bin", merged(changed, allowed, public).tobytes())
            count = len(read_table(base))
        else:
            table = merged(fids, allowed, public)
            atomic_write(base, table.tobytes())
            (CACHE / f"{name}.delta.bin").unlink(missing_ok=True)
            for key, entry in index.items():
                if entry[2] == name and entry[-1] == "delta":
                    entry.pop()
            count = len(table)
        summary["areas"][name] = {"documents": len(fids), "fingerprints": count}
    kept = {v[1] for v in index.values()}
    for stale in {v[1] for v in old.values()} - kept:
        (DOCS / f"{stale}.bin").unlink(missing_ok=True)
    atomic_write(INDEX, json.dumps(index))
    atomic_write(FOLDERS, json.dumps(folders))
    summary["seconds"] = round(time.time() - started, 1)
    atomic_write(CACHE / "summary.json", json.dumps(summary, indent=1))
    return summary


def spotlight_changes(roots: list[Path], since: float, known: dict) -> list[Path] | None:
    """Files under roots whose content changed since `since`, as Spotlight knows them.
    None when Spotlight cannot be trusted to answer: not macOS, indexing off, an error, or a
    root it does not index (= it cannot find a document already known to be there)."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since - 60))   # a minute of slack for the indexer
    tops = [r for r in set(roots) if not any(o != r and o in r.parents for o in roots)]
    mounts = set()
    for root in tops:
        mount = root
        while not os.path.ismount(mount) and mount != mount.parent:
            mount = mount.parent
        mounts.add(mount)
    # Every question at once: each is a separate indexer round trip.
    asks: list[tuple[str, Path | None, subprocess.Popen]] = []
    try:
        for mount in mounts:
            asks.append(("state", None, subprocess.Popen(["mdutil", "-s", str(mount)], stdout=subprocess.PIPE,
                                                         stderr=subprocess.DEVNULL, text=True)))
        for root in tops:
            # Known paths and roots are both absolute and normalised, so a prefix is the parent test
            # (building a Path per known document costs a second on tens of thousands of them).
            inside = f"{root}{os.sep}"
            probe = next((Path(k) for k in known if k.startswith(inside) and os.path.isfile(k)), None)
            if probe is not None:
                asks.append(("probe", probe, subprocess.Popen(
                    ["mdfind", "-onlyin", str(probe.parent), "-name", probe.name],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)))
            asks.append(("changed", root, subprocess.Popen(
                ["mdfind", "-onlyin", str(root), f"kMDItemFSContentChangeDate >= $time.iso({stamp})"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)))
    except OSError:
        return None
    found: list[Path] = []
    for kind, subject, ask in asks:
        try:
            out, _ = ask.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            ask.kill()
            return None
        if ask.returncode != 0:
            return None
        if kind == "state" and "Indexing enabled" not in out:
            return None
        if kind == "probe" and str(subject) not in out.splitlines():
            return None
        if kind == "changed":
            found += [Path(p) for p in out.splitlines() if p]
    return found


def stamp_stat(stamp: str) -> tuple[int, int] | None:
    """(mtime_ns, size) a document's stamp holds, or None when this cannot parse it (an older
    PRINT_FORMAT, or something malformed) -- then it is safest read as changed, not trusted."""
    parts = stamp.split(":")
    if len(parts) != 4 or parts[0] != str(PRINT_FORMAT):
        return None
    try:
        return int(parts[2]), int(parts[3])
    except ValueError:
        return None


def stat_changes(index: dict) -> tuple[list[Path], list[Path]]:
    """(changed, removed) among the documents the index already knows, found by comparing the
    size and modification time it recorded with what `stat` gives now -- no folder is listed and
    no file is opened. This is the fallback for when Spotlight cannot answer (disabled, or inside
    a sandbox): it catches every one of them edited or deleted since the last look; the documents
    created since then are folder_changes()'. A stamp this cannot parse counts as changed: its
    print is rebuilt rather than trusted on faith."""
    changed, removed = [], []
    for key, entry in index.items():
        path = Path(key)
        known = stamp_stat(entry[0])
        try:
            st = path.stat()
        except OSError:
            removed.append(path)
            continue
        if known is None or (st.st_mtime_ns, st.st_size) != known:
            changed.append(path)
    return changed, removed


def folder_changes(index: dict) -> list[Path] | None:
    """Files the index does not know yet in the folders whose modification time moved since the
    last look -- the documents created since then, which stat_changes() cannot see (creating,
    removing or renaming a file changes its folder's time). Only those folders are listed; a new
    folder is walked whole. The folder list is brought up to date. None when there is no folder
    list yet (a cache from before it was kept): the caller then walks everything once."""
    if not FOLDERS.is_file():
        return None
    folders = json.loads(FOLDERS.read_text())
    new: list[Path] = []
    moved = False
    for folder, mtime in list(folders.items()):
        here = Path(folder)
        try:
            now = here.stat().st_mtime_ns
        except OSError:
            folders.pop(folder)
            moved = True
            continue
        if now == mtime:
            continue
        folders[folder] = now
        moved = True
        with contextlib.suppress(OSError):
            for entry in os.scandir(here):
                if entry.name.startswith(".") or entry.name in SKIP_DIRS:
                    continue
                path = here / entry.name
                if entry.is_dir(follow_symlinks=False):
                    if str(path) in folders:
                        continue
                    for sub, dirs, files in os.walk(path):
                        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
                        with contextlib.suppress(OSError):
                            folders[sub] = Path(sub).stat().st_mtime_ns
                        new += [Path(sub) / f for f in files]
                elif entry.is_file(follow_symlinks=False) and str(path) not in index:
                    new.append(path)
    if moved:
        atomic_write(FOLDERS, json.dumps(folders))
    return new


def catch_up(areas: dict[str, list[Path]], summary: dict) -> dict | None:
    """Add the documents changed since the last look to per-area delta tables.
    None = a full walk is needed instead (Spotlight could not answer and the delta this fell back
    to grew large). A deleted document Spotlight reports stays in the tables until the next full
    walk (= the safe side); one the stat fallback finds gone is dropped from the index at once (it
    can name no folder to have missed a new document in, so there is nothing more to catch there).

    Skipped, unchanged, when another process already holds the build lock: its own update (or
    the fuller one under way) is used instead of two processes walking or writing together."""
    with lock_file(wait=False) as acquired:
        if not acquired:
            return summary
        index = json.loads(INDEX.read_text()) if INDEX.is_file() else {}
        roots = [r for n, rs in areas.items() if n != EXEMPT for r in rs]
        changed = spotlight_changes(roots, summary["checked"], index)
        removed: list[Path] = []
        if changed is None:
            created = folder_changes(index)
            if created is None:
                return None
            changed, removed = stat_changes(index)
            changed += created
        started = time.time()
        ignored = [expand(p) for p in read_lines(CONFIG / "ignore.txt")]
        repos = Repos()
        touched: set[str] = set()
        dropped = False
        for path in removed:
            stale = index.pop(str(path), None)
            if stale is None:
                continue
            dropped = True
            if not any(v[1] == stale[1] for v in index.values()):
                (DOCS / f"{stale[1]}.bin").unlink(missing_ok=True)
        for path in changed:
            path = expand(str(path))
            area = area_of_path(areas, path)
            if area in (None, EXEMPT) or any(path == i or i in path.parents for i in ignored):
                continue
            root = max((r for r in areas[area] if r in path.parents), key=lambda r: len(r.parts))
            if any(p in SKIP_DIRS or p.startswith(".") for p in path.relative_to(root).parts[:-1]):
                continue
            found = document(path, repos, root=root)
            ok = found and document_prints(path, *found, index, index, area)[0]
            if ok:
                index[str(path)].append("delta")
                touched.add(area)
        deltas = {n: [v[1] for v in index.values() if v[2] == n and v[-1] == "delta"] for n in touched}
        if sum(len(f) for f in deltas.values()) > MAX_DELTA:
            return None
        if touched:
            allowed: set[int] = set()
            for phrase in read_lines(CONFIG / "allow.txt"):
                allowed |= fingerprints(phrase)
            public = background_prints()
            for name, fids in deltas.items():
                atomic_write(CACHE / f"{name}.delta.bin", merged(fids, allowed, public).tobytes())
        if touched or dropped:
            atomic_write(INDEX, json.dumps(index))
        summary["checked"] = started
        atomic_write(CACHE / "summary.json", json.dumps(summary, indent=1))
        return summary


def load(areas: dict[str, list[Path]], refresh: bool) -> dict[str, list[array]]:
    """Per area, the tables a sent line is looked up in: the full build and what changed since."""
    if shut := sealed(areas):
        # A walk from in here would build the shut areas empty and overwrite their prints.
        summary = built_summary()
        missing = [n for n in areas if n != EXEMPT and (summary is None or n not in summary["areas"])]
        if refresh or summary is None or summary["run"] != [RUN, LATIN_RUN] or missing:
            raise ValueError(f"{', '.join(shut)} cannot be opened here and "
                             + ("the prints cannot be rebuilt from inside" if refresh else
                                f"no prints were built for {', '.join(missing) or 'these settings'}")
                             + ": run corpus-scan.py --update outside the sandbox")
        built = time.strftime("%Y-%m-%d %H:%M", time.localtime(summary["checked"] or summary["built"]))
        say(f"{areas_count(shut)} cannot be opened here -- compared with the prints built outside at {built}")
        return {name: [read_table(CACHE / f"{name}.bin"), read_table(CACHE / f"{name}.delta.bin")]
                for name in summary["areas"]}
    summary_path = CACHE / "summary.json"
    summary, full = None, True
    if summary_path.is_file() and not refresh:
        summary = json.loads(summary_path.read_text())
        current = (summary.get("checked") and summary["run"] == [RUN, LATIN_RUN]
                   and set(summary["areas"]) == {n for n in areas if n != EXEMPT})
        full = not current
        if not current or time.time() - summary["built"] >= MAX_AGE:
            summary = None
        else:
            summary = catch_up(areas, summary)
    if summary is None:
        say("walking the private documents (unchanged ones are reused)...")
        summary = build(areas, full=full)
        documents = sum(a["documents"] for a in summary["areas"].values())
        say(f"built in {summary['seconds']}s: {documents} documents in {areas_count(summary['areas'])}"
            " (--status names them)")
        if summary["unreadable"]:
            say(unreadable_line(summary["unreadable"]))
    return {name: [read_table(CACHE / f"{name}.bin"), read_table(CACHE / f"{name}.delta.bin")]
            for name in summary["areas"]}


# --- where the text is going --------------------------------------------------

def github_repo(url: str) -> str | None:
    """owner/repo (lower case) of a GitHub remote URL or slug; None for anything else."""
    url = url.strip()
    if not url or url.startswith(("/", ".", "~", "file:")):
        return None
    for shape in GITHUB_URL:
        m = shape.match(url)
        if m:
            return f"{m.group(1)}/{m.group(2)}".lower()
    return None


def remote_repos(folder: Path) -> set[str]:
    out = subprocess.run(["git", "-C", str(folder), "remote", "-v"], capture_output=True, text=True).stdout
    return {slug for line in out.splitlines() if len(line.split()) >= 2
            and (slug := github_repo(line.split()[1]))}


def authenticated_visibility(slug: str) -> str:
    """Ask as every account gh holds: a token in the environment (often scoped to a few
    repositories) first, then the accounts in gh's own store."""
    plain = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    for env in (dict(os.environ), plain):
        try:
            r = subprocess.run(["gh", "api", f"repos/{slug}", "--jq", ".private"], capture_output=True,
                               text=True, timeout=15, env={**env, "GH_GUARD_SKIP": "1"})
        except (OSError, subprocess.TimeoutExpired):
            continue
        seen = {"true": "private", "false": "public"}.get(r.stdout.strip())
        if r.returncode == 0 and seen:
            return seen
    return "unknown"


def visibility(slug: str) -> str:
    """public / private / unknown. Asked without credentials first: only a public repository answers that."""
    path = CACHE / "visibility.json"
    try:
        known = json.loads(path.read_text())
    except (OSError, ValueError):
        known = {}
    hit = known.get(slug)
    if hit and time.time() - hit[1] < VISIBILITY_TTL:
        return hit[0]
    # Loaded here, not at the top: every hook call loads this module to read the areas, and the
    # network stack (urllib, http.client, ssl) was half of that call's time.
    import urllib.request
    request = urllib.request.Request(f"https://api.github.com/repos/{slug}",
                                     headers={"Accept": "application/vnd.github+json", "User-Agent": "guard"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            answer = "private" if json.load(response).get("private") else "public"
    except (OSError, ValueError):
        # 404 = private or not there at all; anything else = no answer. Only credentials can tell.
        answer = authenticated_visibility(slug)
    if answer != "unknown":
        known[slug] = [answer, time.time()]
        CACHE.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(known))
    return answer


def clones(areas: dict[str, list[Path]]) -> dict[str, list[str]]:
    """owner/repo -> the local clones under every area, rebuilt hourly."""
    path = CACHE / "clones.json"
    shut = sealed(areas)
    try:
        cached = json.loads(path.read_text())
        # Inside a sandbox a walk misses the shut areas: the map built outside is the better one.
        if shut or time.time() - cached["built"] < CLONES_TTL:
            return cached["map"]
    except (OSError, ValueError, KeyError):
        pass
    found: dict[str, list[str]] = {}
    for root in {r for rs in areas.values() for r in rs}:
        for folder, dirs, _ in os.walk(root):
            here = Path(folder)
            if (here / ".git").is_dir():
                for slug in remote_repos(here):
                    found.setdefault(slug, []).append(str(here))
            deep = len(here.parts) - len(root.parts) >= 5
            dirs[:] = [] if deep else [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
    if not shut:
        CACHE.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"built": time.time(), "map": found}))
    return found


def containing(place: Path, areas: dict[str, list[Path]]) -> frozenset[str]:
    return frozenset(n for n, roots in areas.items() if contains(roots, place))


def destination(slugs: set[str], sender: Path, areas: dict[str, list[Path]]) -> Path | None:
    """Where the destination lives; None = outside every area."""
    if not slugs:
        say("destination could not be told -- checked against every area")
        return None
    places: set[Path] = set()
    for slug in sorted(slugs):
        seen = visibility(slug)
        if seen != "private":
            say(f"destination {slug} is {seen} on GitHub -- checked against every area")
            return None
        if slug in remote_repos(sender):
            places.add(sender)
            continue
        local = [Path(p) for p in clones(areas).get(slug, [])]
        if not local:
            say(f"destination {slug} has no clone on this machine -- checked against every area")
            return None
        places.update(local)
    # Clones that sit in different areas may carry different things: only agreement decides.
    if len({containing(p, areas) for p in places}) != 1:
        say(f"destination {', '.join(sorted(slugs))} has clones in different areas -- checked against every area")
        return None
    return sorted(places)[0]


def gh_destinations(argv: list[str], cwd: Path) -> set[str]:
    """owner/repo a gh call sends to, the way gh picks it; empty when it cannot be told."""
    named = None
    for i, arg in enumerate(argv):
        if arg in ("-R", "--repo") and i + 1 < len(argv):
            named = argv[i + 1]
        elif arg.startswith("--repo="):
            named = arg.split("=", 1)[1]
        elif arg.startswith("-R") and len(arg) > 2:
            named = arg[2:]
    named = named or os.environ.get("GH_REPO")
    if named:
        slug = github_repo(named)
        return {slug} if slug else set()
    words = [a for a in argv if not a.startswith("-")]
    if words[:1] == ["api"]:
        slugs = {f"{m.group(1)}/{m.group(2)}".lower() for a in argv if (m := GH_API_REPO.match(a))}
        return slugs
    if words[:1] == ["gist"] or words[:2] == ["repo", "create"]:
        return set()
    # Otherwise gh sends to the repository of the folder it runs in.
    return remote_repos(cwd)


# --- what is being sent -------------------------------------------------------

def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace",
                          check=True).stdout


def sending_repo() -> str:
    """Where the pushing repository lives: its work tree, or for a bare repository its git dir."""
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode == 0 and top.stdout.strip():
        return top.stdout.strip()
    return git("rev-parse", "--absolute-git-dir").strip()


def outgoing(span: str) -> list[tuple[str, str]]:
    """(where, line) for every added line and message line in a push range
    (`<from>..<to>`, or `<to> ^<from> [^<from>...]` when it has several bases)."""
    # One git call for the whole range: each commit comes as \0<sha>\0<message>\0<patch>.
    # --cc gives a merge the same patch `git show` would.
    log = git("log", "--format=%x00%H%x00%B%x00", "-p", "--cc", "--no-color", "--no-ext-diff", *span.split())
    parts = log.split("\0")
    lines = []
    for sha, message, patch in zip(parts[1::3], parts[2::3], parts[3::3]):
        for line in (message + "\n").splitlines():
            lines.append((f"{sha[:7]} message", line))
        current = "?"
        for line in patch.splitlines():
            if line.startswith("+++ "):
                current = line[6:] if line.startswith("+++ b/") else line[4:]
            elif line.startswith("+"):
                lines.append((f"{sha[:7]} {current}", line[1:]))
    return lines


def hit(line: str, tables: list[array], allowed: list[str] = (), public: array = array("Q")) -> tuple[str, str] | None:
    """("line", text) when a sent line is a whole line of an area's code or data, ("run", run) when
    it holds a run of the area's prose, else None.

    Phrases that are fine to send are taken out of the line first, so a run reaching one character
    past an allowed phrase is not a hit either. A whole line all of whose runs are public text (a
    license wrapped differently in each copy) is not the area's."""
    # normalize() is idempotent, so the line is folded again only after a phrase came out of it.
    folded = False
    for phrase in allowed:
        if not folded:
            line, folded = normalize(line), True
        if phrase in line:
            line, folded = line.replace(phrase, " "), False
    def is_public() -> bool:
        # A comment marker is how a file holds the text, not the text: `# THIS SOFTWARE IS ...`
        # is still the license.
        runs = [digest(w) for w in windows(COMMENT_MARKS.sub("", normalize(line)))]
        return bool(runs) and all(present(public, r) for r in runs)

    for kind in ("row", "line"):
        whole = line_print(line, kind)
        if whole is not None and any(present(t, whole) for t in tables) and not is_public():
            return kind, normalize(line)
    run = next((w for w in windows(line) if any(present(t, digest(w)) for t in tables)), None)
    return ("run", run) if run else None


def keep_blocks(results: list, lines_in_a_row: int) -> list:
    """Drop whole-line hits that are not part of `lines_in_a_row` consecutive hit lines of one
    file or message: a single common line (an import, an idiom) is written by the same people in
    every code base, while copied code arrives as a block."""
    if lines_in_a_row <= 1:
        return results
    kept = list(results)
    start = 0
    while start < len(results):
        end = start
        while (end + 1 < len(results) and results[end + 1][0] == results[start][0]
               and results[end + 1][3] and results[end + 1][3][0] == "line"
               and results[end][3] and results[end][3][0] == "line"):
            end += 1
        if results[start][3] and results[start][3][0] == "line" and end - start + 1 < lines_in_a_row:
            for i in range(start, end + 1):
                kept[i] = (*results[i][:3], None)
        start = end + 1
    return kept


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
    parser.add_argument("--dest", help="the remote URL (or owner/repo) the text is sent to")
    parser.add_argument("--gh-argv", type=Path, help="a file holding the NUL-separated arguments of a gh call")
    parser.add_argument("--dest-area", help=f"the area the text is sent into, or {OUTSIDE} "
                        "(a service a tool sends to, declared in destinations.txt)")
    parser.add_argument("--where", action="store_true", help=f"print where the destination lives, or {OUTSIDE}")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args(argv)

    try:
        areas = load_areas()
    except ValueError as error:
        say(f"REFUSED — {error} (fix {CONFIG / 'areas.txt'})")
        return 2
    if not areas:
        say(f"NOT CHECKED — no areas defined in {CONFIG / 'areas.txt'} on this machine")
        return 0
    if args.refresh or args.update or args.status or args.summary:
        try:
            if args.refresh:
                if sealed(areas):
                    load(areas, refresh=True)  # refuses: nothing is rebuilt from inside a sandbox
                for stale in ("visibility.json", "clones.json"):
                    (CACHE / stale).unlink(missing_ok=True)
                load(areas, refresh=True)
            elif args.update:
                load(areas, refresh=False)
        except ValueError as error:
            say(f"REFUSED — {error}")
            return 2
        summary = json.loads((CACHE / "summary.json").read_text()) if (CACHE / "summary.json").is_file() else None
        if summary:
            age = (time.time() - summary["built"]) / 3600
            built = f"fingerprints built {age:.1f}h ago (run {summary['run']}): "
            # Only --status names areas and files: every other mode prints into whatever runs it
            # -- a session starting through --update, doctor under an agent -- and a name says
            # what the area holds.
            if args.status:
                say(built + ", ".join(f"{n} {a['documents']} documents / {a['fingerprints']} prints"
                                      for n, a in summary["areas"].items()))
            else:
                areas_built = summary["areas"].values()
                say(built + f"{sum(a['documents'] for a in areas_built)} documents / "
                    f"{sum(a['fingerprints'] for a in areas_built)} prints in {areas_count(summary['areas'])}")
            unreadable = summary.get("unreadable", [])
            if args.status:
                for entry in unreadable:
                    path = entry[0] if isinstance(entry, list) else entry
                    reason = unreadable_reason(entry)
                    say(f"could not read (not checked): {path}" + (f" ({reason})" if reason else ""))
            elif unreadable:
                say(unreadable_line(unreadable))
        else:
            say("fingerprints not built yet")
        return 0
    if not (args.span or args.text or args.where):
        parser.error("give --range, --text, --where, --refresh, --update, --status or --summary")

    sender = expand(str(args.repo or (sending_repo() if args.span else os.getcwd())))
    here: Path | None = sender
    if args.gh_argv:
        gh_args = [a for a in args.gh_argv.read_bytes().decode("utf-8", "replace").split("\0")]
        here = destination(gh_destinations(gh_args[:-1] if gh_args[-1:] == [""] else gh_args, sender),
                           sender, areas)
    elif args.dest and (slug := github_repo(args.dest)):
        here = destination({slug}, sender, areas)
    elif args.dest_area:
        # A service has no folder: the area it sits in is declared, and stands in by its first root.
        if args.dest_area == OUTSIDE:
            here = None
        elif args.dest_area in areas and areas[args.dest_area]:
            here = areas[args.dest_area][0]
        else:
            say(f"REFUSED — no area named {args.dest_area!r} (areas.txt)")
            return 2
    if args.where:
        print(here or OUTSIDE)
        return 0
    if here is not None and contains(areas.get(EXEMPT, []), here) and not any(
            contains(rs, here) for n, rs in areas.items() if n != EXEMPT):
        return 0
    checked = [n for n, roots in areas.items() if n != EXEMPT and (here is None or not contains(roots, here))]
    if not checked:
        return 0

    # (group, where, line): a group is one file of one commit, or one payload -- a block of copied
    # code is consecutive lines of one group.
    if args.text:
        lines = [(args.text.name, f"{args.text.name}:{n}", line) for n, line in enumerate(
            args.text.read_text(encoding="utf-8", errors="replace").splitlines(), start=1)]
    else:
        lines = [(where, where, line) for where, line in outgoing(args.span)]

    try:
        prints = load(areas, refresh=False)
    except ValueError as error:
        say(f"REFUSED — {error}")
        return 2
    allowed = [normalize(p) for p in read_lines(CONFIG / "allow.txt")]
    public = background_prints()
    found = []
    for name in checked:
        shapes = patterns(name)
        tables = [t for t in prints.get(name, []) if len(t)]
        results = []
        for group, where, line in lines:
            match = next((m.group(0) for p in shapes if (m := p.search(line))), None)
            found_here = ("shape", match) if match else (hit(line, tables, allowed, public) if tables else None)
            results.append((group, where, line, found_here))
        for _, where, line, what in keep_blocks(results, CODE_LINES):
            if what:
                label = "shape" if what[0] == "shape" else "text"
                found.append(f"{where}: {name} {label} {what[1]!r} in {normalize(line)[:80]!r}")
    if found:
        say(f"this carries text from a private area that {here or 'the destination'} is outside of:")
        for line in found:
            print(f"    {line}", file=sys.stderr)
        say(f"replace it with made-up text, or add a phrase that is fine to {CONFIG / 'allow.txt'}")
        return 1
    say(f"clean ({len(lines)} lines against {areas_count(checked)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
