#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + service_reads/ — a reading call to a service an area's
# reads.txt places in it is a read inside that area: a session that may not read there is refused
# before the call runs, as for a folder, and a session that may is marked.
#
# A throwaway HOME holds a company with the hub that gathers it and a client inside it. The company
# keeps the lines (areas/company/reads.txt); each test plays one tab by its work folder.
#
# The Drive lists (`fileId=@meetings`) are built by rclone: a fake `rclone` first on the PATH answers
# `rclone backend query` from files the test writes, and logs what it was asked.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
SCAN="${GUARD_ROOT}/scanners/corpus/corpus-scan.py"
GMAIL="mcp__claude_ai_Gmail__search_threads"
SLACK="mcp__claude_ai_Slack__slack_read_channel"
SLACK_SEARCH="mcp__claude_ai_Slack__slack_search_public"
BROWSER="mcp__claude-in-chrome"
DRIVE_READ="mcp__claude_ai_Google_Drive__read_file_content"
DRIVE_SEARCH="mcp__claude_ai_Google_Drive__search_files"
DRIVE_RECENT="mcp__claude_ai_Google_Drive__list_recent_files"
MEETING_A="1AaMeetingNotesAAAAAAAAAAAAAAAAAAAA"
MEETING_B="1BbMeetingNotesBBBBBBBBBBBBBBBBBBBB"
MEETING_C="1CcMeetingNotesCCCCCCCCCCCCCCCCCCCC"
OTHER_FILE="1DdQuarterlyPlanDDDDDDDDDDDDDDDDDDD"

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
# call <tool> <input json> [session] — run the hook on one tool call (with HOOK_PATH / HOOK_PYTHON
# set, under that PATH and that python: a machine without rclone).
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}" --arg s "${3:-s1}" \
        '{session_id: $s, tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run env PATH="${HOOK_PATH:-${PATH}}" "${HOOK_PYTHON:-python3}" "${HOOK}" <<< "${event}"
}

# drive_lists — the company places the notes of its meetings in the hub, by a list of Drive files that
# two searches find, and a fake rclone answers them: the first search finds meeting A, the second B.
drive_lists() {
    cat >> "${GUARD_CONFIG_DIR}/areas/company/reads.txt" <<'LINES'
mcp__*Google_Drive__*   hub   fileId=@meetings
rclone:fakedrive        hub   id=@meetings
rclone:fakedrive        hub   path=@meetings
LINES
    mkdir -p "${GUARD_CONFIG_DIR}/areas/company/lists" "${H}/bin"
    cat > "${GUARD_CONFIG_DIR}/areas/company/lists/meetings.drive" <<'LIST'
# the notes Meet writes
remote fakedrive
query name contains 'Notes by Gemini'
query name contains 'Gemini によるメモ'
LIST
    printf '[{"id": "%s", "name": "Standup 2026/11/05 10:08 GMT - Notes by Gemini", "mimeType": "application/vnd.google-apps.document"}]\n' \
        "${MEETING_A}" > "${H}/answer-a.json"
    printf '[{"id": "%s", "name": "1on1 - Gemini によるメモ", "mimeType": "application/vnd.google-apps.document"}]\n' \
        "${MEETING_B}" > "${H}/answer-b.json"
    cat > "${H}/bin/rclone" <<'FAKE'
#!/bin/bash
echo "$*" >> "${FAKE_RCLONE_LOG}"
if [ "${FAKE_RCLONE_EXIT:-0}" != 0 ]; then
    echo 'CRITICAL: Failed to create file system for "fakedrive:": didn'"'"'t find section in config file' >&2
    exit "${FAKE_RCLONE_EXIT}"
fi
case "$4" in
    *"Notes by Gemini"*) cat "${FAKE_RCLONE_DIR}/answer-a.json" ;;
    *) cat "${FAKE_RCLONE_DIR}/answer-b.json" ;;
esac
FAKE
    chmod +x "${H}/bin/rclone"
    export FAKE_RCLONE_LOG="${H}/rclone.log" FAKE_RCLONE_DIR="${H}" PATH="${H}/bin:${PATH}"
}
# asked — how many times the fake rclone was asked.
asked() { if [ -f "${FAKE_RCLONE_LOG}" ]; then wc -l < "${FAKE_RCLONE_LOG}" | tr -d ' '; else echo 0; fi; }
# age_tables — the kept tables were built two minutes ago.
age_tables() {
    local table
    for table in "${GUARD_CORPUS_CACHE}"/drive/*.json; do
        jq --argjson at "$(( $(date +%s) - 120 ))" '.fetched_at = $at' "${table}" > "${table}.new" && mv "${table}.new" "${table}"
    done
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

@test "service reads: a file on the hub's list of meetings is the hub's, every other file of the Drive is everyone's" {
    drive_lists
    as "${CLIENT}"
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_A}\"}"
    denied
    [[ "${output}" == *"this call reads inside hub"* ]]
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_B}\"}"
    denied
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}"
    passed
    as "${HUB}"
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_A}\"}" s2
    passed
    [ "$(marks s2)" = "hub" ]
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}" s3
    passed
    [ -z "$(marks s3)" ]
}

@test "service reads: a call that names no file is outside the list: a search and a recent list stay everyone's" {
    drive_lists
    as "${CLIENT}"
    call "${DRIVE_SEARCH}" '{"query": "title contains \"standup\""}'
    passed
    call "${DRIVE_RECENT}" '{}'
    passed
    call Bash '{"command": "rclone backend query fakedrive: \"name contains standup\""}'
    passed
    call Bash '{"command": "rclone lsjson fakedrive:"}'
    passed
    [ "$(asked)" -eq 0 ]
}

@test "service reads: rclone copyid and backend copyid take a file by id: a meeting is the hub's" {
    drive_lists
    as "${CLIENT}"
    call Bash "{\"command\": \"rclone backend copyid fakedrive: ${MEETING_A} ./ --drive-export-formats txt\"}"
    denied
    [[ "${output}" == *"reads inside hub"* ]]
    call Bash "{\"command\": \"rclone copyid --drive-export-formats txt fakedrive: ${MEETING_B} ./\"}"
    denied
    call Bash "{\"command\": \"rclone copyid fakedrive: ${OTHER_FILE} ./\"}"
    passed
    as "${HUB}"
    call Bash "{\"command\": \"rclone backend copyid fakedrive: ${MEETING_A} ./\"}" s2
    passed
    [ "$(marks s2)" = "hub" ]
}

@test "service reads: rclone cat and copy take a path: it is a meeting when its last name is on the list" {
    drive_lists
    as "${CLIENT}"
    call Bash '{"command": "rclone cat \"fakedrive:Meet Recordings/Standup 2026／11／05 10:08 GMT - Notes by Gemini.txt\""}'
    denied
    [[ "${output}" == *"reads inside hub"* ]]
    call Bash '{"command": "rclone copy \"fakedrive:Meet Recordings/1on1 - Gemini によるメモ\" ./out"}'
    denied
    call Bash '{"command": "rclone cat fakedrive:Docs/quarterly-plan.txt"}'
    passed
    as "${HUB}"
    call Bash '{"command": "rclone cat \"fakedrive:Meet Recordings/1on1 - Gemini によるメモ.txt\""}' s2
    passed
    [ "$(marks s2)" = "hub" ]
}

@test "service reads: an rclone copy toward a remote is a send and no read" {
    drive_lists
    as "${CLIENT}"
    call Bash '{"command": "rclone copy ./notes.txt \"fakedrive:Meet Recordings/1on1 - Gemini によるメモ\""}'
    passed
    call Bash '{"command": "rclone copyto ./notes.txt fakedrive:Standup/notes.txt"}'
    passed
    [ "$(asked)" -eq 0 ]
}

@test "service reads: a list that cannot be checked is read as the meetings: the hub's tab passes, any other is told why" {
    drive_lists
    export FAKE_RCLONE_EXIT=3
    as "${CLIENT}"
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}"
    denied
    [[ "${output}" == *"cannot be checked"* ]]
    [[ "${output}" == *"could not query fakedrive"* ]]
    [[ "${output}" == *"didn't find section in config file"* ]]
    [[ "${output}" == *"reads only inside client"* ]]
    call Bash "{\"command\": \"rclone backend copyid fakedrive: ${OTHER_FILE} ./\"}"
    denied
    as "${HUB}"
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}" s2
    passed
    [ "$(marks s2)" = "hub" ]
}

@test "service reads: without rclone, a missing list, a broken list, or a file known only at run time cannot be checked" {
    drive_lists
    as "${CLIENT}"
    mkdir -p "${H}/bare"
    ln -s "$(command -v python3)" "${H}/bare/python3"
    HOOK_PATH="${H}/bare:/usr/bin:/bin" HOOK_PYTHON="${H}/bare/python3" call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}"
    denied
    [[ "${output}" == *"rclone is not installed"* ]]
    rm "${GUARD_CONFIG_DIR}/areas/company/lists/meetings.drive"
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}"
    denied
    [[ "${output}" == *"the list meetings could not be checked: no such list"* ]]
    printf 'query name contains foo\n' > "${GUARD_CONFIG_DIR}/areas/company/lists/meetings.drive"
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}"
    denied
    [[ "${output}" == *"meetings.drive: it needs exactly one \`remote\` line"* ]]
    printf 'remote fakedrive\nquery name contains foo\n' > "${GUARD_CONFIG_DIR}/areas/company/lists/meetings.drive"
    call Bash '{"command": "rclone copyid fakedrive: \"$FILE_ID\" ./"}'
    denied
    [[ "${output}" == *"only known when the command runs"* ]]
    [ "$(asked)" -eq 0 ]
}

@test "service reads: the table is kept for 60 seconds, and an older one is asked again for a file it lacks" {
    drive_lists
    as "${CLIENT}"
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_A}\"}"
    denied
    [ "$(asked)" -eq 2 ]
    [[ "$(sed -n 1p "${FAKE_RCLONE_LOG}")" == "backend query fakedrive: name contains 'Notes by Gemini'" ]]
    # within a minute, a file the table lacks is not looked for again
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_C}\"}"
    passed
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_B}\"}"
    denied
    [ "$(asked)" -eq 2 ]
    # a minute on, a file the table holds is not looked for again either ...
    age_tables
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_B}\"}"
    denied
    [ "$(asked)" -eq 2 ]
    # ... but one it lacks is: a meeting made since is found
    printf '[{"id": "%s", "name": "Retro - Notes by Gemini"}]\n' "${MEETING_C}" > "${H}/answer-a.json"
    call "${DRIVE_READ}" "{\"fileId\": \"${MEETING_C}\"}"
    denied
    [ "$(asked)" -eq 4 ]
    call "${DRIVE_READ}" "{\"fileId\": \"${OTHER_FILE}\"}"
    passed
    [ "$(asked)" -eq 4 ]
}
