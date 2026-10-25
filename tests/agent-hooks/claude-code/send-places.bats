#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py — where a git or gh send runs from when the command spells
# the folder with a variable: one set to a literal earlier in the command (or in the session's
# environment) is written out, and one only known as the command runs is refused with a reason.
#
# A throwaway HOME holds an agent's own repository (exempt, with a remote: a send from it is
# judged as going around the hooks), a tool's repository the hooks reach, and one whose own
# core.hooksPath switches them off.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    AGENT="${H}/agents/me"
    TOOL="${H}/repos/tool"
    HUSKY="${H}/repos/husky"
    for r in "${AGENT}" "${TOOL}" "${HUSKY}"; do
        mkdir -p "${r}"
        git init -q "${r}"
        git -C "${r}" remote add origin "git@github.com:o/$(basename "${r}").git"
    done
    git -C "${AGENT}" config guard.scope exempt
    git -C "${HUSKY}" config core.hooksPath .husky
    mkdir -p "${H}/org"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}" "${H}/hooks"
    printf 'company ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    for r in me tool husky; do seed_visibility "o/${r}" private; done
}

# bash_in <cwd> <command> — run the hook on one Bash call made from <cwd>.
bash_in() {
    local event
    event="$(jq -n --arg c "$2" --arg d "$1" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }
unread() { denied && [[ "${output}" == *"sends from a folder only known as it runs"* ]]; }

@test "send places: a send from the agent's own repository is still judged as going around the hooks" {
    bash_in "${AGENT}" "git commit -m x"
    denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
}

@test "send places: a folder set to a literal earlier in the command is where the send runs" {
    bash_in "${AGENT}" "W=${TOOL}; cd \$W && git commit -m x"; passed
    bash_in "${AGENT}" "W=${TOOL}; git -C \"\$W\" commit -m x"; passed
    bash_in "${AGENT}" "export W=${TOOL} && git -C \${W} push origin HEAD"; passed
    bash_in "${AGENT}" "R=${H}/repos; cd \$R/tool && git commit -m x"; passed
}

@test "send places: a folder of the session's environment is written out" {
    bash_in "${AGENT}" "cd \$HOME/repos/tool && git commit -m x"; passed
}

@test "send places: a variable set to a folder whose hooks are off still lands there, and is refused" {
    bash_in "${TOOL}" "W=${HUSKY}; cd \$W && git commit -m x"
    denied
    [[ "${output}" == *"overrides core.hooksPath"* ]]
}

@test "send places: a folder only known as the command runs is refused with how to write it" {
    bash_in "${TOOL}" "cd \$ELSEWHERE && git commit -m x"; unread
    [[ "${output}" == *"(\$ELSEWHERE)"* ]]
    bash_in "${TOOL}" "git -C \"\$(git rev-parse --show-toplevel)\" commit -m x"; unread
    bash_in "${TOOL}" "W=\$(pwd); cd \$W && git push"; unread
    bash_in "${TOOL}" "cd \$ELSEWHERE && cd sub && gh pr create --title t --body b"; unread
    bash_in "${TOOL}" "bash -c 'cd \$ELSEWHERE && git commit -m x'"; unread
}

@test "send places: the place comes back once the command goes to a folder written out" {
    bash_in "${TOOL}" "cd \$ELSEWHERE && cd ${TOOL} && git commit -m x"; passed
    bash_in "${TOOL}" "(cd \$ELSEWHERE && make); git commit -m x"; passed
    bash_in "${TOOL}" "pushd \$ELSEWHERE && popd && git commit -m x"; passed
    bash_in "${TOOL}" "cd \$ELSEWHERE && ls && cat notes.md"; passed
}
