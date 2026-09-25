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

    corpus-scan.py --range <from>..<to> [--dest <url>]   a push (pre-push passes the push URL)
    corpus-scan.py --text <file> --gh-argv <file>        one gh payload (gh-guard)
    corpus-scan.py --where [--dest <url> | --gh-argv <file>]
                                          print where the destination lives, or OUTSIDE
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
import urllib.error
import urllib.request
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
    for root in {r for rs in areas.values() for r in rs}:
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
    parser.add_argument("--dest", help="the remote URL (or owner/repo) the text is sent to")
    parser.add_argument("--gh-argv", type=Path, help="a file holding the NUL-separated arguments of a gh call")
    parser.add_argument("--where", action="store_true", help=f"print where the destination lives, or {OUTSIDE}")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args(argv)

    areas = load_areas()
    if not areas:
        say(f"NOT CHECKED — no areas defined in {CONFIG / 'areas.txt'} on this machine")
        return 0
    if args.refresh or args.status:
        if args.refresh:
            for stale in ("visibility.json", "clones.json"):
                (CACHE / stale).unlink(missing_ok=True)
            load(areas, refresh=True)
        summary = json.loads((CACHE / "summary.json").read_text()) if (CACHE / "summary.json").is_file() else None
        if summary:
            age = (time.time() - summary["built"]) / 3600
            say(f"fingerprints built {age:.1f}h ago (run {summary['run']}): " + ", ".join(
                f"{n} {a['documents']} documents / {a['fingerprints']} runs" for n, a in summary["areas"].items()))
        else:
            say("fingerprints not built yet")
        return 0
    if not (args.span or args.text or args.where):
        parser.error("give --range, --text, --where, --refresh or --status")

    sender = expand(str(args.repo or (git("rev-parse", "--show-toplevel").strip() if args.span else os.getcwd())))
    here: Path | None = sender
    if args.gh_argv:
        gh_args = [a for a in args.gh_argv.read_bytes().decode("utf-8", "replace").split("\0")]
        here = destination(gh_destinations(gh_args[:-1] if gh_args[-1:] == [""] else gh_args, sender),
                           sender, areas)
    elif args.dest and (slug := github_repo(args.dest)):
        here = destination({slug}, sender, areas)
    if args.where:
        print(here or OUTSIDE)
        return 0
    if here is not None and contains(areas.get(EXEMPT, []), here) and not any(
            contains(rs, here) for n, rs in areas.items() if n != EXEMPT):
        return 0
    checked = [n for n, roots in areas.items() if n != EXEMPT and (here is None or not contains(roots, here))]
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
        say(f"this carries text from a private area that {here or 'the destination'} is outside of:")
        for line in found:
            print(f"    {line}", file=sys.stderr)
        say(f"replace it with made-up text, or add a phrase that is fine to {CONFIG / 'allow.txt'}")
        return 1
    say(f"clean ({len(lines)} lines against {', '.join(checked)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
