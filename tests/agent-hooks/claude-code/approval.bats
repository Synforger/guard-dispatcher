#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + order.py — a change the guard keeps for the operator
# (switching the hooks around, the guard's settings) passes on the operator's yes to that very
# call, shown in a ```guard block, from a session that may read where the call acts.
#
# A throwaway HOME holds a company folder with a client inside it and a repository in each; a
# made-up transcript holds what the agent showed and what the operator answered.

load ../../_internal/helpers
load ../../_internal/transcript

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
RELAYED="Message from another session, relayed by the client"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    CASE="${H}/org/clients/acme"
    CASE_REPO="${CASE}/repos/pipeline"
    COMPANY_REPO="${H}/org/repos/internal"
    for r in "${CASE_REPO}" "${COMPANY_REPO}"; do
        mkdir -p "${r}"
        git init -q "${r}"
    done
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}/areas/company"
    printf 'company ~/org\nclient  ~/org/clients/acme\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' '送信して' '!も' '!いい' '!ない' '!る' '!た' ">${RELAYED}" > "${GUARD_CONFIG_DIR}/orders.txt"
    mkdir -p "${H}/hooks"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    T="${H}/.claude/projects/org/s1.jsonl"
    mkdir -p "$(dirname "${T}")"
    : > "${T}"
    PROMPT=0
}

# shown <command> — the agent shows a Bash call in a guard block and asks.
shown() { replied "$(printf 'May I run this?\n\n```guard\ntool: Bash\ncommand:\n%s\n```\n' "$1")"; }
# call <tool> <input json> <cwd> [tool use id] — run the hook on a call of the current prompt.
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "$3" --arg p "${T}" --arg q "p${PROMPT}" --arg u "${4:-toolu_1}" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse",
          transcript_path: $p, prompt_id: $q, tool_use_id: $u}')"
    run python3 "${HOOK}" <<< "${event}"
}
bash_in() { call Bash "$(jq -n --arg c "$2" '{command: $c}')" "$1" "${3:-toolu_1}"; }
write_to() { call Write "$(jq -n --arg f "$1" --arg c "$2" '{file_path: $f, content: $c}')" "${H}" "${3:-toolu_1}"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

HOOKS_OFF="git config core.hooksPath .husky"

@test "approval: a hooks change the agent showed passes on the operator's yes, once" {
    said "the template's hooks should run"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *'```guard'* ]]
    shown "${HOOKS_OFF}"
    said "はい、お願いします"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    passed
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}" toolu_2
    denied
    [[ "${output}" == *"already been spent"* ]]
}

@test "approval: a call that differs from the shown one, or a block shown for a send, does not pass" {
    said "fix it"
    shown "${HOOKS_OFF}"
    said "はい"
    bash_in "${COMPANY_REPO}" "git config core.hooksPath .githooks"
    denied
    [[ "${output}" == *"not one the agent showed"* ]]
    replied "$(printf '```send\ntool: Bash\ncommand:\n%s\n```\n' "${HOOKS_OFF}")"
    said "はい"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
}

@test "approval: a question, a no, an order for a send or a relayed message is no yes" {
    for answer in "はい?" "やってない" "送信して" "どうしよう"; do
        said "fix it"
        shown "${HOOKS_OFF}"
        said "${answer}"
        bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
        denied || { echo "passed on: ${answer}"; return 1; }
    done
    shown "${HOOKS_OFF}"
    said "${RELAYED}: はい"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
}

@test "approval: a session that does not read where the call acts gets no yes" {
    export GUARD_WORK_FOLDER="${H}/org"
    said "fix it"
    shown "${HOOKS_OFF}"
    said "はい"
    bash_in "${CASE_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *"acts inside client, which this session does not read"* ]]
    export GUARD_WORK_FOLDER="${CASE}"
    bash_in "${CASE_REPO}" "${HOOKS_OFF}"
    passed
}

@test "approval: the guard's settings, the operator's own files too, change on a yes; an area's settings from a session of that area" {
    said "add the line"
    write_to "${GUARD_CONFIG_DIR}/orders.txt" "+はい"
    denied
    replied "$(printf '```guard\ntool: Write\nfile_path: %s\ncontent: +はい\n```\n' "${GUARD_CONFIG_DIR}/orders.txt")"
    said "どうぞ"
    write_to "${GUARD_CONFIG_DIR}/orders.txt" "+はい"
    passed
    export GUARD_WORK_FOLDER="${H}/org"
    mkdir -p "${GUARD_CONFIG_DIR}/areas/client"
    replied "$(printf '```guard\ntool: Write\nfile_path: %s\ncontent: x\n```\n' "${GUARD_CONFIG_DIR}/areas/client/allow.txt")"
    said "はい"
    write_to "${GUARD_CONFIG_DIR}/areas/client/allow.txt" "x" toolu_2
    denied
    [[ "${output}" == *"acts inside client"* ]]
    export GUARD_WORK_FOLDER="${CASE}"
    write_to "${GUARD_CONFIG_DIR}/areas/client/allow.txt" "x" toolu_3
    passed
}

@test "approval: the marks and a transcript are never rewritten, whatever the operator says" {
    said "clear it"
    shown "rm -f ~/state/s1.json"
    said "はい"
    bash_in "${H}" "rm -f ~/state/s1.json"
    denied
    replied "$(printf '```guard\ntool: Write\nfile_path: %s\ncontent: x\n```\n' "${T}")"
    said "はい"
    write_to "${T}" "x"
    denied
}

@test "approval: taking a repository's own hooksPath away needs no yes" {
    git -C "${COMPANY_REPO}" config core.hooksPath .husky
    said "put it back"
    bash_in "${COMPANY_REPO}" "git config --unset core.hooksPath"
    passed
}
