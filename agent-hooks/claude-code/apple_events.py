"""The applications a script for `osascript` sends Apple events to: outgoing.py names a send to
each of them `app:<name>`, with the script as what it carries."""

from __future__ import annotations

import re

# AppleScript's `tell application "Calendar"` and `application id "com.apple.iCal"`, and
# JavaScript for Automation's `Application("Calendar")` / `Application('com.apple.iCal')`.
APPLICATION = re.compile(r"""\bapplication\s*(?:id\s*)?\(?\s*(["'])([^"'\n]+)\1""", re.IGNORECASE)


def applications(code: str) -> list[str]:
    """Every application the script names, once each in the order it names them, lower-cased:
    macOS finds an application by its name or its bundle id whatever their case."""
    return list(dict.fromkeys(m.group(2).strip().lower() for m in APPLICATION.finditer(code)))
