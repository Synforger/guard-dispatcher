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
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER GUARD_TAB_BINDINGS AGENT_PLATFORM_ROOT
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

@test "approval: a refusal names the words that count as a yes and the block that shows the call" {
    said "the template's hooks should run"
    call Bash "$(jq -n --arg c "${HOOKS_OFF}" '{command: $c, description: "Point the hooks at husky"}')" "${COMPANY_REPO}"
    denied
    local reason
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${output}")"
    [[ "${reason}" == *"Only these words of the operator count as the yes: はい, お願い,"* ]]
    local block
    block="$(sed -n '/^```guard$/,$p' <<< "${reason}")"
    [ "${block}" = "$(printf '```guard\ntool: Bash\ncommand:\n%s\n```' "${HOOKS_OFF}")" ]
    replied "$(printf 'May I run this?\n\n%s\n' "${block}")"
    said "はい"
    call Bash "$(jq -n --arg c "${HOOKS_OFF}" '{command: $c, description: "Point the hooks at husky"}')" "${COMPANY_REPO}"
    passed
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

@test "approval: guard.scope corpus in a repository inside an agent's own folder needs no yes; another scope or place does" {
    export AGENT_PLATFORM_ROOT="${H}/platform"
    local tier="${AGENT_PLATFORM_ROOT}/agents/agent-a/projects/tier-a"
    mkdir -p "${tier}"
    git init -q "${tier}"
    said "set the tier up"
    bash_in "${tier}" "git config guard.scope corpus"
    passed
    bash_in "${H}" "git -C ${tier} config --local guard.scope corpus"
    passed
    for command in "git config guard.scope exempt" "git config --global guard.scope corpus" \
                   "git config guard.scope corpus && ${HOOKS_OFF}"; do
        bash_in "${tier}" "${command}"
        denied || { echo "passed: ${command}"; return 1; }
    done
    bash_in "${H}" "cd ${tier} && git config guard.scope corpus"
    denied
    bash_in "${COMPANY_REPO}" "git config guard.scope corpus"
    denied
    # the repository written is the one judged: another repository's config named another way is not
    for command in "git --git-dir=${COMPANY_REPO}/.git config guard.scope corpus" \
                   "git --work-tree=${COMPANY_REPO} config guard.scope corpus" \
                   "GIT_DIR=${COMPANY_REPO}/.git git config guard.scope corpus" \
                   "env GIT_DIR=${COMPANY_REPO}/.git git config guard.scope corpus"; do
        bash_in "${tier}" "${command}"
        denied || { echo "passed: ${command}"; return 1; }
    done
}

@test "approval: guard.scope corpus without a yes only lowers no stricter scope a repository in an agent's folder holds" {
    export AGENT_PLATFORM_ROOT="${H}/platform"
    local tier="${AGENT_PLATFORM_ROOT}/agents/agent-a/projects/tier-a"
    mkdir -p "${tier}"
    git init -q "${tier}"
    said "set the tier up"
    git -C "${tier}" config guard.scope exempt
    bash_in "${tier}" "git config guard.scope corpus"
    passed
    git -C "${tier}" config guard.scope enforced
    bash_in "${tier}" "git config guard.scope corpus"
    denied
}

@test "approval: a Bash call's description, timeout and running in the background are not compared, and pass once" {
    said "fix it"
    shown "${HOOKS_OFF}"
    said "はい"
    call Bash "$(jq -n --arg c "${HOOKS_OFF}" '{command: $c, description: "Run the template hooks", timeout: 120000, run_in_background: false}')" "${COMPANY_REPO}"
    passed
    # another label on the same command is the same call: the block is spent
    call Bash "$(jq -n --arg c "${HOOKS_OFF}" '{command: $c, description: "Once more", timeout: 60000}')" "${COMPANY_REPO}" toolu_2
    denied
    [[ "${output}" == *"already been spent"* ]]
    # a label does not make another command the shown one
    call Bash "$(jq -n '{command: "git config core.hooksPath .githooks", description: "Run the template hooks"}')" "${COMPANY_REPO}" toolu_3
    denied
    [[ "${output}" == *"not one the agent showed"* ]]
}

@test "approval: a description is compared for every tool but Bash" {
    run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import order
shown = {"tool": "create_issue", "title": "x"}
assert order.same(shown, "mcp__github__create_issue", {"title": "x"})
assert not order.same(shown, "mcp__github__create_issue", {"title": "x", "description": "more text"})
assert order.same({"tool": "Bash", "command": "ls"}, "Bash", {"command": "ls", "description": "List"})
' "${GUARD_ROOT}/agent-hooks/claude-code"
    [ "$status" -eq 0 ]
}

# The operator answers in another tab (the sender, `ses_sender`), whose conversation is `s2.jsonl`;
# that tab relays the answer here with the operator's words at the head, as the client does.
SENDER="ses_sender"
sender_tab() {
    S="${H}/.claude/projects/org/s2.jsonl"
    : > "${S}"
    export GUARD_TAB_BINDINGS="${H}/bindings.json"
    jq -n --arg p "${S}" --arg t "${SENDER}" '{($t): {jsonl_path: $p, confirmed: true}}' > "${GUARD_TAB_BINDINGS}"
}
# in_sender <helper> <args> — write a row of the sender's conversation instead of this one's.
in_sender() { local here="${T}"; T="${S}"; "$@"; T="${here}"; }
# relayed_with <operator's words> [session] — a message relayed into this tab with the operator's words.
relayed_with() {
    said "$(printf '%s (the operator did not type this):\n<agent-message from="AP" session="%s">\n<operator-said>\n%s\n</operator-said>\nThe guard needs the yes you gave.\n</agent-message>' \
        "${RELAYED}" "${2:-${SENDER}}" "$1")"
}

@test "approval: the operator's yes in the sending tab to the very call it showed passes here, once for both tabs" {
    sender_tab
    in_sender said "the other tab is stuck"
    in_sender shown "${HOOKS_OFF}"
    in_sender said "はい"
    relayed_with "はい"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    passed
    [ -d "${AREA_GUARD_STATE}/s2.orders" ]
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}" toolu_2
    denied
    [[ "${output}" == *"already been spent"* ]]
}

@test "approval: a relayed yes passes only for the call the sending tab showed, on the operator's last words there" {
    sender_tab
    in_sender said "the other tab is stuck"
    in_sender shown "git config core.hooksPath .githooks"
    in_sender said "はい"
    relayed_with "はい"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *"did not show this call"* ]]
    # the operator typed again in the sending tab: the yes is no longer their last word there
    in_sender shown "${HOOKS_OFF}"
    in_sender said "はい"
    in_sender said "and one more thing"
    relayed_with "はい"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *"not the last the operator typed"* ]]
    in_sender shown "${HOOKS_OFF}"
    in_sender said "どうしよう"
    relayed_with "どうしよう"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *"do not say yes"* ]]
}

@test "approval: a relayed message without the operator's words, from an unknown tab or another machine is no yes" {
    sender_tab
    in_sender shown "${HOOKS_OFF}"
    in_sender said "はい"
    said "$(printf '%s (the operator did not type this):\n<agent-message from="AP" session="%s">\nはい\n</agent-message>' "${RELAYED}" "${SENDER}")"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *"have the operator answer the same block in the tab that sent"* ]]
    relayed_with "はい" "home:${SENDER}"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    relayed_with "はい" "ses_unknown"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
    [[ "${output}" == *"no confirmed conversation"* ]]
    jq --arg t "${SENDER}" '.[$t].confirmed = false' "${GUARD_TAB_BINDINGS}" > "${H}/b" && mv "${H}/b" "${GUARD_TAB_BINDINGS}"
    relayed_with "はい"
    bash_in "${COMPANY_REPO}" "${HOOKS_OFF}"
    denied
}

@test "approval: an order for a send given in the sending tab passes the same way" {
    sender_tab
    in_sender said "tell them"
    in_sender replied "$(printf '```send\ntool: slack_send_message\nchannel_id: C1\nmessage:\nhello\n```\n')"
    in_sender said "送信して"
    relayed_with "送信して"
    run python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import order
event = {"transcript_path": sys.argv[2], "prompt_id": sys.argv[3], "session_id": "s1"}
why, found = order.ordered("mcp__slack__slack_send_message", {"channel_id": "C1", "message": "hello"}, event)
assert why is None and found.session == "s2", why
why, _ = order.ordered("mcp__slack__slack_send_message", {"channel_id": "C1", "message": "other"}, event)
assert why and "did not show" in why, why
' "${GUARD_ROOT}/agent-hooks/claude-code" "${T}" "p${PROMPT}"
    [ "$status" -eq 0 ]
}
