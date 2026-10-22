#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + service_reads/ — a reading call to a service an area's
# reads.txt places in it is a read inside that area: a session that may not read there is refused
# before the call runs, as for a folder, and a session that may is marked.
#
# A throwaway HOME holds a company with the hub that gathers it and a client inside it. The company
# keeps the lines (areas/company/reads.txt); each test plays one tab by its work folder.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
SCAN="${GUARD_ROOT}/scanners/corpus/corpus-scan.py"
GMAIL="mcp__claude_ai_Gmail__search_threads"
SLACK="mcp__claude_ai_Slack__slack_read_channel"
SLACK_SEARCH="mcp__claude_ai_Slack__slack_search_public"
BROWSER="mcp__claude-in-chrome"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    HUB="${H}/org/hub"
    CLIENT="${H}/org/clients/acme"
    mkdir -p "${HUB}" "${CLIENT}" "${H}/agent"
    export HOME="${H}"
    setup_words
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}/areas/company"
    printf 'company ~/org\nhub ~/org/hub\nclient ~/org/clients/acme\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    cat > "${GUARD_CONFIG_DIR}/areas/company/reads.txt" <<'LINES'
# what the company's services hold is the hub's to read
mcp__*Gmail*__*        hub
mcp__*Slack*__*        hub
mcp__*Slack*__*        client   channel_id=C0CLIENT*
browser:*.docbase.io   hub
host:api.hubapi.com    hub
LINES
}

# as <work folder> — play the tab that works there.
as() { export GUARD_WORK_FOLDER="$1"; }
# call <tool> <input json> [session] — run the hook on one tool call.
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}" --arg s "${3:-s1}" \
        '{session_id: $s, tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
marks() { jq -r '.areas | join(",")' "${AREA_GUARD_STATE}/${1:-s1}.json" 2>/dev/null; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

@test "service reads: a mail search reads inside the hub: refused before it runs elsewhere, marked in the hub" {
    as "${CLIENT}"
    call "${GMAIL}" '{"query": "invoice"}'
    denied
    [[ "${output}" == *"this call reads inside hub"* ]]
    [ -z "$(marks)" ]
    as "${H}/agent"
    call "${GMAIL}" '{"query": "invoice"}' s2
    denied
    as "${HUB}"
    call "${GMAIL}" '{"query": "invoice"}' s3
    passed
    [ "$(marks s3)" = "hub" ]
}

@test "service reads: a draft or a send reads nothing there, and a service no line names is no read" {
    as "${CLIENT}"
    call mcp__claude_ai_Gmail__create_draft '{"to": "someone@example.com", "body": "hello"}'
    passed
    call mcp__claude_ai_Calendar__list_events '{"day": "today"}'
    passed
}

@test "service reads: a channel the company hands to a case is the case's, every other one the hub's" {
    as "${CLIENT}"
    call "${SLACK}" '{"channel_id": "C0CLIENT01"}'
    passed
    call "${SLACK}" '{"channel_id": "C0GENERAL"}'
    denied
    [[ "${output}" == *"reads inside hub"* ]]
    as "${HUB}"
    call "${SLACK}" '{"channel_id": "C0GENERAL"}' s2
    passed
    call "${SLACK}" '{"channel_id": "C0CLIENT01"}' s2
    denied
    [[ "${output}" == *"reads inside client"* ]]
}

@test "service reads: a search over every channel reads where every line points" {
    as "${HUB}"
    call "${SLACK_SEARCH}" '{"query": "release"}'
    denied
    [[ "${output}" == *"reads inside client"* ]]
    as "${CLIENT}"
    call "${SLACK_SEARCH}" '{"query": "release"}' s2
    denied
    [[ "${output}" == *"reads inside hub"* ]]
    printf 'mcp__*Slack*__* hub\n' > "${GUARD_CONFIG_DIR}/areas/company/reads.txt"
    as "${HUB}"
    call "${SLACK_SEARCH}" '{"query": "release"}' s3
    passed
}

@test "service reads: a browser tab opened at the site, and every later call to it, reads inside the hub" {
    as "${CLIENT}"
    call "${BROWSER}__navigate" '{"tabId": 7, "url": "https://team.docbase.io/posts/1"}'
    denied
    as "${HUB}"
    call "${BROWSER}__navigate" '{"tabId": 7, "url": "https://team.docbase.io/posts/1"}' s2
    passed
    call "${BROWSER}__get_page_text" '{"tabId": 7}' s2
    passed
    [ "$(marks s2)" = "hub" ]
    call "${BROWSER}__navigate" '{"tabId": 8, "url": "https://example.com/"}' s2
    passed
}

@test "service reads: a curl that only fetches from the service reads inside the hub" {
    as "${CLIENT}"
    call Bash '{"command": "curl -s https://api.hubapi.com/crm/v3/objects/contacts"}'
    denied
    as "${HUB}"
    call Bash '{"command": "curl -s https://api.hubapi.com/crm/v3/objects/contacts"}' s2
    passed
}

@test "service reads: a line that places a read outside the area that keeps it, or catches everything, is not read" {
    mkdir -p "${GUARD_CONFIG_DIR}/areas/client"
    printf 'mcp__*Gmail*__* hub\nmcp__*__* client\nmcp__*Drive*__* client folder\n' > "${GUARD_CONFIG_DIR}/areas/client/reads.txt"
    run python3 "${SCAN}" --settings
    [[ "${output}" == *"hub is no area within client"* ]]
    [[ "${output}" == *"catches every destination"* ]]
    [[ "${output}" == *"is not \`<destination> <area> [<argument>=<shape>]...\`"* ]]
    as "${CLIENT}"
    call mcp__claude_ai_Drive__read_file '{"id": "1"}'
    passed
}
