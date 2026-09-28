#!/usr/bin/env python3
"""The cage a Claude Code session runs in, built from the areas (`areas.txt`).

A session starts inside exactly one cage and stays there: the OS refuses the reads and
writes (sandbox-runtime: Seatbelt on macOS, bubblewrap on Linux), whatever program
attempts them -- a tool call, a shell redirection or a script's own `open()`. A cage is
`personal` or the name of an area.

- personal  reads everything but the areas, and writes anywhere in HOME but the areas
- an area   reads everything but the other areas (the areas around it stay readable, so a
            client session still reads the company notes it sits in), and writes only
            inside itself and `_exempt`, besides the machine's caches and the login keychain
- any cage  has its own Claude Code config and temp directories, and neither reads nor
            writes another cage's; it does not write the guards themselves (the install
            the hooks run from, the hooks directory, the global git config, `areas.txt`, the
            scanners' master word list), and starts its session knowing when the cage was
            entered (`GUARD_CAGED_SINCE`)

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
                                                the session starts with, `seatbelt` the
                                                macOS rules sandbox-runtime has no setting for
    cage-config.py --list                       print the cages this machine has
    cage-config.py --of PATH                    print the cage PATH belongs to: the innermost
                                                area holding it, else personal
    cage-config.py --record SESSION             print, as JSON, the cage and account a past
                                                conversation's record lives under (to resume it
                                                in the same cage); exit 1 when there is none
    cage-config.py --config-dirs                print the cages' config directories that exist
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone
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
# The session learns the moment its cage was entered from this variable (agent-hooks/ keeps it).
CAGED_SINCE = "GUARD_CAGED_SINCE"
# Each cage's temp directory is `<TMP_ROOT>/<cage>`. GUARD_TMP_ROOT moves the root so a test whose
# throwaway HOME lives in the running cage's own temp directory does not find that HOME hidden as
# another cage's temp. It is read here, before any cage starts, never from inside one.
TMP_ROOT = Path(os.path.realpath(os.environ.get("GUARD_TMP_ROOT") or TMP / "claude-cage"))
# Temp folders every session would share: Claude Code's own when no cage names one, and the
# one sandbox-runtime keeps writable in every sandbox. A cage writes its own instead.
SHARED_TMP = [TMP / f"claude-{os.getuid()}", TMP / "claude"]
# Claude Code settings files anywhere under HOME: `~/.claude/settings.json`, `~/.claude@<cage>/...`,
# a project's `.claude/settings.local.json` (`**/` matches no folder too).
SETTINGS_GLOB = "{home}/**/.claude*/settings*.json"
# Files a program loads by itself from whatever folder it starts in: a project's MCP servers (Claude
# Code runs their commands, approved by name only), Claude Code's commands and agents, the IDE and
# ripgrep settings. sandbox-runtime denies these beneath the folder the cage starts in and nowhere
# else, so a session started in one repository could rewrite them in every other. Kept to the names
# no repository here tracks: a denied name a repository carries stops its clone and pull in a cage
# (`.vscode`, `.gitmodules`), and `.git/hooks` stays writable because git copies samples there on
# init and clone -- the hooks run from the global dispatcher, and a repository pointing its own
# core.hooksPath elsewhere is refused at commit and push by agent-hooks.
LOADED_GLOBS = ["{home}/**/.mcp.json", "{home}/**/.claude/commands", "{home}/**/.claude/agents",
                "{home}/**/.idea", "{home}/**/.ripgreprc"]
# Seatbelt rules every cage adds on macOS that sandbox-runtime has no setting for (run.mjs puts them
# at the end of the profile). Security.framework reads this sysctl before it writes a keychain item;
# refused, every keychain write fails -- and Claude Code keeps its login there, so /login and each
# token refresh fail and the session goes on with a revoked token (401).
# The CPU feature a language runtime reads before it starts (SuperCollider's sclang stops without it).
SEATBELT = ['(allow sysctl-read (sysctl-name "security.mac.sandbox.sentinel"))',
            '(allow sysctl-read (sysctl-name "hw.optional.neon"))']
# The global git config (core.hooksPath, the git guards' way in) and the shells' startup files
# (where a launcher is defined, and an environment variable could point it elsewhere): no cage writes
# them, or a session could switch the guards off for the sessions after it.
GUARD_ENTRIES = [".gitconfig", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile", ".profile"]
# Services every cage may look up: TLS verification for Go programs (gh), the file-change notices
# Claude Code's watcher needs, and the list of audio devices (read only; music tools ask for it).
MACH_LOOKUP = ["com.apple.trustd.agent", "com.apple.FSEvents",
               "com.apple.audio.audiohald", "com.apple.audio.coreaudiod"]
# The personal cage also reaches the clipboard. An area cage does not: what it put there, the personal
# cage could read -- a way out of the area.
PERSONAL_MACH_LOOKUP = ["com.apple.pasteboard.1"]
# Machine-wide caches a session writes whichever cage it is in.
CACHES = ["~/.cache", "~/.npm", "~/Library/Caches", "~/.local/share/claude", "~/.local/state/claude"]
# The login keychain's folder: Claude Code keeps its login there, and each token refresh rewrites
# the keychain file (next to it, a temp file swapped in). An area cage that cannot write it keeps
# a revoked token after the first refresh (401). Readable from every cage already; only whole files
# can be allowed, not one item.
KEYCHAINS = "~/Library/Keychains"
# The operator master word list scanners/anon-scan.sh (and anon-fix.sh, anon-audit-deep.sh)
# read by default, and anon-sync-truth.sh / bootstrap-machine.sh / doctor.sh treat as the
# sync source (`ANON_TRUTH_PATH` overrides the file, same default in every one of them). Its
# directory (not just this one file: an operator may keep more than one list there, e.g. a
# second one an area's `ANON_TRUTH_PATH` points at) is a scanner truth a session must not be
# able to weaken, so its whole folder is carved out below like the guard's own config dir.
ANON_TRUTH_PATH = Path(os.environ.get("ANON_TRUTH_PATH", str(Path.home() / ".config/anon-words/master.txt")))
# What runs outside every cage by itself: a login item, and the programs a shell outside finds on
# PATH. A program a cage could rewrite there runs as the operator the next time anyone types its
# name -- and `~/.local/bin` comes first on PATH, ahead of git, gh and python. So no cage writes a
# PATH folder under HOME, the install a link there leads into, a conda base the shell hook runs at
# every start, nor what this machine lists in OUTSIDE_RUN (one path a line: a server a relay starts
# outside, an editable install). A conda base keeps envs/ and pkgs/ writable: environments are
# made from inside a session.
LOGIN_ITEMS = "~/Library/LaunchAgents"
OUTSIDE_RUN = CONFIG / "outside-run.txt"
CONDA_BASE = ["bin", "condabin", "lib", "etc", "shell", "conda-meta"]


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


def outside_run(home: Path) -> list[Path]:
    """Where programs that run outside the cages live, under HOME (see LOGIN_ITEMS). A link on
    PATH leads to one file (a versioned binary: the folder beside it takes new versions) or into
    an install whose `bin/` holds it (a venv, a Python build: the whole install)."""
    def install(root: Path) -> list[Path]:
        # A conda prefix is its base, not envs/ and pkgs/ beside it.
        if (root / "conda-meta").is_dir():
            return [root / name for name in CONDA_BASE if (root / name).exists()]
        return [root]

    found: list[Path] = [expand(LOGIN_ITEMS)]
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        folder = expand(entry) if entry else None
        if folder is None or not inside(folder, [home]) or not folder.is_dir():
            continue
        found += [folder, *(install(folder.parent) if (folder.parent / "conda-meta").is_dir() else [])]
        for item in folder.iterdir():
            if not item.is_symlink():
                continue
            target = expand(item)
            if not inside(target, [home]) or not target.exists():
                continue
            found += install(target.parent.parent) if target.parent.name == "bin" else [target]
    if OUTSIDE_RUN.is_file():
        for line in OUTSIDE_RUN.read_text(encoding="utf-8").splitlines():
            if line.split("#", 1)[0].strip():
                found.append(expand(line.split("#", 1)[0].strip()))
    return list(dict.fromkeys(found))


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


def config_dir(cage: str, account_dir: Path) -> Path:
    """A cage's Claude Code config directory: the account's own for personal, else `<account>@<cage>`."""
    return account_dir if cage == PERSONAL else Path(f"{account_dir}{CAGE_MARK}{cage}")


def split_config_dir(directory: Path) -> tuple[Path, str]:
    """A config directory -> (the account's directory, the cage)."""
    account, mark, cage = directory.name.partition(CAGE_MARK)
    return (directory.with_name(account), cage) if mark else (directory, PERSONAL)


def config_dirs() -> list[Path]:
    """The cages' config directories that exist, for every account (`~/.claude*@*`)."""
    return sorted(p for p in expand("~").glob(f".claude*{CAGE_MARK}*") if p.is_dir())


def record_of(session: str) -> dict | None:
    """Where a conversation's record lives: {cage, account_dir, config_dir}, the newest when
    the same session is found twice; None when there is none."""
    found = [p for p in expand("~").glob(f".claude*/projects/*/{session}.jsonl") if p.is_file()]
    if not found:
        return None
    directory = max(found, key=lambda p: p.stat().st_mtime).parents[2]
    account, cage = split_config_dir(directory)
    return {"cage": cage, "account_dir": str(account), "config_dir": str(directory)}


def cage_of(path: Path) -> str:
    areas = load_areas()
    areas.pop(EXEMPT, None)
    holding = [(len(r.parts), n) for n, roots in areas.items() for r in roots if inside(path, [r])]
    return max(holding)[1] if holding else PERSONAL


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
    own_config = config_dir(cage, account_dir)
    tmp_dir = TMP_ROOT / cage
    cage_configs = str(home / f".claude*{CAGE_MARK}*")
    other_tmp = [TMP_ROOT / n for n in [PERSONAL, *areas] if n != cage]

    if cage == PERSONAL:
        writable = [home]
    else:
        opened = [*exempt, *(expand(c) for c in [*CACHES, KEYCHAINS])]
        writable = [*own, *(p for r in opened for p in carve(r, holding)), own_config]
    writable.append(tmp_dir)
    # With no CLAUDE_CONFIG_DIR, Claude Code keeps its state next to the default directory.
    if own_config == default_config:
        writable.append(home / ".claude.json")

    sandbox = {
        # No allowedDomains: sandbox-runtime then leaves the network unrestricted (the git and gh
        # guards judge what leaves by content).
        "network": {"deniedDomains": [], "allowMachLookup": [
            *MACH_LOOKUP, *(PERSONAL_MACH_LOOKUP if cage == PERSONAL else [])]},
        "filesystem": {
            "denyRead": [*map(str, hidden), cage_configs, *map(str, other_tmp), *map(str, SHARED_TMP)],
            "allowRead": [str(own_config)] if cage != PERSONAL else [],
            "allowWrite": list(dict.fromkeys(map(str, writable))),
            "denyWrite": [
                *(str(r) for r in others if r not in holding),
                *map(str, SHARED_TMP),
                *dict.fromkeys(map(str, [expand(GUARD_HOME), GUARD])),
                str(home / ".config/git"),
                *(str(home / name) for name in GUARD_ENTRIES),
                str(home / ".git-hooks"),
                str(CONFIG),
                str(ANON_TRUTH_PATH.parent),
                # Claude Code's settings, of every config dir and every project: the entry guard is
                # registered there, and a `disableAllHooks` or a dropped hook would switch it off from
                # inside. The launcher writes them before the cage starts. (A glob: macOS only.)
                SETTINGS_GLOB.format(home=home),
                *(g.format(home=home) for g in LOADED_GLOBS),
                *map(str, outside_run(home)),
                # sandbox-runtime keeps this one writable in every sandbox; it is the personal
                # account's, so only the personal cage writes it.
                *([cage_configs] if cage == PERSONAL else [str(home / ".claude/debug")]),
            ],
        },
        # The session's own terminal (Claude Code's interface) needs a pty.
        "allowPty": True,
    }
    # zsh puts a here-document's temp file under TMPPREFIX (default /tmp/zsh), not TMPDIR.
    env = {"CLAUDE_CODE_TMPDIR": str(tmp_dir), "TMPDIR": str(tmp_dir), "TMPPREFIX": str(tmp_dir / "zsh"),
           # When the cage was entered, in the form Claude Code stamps on a record's rows: the entry
           # guard keeps it with the session, so a later sort knows which rows ran in a cage.
           CAGED_SINCE: datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")}
    if own_config != default_config:
        env["CLAUDE_CONFIG_DIR"] = str(own_config)
    if own_config != account_dir:
        # The login stays the account's: Claude Code names the stored credentials after this
        # directory, and after none at all (empty) for the default one.
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = "" if account_dir == default_config else str(account_dir)
    return {"cage": cage, "sandbox": sandbox, "env": env, "seatbelt": SEATBELT}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("cage", nargs="?")
    parser.add_argument("--account-dir", default="~/.claude",
                        help="the Claude Code config directory of the account (default ~/.claude)")
    parser.add_argument("--list", action="store_true", help="print the cages this machine has")
    parser.add_argument("--of", metavar="PATH", help="print the cage PATH belongs to")
    parser.add_argument("--record", metavar="SESSION", help="print where a conversation's record lives")
    parser.add_argument("--config-dirs", action="store_true", help="print the cages' config directories")
    args = parser.parse_args()
    if args.record:
        found = record_of(args.record)
        if found is None:
            print(f"cage-config: no record of {args.record} under ~/.claude*/projects", file=sys.stderr)
            return 1
        json.dump(found, sys.stdout)
        sys.stdout.write("\n")
        return 0
    if args.config_dirs:
        print("\n".join(map(str, config_dirs())))
        return 0
    if args.of:
        print(cage_of(expand(args.of)))
        return 0
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
