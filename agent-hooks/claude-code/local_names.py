"""The `local:` names an address of this machine answers to, however it is written. Called by outgoing.py's
place_of, which takes one of them only when a line blocks it: a name found here closes what the operator
closed and opens nothing.

No name is looked up on the network: an address is this machine's by its number, by the name every system
keeps for it, by the hosts file, or by being the machine's own host name. A host with a character outside
ASCII may be any name once a client has prepared it, by tables that change with Unicode's versions: it
counts as this machine's, which closes only the port and path a line blocks.
"""

from __future__ import annotations

import functools
import ipaddress
import posixpath
import re
import socket
from pathlib import Path
from urllib.parse import unquote, urlsplit

HOSTS = Path("/etc/hosts")
# What inet_aton is handed: it stops reading at a space, so nothing but the characters of a number.
NUMERIC = re.compile(r"[0-9a-fx.]+")
SLASHES_AFTER_SCHEME = re.compile(r"(?i)^(https?|wss?):/*(?=[^/])")
# An address in code: as far as the string or the word it stands in runs, whatever it is written with.
IN_CODE = re.compile(r"(?i)\b(?:https?|wss?):[\\/]*[^\s'\"`<>]+")
CLOSES_AFTER_AN_ADDRESS = ")]},;."
DEFAULT_PORTS = {"https": 443, "wss": 443}
HTTP_PORT = 80


def in_code(code: str) -> list[str]:
    """Each address written in code once, also without what closes after it (`fetch(url);`)."""
    found = IN_CODE.findall(code)
    return list(dict.fromkeys([*found, *(a.rstrip(CLOSES_AFTER_AN_ADDRESS) for a in found)]))


@functools.cache
def names(url: str) -> tuple[str, ...]:
    """Every `local:<port><path>` the address answers to, as written first; none for another machine's.
    A backslash is read as itself and as the slash some clients take it for."""
    return tuple(dict.fromkeys([*_names(url), *_names(re.sub(r"\\+", "/", url))]))


def _names(url: str) -> list[str]:
    """`names` of one reading of the address."""
    address, count = SLASHES_AFTER_SCHEME.subn(lambda m: f"{m.group(1)}://", url.strip())
    if not count and "://" not in address:
        address = f"http://{address}"
    try:
        parts = urlsplit(address)
        host = unquote(parts.hostname or "").lower().rstrip(".")
        if not host or not _is_this_machine(host):
            return []
        port = parts.port or DEFAULT_PORTS.get(parts.scheme.lower(), HTTP_PORT)
    except ValueError:
        return []
    return [f"local:{port}{path}" for path in _paths(parts.path or "/")]


def _paths(path: str) -> list[str]:
    """The path as written, as a client squashes it, and as a server decodes it."""
    found = [path, _squashed(path), unquote(path), _squashed(unquote(path)), unquote(_squashed(path))]
    found += [p.rstrip("/") or "/" for p in found]      # a server sends `/name/` on to `/name`
    return list(dict.fromkeys(found))


def _squashed(path: str) -> str:
    squashed = posixpath.normpath(re.sub(r"/{2,}", "/", f"/{path}"))
    return f"{squashed}/" if squashed != "/" and path.endswith(("/", "/.", "/..")) else squashed


def _is_this_machine(host: str) -> bool:
    if not host.isascii() or host == "localhost" or host.endswith(".localhost") or host in _own_names():
        return True
    readings = [host]
    if NUMERIC.fullmatch(host):
        parts = ["0" if part == "0x" else part for part in host.split(".")]     # `0x` alone reads as nought
        # a leading zero is octal to one resolver and nothing to another
        readings += [".".join(parts), ".".join((p.lstrip("0") or "0") if p.isdigit() else p for p in parts)]
    for address in filter(None, map(_address, readings)):
        address = getattr(address, "ipv4_mapped", None) or address
        if address.is_loopback or address.is_unspecified:
            return True
    return False


def _address(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        if ":" in host:
            return ipaddress.IPv6Address(host.split("%", 1)[0])
        if NUMERIC.fullmatch(host):
            return ipaddress.IPv4Address(socket.inet_aton(host))
    except (OSError, ValueError):
        pass
    return None


@functools.cache
def _own_names() -> frozenset[str]:
    own = socket.gethostname().lower().rstrip(".")
    found = {own, f"{own.removesuffix('.local')}.local"} if own else set()
    try:
        lines = HOSTS.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = []
    for line in lines:
        number, *listed = line.split("#", 1)[0].lower().split() or [""]
        if listed and (address := _address(number)) is not None and (address.is_loopback or address.is_unspecified):
            found.update(listed)
    return frozenset(found)
