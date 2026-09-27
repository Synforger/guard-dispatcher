#!/usr/bin/env python3
"""The cage a Claude Code session runs in, built from the areas (`areas.txt`).

A session starts inside exactly one cage and stays there: the OS refuses the reads and
writes (sandbox-runtime: Seatbelt on macOS, bubblewrap on Linux), whatever program
attempts them -- a tool call, a shell redirection or a script's own `open()`. A cage is
`personal` or the name of an area.

- personal  reads everything but the areas, and writes anywhere in HOME but the areas
- an area   reads everything but the other areas (the areas around it stay readable, so a
            client session still reads the company notes it sits in), and writes only
            inside itself and `_exempt`
- any cage  has its own Claude Code config and temp directories, and neither reads nor
            writes another cage's; it does not write the guards themselves (the install
            the hooks run from, the hooks directory, the global git config, `areas.txt`)

The sandbox refuses a write whenever a write-deny covers the path, whatever allows it, so an
area around this one is kept out of the writable set rather than denied: where it sits inside
a writable folder (`_exempt` holding both the company's notes and the client's inside them),
that folder is opened entry by entry around it, and a new file directly beside such an area
cannot be created from this cage.

The network is left open: what leaves the machine is judged by the git and gh guards, by
its content, not by where it goes.

Usage:
    cage-config.py <cage> [--account-dir DIR]   print the cage as JSON: `sandbox` is the
                                                sandbox-runtime config, `env` the variables
                                                the session starts with
    cage-config.py --list                       print the cages this machine has
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path

CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
GUARD = Path(__file__).resolve().parents[1]
CORPUS = GUARD / "scanners/corpus-scan.py"
# Where scripts/install.sh puts the guards the hooks run from.
GUARD_HOME = Path(os.environ.get("GUARD_HOME", Path.home() / ".local/share/guard-dispatcher"))
EXEMPT = "_exempt"
PERSONAL = "personal"
# A cage's Claude Code config directory is the account's directory with `@<cage>` appended
# (`~/.claude@company`), so one glob finds every cage's directory whatever the account.
CAGE_MARK = "@"
# `/tmp` as the sandbox sees it (on macOS a link to /private/tmp).
TMP = Path(os.path.realpath("/tmp"))
TMP_ROOT = TMP / "claude-cage"
# Temp folders every session would share: Claude Code's own when no cage names one, and the
# one sandbox-runtime keeps writable in every sandbox. A cage writes its own instead.
SHARED_TMP = [TMP / f"claude-{os.getuid()}", TMP / "claude"]
# Machine-wide caches a session writes whichever cage it is in.
CACHES = ["~/.cache", "~/.npm", "~/Library/Caches", "~/.local/share/claude", "~/.local/state/claude"]


def expand(path: str | Path) -> Path:
    return Path(os.path.realpath(os.path.expanduser(os.path.expandvars(str(path)))))


def load_areas() -> dict[str, list[Path]]:
    """Areas by name, parsed by the private-document scan (the one parser of `areas.txt`).
    No file means no areas; a broken file raises, so a cage is never built from half of it."""
    spec = importlib.util.spec_from_file_location("corpus_scan", CORPUS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = CONFIG / "areas.txt"
    return module.load_areas(source) if source.is_file() else {}


def inside(path: Path, roots: list[Path]) -> bool:
    return any(path == r or r in path.parents for r in roots)


def carve(root: Path, holding: list[Path]) -> list[Path]:
    """`root` as writable paths that leave out every folder in `holding`: the whole root when
    none lies within it, else its entries one by one (links skipped: they may lead anywhere)."""
    if inside(root, holding):
        return []
    if not any(inside(h, [root]) for h in holding):
        return [root]
    out: list[Path] = []
    for entry in sorted(root.iterdir()):
        if not entry.is_symlink():
            out.extend(carve(entry, holding))
    return out


def build(cage: str, account_dir: Path) -> dict:
    areas = load_areas()
    exempt = areas.pop(EXEMPT, [])
    if PERSONAL in areas:
        raise SystemExit(f"cage-config: `{PERSONAL}` is the cage outside every area; rename that area")
    if cage != PERSONAL and cage not in areas:
        known = ", ".join(sorted(areas)) or "none"
        raise SystemExit(f"cage-config: no area named {cage!r} (areas: {known})")

    own = areas.get(cage, [])
    # The areas this one sits inside: readable (a client session reads the company notes
    # around it), never writable (the client's material does not flow into the company's).
    around = {n for n, roots in areas.items() if n != cage and any(inside(r, roots) for r in own)}
    hidden = [r for n, roots in areas.items() if n not in around | {cage} for r in roots]
    others = [r for n, roots in areas.items() if n != cage for r in roots]
    holding = [r for r in others if any(inside(o, [r]) for o in own)]

    home = expand("~")
    default_config = expand("~/.claude")
    config_dir = account_dir if cage == PERSONAL else Path(f"{account_dir}{CAGE_MARK}{cage}")
    tmp_dir = TMP_ROOT / cage
    cage_configs = str(home / f".claude*{CAGE_MARK}*")
    other_tmp = [TMP_ROOT / n for n in [PERSONAL, *areas] if n != cage]

    if cage == PERSONAL:
        writable = [home]
    else:
        opened = [*exempt, *(expand(c) for c in CACHES)]
        writable = [*own, *(p for r in opened for p in carve(r, holding)), config_dir]
    writable.append(tmp_dir)
    # With no CLAUDE_CONFIG_DIR, Claude Code keeps its state next to the default directory.
    if config_dir == default_config:
        writable.append(home / ".claude.json")

    sandbox = {
        # No allowedDomains: sandbox-runtime then leaves the network unrestricted.
        "network": {"deniedDomains": []},
        "filesystem": {
            "denyRead": [*map(str, hidden), cage_configs, *map(str, other_tmp), *map(str, SHARED_TMP)],
            "allowRead": [str(config_dir)] if cage != PERSONAL else [],
            "allowWrite": list(dict.fromkeys(map(str, writable))),
            "denyWrite": [
                *(str(r) for r in others if r not in holding),
                *map(str, SHARED_TMP),
                *dict.fromkeys(map(str, [expand(GUARD_HOME), GUARD])),
                str(home / ".config/git"),
                str(home / ".git-hooks"),
                str(CONFIG),
                # sandbox-runtime keeps this one writable in every sandbox; it is the personal
                # account's, so only the personal cage writes it.
                *([cage_configs] if cage == PERSONAL else [str(home / ".claude/debug")]),
            ],
        },
        # The session's own terminal (Claude Code's interface) needs a pty.
        "allowPty": True,
    }
    env = {"CLAUDE_CODE_TMPDIR": str(tmp_dir), "TMPDIR": str(tmp_dir)}
    if config_dir != default_config:
        env["CLAUDE_CONFIG_DIR"] = str(config_dir)
    return {"cage": cage, "sandbox": sandbox, "env": env}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("cage", nargs="?")
    parser.add_argument("--account-dir", default="~/.claude",
                        help="the Claude Code config directory of the account (default ~/.claude)")
    parser.add_argument("--list", action="store_true", help="print the cages this machine has")
    args = parser.parse_args()
    if args.list:
        areas = load_areas()
        areas.pop(EXEMPT, None)
        print("\n".join([PERSONAL, *sorted(areas)]))
        return 0
    if not args.cage:
        parser.error("name a cage (or --list)")
    json.dump(build(args.cage, expand(args.account_dir)), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
