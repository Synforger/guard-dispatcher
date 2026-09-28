#!/usr/bin/env bats
# scripts/install.sh, bootstrap-machine.sh and doctor.sh on a throwaway HOME.

load helpers

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/.config/anon-words"
    printf '%s\n' "${SENTINEL}" > "${H}/.config/anon-words/master.txt"
    export HOME="${H}"
    unset GIT_CONFIG_GLOBAL CLAUDE_CONFIG_DIR GUARD_CONFIG_DIR ANON_TRUTH_PATH GUARD_HOME
    INSTALLED="${H}/.local/share/guard-dispatcher"
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
    [ "$(readlink "${H}/.local/bin/gh")" = "${INSTALLED}/gh-shim/gh-guard.sh" ]
    [ -f "${H}/.git-hooks/agent-hooks/claude-code/area-guard.py" ]
    [ "$(readlink "${H}/.git-hooks/doctor.sh")" = "${INSTALLED}/scripts/doctor.sh" ]
    [ ! -e "${H}/.git-hooks/sandbox" ]
    [[ "${output}" == *"agent entry guard registered (${H}/.claude/settings.json)"* ]]
}

@test "install: the session cage an older install linked is removed" {
    mkdir -p "${H}/.git-hooks" "${H}/old-install/sandbox"
    ln -s "${H}/old-install/sandbox" "${H}/.git-hooks/sandbox"
    run bash "${GUARD_ROOT}/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ ! -e "${H}/.git-hooks/sandbox" ] && [ ! -L "${H}/.git-hooks/sandbox" ]
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

@test "install: the guards run from the install, which a later edit to the clone does not touch" {
    clone_to "${H}/src"
    printf 'untracked\n' > "${H}/src/scratch.txt"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ "$(cd -P "${H}/.git-hooks/scripts/.." && pwd)" = "${INSTALLED}" ]
    [ "$(readlink "${H}/.git-hooks/pre-push")" = "${INSTALLED}/git-hooks/pre-push" ]
    [ -x "${INSTALLED}/git-hooks/pre-push" ]
    [ ! -e "${INSTALLED}/.git" ]
    [ ! -e "${INSTALLED}/scratch.txt" ]
    printf '# edited\n' >> "${H}/src/scanners/anon-scan.sh"
    ! grep -q '# edited' "${INSTALLED}/scanners/anon-scan.sh" || return 1
    bash "${H}/src/scripts/install.sh" >/dev/null
    grep -q '# edited' "${INSTALLED}/scanners/anon-scan.sh"
}

@test "install: a reinstall keeps the operator word list the install holds" {
    clone_to "${H}/src"
    bash "${H}/src/scripts/install.sh" >/dev/null
    printf 'operator-word\n' > "${INSTALLED}/scanners/anon-words.txt"
    bash "${H}/src/scripts/install.sh" >/dev/null
    [ "$(cat "${INSTALLED}/scanners/anon-words.txt")" = "operator-word" ]
}

@test "install: GUARD_HOME set to the clone runs the guards from it in place" {
    clone_to "${H}/src"
    GUARD_HOME="${H}/src" run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${H}/.git-hooks/pre-push")" = "${H}/src/git-hooks/pre-push" ]
    [ ! -e "${INSTALLED}" ]
}

@test "install: a folder that is not a git clone is refused" {
    clone_to "${H}/src"
    rm -rf "${H}/src/.git"
    run bash "${H}/src/scripts/install.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is not a git clone"* ]]
    [ ! -e "${H}/.git-hooks" ]
}

@test "install: pre-compiles the installed tree's bytecode so the hook does not recompile on every call" {
    run bash "${GUARD_ROOT}/scripts/install.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pre-compiled ${INSTALLED} bytecode"* ]]
    [ -d "${INSTALLED}/agent-hooks/claude-code/__pycache__" ]
    [ -d "${INSTALLED}/scanners/__pycache__" ]
    compgen -G "${INSTALLED}/agent-hooks/claude-code/__pycache__/area-guard.*.pyc" > /dev/null
    compgen -G "${INSTALLED}/scanners/__pycache__/corpus-scan.*.pyc" > /dev/null
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

@test "doctor: a config dir left by a cage is shown without its area's name" {
    mkdir -p "${H}/org" "${H}/.config/guard" "${H}/.claude@acme"
    printf 'company %s\n' "${H}/org" > "${H}/.config/guard/areas.txt"
    printf '{}\n' > "${H}/.claude@acme/settings.json"
    bash "${GUARD_ROOT}/scripts/install.sh" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [[ "${output}" == *"agent entry guard not registered (${H}/.claude@<cage>/settings.json)"* ]]
    [[ "${output}" != *acme* ]]
    bash "${GUARD_ROOT}/scripts/install.sh" --claude-settings "${H}/.claude@acme/settings.json" >/dev/null
    run bash "${H}/.git-hooks/doctor.sh"
    [[ "${output}" == *"agent entry guard registered (${H}/.claude@<cage>/settings.json)"* ]]
    [[ "${output}" != *acme* ]]
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
