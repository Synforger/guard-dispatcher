#!/usr/bin/env python3
"""corpus-scan — stop text copied out of private documents from leaving its area.

The word list catches names someone thought to write down. Text copied from a
real document -- a sentence from a slide, a row of a table -- is on no list.
This scanner compares what is about to be sent with the documents themselves.

Areas are defined on this machine only (never in a repository). The places below are the ones
used when the guard runs on its own; under a platform root the same files sit in
`<root>/config/guard/boundaries/` (allow.txt in `exit/`, background.txt named public.txt), and
`_common/guard_places.py` holds every place:

    ~/.config/guard/areas.txt
        <name> <path> [<path> ...]     one area per line; nested paths belong
                                       to the innermost area
        <prefix>* <path>/* ...         one area per sub-folder of <path>, named
                                       <prefix><folder> (= a client folder made
                                       tomorrow is an area from the moment it exists)
        <name> <path>/* ...            every sub-folder of <path> joins <name>, one
                                       made tomorrow too (hidden folders do not)
        <name> host:<host>:<path> ...  a folder on another machine (`host:build1:/srv/x`)
                                       joins <name>: what is sent there is judged as sent
                                       into <name>, and naming it marks an agent session
                                       (the agent hooks). Its text is not on this machine,
                                       so it is not scanned; <name> needs a folder here too
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
                                       week, or until a published repository's remote
                                       moves; past that a scan uses the old table while
                                       it is rebuilt apart, and a rebuild reads only
                                       the files that changed)

An area's documents are everything under its paths that holds its words:

    prose  Office (.pptx .docx .xlsx, read from their XML), PDF (pdftotext),
           SQLite (.sqlite .db, every text value of its tables), Markdown -- every run of RUN consecutive characters mostly Japanese
           (JAPANESE_SHARE), or LATIN_RUN otherwise, is a print; a sent run is
           compared only when RUN_CONTENT of its characters are kanji, katakana,
           Latin letters or digits (kana and signs alone end anyone's sentence)
    rows   CSV, TSV, plain text -- every whole row of at least that length is a
           print, and one copied row is a hit
    lines  every other file a git repository there tracks (= its code and its
           Markdown) -- every whole line of at least that length is a print, and
           CODE_LINES consecutive copied lines are a hit (a lone common line --
           an import, an idiom -- is written by the same people everywhere)

A run, a row or a line with no letter and no digit in it is no print: the separator
row of a table, a horizontal rule, a banner of signs, an empty row of a CSV say
nothing, and every document that has one holds the same one.

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
hours (MAX_AGE), and when more than MAX_DELTA documents changed since the last one. A scan that finds
one due starts it as a process of its own and waits for it up to WALK_WAIT; past that, the scan goes
on with the tables it has just brought up to date and the walk finishes apart (a send is judged
within its own time limit however long the walk takes). With no tables on disk that fit the areas
(a fresh cache, or areas.txt naming other areas) the build starts the same way; a scan it is not
done for by WALK_WAIT refuses to judge. Only one process at a time walks or writes the fingerprints
(a lock file in the cache); the rest use what is already there rather than wait or walk beside it.

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
import importlib.util
import json
import os
import re
import shlex
import sys
import time
from array import array
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "_internal"))
import guard_places  # noqa: E402
from own_paths import without_own_paths  # noqa: E402


class later:
    """A module that is loaded when something of it is first used.

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
sqlite_text = later("sqlite_text")

# How many consecutive characters count as copied. Twelve characters of
# Japanese are a phrase; twelve of English are two common words ("machine with"),
# so a run without any Japanese has to be much longer before it means anything.
RUN = int(os.environ.get("GUARD_CORPUS_RUN", "12"))
LATIN_RUN = int(os.environ.get("GUARD_CORPUS_LATIN_RUN", "40"))
# How many consecutive whole lines of an area's code or data a sent file has to hold to be a hit.
CODE_LINES = int(os.environ.get("GUARD_CORPUS_CODE_LINES", "2"))
JAPANESE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]")
# A run counts as Japanese, and so as a copy at RUN characters, when at least this share of it is
# Japanese (numerator, denominator). At a half, a short phrase of Japanese and an English name
# ("README の見出し") counted, and a common phrase of six and six stopped a push.
JAPANESE_SHARE = (2, 3)
# A sent run counts as copied only when it carries this many characters that say what it is about: a
# kanji, a katakana, a Latin letter or a digit. Twelve characters of kana and signs around a word or
# two ("は直していません (= ") are how anyone ends a sentence, and an area's documents written by the
# same agent hold them as often as its messages do: over 3919 lines an agent wrote outside every area,
# the runs with four or fewer were all such endings but one pair of names, which its longer mentions
# still caught. Only the sent side is counted, so an area's prints stay as they are.
RUN_CONTENT = int(os.environ.get("GUARD_CORPUS_RUN_CONTENT", "5"))
CONTENT = re.compile(r"[\u3400-\u9fff\uf900-\ufaff\u30a0-\u30ffA-Za-z0-9]")


def mostly_japanese(text: str) -> bool:
    return len(JAPANESE.findall(text)) * JAPANESE_SHARE[1] >= len(text) * JAPANESE_SHARE[0]
# A letter or a digit, of any script. What holds none is ruling, not writing.
WORD = re.compile(r"[^\W_]")
# A stretch of signs and spaces long enough to hold a whole run that says nothing.
SIGNS = re.compile(r"[\W_]{%d,}" % LATIN_RUN)
# The head of a link (scheme, host and the folders named in words) is shared by every link to that
# site: "https://drive.google.com/drive/folders/" plus one character is a whole run, and any document
# holding any folder link holds it. The head ends at the first folder with a digit in it: an id names
# a thing, and a run over it is still a copy.
# A command's options (`--format=csv`, `-i`) are written the same by everyone who runs the tool.
# A run that is half or more of what everyone writes the same (options and the heads of links) is how a
# command is called or where a link points, not anyone's text: `: https://drive.google.com/drive/folders`
# is the same after whatever sentence leads into it.
OPTION = re.compile(r"(?<!\S)--?[A-Za-z][^\s]*")
URL_HEAD = re.compile(r"[a-z][a-z0-9+.-]*://[^\s/]+(?:/[A-Za-z._~-]*)*/", re.IGNORECASE)
MAX_AGE = int(os.environ.get("GUARD_CORPUS_MAX_AGE", str(6 * 3600)))
BACKGROUND_MAX_AGE = int(os.environ.get("GUARD_CORPUS_PUBLIC_MAX_AGE", str(7 * 24 * 3600)))
# How many prints of public text are held as one set while the table is put together.
PUBLIC_RUN = 2_000_000
BUILD_LOCK, PUBLIC_LOCK = "build.lock", "background.lock"
CACHE = guard_places.corpus_folder()
EXEMPT = "_exempt"
NO_AREA = "_outside"
# Names on areas.txt that hold no documents of their own.
UNSCANNED = {EXEMPT, NO_AREA}
#: Not an area: a line of areas.txt that says which other areas' text an area's repositories may hold.
CARRIES = "_carries"
#: A root on another machine: `host:<host>:<absolute path>` (read by load_remote_areas, not load_areas).
REMOTE = "host:"
OFFICE = {".pptx", ".docx", ".xlsx", ".pptm", ".docm", ".xlsm"}
DATABASES = {".sqlite", ".sqlite3", ".db", ".db3"}
# Documents read for their text wherever they sit and whatever their size: inside a repository an
# attachment or an app's data is the area's even when untracked, and a deck or a database is mostly
# bytes that are not its text.
ANYWHERE = OFFICE | {".pdf"} | DATABASES
TEXT ={".md", ".csv", ".tsv", ".txt"}
LOCKFILES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "poetry.lock", "uv.lock",
             "Gemfile.lock", "composer.lock", "go.sum"}
GENERATED = {".pbxproj", ".xcscheme", ".xcworkspacedata", ".storyboard", ".xib", ".plist", ".csproj", ".sln",
             ".vcxproj", ".filters", ".meta", ".uproject", ".uplugin"}
# Folders of a repository that hold someone else's code: public text, not the area's.
VENDORED = {"vendor", "vendors", "external", "extern", "third_party", "thirdparty", "third-party", "3rdparty"}
# Raised whenever a change to reading or printing makes the kept prints of an unchanged document wrong.
PRINT_FORMAT = 5
DOCS = CACHE / "docs"
INDEX = DOCS / "index.json"
# Every folder the last full walk went through, with its modification time: a file created, removed
# or renamed in a folder changes that folder's time, so the stat fallback of catch_up() finds new
# documents by listing only the folders whose time moved.
FOLDERS = DOCS / "folders.json"
# Past this many changed documents since the last full walk, a full walk is due (= the delta is still
# written, so nothing changed goes unseen until the walk folds it into the area's table).
MAX_DELTA = int(os.environ.get("GUARD_CORPUS_MAX_DELTA", "200"))
# How long a scan waits for a full walk it started (walk_apart). Past it the scan goes on with the
# tables on disk and the walk finishes apart. send-scan.py gives the whole scan 120s; this leaves room
# for Spotlight's answer (up to 30s, spotlight_changes) and the scan itself.
WALK_WAIT = int(os.environ.get("GUARD_CORPUS_WALK_WAIT", "60"))
# How often a scan with no tables that fit looks for the ones the build started apart writes.
BUILD_POLL = 0.1
# An area this small has its table merged anew within the scan that sees one of its documents
# rewritten or deleted (well under a second); a larger one gets a full walk started apart.
SMALL_AREA = int(os.environ.get("GUARD_CORPUS_SMALL_AREA", "1000"))
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


# Settings an area keeps for itself (`areas/<area>/` beside the machine's own files), written by
# the session the operator hands them to (`agent-writes.txt`): areas.txt, destinations.txt,
# allow.txt, ignore.txt, patterns/ and reads.txt. A line there works inside the area only: a
# sub-area within its folders, a destination placed in it or blocked, a phrase fine to send of its
# text, a shape of its identifiers, a folder of it that holds none of its documents, a service
# whose reading calls read inside it or an area within it. A line that would reach
# outside the area is skipped and named (`--settings`), so a slip of the area's keeper stops
# nothing else. The machine's own files come first and win.
AREA_SETTINGS = guard_places.setting("areas")
#: "<file>: <line> -- <why>" for every line of an area's settings this process skipped.
SKIPPED: list[str] = []


def area_folders() -> list[tuple[str, Path]]:
    """(area, folder) for each area that keeps settings of its own."""
    if not AREA_SETTINGS.is_dir():
        return []
    return [(f.name, f) for f in sorted(AREA_SETTINGS.iterdir())
            if f.is_dir() and not f.name.startswith((".", "_"))]


def skip(path: Path, line: str, why: str) -> None:
    note = f"{path}: {line!r} -- {why}"
    if note not in SKIPPED:
        SKIPPED.append(note)


def inside(path: Path, roots: list[Path]) -> bool:
    """Strictly inside one of the roots: a folder of the area, not the area itself."""
    return any(root in path.parents for root in roots)


def within(name: str, owner: str, areas: dict[str, list[Path]]) -> bool:
    """The owner itself, or an area all of whose folders here lie inside the owner's."""
    if name == owner:
        return True
    roots, outer = areas.get(name) or [], areas.get(owner) or []
    return bool(roots and outer) and all(inside(r, outer) for r in roots)


def kept_lines(name: str, areas: dict[str, list[Path]], of: str | None = None) -> list[tuple[str, Path, str]]:
    """(owner, file, line) of `name` (a file of an area's settings) in every area's folder that is
    an area here, or in the folders of the areas `of` lies within when it is given."""
    out = []
    for owner, folder in area_folders():
        path = folder / name
        lines = read_lines(path)
        if not lines:
            continue
        if owner not in areas or owner in UNSCANNED:
            for line in lines:
                skip(path, line, f"{owner} is no area")
            continue
        if of is None or within(of, owner, areas):
            out += [(owner, path, line) for line in lines]
    return out


def _areas_of(lines: list[str]) -> dict[str, list[Path]]:
    explicit: dict[str, list[Path]] = {}
    templates: list[tuple[str, list[Path]]] = []
    for line in lines:
        parts = shlex.split(line, comments=True)
        if len(parts) < 2 or parts[0] == CARRIES:       # `_carries` names areas, not paths: load_carries
            continue
        # A relative path would resolve against wherever the scan runs -- an `_exempt .` would
        # exempt every folder. A line that is not a definition is a broken file, not a pass.
        if bad := [p for p in parts[1:] if not p.startswith(("/", "~", "$", REMOTE))]:
            raise ValueError(f"areas.txt: {line!r} names {bad[0]!r}, not an absolute or ~ path")
        parts = [parts[0], *(p for p in parts[1:] if not p.startswith(REMOTE))]
        if len(parts) < 2:
            continue
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


def area_lines(source: Path | None = None) -> list[str]:
    """The lines of areas.txt, then each area's own lines that stay inside it: a sub-area whose
    folders here lie inside the area's (and its roots on other machines), or a `_carries` line
    between areas within it. A line that sets a folder apart from every area (`_exempt`,
    `_outside`), reaches an area defined elsewhere, or names a folder outside is skipped."""
    path = source or guard_places.setting("areas.txt")
    lines = read_lines(path)
    # The machine's own file, however its path is spelled (a symlink, a relative config folder):
    # an area's own lines missed here would drop the sub-areas they draw, a boundary gone silent.
    if path.resolve() != (guard_places.setting("areas.txt")).resolve() or not area_folders():
        return lines
    top = _areas_of(lines)
    carries: list[tuple[str, Path, list[str], str]] = []
    for owner, own, line in kept_lines("areas.txt", top):
        try:
            parts = shlex.split(line, comments=True)
        except ValueError:
            skip(own, line, "is not a line of areas.txt")
            continue
        if len(parts) < 2:
            skip(own, line, "is not a line of areas.txt")
        elif parts[0] == CARRIES:
            carries.append((owner, own, parts, line))
        elif parts[0].startswith("_"):
            skip(own, line, "only the machine's own areas.txt sets a folder apart from every area")
        elif parts[0] in top and not within(parts[0], owner, top):
            skip(own, line, f"{parts[0]} is an area of the machine's own areas.txt, outside {owner}")
        elif bad := [p for p in parts[1:] if not p.startswith(REMOTE)
                     and not (p.startswith(("/", "~", "$")) and inside(expand(p[:-2] if p.endswith("/*") else p),
                                                                    top[owner]))]:
            skip(own, line, f"{bad[0]} is not a folder inside {owner}")
        else:
            lines.append(line)
    if carries:
        areas = _areas_of(lines)
        for owner, own, parts, line in carries:
            named = parts[1:]
            if len(named) < 2 or any(any(c in n for c in "*?[") or not within(n, owner, areas) for n in named):
                skip(own, line, f"a {CARRIES} line here names areas within {owner} only, without globs")
            else:
                lines.append(line)
    return lines


def kept_allowed(name: str, areas: dict[str, list[Path]]) -> list[str]:
    """Phrases fine to send of the area `name`'s text that the areas it lies within keep: taken
    out of a line before it is compared with that area's documents (the machine's allow.txt is
    also taken out of the tables when they are built)."""
    return [line for _, _, line in kept_lines("allow.txt", areas, of=name)]


def shared_places(areas: dict[str, list[Path]]) -> list[str]:
    """The paths of the folders that hold the roots of two or more areas, as they are written from
    HOME when they lie in it, longest first: taken out of a line before it is compared with any
    area's documents. Every area's documents name where the areas live, so a run over such a path
    is no area's text; what follows it (an area's own folders and files) is still compared. A path
    of one folder is left in: a short name taken out of a line would break the runs of prose that
    hold it."""
    home = Path.home()
    roots = [root for rs in areas.values() for root in rs]
    places = set()
    for root in roots:
        for folder in (root, *root.parents):
            if folder == home or folder == folder.parent:
                break
            if sum(1 for other in roots if other == folder or folder in other.parents) < 2:
                continue
            written = folder.relative_to(home) if folder.is_relative_to(home) else folder.relative_to(folder.anchor)
            if len(written.parts) >= 2:
                places.add(normalize(str(written)))
    return sorted(places, key=len, reverse=True)


def kept_ignored(areas: dict[str, list[Path]]) -> list[Path]:
    """Folders an area keeps out of its own walk (no document of it there): only inside its folders."""
    out = []
    for owner, path, line in kept_lines("ignore.txt", areas):
        folder = expand(line)
        if line.startswith(("/", "~", "$")) and inside(folder, areas[owner]):
            out.append(folder)
        else:
            skip(path, line, f"is not a folder inside {owner}")
    return out


def ignored_folders(areas: dict[str, list[Path]]) -> list[Path]:
    return [expand(p) for p in read_lines(guard_places.setting("ignore.txt"))] + kept_ignored(areas)


def kept_patterns(name: str, areas: dict[str, list[Path]]) -> list[tuple[Path, str]]:
    """(file, line) of the identifier shapes of `name` the areas it lies within keep."""
    out = []
    for owner, folder in area_folders():
        path = folder / "patterns" / f"{name}.txt"
        if owner in areas and owner not in UNSCANNED and within(name, owner, areas):
            out += [(path, line) for line in read_lines(path)]
    return out


#: What a destination line may name besides an area: the kinds of send-scan.py's patterns.
DESTINATION_KINDS = ("repo:", "host:", "local:", "tmux:", "browser:", "file:")


def kept_destinations(areas: dict[str, list[Path]]) -> list[tuple[str, str, bool]]:
    """(pattern, where it sits, whether its sends need the operator's order) of the destination
    lines each area keeps, in order: a destination placed in the area or an area within it, or
    blocked. Putting one outside every area, a line catching every destination, or a line that
    does not read as one is skipped and named."""
    out = []
    for owner, path, line in kept_lines("destinations.txt", areas):
        words = line.split("#", 1)[0].split()
        if len(words) not in (2, 3) or (len(words) == 3 and words[2] != "order"):
            skip(path, line, "is not `<pattern> <area|block> [order]`")
            continue
        pattern, target, ordered = words[0], words[1], len(words) == 3
        literal = pattern.lower()
        for kind in DESTINATION_KINDS:
            literal = literal.removeprefix(kind)
        literal = re.sub(r"[*?\[\]]", "", literal)
        if target == "outside":
            skip(path, line, "only the machine's own destinations.txt puts a destination outside every area")
        elif target != "block" and not (target in areas and within(target, owner, areas)):
            skip(path, line, f"{target} is no area within {owner}")
        elif len(literal) < 3:
            skip(path, line, "catches every destination: name the service or the host")
        elif ordered and (target == "block" or pattern.lower().startswith("repo:")):
            skip(path, line, "takes `order` only for a send that can be ordered")
        else:
            out.append((pattern, target, ordered))
    return out


#: A condition of a reads.txt line: an argument of the call and the shape its value has.
READ_CONDITION = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.+)$")


def kept_reads(areas: dict[str, list[Path]]) -> list[tuple[str, str, tuple[tuple[str, str], ...]]]:
    """(destination pattern, area, conditions) of the lines each area keeps in `reads.txt`, in
    order: what a reading call to a service, or a browser tab at a site, reads inside. A line is
    `<destination> <area> [<argument>=<shape>]...`, the destination named as the send guard names
    it (an MCP tool, `browser:<host>`, `host:<host>`). Placing a read outside the area that keeps the
    line, a line catching every destination, or a line that does not read as one is skipped and
    named."""
    out = []
    for owner, path, line in kept_lines("reads.txt", areas):
        words = line.split("#", 1)[0].split()
        conditions = [READ_CONDITION.match(w) for w in words[2:]]
        if len(words) < 2 or not all(conditions):
            skip(path, line, "is not `<destination> <area> [<argument>=<shape>]...`")
            continue
        pattern, target = words[0], words[1]
        # Every MCP tool's name opens with `mcp__`: it names no service.
        literal = pattern.lower().removeprefix("mcp__")
        for kind in DESTINATION_KINDS:
            literal = literal.removeprefix(kind)
        if not (target in areas and within(target, owner, areas)):
            skip(path, line, f"{target} is no area within {owner}")
        elif len(re.sub(r"[*?\[\]_]", "", literal)) < 3:
            skip(path, line, "catches every destination: name the service or the site")
        else:
            out.append((pattern, target, tuple((m.group(1), m.group(2)) for m in conditions)))
    return out


def skipped_settings() -> list[str]:
    """Every line of the areas' own settings that is not read, with why (`--settings`)."""
    areas = load_areas()
    kept_ignored(areas)
    kept_destinations(areas)
    kept_reads(areas)
    for name in areas:
        kept_allowed(name, areas)
        patterns(name, areas)
    return list(SKIPPED)


def load_areas(source: Path | None = None) -> dict[str, list[Path]]:
    """Areas by name. A line whose name holds `*` and whose paths end in `/*` makes one
    area per sub-folder (`client-* /srv/company/clients/*` -> `client-acme` for `clients/acme`);
    on a line whose name does not, every sub-folder of such a path joins the line's area
    (`company ~/*`). Either way a folder created tomorrow is guarded from the moment it exists.
    A path already named on an explicit line keeps that line's name, so `_outside ~/personal`
    keeps `~/personal` out of `company ~/*`. Each area's own lines join them (`area_lines`)."""
    return _areas_of(area_lines(source))


def area_words(areas: dict[str, list[Path]], source: Path | None = None) -> dict[str, set[str]]:
    """The names each area goes by: the names of the folders that make it. A folder a client line
    makes (`client-* .../clients/*`) is the client's name; a line that joins every sub-folder of a
    folder (`company /srv/company/*`) goes by that folder's name, not by its sub-folders' (`repos`,
    `docs`). A Latin name shorter than three letters names nothing (`ai`, `ml`)."""
    joined: dict[str, set[Path]] = {}
    for line in area_lines(source):
        parts = shlex.split(line, comments=True)
        if len(parts) >= 2 and "*" not in parts[0] and not parts[0].startswith("_"):
            joined.setdefault(parts[0], set()).update(expand(p[:-2]) for p in parts[1:] if p.endswith("/*"))
    words: dict[str, set[str]] = {}
    for name, roots in areas.items():
        if name in UNSCANNED or name.startswith("_"):
            continue
        parents = joined.get(name, set())
        names = {r.name for r in roots if r.parent not in parents} | {p.name for p in parents}
        words[name] = {w for w in names if len(w) >= (3 if w.isascii() else 2)}
    return words


def unknown_areas(read_inside: list[str], areas: dict[str, list[Path]]) -> list[str]:
    """The areas a session that has read inside `read_inside` does not know: neither read inside
    nor around one it has (the company around its client is where it works)."""
    return [n for n in areas if n not in UNSCANNED and not n.startswith("_") and n not in read_inside
            and not any(outer(n, r, areas) for r in read_inside)]


def named_areas(text: str, read_inside: list[str]) -> list[tuple[str, str]]:
    """(area, name) for each name of an area unknown to the session that the text carries."""
    areas = load_areas()
    words = area_words(areas)
    found = []
    for area in unknown_areas(read_inside, areas):
        for word in sorted(words.get(area, ())):
            shape = (rf"(?<![A-Za-z0-9]){re.escape(word)}(?![A-Za-z0-9])" if word.isascii() else re.escape(word))
            if re.search(shape, text, re.IGNORECASE):
                found.append((area, word))
    return found


def load_remote_areas(source: Path | None = None) -> list[tuple[str, str, str]]:
    """The roots on other machines, (area, host, path), the longest path first so the innermost
    wins. A root is `host:<host>:<absolute path>`, or `host:<host>:~/<path>` under that machine's home
    (matched as written: a command names it the same way), on the line of an area that also has a
    folder on this machine: its text is scanned there, and what is sent into it is judged against
    the areas it is outside of. A malformed root, a glob, or an area with no folder here is a broken
    file, not a pass."""
    source = source or guard_places.setting("areas.txt")
    local = load_areas(source)
    out = []
    for line in area_lines(source):
        parts = shlex.split(line, comments=True)
        for part in parts[1:]:
            if not part.startswith(REMOTE):
                continue
            host, _, path = part[len(REMOTE):].partition(":")
            if parts[0] in UNSCANNED or parts[0] == CARRIES or "*" in parts[0] + path \
                    or not host or not (path.startswith("/") or path.startswith("~/")):
                raise ValueError(f"areas.txt: {part!r} is not `{REMOTE}<host>:<absolute path or ~/path>` "
                                 f"on an area's line")
            if not local.get(parts[0]):
                raise ValueError(f"areas.txt: {parts[0]!r} has a folder on another machine and none here")
            out.append((parts[0], host.lower(), path.rstrip("/") or "/"))
    return sorted(out, key=lambda r: len(r[2]), reverse=True)


def remote_area(host: str, path: str, remote: list[tuple[str, str, str]]) -> str | None:
    """The innermost area holding `path` on `host` (a root on another machine), or None."""
    host = host.lower()
    for name, h, root in remote:
        if h == host and (path == root or path.startswith(root.rstrip("/") + "/")):
            return name
    return None


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
    for line in area_lines(source):
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


# Set by git for a hook, and by a command run in a linked worktree: they name the repository the
# command runs in, and they win over `git -C <folder>` (`git rev-parse --local-env-vars`).
REPOSITORY_GIT_VARS = frozenset((
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR"))


def git_in(folder: str | Path, *args: str, text: bool = False) -> subprocess.CompletedProcess:
    """A git command about the repository at `folder`, whichever repository a hook that runs this
    scan sits in: with the hook's own GIT_DIR, every published repository was read as that one and
    the table of public text lost all their text."""
    environment = {k: v for k, v in os.environ.items() if k not in REPOSITORY_GIT_VARS}
    return subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=text, env=environment)


def has_remote(repo: Path) -> bool:
    """A repository with a remote has somewhere to send what it holds."""
    listed = git_in(repo, "remote", text=True)
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
    """Every run that counts as a copy: RUN characters mostly Japanese, or LATIN_RUN otherwise.
    A run with no letter and no digit in it is not one (the separator row of a wide table, a rule
    of dashes): it says nothing, and every document that has one holds the same one."""
    text = normalize(text)
    for i in range(len(text) - RUN + 1):
        short = text[i:i + RUN]
        # A particle after a word of English ("README.md を") is still English.
        if mostly_japanese(short):
            yield short
    # The runs that start inside [first, last] lie wholly in a stretch of signs, or start in the
    # head of a link.
    silent = sorted([(m.start(), m.end() - LATIN_RUN) for m in SIGNS.finditer(text)]
                    + [(m.start(), m.end() - 1) for m in URL_HEAD.finditer(text)])
    # How many characters before each position belong to a command's options or to the head of a link.
    common = [0] * (len(text) + 1)
    for m in [*OPTION.finditer(text), *URL_HEAD.finditer(text)]:
        for k in range(m.start(), m.end()):
            common[k + 1] = 1
    for k in range(len(text)):
        common[k + 1] += common[k]
    at = 0
    for i in range(len(text) - LATIN_RUN + 1):
        while at < len(silent) and silent[at][1] < i:
            at += 1
        if at < len(silent) and silent[at][0] <= i:
            continue
        if (common[i + LATIN_RUN] - common[i]) * 2 >= LATIN_RUN:
            continue
        long = text[i:i + LATIN_RUN]
        if not mostly_japanese(long[:RUN]):
            yield long


def fingerprints(text: str) -> set[int]:
    return {digest(w) for w in windows(text)}


def line_print(line: str, kind: str = "line") -> int | None:
    """One print for a whole line of code ("line") or a row of data ("row"), long enough to mean
    something on its own (the same bar as a run: 12 characters mostly Japanese, 40 otherwise).
    Code is copied line by line, and printing every run of every line would hold hundreds of
    millions of values. The kinds are kept apart: a row is one hit, code takes CODE_LINES.
    A line with no letter and no digit in it (a banner of signs, an empty row) is no print."""
    text = normalize(line)
    if WORD.search(text) is None:
        return None
    if len(text) >= LATIN_RUN or (len(text) >= RUN and mostly_japanese(text)):
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
    of prose (Office, PDF, SQLite, Markdown outside repositories); kind "rows" prints whole rows of data
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
    if suffix in DATABASES:
        return ("runs", lambda: sqlite_text.units(path, CACHE / "scratch")) if sqlite_text.is_database(path) else None
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
            out = git_in(repo, "ls-files", "-z").stdout
            self.names[repo] = {n.decode("utf-8", "replace") for n in out.split(b"\0") if n}
        return self.names[repo]

    def reader(self, path: Path, repo: Path | None | bool = False, root: Path | None = None):
        """unit_reader for a file, applying the repository rule: inside a repository only what it
        tracks, minus vendored code (= untracked output and third-party copies are not its documents).
        Office files, PDFs and databases (ANYWHERE) count wherever they sit. `repo` may be passed
        when already known.

        Only a repository that lies inside the area (`root`) is the area's. One that holds the area
        from outside -- an agent's own state tree with a folder for the company -- keeps its notes,
        not the area's documents: only its Office files, PDFs and databases are read."""
        if repo is False:
            repo = self.of(path.parent)
        if repo is not None and root is not None and not (repo == root or root in repo.parents):
            return unit_reader(path, tracked=False) if path.suffix.lower() in ANYWHERE else None
        if repo is not None and path.suffix.lower() not in ANYWHERE:
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
    if not path.is_file() or (st.st_size > MAX_FILE and path.suffix.lower() not in ANYWHERE):
        return None
    # How a document is read is part of its stamp: prints made the old way are never reused.
    mtime_ns, size = content_stat(path, st)
    return f"{PRINT_FORMAT}:{reader[0]}:{mtime_ns}:{size}", reader


def database_read_with(path: Path) -> Path:
    """The document a changed file is read as: a database for its write-ahead log, else itself."""
    database = sqlite_text.database_of(path)
    return database if database is not None and database.suffix.lower() in DATABASES else path


def content_stat(path: Path, st: os.stat_result) -> tuple[int, int]:
    """(mtime_ns, size) of what a document's text is read from: a database's write-ahead log
    counts with it (the newer of the two times, the sum of the sizes), so a row written to the
    log alone changes the stamp."""
    log = sqlite_text.log_of(path) if path.suffix.lower() in DATABASES else None
    try:
        extra = log.stat() if log else None
    except OSError:
        extra = None
    if extra is None:
        return st.st_mtime_ns, st.st_size
    return max(st.st_mtime_ns, extra.st_mtime_ns), st.st_size + extra.st_size


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
        head = git_in(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", text=True).stdout.strip()
        if not head:
            continue
        # -z: a name is given as it is, whatever characters it holds (quoted, `git show` would not find it).
        listing = git_in(repo, "ls-tree", "-r", "-z", head)
        for row in listing.stdout.decode("utf-8", "replace").split("\0"):
            meta, _, name = row.partition("\t")
            words = meta.split()
            if not name or len(words) != 3 or words[1] != "blob":
                continue

            def read(repo: str = repo, head: str = head, name: str = name) -> str | None:
                blob = git_in(repo, "show", f"{head}:{name}")
                if blob.returncode != 0 or len(blob.stdout) > MAX_FILE or b"\0" in blob.stdout[:8192]:
                    return None
                return blob.stdout.decode("utf-8", "replace")

            yield f"{repo}\0{name}", words[2], name, read


def walked_files(root: Path):
    """(key, stamp, name, read) for every file under a folder of public text: the stamp is its
    size and modification time, and read() gives its text (None when it is not text).

    Inside a git repository the files it tracks are read, those in hidden folders too: an area's
    repository counts what it tracks the same way, so a template's `.github/` or notes folder
    would otherwise be an area's text and never public. Elsewhere hidden folders are passed over."""
    for folder, dirs, files in os.walk(root):
        if ".git" in dirs or ".git" in files:
            dirs[:] = []
            yield from filter(None, map(walked_file, tracked_paths(Path(folder))))
            continue
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        yield from filter(None, (walked_file(Path(folder, name)) for name in files))


def tracked_paths(repo: Path) -> list[Path]:
    """The files a repository tracks, less those under a folder SKIP_DIRS names."""
    r = git_in(repo, "ls-files", "-z")
    if r.returncode != 0:
        return []
    names = [n for n in r.stdout.decode("utf-8", "replace").split("\0") if n]
    return [repo / n for n in names if not SKIP_DIRS & set(Path(n).parts[:-1])]


def walked_file(path: Path):
    try:
        if path.is_symlink():
            return None
        status = path.stat()
    except OSError:
        return None
    if status.st_size > MAX_FILE:
        return None

    def read(path: Path = path) -> str | None:
        try:
            data = path.read_bytes()
        except OSError:
            return None
        return None if b"\0" in data[:8192] else data.decode("utf-8", "replace")

    return str(path), f"{status.st_size}:{status.st_mtime_ns}", path.name, read


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


def publish_public(table: array, ident: str, heads: dict[str, str] | None = None) -> None:
    """Put a built table in place, then its name beside it, then the heads it was read at. Stopped
    between the two, the old name stays beside the new table: the areas' tables are then not merged
    again until the next rebuild, which only leaves flagged what the new table would have cleared."""
    atomic_write(public_table(), table.tobytes())
    atomic_write(public_id_path(), ident)
    if heads is not None:
        atomic_write(public_heads_path(), json.dumps(heads, sort_keys=True))


def public_heads_path() -> Path:
    return CACHE / f"background-{PRINT_FORMAT}.heads"


def published_heads(source: Path) -> dict[str, str]:
    """The commit each published repository's remote default branch is at (= what `published_files`
    reads), by repository. A head that moved since the table was built is text made public since."""
    heads: dict[str, str] = {}
    for entry in read_lines(source):
        if not entry.startswith("published "):
            continue
        parent = expand(entry.split(None, 1)[1])
        for gitdir in sorted(parent.glob("*/.git")) + sorted(parent.glob("*/*/.git")):
            repo = str(gitdir.parent)
            head = git_in(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", text=True).stdout.strip()
            if head:
                heads[repo] = git_in(repo, "rev-parse", head, text=True).stdout.strip()
    return heads


def public_is_behind(source: Path) -> bool:
    """A published repository moved since the table was built (= its words are public and the table
    does not hold them yet). Waiting out the week, an area that took up such words stopped the very
    repository that had published them."""
    heads = published_heads(source)
    if not heads:
        return False
    try:
        kept = json.loads(public_heads_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return True
    return kept != heads


def public_is_edited(cached: Path, source: Path) -> bool:
    """background.txt was written after the table was built: the operator changed what is public."""
    return source.stat().st_mtime >= cached.stat().st_mtime


def public_is_old(cached: Path) -> bool:
    """Past its week, or behind what the published repositories carry now (= `public_is_behind`)."""
    return (time.time() - cached.stat().st_mtime >= BACKGROUND_MAX_AGE
            or public_is_behind(guard_places.setting("background.txt")))


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
    cached, source = public_table(), guard_places.setting("background.txt")
    if not source.is_file():
        return array("Q"), ""
    if cached.is_file() and not public_is_edited(cached, source):
        if not public_is_old(cached):
            return read_table(cached), read_public_id()
        if not wait:
            days = int((time.time() - cached.stat().st_mtime) // 86400)
            why = f"{days} days old" if days * 86400 >= BACKGROUND_MAX_AGE else "behind a published repository"
            say(f"the table of public text is {why}: this scan uses it as it is, and it is "
                "being rebuilt apart from the scan (text made public since may still be flagged)")
            rebuild_public_apart()
            return read_table(cached), read_public_id()
    with lock_file(wait=True, name=PUBLIC_LOCK):
        # Whoever held the lock may have built it while this process waited.
        if cached.is_file() and not public_is_edited(cached, source) and not public_is_old(cached):
            return read_table(cached), read_public_id()
        say("reading the public text (files unchanged since the last time are not read again)...")
        started = time.time()
        heads = published_heads(source)
        table, ident = build_public(source)
        publish_public(table, ident, heads)
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


def area_root(areas: dict[str, list[Path]], path: Path) -> tuple[str, Path] | None:
    """(area, root) of the innermost area holding path (= the one whose root is longest), the root
    itself included; None inside `_outside`."""
    best = max(((len(r.parts), n, r) for n, rs in areas.items() for r in rs if path == r or r in path.parents),
               default=None)
    return (best[1], best[2]) if best and best[1] != NO_AREA else None


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
    for phrase in read_lines(guard_places.setting("allow.txt")):
        allowed |= fingerprints(phrase)
    DOCS.mkdir(parents=True, exist_ok=True)
    old = json.loads(INDEX.read_text()) if INDEX.is_file() else {}
    previous = json.loads((CACHE / "summary.json").read_text()) if (CACHE / "summary.json").is_file() else {}
    index: dict = {}
    ignored = ignored_folders(areas)
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
    root it does not index (= it cannot find a document already known to be there).

    A root that holds no document known yet gives Spotlight nothing to be checked against, and
    Spotlight answers nothing for a folder it does not index: such a root is walked instead
    (unvouched_changes), so a document created in a new area is read at the next scan."""
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
    found: list[Path] = []
    try:
        for mount in mounts:
            asks.append(("state", None, subprocess.Popen(["mdutil", "-s", str(mount)], stdout=subprocess.PIPE,
                                                         stderr=subprocess.DEVNULL, text=True)))
        for root in tops:
            # Known paths and roots are both absolute and normalised, so a prefix is the parent test
            # (building a Path per known document costs a second on tens of thousands of them).
            inside = f"{root}{os.sep}"
            probe = next((Path(k) for k in known if k.startswith(inside) and os.path.isfile(k)), None)
            if probe is None:
                found += unvouched_changes(root, known)
                continue
            asks.append(("probe", probe, subprocess.Popen(
                ["mdfind", "-onlyin", str(probe.parent), "-name", probe.name],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)))
            asks.append(("changed", root, subprocess.Popen(
                ["mdfind", "-onlyin", str(root), f"kMDItemFSContentChangeDate >= $time.iso({stamp})"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)))
    except OSError:
        return None
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


def unvouched_changes(root: Path, known: dict) -> list[Path]:
    """Files under a root that the index does not know or whose content moved since it read
    them: a root Spotlight cannot be checked for, walked by itself. It holds no document yet, so
    the walk is short; a file in it that is no document is listed and passed over by the caller."""
    found = []
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in files:
            path = Path(folder, name)
            entry = known.get(str(path))
            try:
                moved = entry is None or stamp_stat(entry[0]) != content_stat(path, path.stat())
            except OSError:
                continue
            if moved:
                found.append(path)
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
        if known is None or content_stat(path, st) != known:
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
    """Add the documents changed since the last look to per-area delta tables. Past MAX_DELTA of
    them the summary says a full walk is due (`walk_due`). None = a full walk is needed first
    (Spotlight could not answer and there is no folder list yet to fall back to). A document whose
    prints are in an area's table and that was rewritten or deleted since leaves its old prints in
    that table, and a sentence taken out of a draft went on being the area's text for hours: a small
    area's table is merged anew here from the prints kept per document (no document is read again),
    and a larger one gets a full walk started apart (`walk_soon`) that this scan does not wait for.
    One the stat fallback finds gone is also dropped from the index at once (it can name no folder
    to have missed a new document in).

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
            # A root made after the last walk is in no folder list: one holding no known document is walked.
            changed += [p for root in roots if not any(k.startswith(f"{root}{os.sep}") for k in index)
                        for p in unvouched_changes(root, index)]
        started = time.time()
        ignored = ignored_folders(areas)
        repos = Repos()
        touched: set[str] = set()
        dropped = False
        # The areas a document whose old prints are in their table was rewritten or deleted in.
        replaced: set[str] = set()
        for path in removed:
            stale = index.pop(str(path), None)
            if stale is None:
                continue
            dropped = True
            if stale[-1] != "delta":
                replaced.add(stale[2])
            if not any(v[1] == stale[1] for v in index.values()):
                (DOCS / f"{stale[1]}.bin").unlink(missing_ok=True)
        # A database's write-ahead log is read with the database: its change is the database's.
        changed = list(dict.fromkeys(database_read_with(expand(str(c))) for c in changed))
        for path in changed:
            found = area_root(areas, path)
            if found is None or found[0] == EXEMPT or any(path == i or i in path.parents for i in ignored):
                continue
            area, root = found
            if path == root:
                # An area's root folder: Spotlight lists folders whose content moved, and asked
                # under an outer area it lists a nested area's root among them. It is no document.
                continue
            if any(p in SKIP_DIRS or p.startswith(".") for p in path.relative_to(root).parts[:-1]):
                continue
            # Its prints are in the area's table when the last walk read it (no delta mark).
            before = index.get(str(path))
            in_table = before is not None and before[-1] != "delta"
            found = document(path, repos, root=root)
            ok = found and document_prints(path, *found, index, index, area)[0]
            if ok:
                index[str(path)].append("delta")
                touched.add(area)
            if in_table and (not path.exists() or index[str(path)][0] != before[0]):
                replaced.add(area)
        deltas = {n: [v[1] for v in index.values() if v[2] == n and v[-1] == "delta"] for n in touched}
        if sum(len(f) for f in deltas.values()) > MAX_DELTA:
            # The delta is written all the same (= what changed is seen now); the full walk that
            # folds it into the area's table is due, and kept due until a walk writes a new summary.
            summary["walk_due"] = True
        if touched or replaced:
            allowed: set[int] = set()
            for phrase in read_lines(guard_places.setting("allow.txt")):
                allowed |= fingerprints(phrase)
            public = background_prints()
            for name, fids in deltas.items():
                atomic_write(CACHE / f"{name}.delta.bin", merged(fids, allowed, public).tobytes())
            for name in replaced:
                fids = [v[1] for v in index.values() if v[2] == name]
                if len(fids) > SMALL_AREA:
                    summary["walk_soon"] = True
                    continue
                table = merged(fids, allowed, public)
                atomic_write(CACHE / f"{name}.bin", table.tobytes())
                (CACHE / f"{name}.delta.bin").unlink(missing_ok=True)
                for entry in index.values():
                    if entry[2] == name and entry[-1] == "delta":
                        entry.pop()
                summary["areas"][name] = {"documents": len(fids), "fingerprints": len(table)}
                dropped = True
        if touched or dropped:
            atomic_write(INDEX, json.dumps(index))
        summary["checked"] = started
        atomic_write(CACHE / "summary.json", json.dumps(summary, indent=1))
        return summary


def say_built(summary: dict) -> None:
    documents = sum(a["documents"] for a in summary["areas"].values())
    say(f"built in {summary['seconds']}s: {documents} documents in {areas_count(summary['areas'])}"
        " (--status names them)")
    if summary["unreadable"]:
        say(unreadable_line(summary["unreadable"]))


def walk_apart(summary: dict, wait: float = WALK_WAIT) -> dict:
    """A full walk is due (the tables are past MAX_AGE, or the delta past MAX_DELTA). Start it as a
    process of its own -- unless one is at it -- and wait for it up to WALK_WAIT: a walk done by then
    is used as if walked here. Past that, this scan goes on with the tables on disk, which catch_up()
    has just brought up to date, and the walk finishes apart: a scan given up on by its caller does
    not stop it half way, and the next scan finds it done."""
    with lock_file(wait=False) as free:
        if not free:
            return summary
    say("walking the private documents (unchanged ones are reused)...")
    walk = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--walk"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    try:
        code = walk.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        say(f"the walk takes longer than {wait:g}s: it goes on apart from this scan, which uses the "
            "tables brought up to date just now")
        return summary
    built = built_summary()
    if code != 0 or built is None or built["built"] <= summary["built"]:
        say(f"the walk did not finish (exit {code}): this scan uses the tables brought up to date just now")
        return summary
    say_built(built)
    return built


class NotBuilt(Exception):
    """No tables on disk fit the areas, and the build started apart did not finish within WALK_WAIT."""


def fits(summary: dict, areas: dict[str, list[Path]]) -> bool:
    """Whether the tables a summary describes were built for these areas, by this way of printing."""
    return bool(summary.get("checked") and summary["run"] == [RUN, LATIN_RUN]
                and set(summary["areas"]) == {n for n in areas if n not in UNSCANNED})


def build_apart(areas: dict[str, list[Path]], wait: float = WALK_WAIT) -> dict:
    """No tables on disk fit these areas (a fresh cache, or areas.txt changed): start the build as a
    process of its own (= the `--walk` walk_apart starts) and wait for tables that fit up to WALK_WAIT.
    Built here instead, a build of tens of thousands of documents outlasts the time a send gives its
    scan, is killed with it, and the next scan starts it over: no send is judged until something
    without a time limit builds the tables. Raises NotBuilt when they are not there by then."""
    say("walking the private documents (unchanged ones are reused)...")
    walk = None
    deadline = time.time() + wait
    while True:
        built = built_summary()
        if built is not None and fits(built, areas):
            say_built(built)
            return built
        if walk is None or walk.poll() is not None:
            # Whoever holds the lock may be building them; once nobody does, this scan starts it.
            with lock_file(wait=False) as free:
                pass
            if free and walk is not None:
                break       # the walk this scan started ended without tables that fit
            if free:
                walk = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--walk"],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        if time.time() >= deadline:
            break
        time.sleep(BUILD_POLL)
    raise NotBuilt(f"the tables of the private documents are being built apart from this scan and were "
                   f"not ready within {wait:g}s: nothing is judged until they are (try again in a few minutes)")


def load(areas: dict[str, list[Path]], refresh: bool) -> dict[str, list[array]]:
    """Per area, the tables a sent line is looked up in: the full build and what changed since."""
    summary_path = CACHE / "summary.json"
    summary = None
    # The table of public text first: an edited background.txt is read before the areas' tables
    # are held against it.
    public_now = public_id()
    if summary_path.is_file() and not refresh:
        summary = json.loads(summary_path.read_text())
        if not fits(summary, areas):
            # Nothing on disk fits these areas: nothing to judge with until they are built anew.
            summary = None
        elif summary.get("public", "") != public_now:
            # The areas' tables were merged against another table of public text: what became
            # public since is still in them, and what is public no longer is still missing. They
            # are merged anew apart; the tables on disk answer meanwhile.
            summary = walk_apart(summary)
        else:
            summary = catch_up(areas, summary)
            if summary is not None and (summary.get("walk_due") or time.time() - summary["built"] >= MAX_AGE):
                summary = walk_apart(summary)
            elif summary is not None and summary.get("walk_soon"):
                # A large area's document was rewritten: its old prints go with a walk this scan
                # does not wait for.
                summary = walk_apart(summary, wait=0)
    if summary is None and refresh:
        say("walking the private documents (unchanged ones are reused)...")
        summary = build(areas, full=True)
        say_built(summary)
    elif summary is None:
        summary = build_apart(areas)
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
    out = git_in(folder, "remote", "-v", text=True).stdout
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
    path = guard_places.setting("destinations.txt")
    out = []
    for line in read_lines(path):
        words = line.split("#", 1)[0].split()
        if len(words) >= 2 and words[0].lower().startswith("repo:"):
            out.append((words[0][5:].lower(), words[1]))
    if area_folders():
        out += [(pattern[5:].lower(), target) for pattern, target, _ in kept_destinations(load_areas())
                if pattern.lower().startswith("repo:")]
    return out


#: The areas a `repo:` line of destinations.txt names as the owner of the repository a push goes
#: to (see destination): their text is the place's own, as the innermost area's is.
OWNERS: set[str] = set()


def destination(slugs: set[str], sender: Path, areas: dict[str, list[Path]]) -> Path | None:
    """Where the destination lives; None = outside every area.

    A `repo:<pattern> <area>` line names the area a repository belongs to. A private one cloned
    inside that area sits where its clone is, and the declared area is its owner (OWNERS): a
    client's repository in the company's own GitHub organization takes the client's text and the
    company's. Otherwise the repository sits in the declared area."""
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
            clone = cloned_place(slugs, sender, areas)
            if clone is not None and target in holding(clone, areas):
                OWNERS.add(target)
                return clone
            return areas[target][0]
    return cloned_place(slugs, sender, areas, say_why=True)


def cloned_place(slugs: set[str], sender: Path, areas: dict[str, list[Path]], say_why: bool = False) -> Path | None:
    """Where the clones of private repositories sit, when they all agree; None otherwise."""
    tell = say if say_why else (lambda _line: None)
    places: set[Path] = set()
    for slug in sorted(slugs):
        seen = visibility(slug)
        if seen != "private":
            tell(f"destination {slug} is {seen} on GitHub -- checked against every area")
            return None
        if slug in remote_repos(sender):
            places.add(sender)
            continue
        local = [Path(p) for p in clones(areas).get(slug, [])]
        if not local:
            tell(f"destination {slug} has no clone on this machine -- checked against every area")
            return None
        places.update(local)
    # Clones that sit in different areas may carry different things: only agreement decides.
    if len({holding(p, areas) for p in places}) != 1:
        tell(f"destination {', '.join(sorted(slugs))} has clones in different areas -- checked against every area")
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


def written_from(where: str, sender: Path) -> Path:
    """The folder a scanned line is written from: that of its file for an added line
    (`<sha> <path>`), the sending repository for a commit message or a payload."""
    _, _, path = where.partition(" ")
    return (sender / path).parent if path and path != "message" else sender


def sending_repo() -> str:
    """Where the pushing repository lives: its work tree, or for a bare repository its git dir."""
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode == 0 and top.stdout.strip():
        return top.stdout.strip()
    return git("rev-parse", "--absolute-git-dir").strip()


def dest_known():
    """scanners/destinations/dest-known.py, the one place that decides what a push sends."""
    spec = importlib.util.spec_from_file_location("dest_known", Path(__file__).resolve().parents[1] / "destinations/dest-known.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def outgoing(span: str) -> list[tuple[str, str]]:
    """(where, line) for every added line and message line in a push range
    (`<from>..<to>`, or `<to> ^<from> [^<from>...]` when it has several bases), as dest-known.py
    says it is sent: of a rewrite, pre-push names in GUARD_DEST_KNOWN what the destination holds."""
    folder = os.environ.get("GUARD_DEST_KNOWN")
    lines = []
    for sha, text, added, _ in dest_known().history(Path(folder) if folder else None, span.split()):
        if text is not None:
            for line in (text + "\n").splitlines():
                lines.append((f"{sha[:7]} message", line))
        lines.extend((f"{sha[:7]} {path}", line) for path, line in added)
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
    run = next((w for w in windows(line) if len(CONTENT.findall(w)) >= RUN_CONTENT
                and any(present(t, digest(w)) for t in tables)), None)
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


def patterns(name: str, areas: dict[str, list[Path]] | None = None) -> list[re.Pattern]:
    """The identifier shapes of the area `name`: the machine's patterns/<name>.txt, then the ones
    the areas it lies within keep (a shape there that does not compile is skipped and named)."""
    compiled = []
    for line in read_lines(guard_places.setting("patterns") / f"{name}.txt"):
        try:
            compiled.append(re.compile(line, re.IGNORECASE))
        except re.error as error:
            say(f"patterns/{name}.txt: {line!r} does not compile ({error})")
            sys.exit(2)
    for path, line in kept_patterns(name, areas) if areas else []:
        try:
            compiled.append(re.compile(line, re.IGNORECASE))
        except re.error as error:
            skip(path, line, f"does not compile ({error})")
    return compiled


def main(argv: list[str] | None = None) -> int:
    started = time.time()
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--range", dest="span")
    parser.add_argument("--text", type=Path)
    parser.add_argument("--settings", action="store_true",
                        help="name every line of the areas' own settings (areas/<area>/) that is not read, and why")
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
    parser.add_argument("--walk", action="store_true", help="the full walk a scan found due (walk_apart)")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args(argv)

    if args.refresh_public:
        # Started by a scan that found the table past its week, or by hand. Whoever holds the lock
        # is already at it: this one leaves.
        cached, source = public_table(), guard_places.setting("background.txt")
        with lock_file(wait=False, name=PUBLIC_LOCK) as mine:
            if mine and source.is_file() and not (cached.is_file() and not public_is_edited(cached, source)
                                                   and not public_is_old(cached)):
                before = read_public_id()
                heads = published_heads(source)
                table, ident = build_public(source)
                try:
                    areas = load_areas()
                except ValueError:
                    areas = {}
                if ident == before or not areas or not (CACHE / "summary.json").is_file():
                    publish_public(table, ident, heads)
                    return 0
                # What is public changed, and the areas' tables were merged against the old table.
                # They are merged anew here, so that no scan has to do it. The build lock is taken
                # before the new table shows: a scan never finds it beside tables nobody is merging.
                _PUBLIC[:] = [(table, ident)]
                with lock_file(wait=True):
                    publish_public(table, ident, heads)
                    _build_locked(areas, full=True)
        return 0
    if args.walk:
        # Started by a scan that found a full walk due or no tables that fit (build_apart), or by
        # hand. Whoever holds the lock is already at it: this one leaves -- unless nothing is on
        # disk yet, when the holder may be a scan of before that builds in its own process.
        try:
            areas = load_areas()
        except ValueError:
            return 2
        with lock_file(wait=built_summary() is None) as mine:
            if mine and areas:
                summary = built_summary()
                _build_locked(areas, full=summary is None or not fits(summary, areas)
                              or summary.get("public", "") != public_id())
        return 0
    try:
        areas = load_areas()
        carries = load_carries(areas)
    except ValueError as error:
        say(f"REFUSED — {error} (fix {guard_places.setting('areas.txt')})")
        return 2
    if not areas:
        say(f"NOT CHECKED — no areas defined in {guard_places.setting('areas.txt')} on this machine")
        return 0
    if args.settings:
        skipped = skipped_settings()
        for note in skipped:
            print(f"not read: {note}")
        say(f"{len(area_folders())} area(s) keep settings of their own; {len(skipped)} line(s) not read")
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
    own = {n for n in held if not any(n != m and outer(n, m, areas) for m in held)} | (OWNERS & held)
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
                f"({CARRIES} in {guard_places.setting('areas.txt')})")
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
    except NotBuilt as not_built:
        say(f"NOT JUDGED — {not_built}")
        return 2
    allowed = shared_places(areas) + [normalize(p) for p in read_lines(guard_places.setting("allow.txt"))]
    public = background_prints()
    own_roots = [root for n in own if n not in UNSCANNED for root in areas.get(n, [])]
    compared = [without_own_paths(line, written_from(where, sender), own_roots) for _, where, line in lines]
    found = []
    for name in checked:
        shapes = patterns(name, areas)
        tables = [t for t in prints.get(name, []) if len(t)]
        fine = allowed + [normalize(p) for p in kept_allowed(name, areas)]
        results = []
        for (group, where, line), text in zip(lines, compared):
            match = next((m.group(0) for p in shapes if (m := p.search(text))), None)
            found_here = ("shape", match) if match else (hit(text, tables, fine, public) if tables else None)
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
        say(f"replace it with made-up text, or add a phrase that is fine to {guard_places.setting('allow.txt')}"
            f" (scanned in {time.time() - started:.1f}s)")
        return 1
    also_held = f"; it may hold the text of {areas_count(holds)} more" if holds else ""
    say(f"clean ({len(lines)} lines against {areas_count(checked)}{also_held}) in {time.time() - started:.1f}s")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:   # a scan that breaks has judged nothing: never read as a hit (= exit 1)
        where = error.__traceback__
        while where.tb_next:
            where = where.tb_next
        say(f"could not judge: {type(error).__name__} in {where.tb_frame.f_code.co_name}() at line "
            f"{where.tb_lineno}: {error}")
        sys.exit(2)
