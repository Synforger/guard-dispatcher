#!/usr/bin/env bats
# sandbox/sort-sessions.py — past conversations move into the cage of the area they worked in.
#
# A throwaway HOME holds a company folder with two clients inside it and one account whose
# config directory has a conversation of each kind: personal, company, client (absolute and
# relative paths), one whose subagent did the reading, one only the entry guard marked, one
# across two clients, one that only printed an area's path, and one still running.

load helpers

SORT="${GUARD_ROOT}/sandbox/sort-sessions.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    A="${H}/.claude"
    mkdir -p "${H}/org/clients/acme" "${H}/org/clients/globex" "${H}/repos/tool" "${A}/projects/-work" \
        "${A}/paste-cache" "${A}/sessions" "${H}/.cache/area-guard"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export AREA_GUARD_STATE="${H}/.cache/area-guard"
    mkdir -p "${GUARD_CONFIG_DIR}"
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org
client-*  ~/org/clients/*
AREAS
    record s-personal "${H}/repos/tool" '{"type":"tool_use","name":"Read","input":{"file_path":"'"${H}"'/repos/tool/a.md"}}'
    record s-company "${H}/repos/tool" '{"type":"tool_use","name":"Bash","input":{"command":"cat ~/org/plan.md | head"}}'
    record s-client "${H}/repos/tool" '{"type":"tool_use","name":"Read","input":{"file_path":"'"${H}"'/org/clients/acme/deck.md"}}'
    record s-relative "${H}/org" '{"type":"tool_use","name":"Bash","input":{"command":"cd clients/acme && ls"}}'
    record s-subagent "${H}/repos/tool" '{"type":"text","text":"asking a helper"}'
    mkdir -p "${A}/projects/-work/s-subagent/subagents"
    line "${H}/repos/tool" '{"type":"tool_use","name":"Grep","input":{"path":"'"${H}"'/org"}}' \
        > "${A}/projects/-work/s-subagent/subagents/agent-1.jsonl"
    record s-marked "${H}/repos/tool" '{"type":"text","text":"nothing named"}'
    printf '["company"]' > "${AREA_GUARD_STATE}/s-marked.json"
    record s-both "${H}/repos/tool" '{"type":"tool_use","name":"Bash","input":{"command":"diff ~/org/clients/acme/a ~/org/clients/globex/a"}}'
    record s-printed "${H}/repos/tool" '{"type":"tool_result","content":"'"${H}"'/org/clients/acme/deck.md"}'
    record s-running "${H}/repos/tool" '{"type":"tool_use","name":"Read","input":{"file_path":"'"${H}"'/org/x.md"}}'
    printf '{"pid": %s, "sessionId": "s-running"}' "$$" > "${A}/sessions/$$.json"
    mkdir -p "${A}/file-history/s-client" "${A}/session-env/s-client"
    touch "${A}/file-history/s-client/v1"
    printf 'client paste' > "${A}/paste-cache/aaaa1111.txt"
    printf 'shared paste' > "${A}/paste-cache/bbbb2222.txt"
    {
        hist s-personal "hello bbbb2222"
        hist s-client "look aaaa1111"
        hist s-client "and bbbb2222"
        hist s-company "plan"
        hist s-running "still here"
    } > "${A}/history.jsonl"
    jq -n --arg org "${H}/org/clients/acme" --arg tool "${H}/repos/tool" \
        '{numStartups: 3, projects: {($org): {hasTrustDialogAccepted: true}, ($tool): {hasTrustDialogAccepted: true}}}' \
        > "${H}/.claude.json"
}

# line <cwd> <content item> — one assistant row of a record.
line() { printf '{"cwd":"%s","message":{"content":[%s]}}\n' "$1" "$2"; }
# record <session> <cwd> <content item> — a conversation record with one row.
record() { line "$2" "$3" > "${A}/projects/-work/$1.jsonl"; }
hist() { printf '{"display":"%s","pastedContents":{},"timestamp":1,"project":"/w","sessionId":"%s"}\n' "$2" "$1"; }

sort_sessions() { run python3 "${SORT}" "$@"; }
at() { [ -f "$1/projects/-work/$2.jsonl" ]; }

@test "sort: the dry run counts and moves nothing" {
    sort_sessions
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 stay"* ]]
    [[ "${output}" == *"3 to company"* ]]
    [[ "${output}" == *"2 to client-acme"* ]]
    [[ "${output}" == *"1 running (skipped)"* ]]
    [[ "${output}" == *"areas do not nest: client-acme, client-globex): s-both"* ]]
    [[ "${output}" == *"add --apply"* ]]
    [ -z "$(compgen -G "${H}/.claude@*")" ]
    at "${A}" s-client
}

@test "sort: each conversation lands in the innermost area it worked in" {
    sort_sessions --apply
    [ "${status}" -eq 0 ]
    at "${A}@client-acme" s-client
    at "${A}@client-acme" s-relative
    at "${A}@company" s-company
    at "${A}@company" s-subagent
    at "${A}@company" s-marked
    [ -f "${A}@company/projects/-work/s-subagent/subagents/agent-1.jsonl" ]
    # Outside every area, printed only, across two clients, or running: left where it was.
    at "${A}" s-personal
    at "${A}" s-printed
    at "${A}" s-both
    at "${A}" s-running
    [ ! -e "${A}/projects/-work/s-client.jsonl" ]
}

@test "sort: the conversation's own folders move with it" {
    sort_sessions --apply
    [ -f "${A}@client-acme/file-history/s-client/v1" ]
    [ -d "${A}@client-acme/session-env/s-client" ]
    [ ! -e "${A}/file-history/s-client" ]
}

@test "sort: history lines follow their conversation, and a paste only they cite goes too" {
    sort_sessions --apply
    [ "$(wc -l < "${A}/history.jsonl")" -eq 2 ]
    [ "$(jq -r .sessionId "${A}@client-acme/history.jsonl" | sort -u)" = "s-client" ]
    [ "$(wc -l < "${A}@client-acme/history.jsonl")" -eq 2 ]
    [ "$(jq -r .sessionId "${A}@company/history.jsonl")" = "s-company" ]
    [ -f "${A}@client-acme/paste-cache/aaaa1111.txt" ]
    [ ! -e "${A}/paste-cache/aaaa1111.txt" ]
    # Cited by a conversation that stays: it stays.
    [ -f "${A}/paste-cache/bbbb2222.txt" ]
}

@test "sort: the state file hands a folder inside an area to that area's cage" {
    sort_sessions --apply
    jq -e --arg p "${H}/org/clients/acme" '.projects[$p] == null' "${H}/.claude.json" > /dev/null
    jq -e --arg p "${H}/repos/tool" '.projects[$p].hasTrustDialogAccepted' "${H}/.claude.json" > /dev/null
    jq -e '.numStartups == 3' "${H}/.claude.json" > /dev/null
    jq -e --arg p "${H}/org/clients/acme" '.projects[$p].hasTrustDialogAccepted' "${A}@client-acme/.claude.json" > /dev/null
}

@test "sort: a second run finds nothing more to move" {
    sort_sessions --apply
    sort_sessions
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 stay"* ]]
    [[ "${output}" != *" to company"* ]]
    [[ "${output}" != *" to client-acme"* ]]
    [[ "${output}" == *"2 stay, 1 running (skipped)"* ]]
}

@test "sort: a destination already taken moves nothing at all" {
    mkdir -p "${A}@company/projects/-work"
    touch "${A}@company/projects/-work/s-company.jsonl"
    before="$(cat "${A}/history.jsonl")"
    sort_sessions --apply
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already in place"* ]]
    at "${A}" s-client
    [ "$(cat "${A}/history.jsonl")" = "${before}" ]
}

@test "sort: a cage's own directory is not an account" {
    mkdir -p "${A}@company"
    sort_sessions --account-dir "${A}@company"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not an account's"* ]]
}
