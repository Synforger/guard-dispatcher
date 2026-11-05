"""Whether an edit of `orders.txt` only adds openings of relayed messages (`>` and `>>` lines).

The entry guard (`area-guard.py`) keeps `orders.txt` to the operator, but for this one kind of
change: an opening tells the guard a message was relayed by a client and not typed by the operator,
so adding one only takes words out of what counts as the operator's. A change that adds an order,
an approving phrase (`+`) or a cancelling tail (`!`), or that takes or rewrites any line, stays the
operator's. Nothing here touches a file: the caller reads the file and passes its text.
"""

from __future__ import annotations

import difflib
import re

#: A line that opens a relayed message (`>`), or one from another machine (`>>`), and names it.
RELAY_LINE = re.compile(r"^>{1,2}\s*[^\s#]")


def text_after(tool: str, arguments: dict, before: str) -> str | None:
    """The file's text once an Edit, a MultiEdit or a Write has run on `before`, or None when that
    cannot be told (an edit whose old text is not in the file once, a tool that writes no text)."""
    if tool == "Write":
        content = arguments.get("content")
        return content if isinstance(content, str) else None
    if tool == "Edit":
        edits = [arguments]
    elif tool == "MultiEdit":
        edits = [e for e in arguments.get("edits") or [] if isinstance(e, dict)]
    else:
        return None
    text = before
    for edit in edits:
        old, new = edit.get("old_string"), edit.get("new_string")
        if not isinstance(old, str) or not isinstance(new, str) or not old:
            return None
        count = text.count(old)
        if count == 0 or (count > 1 and not edit.get("replace_all")):
            return None
        text = text.replace(old, new) if edit.get("replace_all") else text.replace(old, new, 1)
    return text


def only_adds_relay_lines(before: str, after: str) -> bool:
    """Every line of `before` stays, in its place, and every line added is an opening of a relayed
    message, a comment or blank."""
    old, new = before.splitlines(), after.splitlines()
    for kind, _, _, start, end in difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes():
        if kind == "equal":
            continue
        if kind != "insert":
            return False
        for line in new[start:end]:
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and not RELAY_LINE.match(stripped):
                return False
    return True
