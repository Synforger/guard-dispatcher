"""One spelling of a path for every comparison the guard makes: the hooks and the scanners import it.

A name with a voiced kana or an accent has two Unicode spellings: composed (NFC, what a person
types and what the settings hold) and decomposed (NFD, what Finder, downloads and synced drives
often store). macOS opens either spelling of the same file, but hands back the stored one from
the working folder and a folder's listing, and a path is compared byte by byte. An area whose
line is written composed would then not hold a folder stored decomposed: a read inside it would
mark nothing. Every path the guard compares is therefore spelled composed, whenever that
spelling still reaches the same file.
"""

from __future__ import annotations

import os
import unicodedata
from pathlib import Path


def composed(path: str | os.PathLike) -> Path:
    """The path spelled composed (NFC), without touching the disk: for a path to compare that
    came from a folder's listing, beside a root that `resolved` gave."""
    return Path(unicodedata.normalize("NFC", os.fspath(path)))


def resolved(path: str | os.PathLike) -> Path:
    """The real path (links followed), spelled composed when the composed spelling reaches a file
    or folder too (a file system that tells the two spellings apart keeps the stored one)."""
    real = os.path.realpath(path)
    nfc = unicodedata.normalize("NFC", real)
    if nfc == real or os.path.lexists(nfc) or not os.path.lexists(real):
        return Path(nfc)
    return Path(real)
