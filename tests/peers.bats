#!/usr/bin/env bats
# agent-hooks/claude-code/peers.py + outgoing.py (through area-guard.py) — a message to another
# agent session is judged by where that session has read; a local endpoint and a tmux session
# an agent must not type into are reached only by a line that names them.
#
# A throwaway HOME holds a company folder with a client inside it, each with one made-up
# document, and the files Claude Code keeps for its running sessions.

load helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
PEERS="${GUARD_ROOT}/agent-hooks/claude-code/peers.py"
CLIENT_TEXT="the calibration table reads seventeen at dawn"
COMPANY_TEXT="quarterly planning keeps the bench schedule"
OWN_TEXT="the page builder drops the last row when a title wraps"
ID_PLAIN="11111111-1111-4111-8111-111111111111"
ID_COMPANY="22222222-2222-4222-8222-222222222222"
ID_CLIENT="33333333-3333-4333-8333-333333333333"
ID_BOTH="44444444-4444-4444-8444-444444444444"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme/received" "${H}/org/meetings" "${H}/repos/tool" "${GUARD_CONFIG_DIR}" "${H}/bin"
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/org/clients/acme/received/notes.md"
    printf '%s\n' "${COMPANY_TEXT}" > "${H}/org/meetings/plan.md"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export GUARD_CORPUS_MAX_AGE=0
    unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org
client  ~/org/clients/acme
AREAS
    printf '%s\n' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
    # Four sessions run here, under two accounts: one that has read nothing, one that has read
    # inside the company, one inside the client, one inside both.
    session .claude      plain    "${ID_PLAIN}"
    session .claude-work company  "${ID_COMPANY}" company
    session .claude-work client   "${ID_CLIENT}"  client
    session .claude-work both     "${ID_BOTH}"    company client
}

# session <config dir> <name> <id> [area ...] — a running session and what it has read inside.
session() {
    local dir="$1" name="$2" id="$3"
    shift 3
    mkdir -p "${H}/${dir}/sessions" "${AREA_GUARD_STATE}"
    jq -n --arg n "${name}" --arg i "${id}" --argjson p "${PID:-$$}" '{pid: $p, sessionId: $i, name: $n}' \
        > "${H}/${dir}/sessions/${name}-${RANDOM}.json"
    [ "$#" -eq 0 ] || jq -n '{areas: $ARGS.positional, tabs: {}}' --args "$@" > "${AREA_GUARD_STATE}/${id}.json"
}

# call <tool> <input json> — run the hook on one tool call of session s1.
call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}/repos/tool" --arg p "${H}/.claude/projects/tool/s1.jsonl" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse", transcript_path: $p}')"
    run python3 "${HOOK}" <<< "${event}"
}
tell() { call SendMessage "$(jq -n --arg to "$1" --arg m "$2" '{to: $to, message: $m}')"; }
bash_call() { call Bash "$(jq -n --arg c "$1" '{command: $c}')"; }
declare_also() { printf '%s\n' "$@" '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

# --- a message to another session ---------------------------------------------------------

@test "peers: a session that has read nothing takes no area's text, and takes words of the sender's own" {
    tell plain "seen here: ${CLIENT_TEXT}"
    denied
    [[ "${output}" == *"session:plain (a session that has read inside no area)"* ]]
    tell plain "seen here: ${COMPANY_TEXT}"
    denied
    tell plain "${OWN_TEXT}"
    passed
}

@test "peers: a session that has read inside the company takes the company's text, not the client's" {
    tell company "${COMPANY_TEXT}"
    passed
    tell company "${CLIENT_TEXT}"
    denied
    [[ "${output}" == *"a session that has read inside company"* ]]
}

@test "peers: a session that has read inside the client takes the client's text, not the company's around it" {
    tell client "${CLIENT_TEXT}"
    passed
    tell client "${COMPANY_TEXT}"
    denied
    tell both "${CLIENT_TEXT}"
    passed
    tell both "${COMPANY_TEXT}"
    denied
}

@test "peers: every direction passes in words of the sender's own, whatever the sender has read" {
    jq -n '{areas: ["client", "company"], tabs: {}}' > "${AREA_GUARD_STATE}/s1.json"
    for to in plain company client both; do
        tell "${to}" "${OWN_TEXT}"
        passed
    done
}

@test "peers: no word list applies to a session: only the operator's agents read the message" {
    tell plain "ask ${SENTINEL} about the build"
    passed
    call mcp__acme__drive_upload_file "$(jq -n --arg t "ask ${SENTINEL} about the build" '{text: $t}')"
    denied
}

@test "peers: a name with its ref names the same session" {
    tell "plain [3fa9c1]" "${CLIENT_TEXT}"
    denied
    tell "company [7c41e2]" "${COMPANY_TEXT}"
    passed
}

@test "peers: two sessions of one name must each take the message" {
    session .claude company "55555555-5555-4555-8555-555555555555"
    tell company "${COMPANY_TEXT}"
    denied
    tell company "${OWN_TEXT}"
    passed
}

@test "peers: a name no running session carries is a session elsewhere: it has read nothing" {
    tell elsewhere "${COMPANY_TEXT}"
    denied
    [[ "${output}" == *"No session running on this machine has that name"* ]]
    tell elsewhere "${OWN_TEXT}"
    passed
    # a session that has ended no longer carries its name
    ( : ) &
    local gone=$!
    wait "${gone}"
    PID="${gone}" session .claude-work ended "66666666-6666-4666-8666-666666666666" company
    tell ended "${COMPANY_TEXT}"
    denied
}

@test "peers: main and the session's own subagent are inside the session" {
    tell main "${CLIENT_TEXT}"
    passed
    mkdir -p "${H}/.claude/projects/tool/s1/subagents"
    : > "${H}/.claude/projects/tool/s1/subagents/agent-a1b2c3d4e5f600718.jsonl"
    tell a1b2c3d4e5f600718 "${CLIENT_TEXT}"
    passed
    tell a0000000000000000 "${CLIENT_TEXT}"
    denied
}

@test "peers: a message with no text sends nothing" {
    call SendMessage "$(jq -n '{to: "plain", notify_when_idle: true}')"
    passed
    call SendMessage "$(jq -n '{to: "plain", message: "  "}')"
    passed
}

@test "peers: marks kept in the older form are read, and a mark areas.txt no longer names cannot be judged" {
    printf '["company"]' > "${AREA_GUARD_STATE}/${ID_PLAIN}.json"
    tell plain "${COMPANY_TEXT}"
    passed
    jq -n '{areas: ["retired"], tabs: {}}' > "${AREA_GUARD_STATE}/${ID_PLAIN}.json"
    tell plain "${OWN_TEXT}"
    denied
    [[ "${output}" == *"no longer names"* ]]
}

@test "peers: on a machine with no areas a message passes" {
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    tell plain "${CLIENT_TEXT}"
    passed
}

# --- the entry point a relaying client calls ----------------------------------------------

@test "peers.py: judges a message to a session named by its id, running or not" {
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/message.txt"
    run python3 "${PEERS}" --to "${ID_PLAIN}" --text "${H}/message.txt"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"peers: not sent to session:${ID_PLAIN}"* ]]
    run python3 "${PEERS}" --to "${ID_CLIENT}" --text "${H}/message.txt"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    rm "${H}"/.claude-work/sessions/client-*.json
    run python3 "${PEERS}" --to "${ID_CLIENT}" --text "${H}/message.txt"
    [ "${status}" -eq 0 ]
    printf '%s\n' "${OWN_TEXT}" > "${H}/message.txt"
    run python3 "${PEERS}" --to "${ID_PLAIN}" --text "${H}/message.txt"
    [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to plain --text "${H}/message.txt"
    [ "${status}" -eq 0 ]
}

@test "send-scan: --session-areas judges a payload for a session, and several areas are a place inside each" {
    cat >> "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
other ~/other
AREAS
    mkdir -p "${H}/other"
    printf '%s\n' "the other client ships a pale blue enclosure next month" > "${H}/other/spec.md"
    printf '%s\n%s\n' "${CLIENT_TEXT}" "the other client ships a pale blue enclosure next month" > "${H}/message.txt"
    scan() { run python3 "${GUARD_ROOT}/scanners/send-scan.py" --dest session:x --text "${H}/message.txt" --session-areas "$1"; }
    scan "client,other"
    [ "${status}" -eq 0 ]
    scan "client"
    [ "${status}" -eq 1 ]
    scan "other"
    [ "${status}" -eq 1 ]
    scan ""
    [ "${status}" -eq 1 ]
    scan "client,nowhere"
    [ "${status}" -eq 2 ]
}

# --- a service on this machine ------------------------------------------------------------

@test "local: a service on this machine is no send, whatever a catch-all line says" {
    bash_call "curl -s -d '${CLIENT_TEXT}' http://127.0.0.1:8766/pty/ses_1/send"
    passed
    bash_call "curl -s -X POST http://localhost:8766/pty/ses_1/send"
    passed
}

@test "local: an endpoint the operator blocks is refused through curl, wget, HTTPie and code" {
    declare_also 'local:8766/pty/* block'
    bash_call "curl -s -d '{\"text\": \"go\", \"enter\": true}' http://127.0.0.1:8766/pty/ses_1/send"
    denied
    [[ "${output}" == *"local:8766/pty/ses_1/send is blocked for sending"* ]]
    bash_call "curl -s -X POST http://localhost:8766/pty/ses_1/send-raw-key"
    denied
    bash_call "wget -q --post-data 'text=go' http://127.0.0.1:8766/pty/ses_1/send"
    denied
    bash_call "http POST :8766/pty/ses_1/send text=go"
    denied
    bash_call "python3 -c 'import urllib.request as u; u.urlopen(\"http://127.0.0.1:8766/pty/ses_1/send\", b\"go\")'"
    denied
    bash_call "$(printf 'python3 - <<EOF\nimport urllib.request as u\nu.urlopen("http://127.0.0.1:8766/pty/" + sid + "/send", b"go")\nEOF')"
    denied
}

@test "local: a blocked endpoint leaves the rest of the service, and another port, alone" {
    declare_also 'local:8766/pty/* block'
    bash_call "curl -s -d '{\"text\": \"hello\"}' http://127.0.0.1:8766/sessions/ses_1/agent-message"
    passed
    bash_call "curl -s http://127.0.0.1:8766/sessions"
    passed
    bash_call "curl -s -d 'go' http://127.0.0.1:9000/pty/ses_1/send"
    passed
    bash_call "curl -s -d 'go' http://127.0.0.1/pty/ses_1/send"
    passed
}

@test "send-scan: a name that stays on this machine is reached only by a line naming its kind" {
    where() { run python3 "${GUARD_ROOT}/scanners/send-scan.py" --where "$1"; }
    where local:8766/pty/ses_1/send
    [ "${output}" = "undeclared" ]
    where tmux:agents-1
    [ "${output}" = "undeclared" ]
    declare_also 'local:8766/pty/* block' 'tmux:agents-* block'
    where local:8766/pty/ses_1/send
    [ "${output}" = "block" ]
    where tmux:agents-1
    [ "${output}" = "block" ]
    where tmux:build
    [ "${output}" = "undeclared" ]
    where host:example.com
    [ "${output}" = "outside" ]
}

# --- typing into a tmux session -----------------------------------------------------------

# A stand-in tmux: it answers which session a target is in, from a table of `target session`
# lines, as tmux resolves a pane id, a prefix or the pane a command runs in.
fake_tmux() {
    printf '%s\n' "$@" > "${H}/tmux-targets"
    cat > "${H}/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
target=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t) target="$2"; shift ;;
    esac
    shift
done
while read -r name session; do
    if [ "${name}" = "${target}" ]; then
        printf '%s\n' "${session}"
        exit 0
    fi
done < "${HOME}/tmux-targets"
exit 1
TMUX
    chmod +x "${H}/bin/tmux"
    export PATH="${H}/bin:${PATH}"
}

@test "tmux: typing into a session is no send until a line names it" {
    fake_tmux 'agents-1 agents-1'
    bash_call "tmux send-keys -t agents-1 'go ahead' Enter"
    passed
    declare_also 'tmux:agents-* block'
    bash_call "tmux send-keys -t agents-1 'go ahead' Enter"
    denied
    [[ "${output}" == *"tmux:agents-1 is blocked for sending"* ]]
    bash_call "tmux list-sessions"
    passed
    bash_call "tmux capture-pane -p -t agents-1"
    passed
}

@test "tmux: the session is the one tmux resolves: a pane id, a prefix, a window, the pane the command runs in" {
    fake_tmux '%7 agents-1' 'age agents-1' 'agents-1:0.1 agents-1' '=agents-1 agents-1' '%9 build'
    declare_also 'tmux:agents-* block'
    for target in '%7' age agents-1:0.1 '=agents-1'; do
        bash_call "tmux send-keys -t '${target}' go Enter"
        denied
    done
    bash_call "tmux send-keys -tage go Enter"
    denied
    export TMUX_PANE='%7'
    bash_call "tmux send-keys go Enter"
    denied
    export TMUX_PANE='%9'
    bash_call "tmux send-keys go Enter"
    passed
    bash_call "tmux send-keys -t '%9' go Enter"
    passed
}

@test "tmux: every command that types is read, with tmux's own options before it" {
    fake_tmux 'agents-1 agents-1'
    declare_also 'tmux:agents-* block'
    for typing in "send -t agents-1 go" "send-prefix -t agents-1" "paste-buffer -b note -t agents-1" \
                  "pasteb -t agents-1" "pipe-pane -I -t agents-1 'cat note.txt'" "send-keys -l -t agents-1 go"; do
        bash_call "tmux ${typing}"
        denied
        bash_call "tmux -L work -f /dev/null ${typing}"
        denied
    done
    bash_call "tmux new-window -d \\; send-keys -t agents-1 go Enter"
    denied
    bash_call "true && tmux send-keys -t agents-1 go Enter"
    denied
}

@test "tmux: a target tmux cannot resolve is named as spelled; a typing command wrapped in another is tmux:?" {
    fake_tmux
    declare_also 'tmux:agents-* block'
    bash_call "tmux send-keys -t agents-9:0 go Enter"
    denied
    bash_call "tmux send-keys -t '=agents-9' go Enter"
    denied
    bash_call "tmux run-shell 'tmux send-keys -t agents-1 go Enter'"
    passed
    declare_also 'tmux:* block'
    bash_call "tmux run-shell 'tmux send-keys -t agents-1 go Enter'"
    denied
    [[ "${output}" == *"tmux:? is blocked"* ]]
    bash_call "tmux if-shell true 'send-keys -t agents-1 go Enter'"
    denied
    bash_call "tmux send-keys go Enter"
    denied
}
