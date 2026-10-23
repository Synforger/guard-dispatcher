#!/usr/bin/env bats
# agent-hooks/claude-code/handed.py + outgoing.py + scanners/destinations/send-scan.py — a file the
# agent leaves for the operator to hand to people (a `file:` line of destinations.txt) takes the
# destination's word list: a file tool's write before it is made, any other call's file after it.
#
# A throwaway HOME holds a company folder with a client inside it, each with one made-up document,
# and `out/`, the folder the operator hands files on from.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
AFTER="${GUARD_ROOT}/agent-hooks/claude-code/handed.py"
CLIENT_TEXT="the calibration table reads seventeen at dawn"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme/received" "${H}/out" "${H}/repos/tool" "${GUARD_CONFIG_DIR}"
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/org/clients/acme/received/notes.md"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export GUARD_CORPUS_MAX_AGE=0
    printf 'company ~/org\nclient  ~/org/clients/acme\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    # the operator's list flags a real name and a handle; the company's list only the handle
    export ANON_TRUTH_PATH="${H}/.config/anon-words/master.txt"
    mkdir -p "${H}/.config/anon-words"
    printf '%s\n' "${SENTINEL}" "Taro Example" > "${ANON_WORDS_FILE}"
    cp "${ANON_WORDS_FILE}" "${ANON_TRUTH_PATH}"
    printf '%s\n' "${SENTINEL}" > "${H}/.config/anon-words/company.txt"
    printf '%s\n' 'file:~/out/* company' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
}

# call <tool> <input json> — run the entry guard on one tool call.
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}/repos/tool" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
write() { call Write "$(jq -n --arg f "$1" --arg c "$2" '{file_path: $f, content: $c}')"; }
# after [duration ms] [session] — run the after-call check on a Bash call that took that long.
after() {
    local event
    event="$(jq -n --argjson d "${1:-1000}" --arg s "${2:-s1}" \
        '{session_id: $s, tool_name: "Bash", tool_input: {command: "make"}, tool_response: {},
          tool_use_id: "toolu_1", cwd: "/", hook_event_name: "PostToolUse", duration_ms: $d}')"
    run python3 "${AFTER}" <<< "${event}"
}

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }
reported() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"decision": "block"'* ]]; }

@test "handed: a file tool's write into a file left for the operator takes the destination's word list" {
    write "${H}/out/a.md" "Taro Example wrote this"
    passed
    write "${H}/out/a.md" "signed ${SENTINEL}"
    denied
    [[ "${output}" == *"file:~/out/a.md (in company)"* ]]
    [[ "${output}" == *"word list"* ]]
    # anywhere else it is a file like any other
    write "${H}/repos/tool/a.md" "signed ${SENTINEL}"
    passed
}

@test "handed: an edit carries the file's text as well, since all of it is handed on" {
    printf 'draft by %s\n' "${SENTINEL}" > "${H}/out/b.md"
    call Edit "$(jq -n --arg f "${H}/out/b.md" '{file_path: $f, old_string: "draft", new_string: "final"}')"
    denied
    call MultiEdit "$(jq -n --arg f "${H}/out/b.md" '{file_path: $f, edits: [{old_string: "draft", new_string: "final"}]}')"
    denied
}

@test "handed: a file left for the operator is not compared with the private documents" {
    printf '%s\n' 'file:~/out/* company' 'mcp__*drive* company' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
    # the same text sent to a service of the company is the client's, and refused
    call mcp__acme__drive_upload_file "$(jq -n --arg t "${CLIENT_TEXT}" '{text: $t}')"
    denied
    [[ "${output}" == *"private area"* ]]
    write "${H}/out/c.md" "${CLIENT_TEXT}"
    passed
}

@test "handed: a line catching every destination does not reach a file" {
    printf '%s\n' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
    write "${H}/out/a.md" "signed ${SENTINEL}"
    passed
    after
    passed
}

@test "handed: a file another call left is reported after it, once for each change" {
    printf 'built by %s\n' "${SENTINEL}" > "${H}/out/report.md"
    printf 'nothing to see\n' > "${H}/out/clean.md"
    after
    reported
    [[ "${output}" == *"file:~/out/report.md (in company)"* ]]
    [[ "${output}" != *"clean.md"* ]]
    # the same change is not reported again, in this session or another
    after
    passed
    after 1000 s2
    passed
    # a new change is
    sleep 1
    printf 'built again by %s\n' "${SENTINEL}" > "${H}/out/report.md"
    after
    reported
}

@test "handed: a file changed before the call is not the call's, and one that is not text carries no words" {
    printf 'old %s\n' "${SENTINEL}" > "${H}/out/old.md"
    touch -t 202001010000 "${H}/out/old.md"
    printf '\0\1\2 %s' "${SENTINEL}" > "${H}/out/image.png"
    mkdir -p "${H}/out/.cache"
    printf '%s\n' "${SENTINEL}" > "${H}/out/.cache/x.md"
    after
    passed
}

@test "handed: a file written after the session's last call ended is reported at its next call" {
    after
    passed
    sleep 3
    printf 'from the background %s\n' "${SENTINEL}" > "${H}/out/late.md"
    after 0
    reported
    [[ "${output}" == *"late.md"* ]]
}

@test "handed: with no file left for the operator, nothing is looked at" {
    rm "${GUARD_CONFIG_DIR}/destinations.txt"
    printf '%s\n' "${SENTINEL}" > "${H}/out/a.md"
    after
    passed
    [ ! -e "${AREA_GUARD_STATE}/s1.handed" ]
}
