#!/usr/bin/env python3
"""Another agent session as a destination: the Claude Code side.

A message one session sends another is a send like any other: the receiver may write where the
sender may not. Where the receiver sits is not declared anywhere; it is what the entry guard
already keeps: the areas that session has read inside (its marks, `area-guard.py`). A message
is judged against them by `scanners/destinations/send-scan.py` (`--session-areas`):

- into a session that has read inside the areas the text comes from (or inside an area within
  them): passes, the receiver learns nothing it could not read;
- into a session that has read less: the text of the areas it has not read is refused, as for a
  push. A message in words of the sender's own passes.

So the same rule covers every pair of sessions, in both directions, with no line to write.

Claude Code keeps one file per running session under each config directory
(`~/.claude*/sessions/<pid>.json`: its id, its name, its process). `SendMessage` names its
receiver by that name; a client that relays messages between sessions (it types them into the
receiver's terminal, or hands them over some other way) names it by the session's id.

    peers.py --to SESSION --text FILE     judge FILE as a message to SESSION (an id or a name)
                                          exit 0 passes, 1 refuses (one line why), 2 cannot judge
    peers.py --to SESSION --covers SENDER exit 0 when SESSION knows every area SENDER has read
                                          inside, 1 when not: a relaying client shows the sender's
                                          name (which says where it works) only on 0

A relaying client runs this before it delivers, so every way into it is judged at one place.

What the operator typed in a session is judged apart from what an agent wrote. An agent's words
are scanned: a paraphrase carries nothing of the documents. The operator's own words are not
written with that care, and no scan knows what they say, so they are taken to carry every area
the session they were typed in has read inside: they pass only to a session that has read inside
each of those areas (and are scanned like any message besides).

    peers.py --to SESSION --text FILE --typed-in SESSION    FILE is what the operator typed there

A session addresses another by the role it holds (`roles.txt` among an area's own settings: a name
and the folder the session works in), and a relaying client shows that name in place of a hidden
one. A role is shown only to a session that reads inside the area keeping it:

    peers.py --roles --folder FOLDER [--session SESSION]
                                          `<role>\t<folder>` per line, for every role a session
                                          working in FOLDER (and holding SESSION's marks) may see

A request that travels between sessions is kept as a ticket in a folder named `tickets`, which the
client's backend alone writes (`ticket_places.py` holds the rule). Where a ticket sits is told here,
and what is written into it is judged here as a message to a session that has read inside the
boundaries of that folder:

    peers.py --place-for SESSION [--typed-in SESSION2] [--folder WORKING_FOLDER]
                                          the folder for a ticket opened by SESSION (and holding what
                                          the operator typed in SESSION2; with --folder, the areas
                                          holding the folder SESSION works in count as read, but not
                                          the names its reads file gives): exit 0 prints it, 1 when the
                                          areas read fit in no one place (one line why), 2 cannot judge
    peers.py --to-place FOLDER --text FILE [--typed-in SESSION]
                                          judge FILE as a message to the folder's boundaries: as
                                          `--to`, with them standing for what a session has read
    peers.py --to SESSION --covers-place FOLDER [--folder WORKING_FOLDER]
                                          exit 0 when SESSION may read every boundary of FOLDER: the
                                          areas it has read inside, and those its working folder
                                          reaches (the folder it started in, unless --folder says), 1 if not
    peers.py --places [--session SESSION]
                                          every folder tickets sit in, one per line; with --session
                                          only those SESSION may read
"""

from __future__ import annotations

import argparse
import functools
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import area_roles  # noqa: E402
import guard_places  # noqa: E402
from path_forms import resolved  # noqa: E402
import ticket_places  # noqa: E402
import work_reads  # noqa: E402
from children import registry  # noqa: E402

STATE = guard_places.marks_folder()
SEND_SCAN = Path(__file__).resolve().parents[2] / "scanners/destinations/send-scan.py"
# ` [3fa9c1]` after a name tells two sessions of one name apart; the files do not hold it.
REF = re.compile(r"\s*\[[0-9A-Za-z]+\]\s*$")
SESSION_ID = re.compile(r"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")


def config_dirs() -> list[Path]:
    """Every Claude Code config directory on this machine: one per account the operator runs."""
    found = {Path(p) for p in glob.glob(str(Path.home() / ".claude*")) if Path(p, "sessions").is_dir()}
    if named := os.environ.get("CLAUDE_CONFIG_DIR"):
        found.add(Path(named))
    return sorted(found)


def alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (OSError, TypeError, ValueError):
        return False
    return True


def running() -> list[dict]:
    """The sessions running on this machine, as Claude Code records them."""
    out = []
    for folder in config_dirs():
        for path in sorted((folder / "sessions").glob("*.json")):
            try:
                row = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(row, dict) and row.get("sessionId") and alive(row.get("pid")):
                out.append(row)
    return out


def marks(session: str) -> list[str]:
    """The areas a session is held to: what the entry guard keeps for it, and for a child what its
    parent had read when the child was registered."""
    try:
        data = json.loads((STATE / f"{session}.json").read_text())
    except (OSError, ValueError):
        data = []
    own = set(data if isinstance(data, list) else data.get("areas") or [])
    return sorted(registry.marks_of(session, own))


def receivers(to: str) -> list[str]:
    """The ids of the sessions `to` names: an id names itself (running or not: its marks outlive
    it), a name every running session that carries it. None when no session here has the name."""
    to = REF.sub("", to.strip())
    if SESSION_ID.match(to):
        return [to]
    return sorted({row["sessionId"] for row in running() if row.get("name") == to})


def subagent(to: str, transcript: str | None) -> bool:
    """Whether `to` is one of this session's own subagents (by its agent id): a message to it
    stays inside the session."""
    if not transcript or not re.fullmatch(r"[0-9A-Za-z_-]+", to):
        return False
    return (Path(transcript).with_suffix("") / "subagents" / f"agent-{to}.jsonl").is_file()


def scan(name: str, payload: Path, areas: list[str]) -> tuple[int, str]:
    """(exit status, the line why) for a message to the destination `name`, whose session has read
    inside `areas`: the send scan's judgement of the text in `payload`."""
    try:
        r = subprocess.run(["python3", str(SEND_SCAN), "--dest", name, "--text", str(payload),
                            "--session-areas", ",".join(areas)],
                           capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return 2, (f"not sent to {name}: the send scan did not finish within 180s -- refused because "
                   f"it could not be judged in time, not because of what it found")
    except OSError:
        return 2, f"not sent to {name}: the send scan could not run"
    if r.returncode == 0:
        return 0, ""
    for line in r.stderr.splitlines():      # which run was hit, ahead of the one line why
        if line.startswith("    "):
            print(line, file=sys.stderr)
    why = (r.stderr.strip().splitlines() or ["the send scan refused it"])[-1].removeprefix("send-scan: ")
    return (1 if r.returncode == 1 else 2), why


def judge_for(name: str, payload: Path, area_sets: list[list[str]]) -> tuple[int, str]:
    """(exit status, the line why) for a message to the destination `name`, judged as bound for a
    reader that has read inside each set of areas in turn: the first set that refuses decides."""
    for areas in area_sets:
        status, why = scan(name, payload, areas)
        if status:
            return status, why
    return 0, ""


def judge(to: str, payload: Path) -> tuple[int, str]:
    """(exit status, the line why) for a message to `to`. A name no session here carries is a
    session elsewhere (another machine, the cloud) as far as this machine can tell: it is judged
    as one that has read nothing. Several sessions of one name must each take the message."""
    found = receivers(to)
    status, why = judge_for(f"session:{REF.sub('', to.strip())}", payload, [marks(s) for s in found] or [[]])
    if status and not found:
        why += (". No session running on this machine has that name, so it is taken to be one "
                "elsewhere; this session's own subagent is named by its agent id")
    return status, why


@functools.cache
def corpus_module():
    """The private-document scan as a module: the areas are parsed in that one place."""
    spec = importlib.util.spec_from_file_location("corpus_scan", SEND_SCAN.parents[1] / "corpus/corpus-scan.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def covers(to: str, sender: str) -> bool:
    """Whether every session `to` names knows every area the sender has read inside: has read
    inside it, or works inside it (the company around the client it has read). A relaying client
    shows the sender's name (which says where it works) only then."""
    module = corpus_module()
    areas = module.load_areas()
    told = marks(REF.sub("", sender.strip()))
    for receiver in receivers(to) or [None]:
        unknown = set(module.unknown_areas(marks(receiver) if receiver else [], areas))
        if unknown & set(told):
            return False
    return True


def roles(folder: Path, session: str | None) -> list[tuple[str, Path]]:
    """(role, folder) for every role a session working in `folder`, holding `session`'s marks,
    may see: those an area it reads inside keeps (area_roles.visible)."""
    module = corpus_module()
    named_areas = module.load_areas()
    areas = area_pairs(named_areas)
    home = resolved(folder)
    seen = area_roles.reach_from(home, areas, work_reads.named(home)) | set(marks(session) if session else [])
    shown = area_roles.visible(module.kept_roles(named_areas), seen,
                               lambda name, owner: module.within(name, owner, named_areas),
                               module.outward_roles(named_areas))
    return [(name, place) for name, place, _ in shown]


def area_pairs(named_areas: dict[str, list[Path]]) -> area_roles.Areas:
    """The areas as (name, root) pairs, the form `area_roles` and `ticket_places` take."""
    return [(name, root) for name, roots in named_areas.items() for root in roots]


def marks_of(session: str) -> set[str]:
    """The areas read inside by every session `session` names (an id or a name): none for a name no
    session carries."""
    return set().union(*[set(marks(s)) for s in receivers(session)] or [set()])


def carried_refusal(name: str, carried: set[str], readers: list[set[str]]) -> tuple[int, str]:
    """(exit status, the line why) for the operator's words that carry the areas `carried`, bound for
    `name` that is read by readers who have read inside each set of `readers`: every one must have
    read inside every area carried."""
    for read in readers:
        if missing := sorted(carried - read):
            return 1, (f"not sent to {name}: what the operator typed in a session that has read inside "
                       f"{', '.join(missing)} goes only to a session that has read there too")
    return 0, ""


def typed_in(to: str, sender: str) -> tuple[int, str]:
    """(exit status, the line why) for the operator's own words, typed in `sender`, bound for
    `to`: they go only where every area `sender` has read inside has been read too."""
    return carried_refusal(f"session:{REF.sub('', to.strip())}", marks_of(sender),
                           [set(marks(s) if s else []) for s in receivers(to) or [None]])


def place_boundaries(folder: Path) -> set[str]:
    """The areas a ticket folder lies in most closely, and those around them."""
    return ticket_places.boundaries(resolved(folder), area_pairs(corpus_module().load_areas()))


def place_for(session: str, typed: str | None, work_folder: Path | None = None) -> tuple[int, str]:
    """(exit status, the folder or the line why) for a ticket opened by `session`, that holds what
    the operator typed in `typed`. With `work_folder`, the areas holding the folder `session` works in
    count as read too: a tab inside an area that has read nothing yet still writes its name and tier
    inside it. The names the folder's reads file gives do not count: they are areas the session may
    read, and a ticket carries only what it has read, so a reads file naming many areas (`client-*`)
    would leave every ticket of the tab in no one place."""
    try:
        read = marks_of(session) | (marks_of(typed) if typed else set()) | \
            (reached(work_folder, with_reads_file=False) if work_folder else set())
        return 0, str(ticket_places.place_for(read, area_pairs(corpus_module().load_areas())))
    except ticket_places.PlaceError as error:
        return error.status, error.why
    except (OSError, ValueError) as error:
        return ticket_places.CANNOT_JUDGE, f"the areas could not be read: {error}"


def judge_place(folder: Path, payload: Path, typed: str | None) -> tuple[int, str]:
    """(exit status, the line why) for a message written into the ticket folder `folder`, which
    stands for a reader that has read inside the folder's boundaries."""
    name = f"place:{resolved(folder)}"
    try:
        wanted = place_boundaries(folder)
    except (OSError, ValueError) as error:
        return ticket_places.CANNOT_JUDGE, f"not sent to {name}: the areas could not be read ({error})"
    status, why = carried_refusal(name, marks_of(typed), [wanted]) if typed else (0, "")
    return (status, why) if status else judge_for(name, payload, [sorted(wanted)])


def reached(work_folder: Path, *, with_reads_file: bool = True) -> set[str]:
    """The areas a session working in `work_folder` may read inside without having read there: the
    areas holding the folder and those around them, and (`with_reads_file`) the areas its reads file
    names, a glob in it (`client-*`) standing for every area it matches. Only names areas.txt has."""
    home = resolved(work_folder)
    areas = area_pairs(corpus_module().load_areas())
    found = area_roles.reach_from(home, areas, work_reads.named(home) if with_reads_file else ())
    return set(found) & {name for name, _ in areas}


def readable(session: str, work_folder: Path | None) -> set[str]:
    """The areas `session` may read inside: those it has, and those the folder it works in reaches
    (without one, the folder its running record says it started in)."""
    home = work_folder or next((Path(row["cwd"]) for row in running()
                                if row["sessionId"] == session and row.get("cwd")), None)
    return set(marks(session)) | (reached(home) if home else set())


def covers_place(to: str, folder: Path, work_folder: Path | None) -> bool:
    """Whether every session `to` names may read every boundary of the ticket folder `folder`
    (the areas around a read area count as read, as in `covers`)."""
    named_areas = corpus_module().load_areas()
    wanted = place_boundaries(folder)
    for session in receivers(to) or [None]:
        read = readable(session, work_folder) if session else set()
        if wanted & set(corpus_module().unknown_areas(sorted(read), named_areas)):
            return False
    return True


def places(session: str | None) -> list[Path]:
    """Every folder a ticket sits in; with `session`, those whose boundaries it may read."""
    found = ticket_places.all_places(area_pairs(corpus_module().load_areas()))
    return [p for p in found if session is None or covers_place(session, p, None)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--to", help="the receiving session: its id, or its name")
    parser.add_argument("--text", type=Path, help="a file holding the message")
    parser.add_argument("--covers", metavar="SESSION", help="exit 0 when the receiver knows every area this "
                        "sending session has read inside (its name may be shown to it), 1 when not")
    parser.add_argument("--typed-in", metavar="SESSION", help="the text is what the operator typed in this "
                        "session (its id, or its name): it carries every area that session has read inside")
    parser.add_argument("--roles", action="store_true", help="print the roles a session working in --folder "
                        "may see, one `<role>\\t<folder>` per line")
    parser.add_argument("--folder", type=Path, help="with --roles: the folder the viewing session works in; "
                        "with --covers-place: the folder the receiving session works in; "
                        "with --place-for: the folder the opening session works in")
    parser.add_argument("--session", help="with --roles: the viewing session, whose marks count too; "
                        "with --places: only the folders this session may read")
    parser.add_argument("--place-for", metavar="SESSION", help="print the folder a ticket opened by this "
                        "session sits in")
    parser.add_argument("--to-place", metavar="FOLDER", type=Path, help="judge --text as a message written "
                        "into this ticket folder")
    parser.add_argument("--covers-place", metavar="FOLDER", type=Path, help="exit 0 when the --to session may "
                        "read every boundary of this ticket folder, 1 when not")
    parser.add_argument("--places", action="store_true", help="print every folder tickets sit in")
    args = parser.parse_args()
    if args.roles:
        if args.folder is None:
            parser.error("--roles needs --folder")
        for name, place in roles(args.folder, args.session):
            print(f"{name}\t{place}")
        return 0
    if args.places:
        for place in places(args.session):
            print(place)
        return 0
    if args.place_for:
        status, said = place_for(args.place_for, args.typed_in, args.folder)
        print(said, file=sys.stdout if status == 0 else sys.stderr)
        return status
    if args.covers_place:
        if not args.to:
            parser.error("--covers-place needs --to")
        return 0 if covers_place(args.to, args.covers_place, args.folder) else 1
    if args.to_place:
        if args.text is None:
            parser.error("--to-place needs --text")
        status, why = judge_place(args.to_place, args.text, args.typed_in)
        if why:
            print(f"peers: {why}", file=sys.stderr)
        return status
    if not args.to:
        parser.error("give --to")
    if args.covers:
        return 0 if covers(args.to, args.covers) else 1
    if args.text is None:
        parser.error("give --text, or --covers")
    status, why = typed_in(args.to, args.typed_in) if args.typed_in else (0, "")
    if not status:
        status, why = judge(args.to, args.text)
    if why:
        print(f"peers: {why}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
