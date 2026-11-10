"""Whether a line is a stylesheet rule or declaration: corpus-scan.py's line_print() calls it for
every whole line it would print, and a style line gets no print.

A rule such as `th, td { border: 1px solid var(--line); padding: 6px 8px; }` sets how a page
looks and says nothing of what the page is about. Every agent writes the same few rules for a
table or a heading, so the same line stands in documents of areas that never saw each other, and a
page written anywhere else carries it again. A line holding a character outside ASCII (a Japanese
`content:` text, a font named in Japanese) is not taken for style and is printed as before.
"""

from __future__ import annotations

import re

#: One declaration: a property written as stylesheets write it (lower case and hyphens, a vendor
#: prefix, or a custom one starting with `--`), a colon, a value with no brace and no semicolon,
#: and no colon followed by a space (`{ ok: true, view: body }` of a script holds a second key in
#: its value; a stylesheet's colon in a value is `url(https://...)`). The value does not start
#: with a colon either: `name::call` is a shell function's namespace, not a declaration.
DECLARATION = re.compile(r"\s*(?:--[\w-]+|-?[a-z][a-z0-9-]*)\s*:(?!:)\s*(?:[^;{}:]|:(?!\s))+?\s*")
#: Selectors before the block of a one-line rule: no brace and no semicolon; an `=` only inside an
#: attribute selector (`input[type=text]`), so `const options = { ... }` is not a rule; a colon only
#: before the name of a pseudo-class (`a:hover`), so YAML's `engines: {node: ...}` is not one.
SELECTORS = re.compile(r"(?:[^{};=:\[\]]|:(?=[\w:-])|\[[^\[\]]*\])+")


def is_style_line(line: str) -> bool:
    """True for a one-line rule (`selectors { declarations; }`) and for a declaration alone on its
    line (`property: value;`), when the line is all ASCII. A rule's block holds a semicolon: an
    object of a script separates its keys with commas (`return { label: text, shortLabel }`)."""
    text = line.strip()
    if not text or not text.isascii():
        return False
    if text.endswith("}") and text.count("{") == 1 and text.count("}") == 1:
        selectors, _, body = text[:-1].partition("{")
        return bool(SELECTORS.fullmatch(selectors)) and ";" in body and declarations(body)
    if text.endswith(";") and "{" not in text and "}" not in text:
        return DECLARATION.fullmatch(text[:-1]) is not None
    return False


def declarations(body: str) -> bool:
    """True when `body` is one or more declarations separated by semicolons (a last one may end
    without its semicolon)."""
    parts = body.split(";")
    if not parts[-1].strip():
        parts = parts[:-1]
    return bool(parts) and all(DECLARATION.fullmatch(part) for part in parts)
