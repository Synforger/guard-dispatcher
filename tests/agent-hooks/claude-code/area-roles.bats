#!/usr/bin/env bats
# agent-hooks/claude-code/area_roles.py + area-guard.py + peers.py --roles — the roles an area keeps
# in roles.txt: a refused read names the role that may read it and how to ask it, and a relaying
# client may show a session the roles of the areas it reads inside, and no others.
#
# A throwaway HOME holds a company with the hub that gathers it, a team folder and a client inside
# it. The company keeps the lines (areas/company/reads.txt, roles.txt); each test plays one tab by
# its work folder.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
PEERS="${GUARD_ROOT}/agent-hooks/claude-code/peers.py"
SCAN="${GUARD_ROOT}/scanners/corpus/corpus-scan.py"
SLACK="mcp__claude_ai_Slack__slack_read_channel"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    HUB="${H}/org/hub"
    TEAM="${H}/org/team"
    CLIENT="${H}/org/clients/acme"
    mkdir -p "${HUB}" "${TEAM}" "${CLIENT}" "${H}/agent"
    export HOME="${H}"
    setup_words
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}/areas/company" "${AREA_GUARD_STATE}"
    printf 'company ~/org\nhub ~/org/hub\nclient ~/org/clients/acme\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf 'mcp__*Slack*__*   hub\n' > "${GUARD_CONFIG_DIR}/areas/company/reads.txt"
    cat > "${GUARD_CONFIG_DIR}/areas/company/roles.txt" <<'LINES'
# the names the company's sessions address each other by
gatherer   ~/org/hub
desk       ~/org/team
LINES
}

as() { export GUARD_WORK_FOLDER="$1"; }
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}" --arg s "${3:-s1}" \
        '{session_id: $s, tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

@test "area roles: a read refused in the company names the role that reads it, and how to ask it" {
    as "${TEAM}"
    call "${SLACK}" '{"channel_id": "C1"}'
    denied
    [[ "${output}" == *"this call reads inside hub"* ]]
    [[ "${output}" == *'the tab of gatherer (`tabs send gatherer <a file with what to do>`)'* ]]
    # The desk reaches the company only, not the hub: it is no one to ask for this.
    [[ "${output}" != *"tabs send desk"* ]]
}

@test "area roles: a folder read refused in the company names the role too" {
    : > "${HUB}/notes.md"
    as "${CLIENT}"
    call Read "{\"file_path\": \"${HUB}/notes.md\"}"
    denied
    [[ "${output}" == *"tabs send gatherer"* ]]
}

@test "area roles: with no roles.txt the refusal says to ask a session that works there" {
    rm "${GUARD_CONFIG_DIR}/areas/company/roles.txt"
    as "${TEAM}"
    call "${SLACK}" '{"channel_id": "C1"}'
    denied
    [[ "${output}" == *"Ask a session that works there"* ]]
}

@test "area roles: a session outside the company is not shown the company's roles" {
    : > "${HUB}/notes.md"
    as "${H}/agent"
    call Read "{\"file_path\": \"${HUB}/notes.md\"}"
    denied
    [[ "${output}" == *"Ask a session that works there"* ]]
    [[ "${output}" != *"gatherer"* ]]
}

@test "area roles: peers --roles shows a session the roles of the areas it reads inside, and no others" {
    run python3 "${PEERS}" --roles --folder "${TEAM}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gatherer	${HUB}"* ]]
    [[ "${output}" == *"desk	${TEAM}"* ]]
    run python3 "${PEERS}" --roles --folder "${H}/agent"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    # A session that read inside the company (its marks) sees them wherever it works.
    printf '{"areas": ["client"], "tabs": {}}' > "${AREA_GUARD_STATE}/s9.json"
    run python3 "${PEERS}" --roles --folder "${H}/agent" --session s9
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gatherer	${HUB}"* ]]
}

@test "area roles: a line naming a folder outside the area, or not two words, is not read and is named" {
    cat >> "${GUARD_CONFIG_DIR}/areas/company/roles.txt" <<'LINES'
stranger   ~/agent
two words  ~/org/team
LINES
    run python3 "${SCAN}" --settings
    [[ "${output}" == *"stranger"*"is not inside company"* ]]
    [[ "${output}" == *"two words"*"is not \`<role> <folder>\`"* ]]
    run python3 "${PEERS}" --roles --folder "${TEAM}"
    [[ "${output}" != *"stranger"* ]]
}
