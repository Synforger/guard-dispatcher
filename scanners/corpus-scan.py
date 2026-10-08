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
        <name> <path>/* ...            every sub-folder of <path> joins <name>, one
                                       made tomorrow too (hidden folders do not)
        _outside <path> ...            folders in no area, whatever holds them
                                       (a personal folder on the company's machine)
        _exempt <path> ...             repositories that are never scanned
        _carries <area> <other> ...    a repository inside <area> that has no remote may
                                       be committed to with the text of the areas named
                                       (a glob names several: `client-*`). Only a commit:
                                       whatever leaves that repository is judged as before
    ~/.config/guard/patterns/<name>.txt
        one regular expression per line (case-insensitive) for identifiers of
        that area that follow a shape: product codes, client names
    ~/.config/guard/allow.txt          phrases that are fine to send
    ~/.config/guard/ignore.txt         folders inside an area that hold no documents
                                       of it (an external corpus, build logs)
    ~/.config/guard/background.txt     folders of public text and code; whatever
                                       also appears there is not specific to an
                                       area and is dropped (a table of it keeps for a
                                       week; past that a scan uses the old table while
                                       it is rebuilt apart, and a rebuild reads only
                                       the files that changed)

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
Spotlight and added at once. When Spotlight cannot answer (disabled, or an area
it does not index) the size and modification time each document's print was
built from are compared with what `stat` gives now instead, and only the folders
whose modification time moved are listed again (a file created, removed or
renamed changes its folder's time): a document edited, deleted or created since
the last look is caught at once without walking everything. A full walk still comes at least every six
hours (MAX_AGE). Only one process at a time walks or writes the
fingerprints (a lock file in the cache); the rest use what is already there
rather than wait or walk beside it.

What is checked depends on where the text is going: every area but the
destination's own, the innermost ones that contain it. A repository inside an
area may carry that area's text; an area around it (the company around one of
its clients) is still checked, so what goes to a client does not take the
company's own text.

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
    corpus-scan.py --text <file> --repo <dir> --commit   what a commit adds to the repository at <dir>
                                          (pre-commit): it stays on this machine, so the areas a
                                          `_carries` line lets that repository hold are not checked
    corpus-scan.py --where [--dest <url> | --gh-argv <file>]
                                          print where the destination lives, or OUTSIDE
    corpus-scan.py --refresh              rebuild the fingerprints now
    corpus-scan.py --refresh-public       rebuild the table of public text if it is not current, unless
                                          another process is at it (what a scan starts when it finds
                                          the table past its week)
    corpus-scan.py --status               what is configured and how fresh, naming each area and
                                          each document that could not be read, and why (for the
                                          operator)
    corpus-scan.py --summary              the same in counts, grouped by why, naming nothing (for
                                          output that an agent or a log reads: doctor, bootstrap)

Exit: 0 clean or not configured, 1 hit, 2 usage / configuration error.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import fnmatch
import importlib
import json
import os
import re
import shlex
import sys
import time
from array import array
from collections import Counter
from pathlib import Path


class later:
    """A standard-library module that is loaded when something of it is first used.

    This file is also read as a module, for its areas alone, by the agent's entry guard -- before
    every tool call -- and each run of it as a command pays for what it loads. What only a scan
    uses is not loaded until a scan uses it."""

    def __init__(self, name: str) -> None:
        self._name = name

    def __getattr__(self, attribute: str):
        value = getattr(importlib.import_module(self._name), attribute)
        setattr(self, attribute, value)     # the next use finds it here, at the cost of a plain attribute
        return value


bisect, hashlib, heapq, html = later("bisect"), later("hashlib"), later("heapq"), later("html")
subprocess, tempfile = later("subprocess"), later("tempfile")
unicodedata, zipfile = later("unicodedata"), later("zipfile")

# How many consecutive characters count as copied. Twelve characters of
# Japanese are a phrase; twelve of English are two common words ("machine with"),
# so a run without any Japanese has to be much longer before it means anything.
RUN = int(os.environ.get("GUARD_CORPUS_RUN", "12"))
LATIN_RUN = int(os.environ.get("GUARD_CORPUS_LATIN_RUN", "40"))
# How many consecutive whole lines of an area's code or data a sent file has to hold to be a hit.
CODE_LINES = int(os.environ.get("GUARD_CORPUS_CODE_LINES", "2"))
JAPANESE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]")
MAX_AGE = int(os.environ.get("GUARD_CORPUS_MAX_AGE", str(6 * 3600)))
BACKGROUND_MAX_AGE = int(os.environ.get("GUARD_CORPUS_PUBLIC_MAX_AGE", str(7 * 24 * 3600)))
# How many prints of public text are held as one set while the table is put together.
PUBLIC_RUN = 2_000_000
BUILD_LOCK, PUBLIC_LOCK = "build.lock", "background.lock"
CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
CACHE = Path(os.environ.get("GUARD_CORPUS_CACHE", Path.home() / ".cache/guard-corpus"))
EXEMPT = "_exempt"
NO_AREA = "_outside"
# Names on areas.txt that hold no documents of their own.
UNSCANNED = {EXEMPT, NO_AREA}
#: Not an area: a line of areas.txt that says which other areas' text an area's repositories may hold.
CARRIES = "_carries"
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
def lock_file(wait: bool, name: str = BUILD_LOCK):
    """The one lock a build or a catch-up takes, so several processes never write the same cache
    files at once: only the holder walks or writes; the rest read what is already there. The table
    of public text has a lock of its own (PUBLIC_LOCK): rebuilding it holds up no walk.

    Non-blocking unless `wait` (nothing usable exists yet, so there is nothing to fall back to,
    and this run must be the one that builds it). A process that loses a non-blocking race yields
    False having touched nothing -- it goes on to use whatever is already on disk."""
    CACHE.mkdir(parents=True, exist_ok=True)
    with open(CACHE / name, "a+") as fh:
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
    area per sub-folder (`client-* /srv/company/clients/*` -> `client-acme` for `clients/acme`);
    on a line whose name does not, every sub-folder of such a path joins the line's area
    (`company ~/*`). Either way a folder created tomorrow is guarded from the moment it exists.
    A path already named on an explicit line keeps that line's name, so `_outside ~/personal`
    keeps `~/personal` out of `company ~/*`."""
    explicit: dict[str, list[Path]] = {}
    templates: list[tuple[str, list[Path]]] = []
    for line in read_lines(source or CONFIG / "areas.txt"):
        parts = shlex.split(line, comments=True)
        if len(parts) < 2 or parts[0] == CARRIES:       # `_carries` names areas, not paths: load_carries
            continue
        # A relative path would resolve against wherever the scan runs -- an `_exempt .` would
        # exempt every folder. A line that is not a definition is a broken file, not a pass.
        if bad := [p for p in parts[1:] if not p.startswith(("/", "~", "$"))]:
            raise ValueError(f"areas.txt: {line!r} names {bad[0]!r}, not an absolute or ~ path")
        if "*" in parts[0]:
            templates.append((parts[0], [expand(p[:-2]) for p in parts[1:] if p.endswith("/*")]))
        else:
            explicit.setdefault(parts[0], []).extend(expand(p) for p in parts[1:] if not p.endswith("/*"))
            if joined := [expand(p[:-2]) for p in parts[1:] if p.endswith("/*")]:
                templates.append((parts[0], joined))
    areas = dict(explicit)
    named = {r for roots in explicit.values() for r in roots}
    for template, parents in templates:
        for parent in parents:
            try:
                children = [c for c in sorted(parent.iterdir()) if c.is_dir() and not c.name.startswith(".")]
            except (FileNotFoundError, NotADirectoryError):
                children = []
            for child in children:
                child = expand(str(child))
                if child not in named:
                    areas.setdefault(template.replace("*", child.name), []).append(child)
    return areas


def load_carries(areas: dict[str, list[Path]], source: Path | None = None) -> dict[str, list[str]]:
    """Which other areas' text a repository inside an area may hold when it is committed to:
    area -> the names (or globs over names) its `_carries` lines give.

    An area that gathers what others hold -- the notes of someone who reads the company's
    meetings and each client's mail -- writes down text of every one of them, and a repository
    of those notes that has no remote sends it nowhere. A commit there is then not refused for
    carrying it. Nothing else changes: the repository's own files are documents of its area, and
    whatever leaves it (a push, a `gh` call, a tool's send, a message to another session) is
    judged as before. A line that is not `_carries <an area> <a name or glob> ...` is a broken
    file, not a pass."""
    carries: dict[str, list[str]] = {}
    for line in read_lines(source or CONFIG / "areas.txt"):
        parts = shlex.split(line, comments=True)
        if not parts or parts[0] != CARRIES:
            continue
        if len(parts) < 3:
            raise ValueError(f"areas.txt: {line!r} is not `{CARRIES} <area> <other area> ...`")
        if parts[1] not in areas or parts[1] in UNSCANNED:
            raise ValueError(f"areas.txt: {line!r} names {parts[1]!r}, which is no area")
        if bad := [w for w in parts[2:] if w.startswith(("/", "~", "$", "_"))]:
            raise ValueError(f"areas.txt: {line!r} names {bad[0]!r}, not an area's name")
        carries.setdefault(parts[1], []).extend(parts[2:])
    return carries


def has_remote(repo: Path) -> bool:
    """A repository with a remote has somewhere to send what it holds."""
    listed = subprocess.run(["git", "-C", str(repo), "remote"], capture_output=True, text=True)
    return listed.returncode != 0 or bool(listed.stdout.strip())


def built_summary() -> dict | None:
    try:
        return json.loads((CACHE / "summary.json").read_text())
    except (OSError, ValueError):
        return None


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


def published_files(parent: Path):
    """(key, stamp, name, read) for every file of every repository under parent, as published on
    its remote: the stamp is the blob's id, and read() gives its text (None when it is not text).

    Only what the remote's default branch already carries -- never the working
    tree, where the leak being prepared would whitelist itself.
    """
    for gitdir in sorted(parent.glob("*/.git")) + sorted(parent.glob("*/*/.git")):
        repo = str(gitdir.parent)
        head = subprocess.run(["git", "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if not head:
            continue
        # -z: a name is given as it is, whatever characters it holds (quoted, `git show` would not find it).
        listing = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", head], capture_output=True)
        for row in listing.stdout.decode("utf-8", "replace").split("\0"):
            meta, _, name = row.partition("\t")
            words = meta.split()
            if not name or len(words) != 3 or words[1] != "blob":
                continue

            def read(repo: str = repo, head: str = head, name: str = name) -> str | None:
                blob = subprocess.run(["git", "-C", repo, "show", f"{head}:{name}"], capture_output=True)
                if blob.returncode != 0 or len(blob.stdout) > MAX_FILE or b"\0" in blob.stdout[:8192]:
                    return None
                return blob.stdout.decode("utf-8", "replace")

            yield f"{repo}\0{name}", words[2], name, read


def walked_files(root: Path):
    """(key, stamp, name, read) for every file under a folder of public text: the stamp is its
    size and modification time, and read() gives its text (None when it is not text)."""
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in files:
            path = Path(folder, name)
            try:
                if path.is_symlink():
                    continue
                status = path.stat()
            except OSError:
                continue
            if status.st_size > MAX_FILE:
                continue

            def read(path: Path = path) -> str | None:
                try:
                    data = path.read_bytes()
                except OSError:
                    return None
                return None if b"\0" in data[:8192] else data.decode("utf-8", "replace")

            yield str(path), f"{status.st_size}:{status.st_mtime_ns}", name, read


def public_files(source: Path):
    """Every file background.txt makes public, with the stamp its prints were taken at."""
    for entry in read_lines(source):
        if entry.startswith("published "):
            yield from published_files(expand(entry.split(None, 1)[1]))
        else:
            yield from walked_files(expand(entry))


def public_prints(name: str, text: str) -> set[int]:
    """What a public file makes unremarkable: every run of its prose, every line of its code."""
    prints = {v for line in text.splitlines() if (v := line_print(line)) is not None}
    if (Path(name).suffix.lower() in {".md", ".rst", ".txt"}
            or Path(name).name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE"))):
        # A license reads the same however each copy wraps its lines, so its runs are kept too.
        prints |= fingerprints(text)
    return prints


def public_table() -> Path:
    # The format is in the name: public text read another way is never mistaken for the old table.
    return CACHE / f"background-{PRINT_FORMAT}.bin"


def public_id_path() -> Path:
    return CACHE / f"background-{PRINT_FORMAT}.id"


def read_public_id() -> str:
    """The name the table of public text on disk goes by: a hash of what it holds ("" when there
    is no table, or it was built before tables had a name). An area's tables are merged against
    one table of public text, and the summary keeps that table's name (`public`): when the two
    differ, what became public since is still in the area's tables."""
    try:
        return public_id_path().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def publish_public(table: array, ident: str) -> None:
    """Put a built table in place, then its name beside it. Stopped between the two, the old name
    stays beside the new table: the areas' tables are then not merged again until the next
    rebuild, which only leaves flagged what the new table would have cleared."""
    atomic_write(public_table(), table.tobytes())
    atomic_write(public_id_path(), ident)


def public_is_edited(cached: Path, source: Path) -> bool:
    """background.txt was written after the table was built: the operator changed what is public."""
    return source.stat().st_mtime >= cached.stat().st_mtime


def public_is_old(cached: Path) -> bool:
    return time.time() - cached.stat().st_mtime >= BACKGROUND_MAX_AGE


def build_public(source: Path) -> tuple[array, str]:
    """Build the table of public text, reading only the files that changed since the last build.
    Returns the table and the name it goes by (`read_public_id`); `publish_public` puts it in place.

    Each file's prints are kept, with the stamp they were taken at, in one pack beside an index
    (key -> stamp, where its prints start in the pack, how many). A file whose stamp holds is
    copied from the old pack; only a new or changed one is read and printed. The table is the
    union of them all, put together from sorted runs of at most PUBLIC_RUN prints so that the
    whole of it is never held as one set."""
    kept_in = CACHE / f"public-{PRINT_FORMAT}"
    kept_in.mkdir(parents=True, exist_ok=True)
    index_path = kept_in / "index.json"
    try:
        old = json.loads(index_path.read_text()) if index_path.is_file() else {}
    except ValueError:
        old = {}
    old_pack = kept_in / old.get("pack", "") if old.get("pack") else None
    if old_pack is None or not old_pack.is_file():
        old, old_pack = {}, None
    known = old.get("files", {})
    files: dict = {}
    runs: list[array] = []
    pending: set[int] = set()
    fd, tmp = tempfile.mkstemp(dir=kept_in, prefix="pack.", suffix=".bin")
    try:
        with os.fdopen(fd, "wb") as out, (open(old_pack, "rb") if old_pack else contextlib.nullcontext()) as before:
            position = 0
            for key, stamp, name, read in public_files(source):
                chunk, was = array("Q"), known.get(key)
                if was and was[0] == stamp:
                    before.seek(was[1] * chunk.itemsize)
                    chunk.frombytes(before.read(was[2] * chunk.itemsize))
                if not was or was[0] != stamp or len(chunk) != was[2]:
                    text = read()
                    prints = public_prints(name, text) if text is not None else set()
                    chunk = array("Q", prints)       # in no order: the table is sorted from the runs
                    pending |= prints
                else:
                    pending.update(chunk)
                out.write(chunk.tobytes())
                files[key] = [stamp, position, len(chunk)]
                position += len(chunk)
                if len(pending) >= PUBLIC_RUN:
                    runs.append(array("Q", sorted(pending)))
                    pending = set()
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    runs.append(array("Q", sorted(pending)))
    table, last = array("Q"), None
    for value in heapq.merge(*runs):
        if value != last:
            table.append(value)
        last = value
    # The index names its pack, so the two are replaced as one: until the index is written the
    # old index still points at the old pack, whole.
    atomic_write(index_path, json.dumps({"pack": Path(tmp).name, "files": files}))
    for stale in kept_in.glob("pack.*.bin"):
        if stale.name != Path(tmp).name:
            stale.unlink(missing_ok=True)
    return table, hashlib.blake2b(table.tobytes(), digest_size=8).hexdigest()


def rebuild_public_apart() -> None:
    """Start the rebuild of the public table as a process of its own, unless one is at it. The
    process outlives the scan that started it: a commit that ends, or is given up on, does not
    stop the rebuild half way."""
    with lock_file(wait=False, name=PUBLIC_LOCK) as free:
        if not free:
            return
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--refresh-public"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


#: The table of public text, once this process has it: a scan asks for it more than once (to take
#: public runs out of an area's table, then to judge a line), and reads it from disk one time.
_PUBLIC: list[tuple[array, str]] = []


def background_prints(wait: bool = False) -> array:
    """The table of public text, as this process first found it (`current_public`)."""
    if not _PUBLIC:
        _PUBLIC.append(current_public(wait))
    return _PUBLIC[0][0]


def public_id() -> str:
    """The name of the table `background_prints` gives this process."""
    background_prints()
    return _PUBLIC[0][1]


def current_public(wait: bool = False) -> tuple[array, str]:
    """Runs of public text, sorted, and the name the table goes by. Public text changes rarely,
    so it keeps for a week.

    A table past its week is used as it is while a process of its own rebuilds it
    (`rebuild_public_apart`): a commit does not wait for text that almost never changes, and an
    old table only fails to clear what became public since it was built. A table older than
    background.txt is rebuilt here and now -- the operator changed what is public and expects the
    next scan to know -- and so is one that does not exist yet, or any that is not current when
    the caller asks to wait (`--refresh`). One process builds at a time; another that needs the
    table waits for it rather than build beside it."""
    cached, source = public_table(), CONFIG / "background.txt"
    if not source.is_file():
        return array("Q"), ""
    if cached.is_file() and not public_is_edited(cached, source):
        if not public_is_old(cached):
            return read_table(cached), read_public_id()
        if not wait:
            days = int((time.time() - cached.stat().st_mtime) // 86400)
            say(f"the table of public text is {days} days old: this scan uses it as it is, and it is "
                "being rebuilt apart from the scan (text made public since may still be flagged)")
            rebuild_public_apart()
            return read_table(cached), read_public_id()
    with lock_file(wait=True, name=PUBLIC_LOCK):
        # Whoever held the lock may have built it while this process waited.
        if cached.is_file() and not public_is_edited(cached, source) and not public_is_old(cached):
            return read_table(cached), read_public_id()
        say("reading the public text (files unchanged since the last time are not read again)...")
        started = time.time()
        table, ident = build_public(source)
        publish_public(table, ident)
        say(f"table of public text built in {time.time() - started:.1f}s: {len(table)} prints")
        return table, ident


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
    """The innermost area holding path (= the one whose root is longest); None inside `_outside`."""
    best = max(((len(r.parts), n) for n, rs in areas.items() for r in rs if path == r or r in path.parents),
               default=None)
    return best[1] if best and best[1] != NO_AREA else None


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
    merged_all = True       # every area's table was merged anew against this table of public text
    for name, roots in areas.items():
        if name in UNSCANNED:
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
            merged_all = False
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
    # A table kept from before was merged against the table of public text of that time.
    summary["public"] = public_id() if merged_all else previous.get("public", "")
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
    no file is opened. This is the fallback for when Spotlight cannot answer (disabled, or an
    area it does not index): it catches every one of them edited or deleted since the last look; the documents
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
        roots = [r for n, rs in areas.items() if n not in UNSCANNED for r in rs]
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
    summary_path = CACHE / "summary.json"
    summary, full = None, True
    # The table of public text first: an edited background.txt is read before the areas' tables
    # are held against it.
    public_now = public_id()
    if summary_path.is_file() and not refresh:
        summary = json.loads(summary_path.read_text())
        current = (summary.get("checked") and summary["run"] == [RUN, LATIN_RUN]
                   and set(summary["areas"]) == {n for n in areas if n not in UNSCANNED})
        # The areas' tables were merged against another table of public text: what became public
        # since is still in them, and what is public no longer is still missing. Merge them anew.
        moved = summary.get("public", "") != public_now
        full = not current or moved
        if not current or moved or time.time() - summary["built"] >= MAX_AGE:
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
    try:
        cached = json.loads(path.read_text())
        if time.time() - cached["built"] < CLONES_TTL:
            return cached["map"]
    except (OSError, ValueError, KeyError):
        pass
    found: dict[str, list[str]] = {}
    for root in {r for n, rs in areas.items() if n != NO_AREA for r in rs}:
        for folder, dirs, _ in os.walk(root):
            here = Path(folder)
            if (here / ".git").is_dir():
                for slug in remote_repos(here):
                    found.setdefault(slug, []).append(str(here))
            deep = len(here.parts) - len(root.parts) >= 5
            dirs[:] = [] if deep else [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
    CACHE.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"built": time.time(), "map": found}))
    return found


def outer(name: str, inner: str, areas: dict[str, list[Path]]) -> bool:
    """A root of `name` holds a root of `inner` (the company around one of its clients)."""
    return any(r != i and r in i.parents for r in areas.get(name, []) for i in areas.get(inner, []))


def holding(place: Path, areas: dict[str, list[Path]]) -> frozenset[str]:
    """Every area place is inside (a client inside the company is inside both), less those an
    `_outside` folder cuts it off from: an area whose root holds that folder."""
    cut = max((len(r.parts) for r in areas.get(NO_AREA, []) if contains([r], place)), default=0)
    return frozenset(n for n, roots in areas.items() if n != NO_AREA
                     and any(len(r.parts) > cut and contains([r], place) for r in roots))


def repo_rules() -> list[tuple[str, str]]:
    """`repo:<owner>/<name>` lines of destinations.txt: where a GitHub repository sits whatever its
    visibility and wherever it is cloned (`repo:my-account/* outside`: a personal account is outside
    every area even for a private repository, which its owner may publish tomorrow). A line with
    a third word keeps the place it declares here: send-scan.py refuses the line as written, and a
    push is not let through meanwhile."""
    path = CONFIG / "destinations.txt"
    out = []
    for line in read_lines(path):
        words = line.split("#", 1)[0].split()
        if len(words) >= 2 and words[0].lower().startswith("repo:"):
            out.append((words[0][5:].lower(), words[1]))
    return out


def destination(slugs: set[str], sender: Path, areas: dict[str, list[Path]]) -> Path | None:
    """Where the destination lives; None = outside every area."""
    if not slugs:
        say("destination could not be told -- checked against every area")
        return None
    declared = repo_rules()
    for slug in sorted(slugs):
        target = next((t for pattern, t in declared if fnmatch.fnmatchcase(slug.lower(), pattern)), None)
        if target == "outside":
            say(f"destination {slug} is declared outside every area -- checked against every area")
            return None
        if target in areas and areas[target]:
            return areas[target][0]
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
    if len({holding(p, areas) for p in places}) != 1:
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
    started = time.time()
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--range", dest="span")
    parser.add_argument("--text", type=Path)
    parser.add_argument("--repo", type=Path, help="where the sending repository lives (default: here)")
    parser.add_argument("--dest", help="the remote URL (or owner/repo) the text is sent to")
    parser.add_argument("--gh-argv", type=Path, help="a file holding the NUL-separated arguments of a gh call")
    parser.add_argument("--dest-area", help=f"the area the text is sent into, or {OUTSIDE} "
                        "(a service a tool sends to, declared in destinations.txt); several areas "
                        "joined by commas are a place inside each (a session that has read in all)")
    parser.add_argument("--where", action="store_true", help=f"print where the destination lives, or {OUTSIDE}")
    parser.add_argument("--commit", action="store_true",
                        help="the text is what a commit adds to the repository at --repo: it stays on this "
                        f"machine, so the areas a `{CARRIES}` line lets that repository hold are not checked")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--refresh-public", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args(argv)

    if args.refresh_public:
        # Started by a scan that found the table past its week, or by hand. Whoever holds the lock
        # is already at it: this one leaves.
        cached, source = public_table(), CONFIG / "background.txt"
        with lock_file(wait=False, name=PUBLIC_LOCK) as mine:
            if mine and source.is_file() and not (cached.is_file() and not public_is_edited(cached, source)
                                                   and not public_is_old(cached)):
                before = read_public_id()
                table, ident = build_public(source)
                try:
                    areas = load_areas()
                except ValueError:
                    areas = {}
                if ident == before or not areas or not (CACHE / "summary.json").is_file():
                    publish_public(table, ident)
                    return 0
                # What is public changed, and the areas' tables were merged against the old table.
                # They are merged anew here, so that no scan has to do it. The build lock is taken
                # before the new table shows: a scan never finds it beside tables nobody is merging.
                _PUBLIC[:] = [(table, ident)]
                with lock_file(wait=True):
                    publish_public(table, ident)
                    _build_locked(areas, full=True)
        return 0
    try:
        areas = load_areas()
        carries = load_carries(areas)
    except ValueError as error:
        say(f"REFUSED — {error} (fix {CONFIG / 'areas.txt'})")
        return 2
    if not areas:
        say(f"NOT CHECKED — no areas defined in {CONFIG / 'areas.txt'} on this machine")
        return 0
    if args.refresh or args.status or args.summary:
        if args.refresh:
            for stale in ("visibility.json", "clones.json"):
                (CACHE / stale).unlink(missing_ok=True)
            background_prints(wait=True)
            load(areas, refresh=True)
        summary = json.loads((CACHE / "summary.json").read_text()) if (CACHE / "summary.json").is_file() else None
        if summary:
            age = (time.time() - summary["built"]) / 3600
            built = f"fingerprints built {age:.1f}h ago (run {summary['run']}): "
            # Only --status names areas and files: every other mode prints into whatever runs it
            # -- doctor under an agent -- and a name says what the area holds.
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
        parser.error("give --range, --text, --where, --refresh, --refresh-public, --status or --summary")

    sender = expand(str(args.repo or (sending_repo() if args.span else os.getcwd())))
    here: Path | None = sender
    also: list[Path] = []
    if args.gh_argv:
        gh_args = [a for a in args.gh_argv.read_bytes().decode("utf-8", "replace").split("\0")]
        here = destination(gh_destinations(gh_args[:-1] if gh_args[-1:] == [""] else gh_args, sender),
                           sender, areas)
    elif args.dest and (slug := github_repo(args.dest)):
        here = destination({slug}, sender, areas)
    elif args.dest_area:
        # A service has no folder: the area it sits in is declared, and stands in by its first
        # root. Several areas (`a,b`) are a place inside each: a session that has read in all.
        names = [n for n in args.dest_area.split(",") if n]
        if names == [OUTSIDE]:
            here = None
        elif names and all(n in areas and areas[n] for n in names):
            here, also = areas[names[0]][0], [areas[n][0] for n in names[1:]]
        else:
            missing = next((n for n in names if not (n in areas and areas[n])), args.dest_area)
            say(f"REFUSED — no area named {missing!r} (areas.txt)")
            return 2
    if args.where:
        print(here or OUTSIDE)
        return 0
    held = holding(here, areas) if here is not None else frozenset()
    for place in also:
        held |= holding(place, areas)
    if held == {EXEMPT}:
        return 0
    # A place carries its own areas' text; an area holding one of them (the company around a
    # client) is still checked: what goes to a client does not take the company's own text.
    own = {n for n in held if not any(n != m and outer(n, m, areas) for m in held)}
    checked = [n for n in areas if n not in UNSCANNED and n not in own]
    # A commit stays on this machine. Where areas.txt lets a repository of this area hold other
    # areas' text, those are not checked -- while the repository has no remote to send it to.
    holds: list[str] = []
    could_hold: list[str] = []
    if args.commit:
        named = [n for n in checked if any(fnmatch.fnmatchcase(n, pattern) for o in own for pattern in carries.get(o, ()))]
        if named and has_remote(sender):
            could_hold = named
        elif named:
            holds, checked = named, [n for n in checked if n not in named]
    if not checked:
        if holds:
            say(f"not checked: this repository may hold the text of the {areas_count(holds)} it is outside of "
                f"({CARRIES} in {CONFIG / 'areas.txt'})")
        return 0

    # (group, where, line): a group is one file of one commit, or one payload -- a block of copied
    # code is consecutive lines of one group.
    if args.text:
        lines = [(args.text.name, f"{args.text.name}:{n}", line) for n, line in enumerate(
            args.text.read_text(encoding="utf-8", errors="replace").splitlines(), start=1)]
    else:
        lines = [(where, where, line) for where, line in outgoing(args.span)]

    prints = load(areas, refresh=False)
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
        if could_hold:
            say(f"areas.txt lets a repository here hold the text of {', '.join(could_hold)}, but only one with no "
                "remote: this one has somewhere to send it")
        say(f"replace it with made-up text, or add a phrase that is fine to {CONFIG / 'allow.txt'}"
            f" (scanned in {time.time() - started:.1f}s)")
        return 1
    also_held = f"; it may hold the text of {areas_count(holds)} more" if holds else ""
    say(f"clean ({len(lines)} lines against {areas_count(checked)}{also_held}) in {time.time() - started:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
