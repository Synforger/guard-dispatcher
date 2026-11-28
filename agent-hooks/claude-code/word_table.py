"""The table of which words may go where, built from the settings, for a session that was stopped
by a word list (`area-guard.py words`). A word stops where a list that holds it is held to the
send: the operator's list (`master`) outside every area, an area's own list (`<area>.txt`) inside
that area. It passes everywhere else. Only the areas the session may read are named. Judging
only: the caller reads the files and hands their lines in."""

from __future__ import annotations

MASTER = "master"
OUTSIDE = "outside"
BLOCK = "block"
#: Where a destination with no line of its own sits (send-scan.py's DEFAULTS), for the master's row.
DEFAULT_OUTSIDE = ("Artifact*", "WebFetch", "WebSearch", "mcp__claude_ai_*")


def words_of(lines: list[str]) -> list[str]:
    """The patterns of a word list, as anon-pattern.sh reads them: a `#` starts a comment, blank lines
    are skipped, `cs:` (matched case-sensitively) is kept as written."""
    found = []
    for line in lines:
        word = line.split("#", 1)[0].strip()
        if word and word not in found:
            found.append(word)
    return found


def table(lists: dict[str, list[str]], destinations: list[tuple[str, str]], areas: list[str],
          visible: set[str] | None, enclosing: dict[str, set[str]] | None = None) -> str:
    """The table as text. `lists`: list name (`master` or an area) -> its patterns. `destinations`:
    (pattern, where it sits) of destinations.txt. `areas`: every area's name. `visible`: the areas
    the session may read, None for all. `enclosing`: area -> the areas whose folders hold its
    folders: a send into an area takes its own list, a write into its folders the lists of those
    areas too."""
    enclosing = enclosing or {}
    shown_areas = sorted(a for a in set(areas) if visible is None or a in visible)
    shown_lists = [MASTER] if MASTER in lists else []
    shown_lists += [a for a in shown_areas if a in lists]
    out = ["Word lists, and the sends their words stop:", ""]
    for name in shown_lists:
        if name == MASTER:
            places = [p for p, where in destinations if where == OUTSIDE] + list(DEFAULT_OUTSIDE)
            out.append(f"  {MASTER} (the operator's list): a send outside every area")
        else:
            places = [p for p, where in destinations if where == name]
            around = sorted(a for a in shown_areas if name in enclosing.get(a, set()))
            also = f" and of {', '.join(around)}" if around else ""
            out.append(f"  {name}: a send into {name}, and a write into the folders of {name}{also}")
        out.append(f"    destinations: {', '.join(places) if places else '(none declared)'}")
    if not shown_lists:
        out.append("  (no word list is kept on this machine)")
    out += ["", "A word passes into every place no list holding it stops. A message to another session",
            "gets no word list. Each word, the lists that stop it, and where it passes:", ""]
    scopes = [OUTSIDE, *shown_areas]
    rows = []
    for name in shown_lists:
        for word in lists[name]:
            if word in (row[0] for row in rows):
                continue
            stopped_by = [n for n in shown_lists if word in lists[n]]
            stopped = {OUTSIDE if n == MASTER else n for n in stopped_by}
            passes = []
            for scope in scopes:
                if scope in stopped:
                    continue
                if scope != OUTSIDE and enclosing.get(scope, set()) & stopped:
                    passes.append(f"a send into {scope} (not a write into its folders)")
                else:
                    passes.append(_scope_name(scope))
            passes.append("another session")
            rows.append((word, ", ".join(stopped_by), ", ".join(passes)))
    width = max((len(row[0]) for row in rows), default=0)
    for word, stopped_by, passes in rows:
        out.append(f"  {word.ljust(width)}  stopped by: {stopped_by}; passes: {passes}")
    blocked = [p for p, where in destinations if where == BLOCK]
    if blocked:
        out += ["", f"Blocked for every send, whatever it holds: {', '.join(blocked)}"]
    return "\n".join(out) + "\n"


def _scope_name(scope: str) -> str:
    return "outside every area" if scope == OUTSIDE else f"into {scope}"
