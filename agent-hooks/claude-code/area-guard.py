#!/usr/bin/env python3
"""Keep an AI agent from carrying what it read out of an area (Claude Code PreToolUse hook).

Areas are defined in `$GUARD_CONFIG_DIR/areas.txt` (default `~/.config/guard/`), the same file
the private-document scan reads, through the same parser (`scanners/corpus-scan.py`). A session
that reads inside an area is marked with the area's name. A marked session may not write into a
git repository outside its marks, nor commit, push or send through `gh` to a destination outside
them.

- Marking: the target of Read / Grep / Glob, a Bash cwd, an area path named in a Bash command
           (unless the command only checks it: a lone test / [ / stat / realpath / readlink /
           ls -d with every argument literal)
- Refused: Edit / Write / NotebookEdit on a file inside a git repository outside the marks;
           a Bash `git commit` / `git push` / sending `gh` call (reads pass) whose destination is
           outside the marks
- Destination: a commit lands in its repository. A push or `gh` call lands in the GitHub
           repository it names, judged by the private-document scan (`corpus-scan.py --where`):
           a public repository is outside every area wherever it is cloned, a private one sits
           where its local clone is, and an unknown one is outside
- Several marks allow writing only inside all of them (company > client means inside the client)
- `_exempt` is never refused (the operator's own notes; their commits are scanned by the hooks)

Separately, and on every machine, a Bash command that switches the guards off or around
(skip variables, `--no-verify`, a hooksPath / exempt setting, clearing the marks, sending from a
repository the hooks do not reach) is refused: the operator types those, the agent does not.

Nothing is printed when a call passes, so nothing lands in the agent's context. A refusal is one
line. Marks are kept in `~/.cache/area-guard/<session_id>.json`, so they outlive compaction.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
AREAS = CONFIG / "areas.txt"
STATE = Path(os.environ.get("AREA_GUARD_STATE", Path.home() / ".cache/area-guard"))
CORPUS = Path(__file__).resolve().parents[2] / "scanners/corpus-scan.py"
EXEMPT = "_exempt"
READS = {"Read", "Grep", "Glob"}
WRITES = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
GIT_SEND = re.compile(r"\bgit\b[^|;&]*?\s(commit|push)\b")
GH_READONLY = {"view", "list", "status", "checks", "diff", "download", "clone", "watch", "token", "show"}
SHELL_BREAK = {"&&", "||", ";", "|"}


def real(path: str | Path, base: str | None = None) -> Path:
    p = Path(os.path.expanduser(os.path.expandvars(str(path))))
    if not p.is_absolute() and base:
        p = Path(base) / p
    return Path(os.path.realpath(p))


def corpus_module():
    """The private-document scan as a module: areas are parsed in that one place
    (including the `<prefix>* <path>/*` form that makes every client folder an area)."""
    spec = importlib.util.spec_from_file_location("corpus_scan", CORPUS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_areas() -> list[tuple[str, Path]]:
    """(name, real path), longest path first so the innermost area wins. Empty when unreadable."""
    if not AREAS.is_file():
        return []
    try:
        areas = corpus_module().load_areas(AREAS)
    except Exception:  # noqa: BLE001 — a broken checkout must not stop the agent; the push-time scan still refuses
        return []
    out = [(name, real(root)) for name, roots in areas.items() for root in roots]
    return sorted(out, key=lambda a: len(str(a[1])), reverse=True)


def area_of(path: Path, areas) -> str | None:
    for name, root in areas:
        if path == root or root in path.parents:
            return name
    return None


def inside(path: Path, name: str, areas) -> bool:
    return any(n == name and (path == r or r in path.parents) for n, r in areas)


def repo_root(path: Path) -> Path | None:
    d = path if path.is_dir() else path.parent
    while not d.exists() and d != d.parent:
        d = d.parent
    r = subprocess.run(["git", "-C", str(d), "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    return real(r.stdout.strip()) if r.returncode == 0 else None


def spell_home(command: str) -> str:
    """The command with ~/, $HOME and ${HOME} written out as the home folder."""
    home = str(Path.home())
    text = command.replace("${HOME}", home).replace("$HOME", home)
    return re.sub(r"(?<![\w/])~(?=/)", home, text)


def mentioned_paths(command: str, areas) -> list[Path]:
    """Area paths named in a Bash command (spelled with ~, $HOME, or absolute)."""
    text = spell_home(command)
    found = []
    for _, root in areas:
        for spelling in {str(root), os.path.normpath(str(root))}:
            if spelling in text:
                found.append(root)
    # A path through a shortcut symlink whose target is inside an area counts too
    for token in re.findall(r"(/[^\s'\"|;&<>]+)", text):
        try:
            p = real(token)
        except OSError:
            continue
        if area_of(p, areas):
            found.append(p)
    return found


# A command that says whether a path exists and what it is, never what it holds, reads
# nothing when it runs alone: one command, each argument taken literally.
JOINS = re.compile(r"[;&|<>()`\n\r]")      # a second command, pipe, redirect, subshell, substitution
EXPANDS = re.compile(r"[*?\[\]{}$]")       # a glob, brace expansion or variable turns into other paths
ATTRIBUTES_ONLY = {"test", "stat", "realpath", "readlink"}
LS_FLAGS = re.compile(r"-[dlaAhFG1]+|--directory")


def ls_names_only(args: list[str]) -> bool:
    """`ls` prints what a folder holds unless -d makes it print the named paths themselves."""
    flags = [a for a in args if a.startswith("-")]
    return (all(LS_FLAGS.fullmatch(f) for f in flags)
            and any(f == "--directory" or (not f.startswith("--") and "d" in f) for f in flags))


def path_only(command: str) -> bool:
    """True when the command only checks the paths it names (see ATTRIBUTES_ONLY and ls -d).
    Any doubt is False, and then a named area path marks the session."""
    text = spell_home(command)
    if JOINS.search(text):
        return False
    try:
        words = shlex.split(text)
    except ValueError:
        return False
    if words[:1] == ["["]:                     # `[ ... ]` is `test ...`
        if words[-1] != "]":
            return False
        words = ["test", *words[1:-1]]
    if not words or any(EXPANDS.search(a) for a in words[1:]):
        return False
    name, args = words[0], words[1:]
    return name in ATTRIBUTES_ONLY or (name == "ls" and ls_names_only(args))


def bash_marks(command: str, cwd: str, areas) -> list[Path]:
    """What a Bash command reads from: its folder always, and the area paths it names unless
    it only checks them."""
    named = [] if path_only(command) else mentioned_paths(command, areas)
    return [*named, real(cwd)]


def upto_break(words: list[str]) -> list[str]:
    return words[:next((i for i, w in enumerate(words) if w in SHELL_BREAK), len(words))]


def sends_of(command: str, cwd: str) -> list[tuple[Path, list[str]]]:
    """Every send in a command (git commit / push, a sending gh call) as
    (repository it runs in, arguments naming its destination for corpus-scan).
    A commit stays local, so its arguments are empty."""
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    target = cwd
    m = re.search(r"\bgit\s+-C\s+(\S+)", command) or re.search(r"(?:^|&&|;)\s*cd\s+(\S+)", command)
    if m:
        target = m.group(1).rstrip(";&|").strip("'\"")   # in `cd ~/x; git commit` the `;` is not part of the path
    target_path = real(target, cwd)
    found: list[tuple[Path, list[str]]] = []
    kinds = {k.group(1) for k in GIT_SEND.finditer(command)}
    if "commit" in kinds:
        found.append((target_path, []))
    for i, w in enumerate(words):
        if w == "push" and "push" in kinds:
            after = upto_break(words[i + 1:])
            named = next((a for a in after if not a.startswith("-")), None)
            found.append((target_path, ["--dest", push_url(target_path, named)]))
        elif w == "gh":
            gh_args = upto_break(words[i + 1:])
            rest = [a for a in gh_args if not a.startswith("-")]
            if rest[:1] == ["api"]:   # GET by default; it sends only with a body or a method
                sends = any(re.match(r"-[XfF]|--(method|field|raw-field|input)(=|$)", a) for a in gh_args)
            else:
                sends = len(rest) >= 2 and rest[0] != "search" and rest[1] not in GH_READONLY
            if sends:
                found.append((target_path, ["--gh-argv-inline", *gh_args]))
    return found


def push_url(repo: Path, named: str | None) -> str:
    """Where `git push` sends: a named remote's push URL, else the upstream, else origin."""
    if named and (":" in named or "/" in named):
        return named
    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout.strip()
    name = named or git("config", f"branch.{git('branch', '--show-current')}.pushRemote") \
        or git("config", "remote.pushDefault") \
        or git("config", f"branch.{git('branch', '--show-current')}.remote") or "origin"
    return git("remote", "get-url", "--push", name)


def destination(target: Path, dest_args: list[str]) -> Path | None:
    """Where a send lands; None when outside every area (a public repository, say).
    When the private-document scan cannot answer, the sending repository stands in."""
    if not dest_args:
        return target
    with tempfile.NamedTemporaryFile() as argv_file:
        args = dest_args
        if dest_args[0] == "--gh-argv-inline":
            argv_file.write(b"".join(a.encode() + b"\0" for a in dest_args[1:]))
            argv_file.flush()
            args = ["--gh-argv", argv_file.name]
        try:
            r = subprocess.run(["python3", str(CORPUS), "--where", "--repo", str(target), *args],
                               capture_output=True, text=True, timeout=60,
                               env={**os.environ, "GUARD_CONFIG_DIR": str(CONFIG)})
        except (OSError, subprocess.TimeoutExpired):
            return target
    out = r.stdout.strip().splitlines()[-1:] if r.returncode == 0 else []
    if not out:
        return target
    return None if out[0] == "OUTSIDE" else real(out[0])


def load_marks(session: str) -> set[str]:
    f = STATE / f"{session}.json"
    try:
        return set(json.loads(f.read_text()))
    except (OSError, ValueError):
        return set()


def save_marks(session: str, marks: set[str]) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / f"{session}.json").write_text(json.dumps(sorted(marks)))


def allowed(target: Path, marks: set[str], areas) -> bool:
    if area_of(target, areas) == EXEMPT:
        return True
    return all(inside(target, m, areas) for m in marks)


BYPASS_ENV = re.compile(r"(?<![\w-])(GH_GUARD_SKIP|GUARD_[A-Z_]+|ANON_WORDS_FILE|HUSKY"
                        r"|GIT_CONFIG_(?:PARAMETERS|COUNT|KEY_\d+|VALUE_\d+|GLOBAL|SYSTEM|NOSYSTEM))=")
GUARD_KEYS = re.compile(r"\b(core\.hookspath|guard\.scope|guard\.exemptprefix)\b", re.I)
GIT_VALUE_FLAGS = {"-m", "-F", "-c", "-C", "--message", "--file", "--author", "--date", "--fixup", "--squash",
                   "--reuse-message", "--reedit-message", "-t", "--template", "--cleanup", "--trailer"}


def git_config(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "config", *args], capture_output=True, text=True).stdout.strip()


def unguarded(repo: Path) -> str | None:
    """Why the git hooks do not reach this repository, or None (also when it is not a repository)."""
    top = repo_root(repo)
    if top is None:
        return None
    if git_config(top, "--local", "--get", "core.hooksPath"):
        return "the repository overrides core.hooksPath (husky and the like switch the hooks off)"
    hooks = git_config(top, "--get", "core.hooksPath")
    if not hooks or not (real(hooks, str(top)) / "pre-push").exists():
        return "no global core.hooksPath points at the guard hooks"
    if git_config(top, "--get", "guard.scope") == "exempt":
        return "guard.scope = exempt"
    prefix = git_config(top, "--get", "guard.exemptPrefix")
    if prefix and (top == real(prefix) or real(prefix) in top.parents):
        return "inside guard.exemptPrefix"
    return None


def bypass(command: str, cwd: str, areas) -> str | None:
    """Why a command switches the guards off or around, or None. The operator may; the agent may not."""
    expanded = spell_home(command)
    if re.search(r"\b(rm|mv|cp|truncate|tee|touch|ln)\b[^|;&]*\.cache/area-guard|>\s*\S*\.cache/area-guard", expanded):
        return "removes or rewrites the entry guard's marks"
    if (re.search(r"\bgit\b[^|;&]*\bconfig\b", command) and GUARD_KEYS.search(command)
            and not re.search(r"(^|\s)(--get|--get-all|--get-regexp|--list|-l)(\s|$)", command)):
        return "a git config that switches the hooks off"
    sends = sends_of(command, cwd)
    if not sends:
        return None
    if m := BYPASS_ENV.search(command):
        return f"sends with {m.group(1)} set"
    if re.search(r"(^|\s)--no-verify(\s|$)", command):
        return "--no-verify"
    if re.search(r"\bgit\b[^|;&]*\s-c\s*core\.hookspath", command, re.I):
        return "git -c core.hooksPath"
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    for i, w in enumerate(words):
        if w == "commit":
            after = upto_break(words[i + 1:])
            for j, a in enumerate(after):
                if (re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", a) and not (j and after[j - 1] in GIT_VALUE_FLAGS)):
                    return "git commit -n (= --no-verify)"
    for target, dest_args in sends:
        if dest_args[:1] == ["--gh-argv-inline"] or not areas or area_of(target, areas) == EXEMPT:
            continue
        if reason := unguarded(target):
            return f"{repo_root(target)}: {reason}"
    return None


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": reason}}, ensure_ascii=False))


def main() -> int:
    event = json.load(sys.stdin)
    areas = load_areas()
    tool, args, cwd = event.get("tool_name", ""), event.get("tool_input", {}), event.get("cwd", os.getcwd())
    # Switching the guards off or around is refused even on a machine with no areas
    if tool == "Bash" and (reason := bypass(args.get("command", ""), cwd, areas)):
        deny(f"area-guard: an agent does not switch the guards off or around ({reason}). "
             f"If it is needed, tell the operator why; the operator does it by hand")
        return 0
    if tool in WRITES and ".cache/area-guard" in str(real(args.get("file_path") or args.get("notebook_path") or "", cwd)):
        deny("area-guard: an agent does not rewrite the entry guard's marks")
        return 0
    if not areas:
        return 0
    session = event.get("session_id", "unknown")
    marks = load_marks(session)
    touched: list[Path] = []

    if tool in READS:
        for key in ("file_path", "path", "notebook_path"):
            if args.get(key):
                touched.append(real(args[key], cwd))
    elif tool == "Bash":
        command = args.get("command", "")
        touched += bash_marks(command, cwd, areas)
        for send in sends_of(command, cwd) if marks else []:
            place = destination(*send)
            if place is None or not allowed(place, marks, areas):
                where = "a public repository or another place outside every area" if place is None \
                    else str(repo_root(place) or place)
                deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
                     f"send to {where} (areas: {AREAS}). Do it in another session")
                return 0
    elif tool in WRITES:
        target = real(args.get("file_path") or args.get("notebook_path") or "", cwd)
        root = repo_root(target)
        if root is not None and marks and not allowed(target, marks, areas):
            deny(f"area-guard: this session has read inside {', '.join(sorted(marks))}, so it cannot "
                 f"write {target} (areas: {AREAS}). Do it in another session")
            return 0

    new = {a for a in (area_of(p, areas) for p in touched) if a and a != EXEMPT}
    if new - marks:
        save_marks(session, marks | new)
    return 0


if __name__ == "__main__":
    sys.exit(main())
