"""How an address is read for the machine it names: the judgments outgoing.py's destination names rest on.
Nothing here touches a file, the network or the destination lines.

The scheme of an address is what its head says (`://` after letters), not any `://` the address
holds. The host of an address urlsplit refuses (a character in its user information that a client
takes for itself, a bracket) is read by hand, user information dropped; an address whose host cannot
be read at all gives None, so that the caller counts it as a destination that is not known and not
as no destination. The patterns curl expands in an address (`[1-3]`, `{a,b}`) stand for every
address they expand to.
"""

from __future__ import annotations

import itertools
import math
import re
import unicodedata
from typing import NamedTuple
from urllib.parse import urlsplit

# Addresses one word may stand for before they are no longer listed: more is read by what stands
# before the first pattern.
MAX_ADDRESSES = 1000
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
# Where the host of an address ends.
AFTER_HOST = "/?#"
RANGE = re.compile(r"(?:(\d+)-(\d+)|([A-Za-z])-([A-Za-z]))(?::(\d+))?")
# What an IPv6 address in brackets is written with, a zone included.
IPV6 = re.compile(r"[0-9A-Za-z:.%_~-]+")
# What a backslash takes the pattern meaning from.
ESCAPED = "{}[],\\"
PATTERN_START = re.compile(r"[\[\]{}\\]")


class Parts(NamedTuple):
    scheme: str
    host: str
    port: int | None
    path: str
    plain: str      # the address with its scheme written out and its user information dropped


class Expansion(NamedTuple):
    urls: list[str]
    exact: bool     # False: only what stands before the first pattern, the rest of the address is not read


def with_scheme(url: str) -> str:
    """The address with a scheme: the one at its head, else `http://`."""
    return url if SCHEME.match(url) else f"http://{url}"


def read(url: str) -> list[Parts] | None:
    """The readings of the machine an address names, one or two. An empty list: it names none
    (`file:///x`). None: it names one that cannot be read."""
    address = with_scheme(url)
    try:
        parts = urlsplit(address)
        host = parts.hostname or ""
    except ValueError:
        return _by_hand(address)
    if not host:
        return []
    try:
        port = parts.port
    except ValueError:
        port = None
    return [Parts(parts.scheme, host, port, parts.path, address)]


def path_of(url: str) -> str:
    """The path of an address, as `read` finds it, or what urlsplit finds when the host names none."""
    address = with_scheme(url)
    try:
        return urlsplit(address).path
    except ValueError:
        return next((reading.path for reading in read(url) or []), "")


def _by_hand(address: str) -> list[Parts] | None:
    """The host of an address urlsplit refuses, read as the text says and as the text reads once a
    client prepares it (NFKC): both are machines the address may name."""
    scheme, _, rest = address.partition("://")
    found = []
    for text in dict.fromkeys([rest, unicodedata.normalize("NFKC", rest)]):
        end = next((i for i, char in enumerate(text) if char in AFTER_HOST), len(text))
        hostport, after = text[:end].rpartition("@")[2], text[end:]
        host, port = _host_and_port(hostport)
        if host:
            path = re.split(r"[?#]", after, maxsplit=1)[0]
            found.append(Parts(scheme.lower(), host, port, path, f"{scheme}://{hostport}{after}"))
    return found or None


def _host_and_port(hostport: str) -> tuple[str, int | None]:
    if hostport.startswith("["):
        close = hostport.find("]")
        if close < 0:
            return "", None
        host, port = hostport[1:close], hostport[close + 1:].removeprefix(":")
    else:
        host, _, port = hostport.partition(":")
    return host.lower(), int(port) if port.isascii() and port.isdigit() else None


def expand(word: str) -> Expansion | None:
    """Every address curl expands the word to. A pattern curl does not expand (an IPv6 address in
    brackets, a backslash before a bracket) is the text it is. None when the word cannot be listed
    and what stands before the first pattern does not hold the host."""
    if not PATTERN_START.search(word):
        return Expansion([word], True)
    parsed = _parse(word)
    if isinstance(parsed, list) and math.prod(len(part) for part in parsed) <= MAX_ADDRESSES:
        return Expansion(["".join(chosen) for chosen in itertools.product(*parsed)], True)
    head = word[:_first_pattern(word)]
    if "/" in SCHEME.sub("", head) or any(char in head for char in "?#"):
        return Expansion([head], False)
    return None


def _first_pattern(word: str) -> int:
    match = PATTERN_START.search(word)
    return match.start() if match else len(word)


def _parse(word: str) -> list[tuple[str, ...]] | None:
    """The word as a list of what each place takes (a text outside a pattern takes only itself), or
    None when a pattern is one curl does not take or lists too much."""
    parts: list[tuple[str, ...]] = []
    text: list[str] = []
    at = 0
    while at < len(word):
        char = word[at]
        if char == "\\" and word[at + 1:at + 2] and word[at + 1] in ESCAPED:
            text.append(word[at + 1])
            at += 2
        elif char == "[":
            close = word.find("]", at)
            if close < 0:
                return None
            body = word[at + 1:close]
            if RANGE.fullmatch(body):
                values = _range(body)
                if values is None:
                    return None
                parts += [("".join(text),), values]
                text = []
            elif ":" in body and IPV6.fullmatch(body):
                text.append(word[at:close + 1])
            else:
                return None
            at = close + 1
        elif char == "{":
            items, at = _set(word, at)
            if items is None:
                return None
            parts += [("".join(text),), tuple(items)]
            text = []
        elif char in "]}":
            return None
        else:
            text.append(char)
            at += 1
    return [*parts, ("".join(text),)]


def _set(word: str, at: int) -> tuple[list[str] | None, int]:
    """The items of the set that opens at `at`, and where it ends: no item when it never closes or
    holds a pattern of its own (curl does not nest them)."""
    items, item = [], []
    at += 1
    while at < len(word):
        char = word[at]
        if char == "\\" and word[at + 1:at + 2] and word[at + 1] in ESCAPED:
            item.append(word[at + 1])
            at += 1
        elif char == "}":
            items.append("".join(item))
            return (None if items == [""] else items), at + 1
        elif char == ",":
            items.append("".join(item))
            item = []
        elif char in "{[":
            return None, at
        else:
            item.append(char)
        at += 1
    return None, at


def _range(body: str) -> tuple[str, ...] | None:
    """What `[1-3]`, `[01-10]`, `[a-e]` and a step (`[1-9:2]`) stand for; None when curl refuses it
    or it stands for more than MAX_ADDRESSES."""
    match = RANGE.fullmatch(body)
    first, last, from_letter, to_letter, step_text = match.groups()
    step = int(step_text) if step_text else 1
    if step < 1:
        return None
    if first is not None:
        start, end = int(first), int(last)
        if start > end or (end - start) // step >= MAX_ADDRESSES:
            return None
        width = len(first) if first.startswith("0") and len(first) > 1 else 0
        return tuple(f"{number:0{width}d}" for number in range(start, end + 1, step))
    if from_letter.isupper() != to_letter.isupper() or from_letter > to_letter:
        return None
    return tuple(chr(code) for code in range(ord(from_letter), ord(to_letter) + 1, step))
