#!/usr/bin/env bats
# scripts/install.sh, bootstrap-machine.sh and doctor.sh on a throwaway HOME.

load ../_internal/helpers

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/.config/anon-words"
    printf '%s\n' "${SENTINEL}" > "${H}/.config/anon-words/master.txt"
    export HOME="${H}"
    unset GIT_CONFIG_GLOBAL CLAUDE_CONFIG_DIR GUARD_CONFIG_DIR ANON_TRUTH_PATH
    cd "${H}" || return 1
}

# clone_to <dir> — a throwaway clone holding this checkout's tracked files as they are
# on disk (staged, not committed, so it carries uncommitted work under test).
clone_to() {
    mkdir -p "$1"
    ( cd "${GUARD_ROOT}" && git ls-files -z | tar --null -T - -cf - ) | tar -xf - -C "$1"
    git -C "$1" init -q
    git -C "$1" add -A
}

agent_entries() {
    python3 - "$1" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
for group in settings.get("hooks", {}).get("PreToolUse", []):
    for hook in group["hooks"]:
        print(hook["command"])
PY
}

@test "install: bootstrap arms git, gh and the agent on a fresh machine, doctor clean" {
    run bash "${GUARD_ROOT}/scripts/bootstrap-machine.sh" --claude-settings "${H}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"doctor: clean"* ]]
    [ -x "${H}/.git-hooks/pre-push" ]
    [ "$(readlink "${H}/.local/bin/gh")" = "${GUARD_ROOT}/gh-shim/gh-guard.sh" ]
    [ -f "${H}/.git-hooks/agent-hooks/claude-code/area-guard.py" ]
    [ "$(readlink "${H}/.git-hooks/doctor.sh")" = "${GUARD_ROOT}/scripts/doctor.sh" ]
    [[ "${output}" == *"agent entry guard registered (${H}/.claude/settings.json)"* ]]
}

@test "install: registering twice leaves one entry, replaces an old copy, keeps other hooks" {
    mkdir -p "${H}/.claude"
    cat > "${H}/.claude/settings.json" <<'JSON'
{"theme": "light", "hooks": {"PreToolUse": [
  {"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": "notify-me"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 /old/place/area-guard.py"}]}
]}}
JSON
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    run agent_entries "${H}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c 'area-guard.py')" -eq 1 ]
    [[ "${output}" == *'f="$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py"'* ]]
    [[ "${output}" == *"notify-me"* ]]
    [[ "${output}" != *"/old/place/"* ]]
    [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["theme"])' "${H}/.claude/settings.json")" = "light" ]
}

@test "install: the guards run from the clone in place, so a pulled change runs at once" {
    clone_to "${H}/src"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${H}/.git-hooks/pre-push")" = "${H}/src/git-hooks/pre-push" ]
    [ "$(readlink "${H}/.git-hooks/scanners/anon-scan.sh")" = "${H}/src/scanners/words/anon-scan.sh" ]
    printf '# edited\n' >> "${H}/src/scanners/words/anon-scan.sh"
    grep -q '# edited' "${H}/.git-hooks/scanners/anon-scan.sh"
}

@test "install: a watcher finds the hooks' links in place through reinstalls from the same clone" {
    clone_to "${H}/src"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    : > "${H}/missed"
    (
        while [ ! -e "${H}/done" ]; do
            for f in agent-hooks/claude-code/area-guard.py scripts/install.sh pre-push scanners/send-scan.py; do
                [ -e "${H}/.git-hooks/${f}" ] || echo "${f}" >> "${H}/missed"
            done
        done
    ) &
    local watcher=$! n
    for n in 1 2 3 4 5 6; do
        bash "${H}/src/scripts/install.sh" > /dev/null 2>&1
    done
    : > "${H}/done"
    wait "${watcher}"
    [ ! -s "${H}/missed" ] || { sort "${H}/missed" | uniq -c; return 1; }
    # nothing is left under a passing name
    [ -z "$(find "${H}/.git-hooks" -maxdepth 2 -name '.*.new-*')" ]
}

# installed_links <folder>: the inode and path of every link the install laid there.
installed_links() {
    find "$1" -type l -exec ls -di {} + | sort
}

@test "install: a reinstall keeps the inode of a link that already points at its place, and moves the others" {
    clone_to "${H}/src"
    bash "${H}/src/scripts/install.sh" > /dev/null
    local before
    before="$(installed_links "${H}/.git-hooks")"
    [ -n "${before}" ]
    bash "${H}/src/scripts/install.sh" > /dev/null
    [ "$(installed_links "${H}/.git-hooks")" = "${before}" ]

    # installing from another clone still points every link at that clone
    clone_to "${H}/moved"
    bash "${H}/moved/scripts/install.sh" > /dev/null
    [ "$(readlink "${H}/.git-hooks/agent-hooks")" = "${H}/moved/agent-hooks" ]
    [ "$(readlink "${H}/.git-hooks/pre-push")" = "${H}/moved/git-hooks/pre-push" ]
    [ "$(readlink "${H}/.git-hooks/scanners/anon-scan.sh")" = "${H}/moved/scanners/words/anon-scan.sh" ]
}

@test "install: a scanner renamed only in case keeps one link, to the file under its new name" {
    clone_to "${H}/src"
    bash "${H}/src/scripts/install.sh" > /dev/null
    mv "${H}/src/scanners/words/anon-fix.sh" "${H}/src/scanners/words/Anon-Fix.sh"
    local folder="${H}/.git-hooks/scanners" turn
    for turn in 1 2; do
        bash "${H}/src/scripts/install.sh" > /dev/null
        [ "$(readlink "${folder}/Anon-Fix.sh")" = "${H}/src/scanners/words/Anon-Fix.sh" ]
        # a file system that tells case apart holds no second link under the old name
        [ "$(ls "${folder}" | grep -ic '^anon-fix[.]sh$')" -eq 1 ]
    done
}

# link_step <case>: the link step alone, met by what another install running beside it leaves.
link_step() {
    python3 - "${GUARD_ROOT}/scripts/_internal" "${H}" "$1" <<'PY_STEP'
import errno
import os
import sys
import types
from pathlib import Path

sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
import swap_links

home, case = Path(sys.argv[2]), sys.argv[3]
source, link = home / "source", home / "link"
source.write_text("x")
link.symlink_to(home / "before")
if case == "moving":
    readlink = os.readlink

    def unreadable(path: Path) -> str:
        raise OSError(errno.EINVAL, "the link is being moved")

    os.readlink = unreadable
    swap_links.swap(source, link, [])
    os.readlink = readlink
    assert os.readlink(link) == str(source)
else:
    class Gone:
        name = "part"

        def is_symlink(self) -> bool:
            return True

        def lstat(self) -> os.stat_result:
            raise FileNotFoundError(errno.ENOENT, "renamed into its place")

    swap_links.prune(types.SimpleNamespace(iterdir=lambda: [Gone()]), {link})
    assert link.is_symlink()
PY_STEP
}

@test "install: a link another install is moving is laid again, not an error" {
    run link_step moving
    [ "${status}" -eq 0 ]
}

@test "install: a passing link another install renamed away is not an error to the pruning" {
    run link_step gone
    [ "${status}" -eq 0 ]
}

@test "install: a file or a link standing where the scanners folder goes gives way to the folder" {
    clone_to "${H}/src"
    local place="${H}/.git-hooks/scanners"
    mkdir -p "${H}/.git-hooks" "${H}/elsewhere"
    printf 'x\n' > "${place}"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ -d "${place}" ]
    [ -f "${place}/send-scan.py" ]

    rm -r "${place}"
    ln -s "${H}/elsewhere" "${place}"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ ! -L "${place}" ]
    [ -f "${place}/send-scan.py" ]
    # what the link pointed at is left as it was
    [ -z "$(ls -A "${H}/elsewhere")" ]
}

@test "install: a scanner called by its name alone finds the parts it uses, and a link to nothing is removed" {
    clone_to "${H}/src"
    mkdir -p "${H}/.git-hooks"
    ln -s "${H}/src/gone" "${H}/.git-hooks/lib"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ ! -L "${H}/.git-hooks/lib" ]
    for name in anon-scan.sh anon-audit-deep.sh anon-fix.sh anon-pattern.sh anon-sync-truth.sh \
                corpus-scan.py send-scan.py dest-known.py guard_places.py; do
        [ -f "${H}/.git-hooks/scanners/${name}" ]
    done
    [ "$(python3 "${H}/.git-hooks/scanners/guard_places.py" master-words)" = "${H}/.config/anon-words/master.txt" ]
    mk_repo synforger
    printf 'clean\n' > clean.txt
    ANON_SCAN_PATHS="$(pwd)/clean.txt" run bash "${H}/.git-hooks/scanners/anon-scan.sh"
    [ "${status}" -eq 0 ]
    run python3 "${H}/.git-hooks/scanners/corpus-scan.py" --summary
    [ "${status}" -eq 0 ]
}

@test "install: a reinstall drops the visible links to nothing and leaves every other entry as it was, doctor clean" {
    clone_to "${H}/src"
    bash "${H}/src/scripts/install.sh" > /dev/null
    local folder="${H}/.git-hooks"
    # what an operator may have put beside the install's own entries, a hidden link to nothing included
    mkdir -p "${folder}/mine"
    printf 'x\n' > "${folder}/notes.txt"
    printf 'x\n' > "${folder}/scanners/notes.txt"
    ln -s "${H}/src" "${folder}/my-link"
    ln -s "${H}/gone" "${folder}/.hidden-link"
    local before
    before="$(find "${folder}" -exec ls -di {} + | sort)"
    ln -s "${H}/gone" "${folder}/gone-link"
    ln -s "${folder}/notes.txt/part" "${folder}/through-a-file"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    diff <(printf '%s\n' "${before}") <(find "${folder}" -exec ls -di {} + | sort)
    run bash "${folder}/doctor.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"doctor: clean"* ]]
}

@test "install: a script run through the installed scripts link finds the clone it belongs to" {
    clone_to "${H}/src"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    run bash "${H}/.git-hooks/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${H}/.git-hooks/scripts")" = "${H}/src/scripts" ]
    [ "$(readlink "${H}/.git-hooks/scanners/anon-scan.sh")" = "${H}/src/scanners/words/anon-scan.sh" ]
    mk_repo synforger
    export GUARD_CONFIG_DIR="${H}/guard-config"
    run bash "${H}/.git-hooks/scripts/weekly-audit.sh" --accept --as-of 2026-10-19T15:00:00Z "$(pwd)"
    [[ "${output}" != *"No such file"* && "${output}" != *"can't open file"* ]]
    [ -f "${GUARD_CONFIG_DIR}/audit/known/$(basename "$(pwd)").known" ] || \
        [ -f "${H}/.config/guard-dispatcher/known/$(basename "$(pwd)").known" ]
}

@test "install: pre-compiles the clone's bytecode so the hook does not recompile on every call" {
    clone_to "${H}/src"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pre-compiled ${H}/src bytecode"* ]]
    [ -d "${H}/src/agent-hooks/claude-code/__pycache__" ]
    [ -d "${H}/src/scanners/corpus/__pycache__" ]
    compgen -G "${H}/src/agent-hooks/claude-code/__pycache__/area-guard.*.pyc" > /dev/null
    compgen -G "${H}/src/scanners/corpus/__pycache__/corpus-scan.*.pyc" > /dev/null
    compgen -G "${H}/src/_common/__pycache__/guard_places.*.pyc" > /dev/null
}

@test "install: an unknown argument is refused before anything is linked" {
    run bash "${GUARD_ROOT}/scripts/install.sh" --settings x
    [ "${status}" -eq 2 ]
    [ ! -e "${H}/.git-hooks" ]
}

@test "doctor: with areas, an agent config dir that lacks the guard is a finding" {
    mkdir -p "${H}/org" "${H}/.config/guard" "${H}/.claude-work"
    printf 'company %s\n' "${H}/org" > "${H}/.config/guard/areas.txt"
    printf '{}\n' > "${H}/.claude-work/settings.json"
    bash "${GUARD_ROOT}/scripts/install.sh" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"agent entry guard not registered (${H}/.claude-work/settings.json)"* ]]

    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude-work/settings.json" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"agent entry guard registered (${H}/.claude-work/settings.json)"* ]]
}

@test "doctor: the operator's off switch is reported and survives a reinstall" {
    mkdir -p "${H}/org" "${H}/.config/guard" "${H}/.claude-work"
    printf 'company %s\n' "${H}/org" > "${H}/.config/guard/areas.txt"
    printf '{}\n' > "${H}/.claude-work/settings.json"
    touch "${H}/.config/guard/agent-off"
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude-work/settings.json" >/dev/null
    [ -e "${H}/.config/guard/agent-off" ]
    run bash "${H}/.git-hooks/doctor.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"switched OFF by the operator"* ]]
}

@test "install: the guard is asked about every tool, not only the file and shell tools" {
    mkdir -p "${H}/.claude"
    printf '{}\n' > "${H}/.claude/settings.json"
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    run python3 -c 'import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
print([g["matcher"] for g in groups if any("area-guard.py" in h["command"] for h in g["hooks"])])' "${H}/.claude/settings.json"
    [ "${output}" = "['*']" ]
}

@test "doctor: a guard registered for some tools only is a finding" {
    mkdir -p "${H}/org" "${H}/.config/guard" "${H}/.claude-work"
    printf 'company %s\n' "${H}/org" > "${H}/.config/guard/areas.txt"
    bash "${GUARD_ROOT}/scripts/install.sh" >/dev/null
    cat > "${H}/.claude-work/settings.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Read|Grep|Glob|Bash|Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [{"type": "command", "command": "f=\"$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py\"; exec python3 \"$f\""}]}]}}
JSON
    run bash "${H}/.git-hooks/doctor.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"agent entry guard registered for some tools only (${H}/.claude-work/settings.json)"* ]]
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude-work/settings.json" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [[ "${output}" == *"agent entry guard registered (${H}/.claude-work/settings.json)"* ]]
}

@test "doctor: without areas, an unregistered agent guard is only noted" {
    mkdir -p "${H}/.claude"
    printf '{}\n' > "${H}/.claude/settings.json"
    bash "${GUARD_ROOT}/scripts/install.sh" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no areas to keep it inside"* ]]
}

@test "install: the registered command refuses through the hook, and passes when the hook is gone" {
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    local command event
    command="$(agent_entries "${H}/.claude/settings.json" | grep area-guard.py)"
    event='{"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "git push --no-verify"}, "cwd": "/", "hook_event_name": "PreToolUse"}'
    run bash -c "${command}" <<< "${event}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"permissionDecision": "deny"'* ]]

    rm "${H}/.git-hooks/agent-hooks"
    run bash -c "${command}" <<< "${event}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# after_entries <settings> — "<event> <matcher> <command>" of each after-call hook.
after_entries() {
    python3 - "$1" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
for event in ("PostToolUse", "PostToolUseFailure"):
    for group in settings.get("hooks", {}).get(event, []):
        for hook in group["hooks"]:
            print(event, group.get("matcher"), hook["command"])
PY
}

@test "install: the after-call check is registered once for every tool, after success and failure" {
    mkdir -p "${H}/.claude"
    cat > "${H}/.claude/settings.json" <<'JSON'
{"hooks": {"PostToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "format-me"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 /old/place/handed.py"}]}]}}
JSON
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    run after_entries "${H}/.claude/settings.json"
    [ "$(printf '%s\n' "${output}" | grep -c '^PostToolUse \* .*handed.py')" -eq 1 ]
    [ "$(printf '%s\n' "${output}" | grep -c '^PostToolUseFailure \* .*handed.py')" -eq 1 ]
    [[ "${output}" == *"format-me"* ]]
    [[ "${output}" != *"/old/place/"* ]]
}

@test "doctor: with a file left for the operator, an unregistered after-call check is a finding" {
    mkdir -p "${H}/org" "${H}/.config/guard" "${H}/.claude"
    printf 'company %s\n' "${H}/org" > "${H}/.config/guard/areas.txt"
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [[ "${output}" == *"no file left for the operator is a destination"* ]]
    printf '%s\n' 'file:~/out/* company' > "${H}/.config/guard/destinations.txt"
    python3 -c '
import json, sys
path = sys.argv[1]
settings = json.load(open(path))
settings["hooks"].pop("PostToolUseFailure")
json.dump(settings, open(path, "w"))' "${H}/.claude/settings.json"
    run bash "${H}/.git-hooks/doctor.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"after-call check not registered for every tool after success and failure (${H}/.claude/settings.json)"* ]]
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [[ "${output}" == *"after-call check registered (${H}/.claude/settings.json)"* ]]
}

# entry_gaps <kind> — the link step laid over an entry that is a file, a folder or a link to somewhere
# else, listing the file-system calls after which the entry no longer resolved.
entry_gaps() {
    python3 - "${GUARD_ROOT}/scripts/_internal" "${H}" "$1" <<'PY_GAPS'
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
import swap_links

home, kind = Path(sys.argv[2]), sys.argv[3]
source, entry, elsewhere = home / "source", home / "entry", home / "elsewhere"
source.write_text("x")
elsewhere.write_text("y")
if kind == "file":
    entry.write_text("old")
elif kind == "folder":
    entry.mkdir()
    (entry / "part").write_text("old")
else:
    entry.symlink_to(elsewhere)

gaps = []


def watch(module, name):
    original = getattr(module, name)

    def watched(*arguments, **keywords):
        result = original(*arguments, **keywords)
        try:
            os.stat(entry)
        except OSError:
            gaps.append(name)
        return result

    setattr(module, name, watched)


for name in ("unlink", "remove", "rmdir", "rename", "replace", "symlink", "link"):
    watch(os, name)
watch(shutil, "rmtree")
assert swap_links.main([str(source), str(entry)]) == 0
assert os.readlink(entry) == str(source)
print(" ".join(gaps) or "none")
PY_GAPS
}

@test "install: an entry that is a file, a folder or a link elsewhere resolves after every step of being replaced" {
    local kind
    for kind in file folder link; do
        run entry_gaps "${kind}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "none" ] || { echo "${kind}: ${output}"; return 1; }
        rm -rf "${H}/entry" "${H}/source" "${H}/elsewhere"
    done
}

# moving_links <rounds> — 16 links moved between two sets of sources again and again, then laid
# again at the place they already are, while two readers open every one of them without pause.
# Prints "<opens that failed> <inodes that changed when the place was the same>".
moving_links() {
    python3 - "${GUARD_ROOT}/scripts/_internal" "${H}" "$1" <<'PY_MOVING'
import multiprocessing
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
import swap_links

home, rounds = Path(sys.argv[2]), int(sys.argv[3])
names = [f"part{n}" for n in range(16)]
sides = [home / "side-a", home / "side-b"]
place = home / "place"
for side in sides:
    side.mkdir()
    for name in names:
        (side / name).write_text("x")
place.mkdir()


def pairs(side):
    return [str(path) for name in names for path in (side / name, place / name)]


def read(stop, failed):
    count = 0
    while not stop.is_set():
        for name in names:
            try:
                with open(place / name, "rb"):
                    pass
            except OSError:
                count += 1
    failed.put(count)


assert swap_links.main(["--only", str(place), *pairs(sides[0])]) == 0
context = multiprocessing.get_context("fork")
stop, failed = context.Event(), context.Queue()
readers = [context.Process(target=read, args=(stop, failed)) for _ in range(2)]
for reader in readers:
    reader.start()
for turn in range(rounds):
    assert swap_links.main(["--only", str(place), *pairs(sides[turn % 2 ^ 1])]) == 0
before = [(place / name).lstat().st_ino for name in names]
for _ in range(rounds):
    assert swap_links.main(["--only", str(place), *pairs(sides[(rounds - 1) % 2 ^ 1])]) == 0
moved = sum(then != (place / name).lstat().st_ino for then, name in zip(before, names))
stop.set()
total = sum(failed.get(timeout=20) for _ in readers)
for reader in readers:
    reader.join()
print(total, moved)
PY_MOVING
}

@test "install: a link that moves to another source is never unreadable meanwhile, and one that stays keeps its inode" {
    run moving_links 100
    [ "${status}" -eq 0 ]
    [ "${output}" = "0 0" ] || { echo "opens that failed, inodes that changed: ${output}"; return 1; }
}

# the pid of a process that has ended
dead_pid() {
    sleep 0 &
    local pid=$!
    wait "${pid}"
    printf '%s\n' "${pid}"
}

@test "install: a passing link of an install still running is left, and what an install that died left is removed" {
    clone_to "${H}/src"
    bash "${H}/src/scripts/install.sh" > /dev/null
    local dead folder="${H}/.git-hooks/scanners"
    dead="$(dead_pid)"
    ln -s "${H}/src/scripts" "${H}/.git-hooks/.agent-hooks.new-${dead}"
    ln -s "${H}/src/scripts" "${H}/.git-hooks/.pre-push.old-${dead}"
    ln -s "${H}/src/scripts" "${folder}/.send-scan.py.new-${dead}"
    mkdir "${H}/.git-hooks/.scanners.new-${dead}"
    ln -s "${H}/src/scripts" "${H}/.git-hooks/.scanners.new-${dead}/send-scan.py"
    ln -s "${H}/src/scripts" "${H}/.git-hooks/.pre-commit.new-$$"
    ln -s "${H}/src/scripts" "${folder}/.send-scan.py.new-$$"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ -z "$(find "${H}/.git-hooks" -maxdepth 2 -name "*-${dead}")" ]
    [ -L "${H}/.git-hooks/.pre-commit.new-$$" ]
    [ -L "${folder}/.send-scan.py.new-$$" ]
    [ -f "${folder}/send-scan.py" ]
}

@test "install: a git config that already names the hooks folder is not written again" {
    clone_to "${H}/src"
    bash "${H}/src/scripts/install.sh" > /dev/null
    : > "${H}/.gitconfig.lock"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ "$(git config --global --get core.hooksPath)" = "${H}/.git-hooks" ]
}

@test "install: a git config that another process holds for a moment is waited for" {
    clone_to "${H}/src"
    : > "${H}/.gitconfig.lock"
    ( sleep 0.5; rm -f "${H}/.gitconfig.lock" ) 3>&- &
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ "$(git config --global --get core.hooksPath)" = "${H}/.git-hooks" ]
}

@test "install: two installs at once both finish, and leave the links in place and nothing under a passing name" {
    clone_to "${H}/src"
    clone_to "${H}/other"
    bash "${H}/src/scripts/install.sh" > /dev/null
    local turn first second
    for turn in 1 2; do
        bash "${H}/$([ $((turn % 2)) -eq 0 ] && echo src || echo other)/scripts/install.sh" > /dev/null 2> "${H}/first.err" &
        first=$!
        bash "${H}/$([ $((turn % 2)) -eq 0 ] && echo other || echo src)/scripts/install.sh" > /dev/null 2> "${H}/second.err" &
        second=$!
        wait "${first}" || { cat "${H}/first.err"; return 1; }
        wait "${second}" || { cat "${H}/second.err"; return 1; }
    done
    [ -f "${H}/.git-hooks/agent-hooks/claude-code/area-guard.py" ]
    [ -f "${H}/.git-hooks/scanners/send-scan.py" ]
    [ -z "$(find "${H}/.git-hooks" -maxdepth 2 \( -name '.*.new-*' -o -name '.*.old-*' \))" ]
}

@test "install: a settings file that already holds the entries is not written again, and a link to it stays a link" {
    mkdir -p "${H}/.claude" "${H}/shared"
    printf '{}\n' > "${H}/shared/settings.json"
    ln -s "${H}/shared/settings.json" "${H}/.claude/settings.json"
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" > /dev/null
    [ -L "${H}/.claude/settings.json" ]
    grep -q 'area-guard.py' "${H}/shared/settings.json"
    touch -t 200001010000 "${H}/shared/settings.json"
    local before
    before="$(ls -l "${H}/shared/settings.json")"
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" > /dev/null
    [ "$(ls -l "${H}/shared/settings.json")" = "${before}" ]
}

@test "install: a settings file closed to others stays closed while it is replaced, and after" {
    mkdir -p "${H}/.claude" "${H}/watch"
    printf '{}\n' > "${H}/.claude/settings.json"
    chmod 600 "${H}/.claude/settings.json"
    # python imports this at start: it records the mode of the passing file once the settings are in it
    cat > "${H}/watch/sitecustomize.py" <<'PY'
import os
import pathlib
import stat

original = pathlib.Path.write_text


def write_text(self, *arguments, **keywords):
    result = original(self, *arguments, **keywords)
    if self.name.startswith(".settings.json.new-"):
        with open(os.environ["MODES"], "a") as modes:
            modes.write("%o\n" % stat.S_IMODE(self.stat().st_mode))
    return result


pathlib.Path.write_text = write_text
PY
    umask 022
    MODES="${H}/modes" PYTHONPATH="${H}/watch" \
        bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude/settings.json" > /dev/null
    [ "$(cat "${H}/modes")" = "600" ]
    [ "$(ls -l "${H}/.claude/settings.json" | cut -c1-10)" = "-rw-------" ]
}

@test "bootstrap: the gh link is laid by the step of the hooks' links, kept when it already points at its place" {
    mkdir -p "${H}/bin"
    printf '#!/bin/sh\ntouch "%s/ln-called"\nexec /bin/ln "$@"\n' "${H}" > "${H}/bin/ln"
    chmod +x "${H}/bin/ln"
    PATH="${H}/bin:${PATH}" run bash "${GUARD_ROOT}/scripts/bootstrap-machine.sh"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${H}/.local/bin/gh")" = "${GUARD_ROOT}/gh-shim/gh-guard.sh" ]
    [ ! -e "${H}/ln-called" ]
    ln -sfn "${H}/elsewhere" "${H}/.local/bin/gh"
    PATH="${H}/bin:${PATH}" run bash "${GUARD_ROOT}/scripts/bootstrap-machine.sh"
    [ "$(readlink "${H}/.local/bin/gh")" = "${GUARD_ROOT}/gh-shim/gh-guard.sh" ]
    local before
    before="$(ls -di "${H}/.local/bin/gh")"
    PATH="${H}/bin:${PATH}" run bash "${GUARD_ROOT}/scripts/bootstrap-machine.sh"
    [ "$(ls -di "${H}/.local/bin/gh")" = "${before}" ]
    [ ! -e "${H}/ln-called" ]
}
