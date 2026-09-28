#!/usr/bin/env bats
# agent-hooks/claude-code/outgoing.py + scanners/send-scan.py (through area-guard.py) — what a tool or a network command
# sends out is judged like a push: its payload against the areas its destination is outside of.
#
# A throwaway HOME holds a company folder with a client inside it; each holds one made-up
# document. Every call feeds the hook the JSON Claude Code sends before a tool runs.

load helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
CLIENT_TEXT="the calibration table reads seventeen at dawn"
COMPANY_TEXT="quarterly planning keeps the bench schedule"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme/received" "${H}/org/meetings" "${H}/repos/tool" "${GUARD_CONFIG_DIR}"
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/org/clients/acme/received/notes.md"
    printf '%s\n' "${COMPANY_TEXT}" > "${H}/org/meetings/plan.md"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export GUARD_CORPUS_MAX_AGE=0
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org
client  ~/org/clients/acme
AREAS
}

# call <tool> <input json> — run the hook on one tool call.
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}/repos/tool" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
send() { call "$1" "$(jq -n --arg t "$2" '{text: $t}')"; }
destinations() { printf '%s\n' "$@" > "${GUARD_CONFIG_DIR}/destinations.txt"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

# --- a service the tool sends to ------------------------------------------------------

@test "outgoing: an undeclared service is outside every area: area text is refused, other text passes" {
    send mcp__acme__drive_upload_file "notes: ${CLIENT_TEXT}"
    denied
    [[ "${output}" == *"mcp__acme__drive_upload_file (outside every area)"* ]]
    send mcp__acme__drive_upload_file "notes: ${COMPANY_TEXT}"
    denied
    send mcp__acme__drive_upload_file "a note of my own about nothing private"
    passed
}

@test "outgoing: a service declared inside the company takes company text, not the client's" {
    destinations 'mcp__*drive* company'
    send mcp__acme__drive_upload_file "${COMPANY_TEXT}"
    passed
    send mcp__acme__drive_upload_file "${CLIENT_TEXT}"
    denied
    [[ "${output}" == *"(in company)"* ]]
}

@test "outgoing: a service declared inside the client takes the client's text and the company's around it" {
    destinations 'mcp__*drive* client'
    send mcp__acme__drive_upload_file "${CLIENT_TEXT}"
    passed
    send mcp__acme__drive_upload_file "${COMPANY_TEXT}"
    passed
}

@test "outgoing: a reading call is not scanned" {
    send mcp__acme__drive_search_files "${CLIENT_TEXT}"
    passed
    send mcp__acme__slack_read_channel "${CLIENT_TEXT}"
    passed
}

@test "outgoing: block refuses every send of the tool, whatever it carries; reading still passes" {
    destinations '*slack* block' 'mcp__*drive* company'
    send mcp__claude_ai_Slack__slack_send_message "hello"
    denied
    [[ "${output}" == *"is blocked for sending"* ]]
    send mcp__claude_ai_Slack__slack_read_channel "hello"
    passed
    send mcp__acme__drive_upload_file "hello"
    passed
}

@test "outgoing: the contents of a local file a tool uploads are scanned" {
    printf 'draft\n%s\n' "${CLIENT_TEXT}" > "${H}/repos/tool/page.html"
    call Artifact "$(jq -n --arg f "${H}/repos/tool/page.html" '{file_path: $f}')"
    denied
    call Artifact "$(jq -n --arg f "page.html" '{files: {"a.html": $f}}')"
    denied
    call Artifact '{"action": "read", "url": "https://example.invalid/a"}'
    passed
    printf 'nothing private\n' > "${H}/repos/tool/page.html"
    call Artifact "$(jq -n --arg f "${H}/repos/tool/page.html" '{file_path: $f}')"
    passed
}

# --- the host's web tools ------------------------------------------------------------------

@test "outgoing: a web search carrying area text is refused; an ordinary query passes" {
    call WebSearch "$(jq -n --arg q "${CLIENT_TEXT}" '{query: $q}')"
    denied
    [[ "${output}" == *"WebSearch (outside every area)"* ]]
    call WebSearch '{"query": "python zipfile read xml members"}'
    passed
}

@test "outgoing: a web fetch carrying area text in its prompt or URL is refused" {
    call WebFetch "$(jq -n --arg p "summarise how ${CLIENT_TEXT}" '{url: "https://example.com/", prompt: $p}')"
    denied
    call WebFetch "$(jq -n --arg u "https://example.com/?q=${CLIENT_TEXT}" '{url: $u, prompt: "summarise"}')"
    denied
    call WebFetch '{"url": "https://docs.python.org/3/library/zipfile.html", "prompt": "list the methods"}'
    passed
}

@test "outgoing: a web tool can be declared like any service" {
    destinations 'WebSearch company'
    call WebSearch "$(jq -n --arg q "${COMPANY_TEXT}" '{query: $q}')"
    passed
}

# --- files whose text is not plain -----------------------------------------------------

upload() { call Artifact "$(jq -n --arg f "$1" '{file_path: $f}')"; }
# read_client — a Read inside the client marks this session (s1).
read_client() { call Read "$(jq -n --arg f "${H}/org/clients/acme/received/notes.md" '{file_path: $f}')"; }
# mk_binary <path> — a file that is not text (a NUL in its first bytes, as an image has).
mk_binary() { printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' > "$1"; }

@test "outgoing: the text inside an uploaded Office document is scanned" {
    mk_office "${H}/repos/tool/deck.pptx" "${CLIENT_TEXT}"
    upload "${H}/repos/tool/deck.pptx"
    denied
    mk_office "${H}/repos/tool/plain.pptx" "a heading of my own"
    upload "${H}/repos/tool/plain.pptx"
    passed
}

@test "outgoing: the text inside an uploaded PDF is scanned" {
    command -v pdftotext >/dev/null || skip "pdftotext is not installed"
    mk_pdf "${H}/repos/tool/report.pdf" "${CLIENT_TEXT}" flate
    upload "${H}/repos/tool/report.pdf"
    denied
    bash_call "curl -F 'doc=@report.pdf' https://up.example.com/"
    denied
}

@test "outgoing: a file that is not text passes from a session that read nothing private" {
    mk_binary "${H}/repos/tool/shot.png"
    upload "${H}/repos/tool/shot.png"
    passed
    bash_call "curl -T shot.png https://up.example.com/"
    passed
}

@test "outgoing: a file that is not text is refused once the session has read inside an area" {
    mk_binary "${H}/repos/tool/shot.png"
    read_client
    passed
    upload "${H}/repos/tool/shot.png"
    denied
    [[ "${output}" == *"cannot be scanned (not a text file)"* ]]
    [[ "${output}" == *"has read inside client"* ]]
    bash_call "curl -T shot.png https://up.example.com/"
    denied
}

@test "outgoing: a text file too large to scan is refused once the session has read inside an area" {
    python3 -c "open('${H}/repos/tool/big.log', 'w').write('x' * (9 * 1024 * 1024))"
    upload "${H}/repos/tool/big.log"
    passed
    read_client
    upload "${H}/repos/tool/big.log"
    denied
    [[ "${output}" == *"cannot be scanned (larger than 8 MB)"* ]]
}

@test "outgoing: a file that is not text is refused when it sits inside an area" {
    mk_binary "${H}/org/clients/acme/received/scan.png"
    upload "${H}/org/clients/acme/received/scan.png"
    denied
    [[ "${output}" == *"sits inside client"* ]]
}

@test "outgoing: an Office document that cannot be opened counts as unscanned" {
    printf 'not a zip at all\n' > "${H}/repos/tool/broken.docx"
    upload "${H}/repos/tool/broken.docx"
    passed
    read_client
    upload "${H}/repos/tool/broken.docx"
    denied
    [[ "${output}" == *"its text could not be taken out"* ]]
}

@test "outgoing: outside every area the word list applies, as for a public repository" {
    send mcp__acme__docs_create "a draft naming ${SENTINEL}"
    denied
    [[ "${output}" == *"flagged identifier"* ]]
    destinations 'mcp__acme__docs_* company'
    send mcp__acme__docs_create "a draft naming ${SENTINEL}"
    passed
}

@test "outgoing: a broken destinations file sends nothing" {
    destinations 'mcp__*drive* nowhere'
    send mcp__acme__drive_upload_file "hello"
    denied
    [[ "${output}" == *"destinations.txt:1"* ]]
}

# --- a network command ------------------------------------------------------------------

bash_call() { call Bash "$(jq -n --arg c "$1" '{command: $c}')"; }

@test "outgoing: curl with a body carrying area text is refused; the host decides the destination" {
    bash_call "curl -s -d 'q=${CLIENT_TEXT}' https://api.example.com/x"
    denied
    [[ "${output}" == *"host:api.example.com"* ]]
    bash_call "curl -s --data-raw='${COMPANY_TEXT}' https://api.example.com/x"
    denied
    destinations 'host:*.example.com company'
    bash_call "curl -s -d '${COMPANY_TEXT}' https://api.example.com/x"
    passed
}

@test "outgoing: a curl glued to a break or followed by a redirect is still found" {
    bash_call "echo start;curl -s -d '${CLIENT_TEXT}' https://api.example.com/x"
    denied
    bash_call "true&&curl -s -d '${CLIENT_TEXT}' https://api.example.com/x>/dev/null 2>&1"
    denied
    [[ "${output}" == *"host:api.example.com"* ]]
    bash_call "curl -s https://example.com/ >out.txt 2>&1;echo done"
    passed
}

@test "outgoing: the file a curl or wget sends is scanned" {
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/repos/tool/body.txt"
    bash_call "curl -F 'doc=@body.txt' https://up.example.com/"
    denied
    bash_call "curl -T body.txt https://up.example.com/"
    denied
    bash_call "curl --data-binary @${H}/repos/tool/body.txt https://up.example.com/"
    denied
    bash_call "wget --post-file=body.txt https://up.example.com/"
    denied
}

@test "outgoing: a body curl reads from a file on its standard input is scanned" {
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/repos/tool/body.txt"
    bash_call "curl -d @- https://api.example.com/x < body.txt"
    denied
    bash_call "curl -T - https://up.example.com/ <body.txt"
    denied
    bash_call "curl -F 'doc=@-' https://up.example.com/ < ${H}/repos/tool/body.txt"
    denied
    printf 'nothing private\n' > "${H}/repos/tool/body.txt"
    bash_call "curl -d @- https://api.example.com/x < body.txt"
    passed
}

@test "outgoing: a here-string curl sends is scanned" {
    bash_call "curl --data-binary @- https://api.example.com/x <<< '${CLIENT_TEXT}'"
    denied
    bash_call "curl --data-binary @- https://api.example.com/x <<< 'ping'"
    passed
}

@test "outgoing: a body known only when the command runs is refused, whatever it would hold" {
    local c
    for c in "cat body.txt | curl -d @- https://api.example.com/x" \
             "curl -d \"\$(cat body.txt)\" https://api.example.com/x" \
             "curl -d \$(cat body.txt) https://api.example.com/x" \
             "curl -d \"\$BODY\" https://api.example.com/x" \
             "curl -d \"\`cat body.txt\`\" https://api.example.com/x" \
             "curl -T - https://up.example.com/ <<EOF
anything
EOF"; do
        bash_call "${c}"
        denied || { echo "passed: ${c}"; return 1; }
        [[ "${output}" == *"only known when the command runs"* ]]
    done
}

@test "outgoing: a runtime body bound for this machine still passes" {
    bash_call "curl -s -d \"\$(cat body.txt)\" http://127.0.0.1:8766/hooks/event"
    passed
    bash_call "cat payload.json | curl -s --data-binary @- http://localhost:8766/hooks/event"
    passed
}

@test "outgoing: a fetch, the loopback host and a body without area text pass" {
    bash_call "curl -s https://example.com/'${CLIENT_TEXT// /%20}'"
    passed
    bash_call "curl -s -d '${CLIENT_TEXT}' http://127.0.0.1:8766/hooks/event"
    passed
    bash_call "curl -s -X POST -d 'ping' https://api.example.com/x"
    passed
}
