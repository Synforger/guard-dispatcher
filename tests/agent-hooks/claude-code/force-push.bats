#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + push_options.py — a push that forces its refs, to a
# repository whose `repo:` line in destinations.txt ends with `order`, passes on the operator's yes
# to that very call (shown in a ```guard block). Every other push goes as before.
#
# A throwaway HOME holds two repositories with a GitHub remote: one declared `order`, one declared
# without it; a made-up transcript holds what the agent showed and what the operator answered.

load ../../_internal/helpers
load ../../_internal/transcript

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
HELD_URL="git@github.com:acme/held.git"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    HELD="${H}/org/repos/held"
    FREE="${H}/org/repos/free"
    for r in "${HELD}" "${FREE}"; do
        mkdir -p "${r}"
        git init -q "${r}"
    done
    git -C "${HELD}" remote add origin "${HELD_URL}"
    git -C "${FREE}" remote add origin "git@github.com:acme/free.git"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER GUARD_TAB_BINDINGS AGENT_PLATFORM_ROOT
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'company ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf 'repo:acme/held company order\nrepo:acme/free company\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
    printf '%s\n' '送信して' '!も' '!いい' '!ない' '!る' '!た' > "${GUARD_CONFIG_DIR}/orders.txt"
    mkdir -p "${H}/hooks"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
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
# held <command> — the command is stopped for the operator's approval, naming the form that forces it.
held() {
    bash_in "${HELD}" "$1"
    denied && [[ "${output}" == *"held to the operator's approval"* ]] || { echo "not held: $1 -> ${output}"; return 1; }
}
unheld() {
    bash_in "${HELD}" "$1"
    passed || { echo "held: $1 -> ${output}"; return 1; }
}

@test "force push: every form that forces a ref is held for the operator" {
    local command
    for command in "git push -f" "git push --force origin main" "git push --force-with-lease" \
        "git push --force-with-lease=main:abc123 origin main" "git push --force-if-includes origin main" \
        "git push --mirror" "git push -uf origin main" "git push -fu origin main" "git push origin +main" \
        "git push origin +HEAD:refs/heads/x" "git push --force-w origin main" "git push -o ci -f origin" \
        "git push -o ci origin +main" "git push -- origin +main"; do
        held "${command}"
    done
}

@test "force push: a refusal names the form, the destination and the block that shows the call" {
    said "push the rebased branch"
    bash_in "${HELD}" "git push --force-with-lease origin main"
    denied
    local reason
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${output}")"
    [[ "${reason}" == *"--force-with-lease to ${HELD_URL}"* ]]
    [[ "${reason}" == *'```guard'* ]]
}

@test "force push: a push that forces nothing goes as before, and a value is not read as an option" {
    local command
    for command in "git push" "git push origin main" "git push -u origin main" "git push --tags" \
        "git push origin :old-branch" "git push --delete origin old" "git push -o -f origin main" \
        "git push --push-option=-f origin main" "git push --no-force-with-lease origin main" \
        "git push -- origin main" "git push origin refs/heads/a:refs/heads/b" "git push --repo origin main"; do
        unheld "${command}"
    done
}

@test "force push: a repository whose line has no order is not held" {
    bash_in "${FREE}" "git push --force origin main"; passed
    bash_in "${FREE}" "git push origin +main"; passed
}

@test "force push: it is the destination that is held, wherever the command stands" {
    bash_in "${FREE}" "git -C ${HELD} push --force"
    denied
    bash_in "${FREE}" "cd ${HELD} && git push -f"
    denied
    bash_in "${HELD}" "git push --force git@github.com:acme/free.git main"
    passed
    bash_in "${FREE}" "git push --force ${HELD_URL} main"
    denied
}

@test "force push: a force in a shell's -c string or a script the command runs is held too" {
    held "bash -c 'git push --force origin main'"
    printf '#!/bin/sh\ngit push origin +main\n' > "${HELD}/ship.sh"
    held "bash ship.sh"
    held "bash < ship.sh"
    held "cat ship.sh | sh"
    printf 'echo hello\n' > "${HELD}/hello.sh"
    unheld "bash hello.sh"
}

@test "force push: it passes on the operator's yes to that call, once, and leaves a grant for the pre-push hook" {
    said "push the rebased branch"
    held "git push --force-with-lease origin main"
    shown "git push --force-with-lease origin main"
    said "はい"
    bash_in "${HELD}" "git push --force-with-lease origin main"
    passed
    bash_in "${HELD}" "git push --force-with-lease origin main" toolu_2
    denied
    [[ "${output}" == *"already been spent"* ]]
    local grants=("${H}/force-grants"/*.json)
    [ "${#grants[@]}" -eq 1 ]
    [ "$(jq -r '.urls[0]' "${grants[0]}")" = "${HELD_URL}" ]
    [ "$(jq -r '.expires > now' "${grants[0]}")" = "true" ]
}

@test "force push: the grant is the repository's own, named by the top folder" {
    said "push it"
    shown "git push -f"
    said "はい"
    bash_in "${HELD}" "git push -f"
    passed
    local key
    key="$(printf '%s' "$(cd -P "${HELD}" && pwd)" | shasum -a 256 | cut -c1-16)"
    [ -f "${H}/force-grants/${key}.json" ]
}

@test "force push: a call that differs from the shown one, or a no, does not pass and leaves no grant" {
    said "push it"
    shown "git push --force origin main"
    said "はい"
    bash_in "${HELD}" "git push --force origin develop"
    denied
    [[ "${output}" == *"not one the agent showed"* ]]
    said "push it"
    shown "git push --force origin main"
    said "やってない"
    bash_in "${HELD}" "git push --force origin main"
    denied
    [ ! -d "${H}/force-grants" ]
}

@test "force push: a yes to a call that a later judgement refuses leaves no grant" {
    local command="git push --force origin main; python3 peers.py --places"
    said "push it"
    shown "${command}"
    said "はい"
    bash_in "${HELD}" "${command}"
    denied
    [[ "${output}" == *"--places"* ]]
    [ ! -d "${H}/force-grants" ]
}

@test "force push: the call that also goes around the hooks is covered by the same yes" {
    local command="GUARD_CORPUS_SKIP=1 git push --force origin main"
    said "push it"
    shown "${command}"
    said "はい"
    bash_in "${HELD}" "${command}"
    passed
    [ "$(ls "${H}/force-grants" | wc -l)" -eq 1 ]
}

@test "force push: several forced pushes in one call take the one yes, and each repository its grant" {
    local command="git push --force origin main && git -C ${FREE} push -f && git push origin +other"
    said "push them"
    shown "${command}"
    said "はい"
    bash_in "${HELD}" "${command}"
    passed
    [ "$(ls "${H}/force-grants" | wc -l)" -eq 1 ]
}

@test "force push: an agent cannot write the grants, however it spells the folder" {
    write_to "${H}/force-grants/0123456789abcdef.json" '{"urls": [], "expires": 9999999999}'
    denied
    [[ "${output}" == *"does not rewrite the entry guard's marks"* ]]
    bash_in "${HELD}" "rm -r ${H}/force-grants"; denied
    bash_in "${HELD}" "echo '{}' > ${H}/force-grants/0123456789abcdef.json"; denied
    bash_in "${HELD}" "cp grant.json ${H}/force-grants/"; denied
    bash_in "${HELD}" "touch \$HOME/force-grants/x.json"; denied
    [[ "${output}" == *"removes or rewrites the entry guard's marks"* ]]
    write_to "${H}/.cache/force-grants/x.json" '{}'; denied
    write_to "${H}/state/guard/force-grants/x.json" '{}'; denied
}
