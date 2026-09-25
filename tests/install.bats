#!/usr/bin/env bats
# scripts/install.sh, bootstrap-machine.sh and doctor.sh on a throwaway HOME.

load helpers

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/.config/anon-words"
    printf '%s\n' "${SENTINEL}" > "${H}/.config/anon-words/master.txt"
    export HOME="${H}"
    unset GIT_CONFIG_GLOBAL CLAUDE_CONFIG_DIR GUARD_CONFIG_DIR ANON_TRUTH_PATH
    cd "${H}" || return 1
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
