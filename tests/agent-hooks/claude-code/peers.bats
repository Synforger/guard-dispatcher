#!/usr/bin/env bats
# agent-hooks/claude-code/peers.py + outgoing.py (through area-guard.py) — a message to another
# agent session is judged by where that session has read; a local endpoint and a tmux session
# an agent must not type into are reached only by a line that names them.
#
# A throwaway HOME holds a company folder with a client inside it, each with one made-up
# document, and the files Claude Code keeps for its running sessions.

load ../../_internal/helpers

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

@test "peers: a session that has read inside the company and two of its clients takes the text of each" {
    printf '%s\n' 'beta ~/org/clients/beta' 'other ~/other' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/org/clients/beta" "${H}/other"
    printf '%s\n' "the beta rig idles at forty volts" > "${H}/org/clients/beta/brief.md"
    printf '%s\n' "the other client ships a pale blue enclosure next month" > "${H}/other/spec.md"
    session .claude-work many "55555555-5555-4555-8555-555555555555" company client beta
    for text in "${COMPANY_TEXT}" "${CLIENT_TEXT}" "the beta rig idles at forty volts"; do
        tell many "${text}"
        passed
    done
    # an area it has not read stays out, and a session that read one client still sits inside it
    tell many "the other client ships a pale blue enclosure next month"
    denied
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

@test "peers: a name of an area the receiver has not read inside is refused, in every direction" {
    tell plain "the acme tab asks for a fix"
    denied
    [[ "${output}" == *"names 1 area that session has not read inside"* ]]
    tell company "the acme tab asks for a fix"
    denied
    tell client "the acme tab asks for a fix"
    passed
    # the company around the client is where a client session works: its name tells it nothing new
    tell client "the org planning tab"
    passed
    tell plain "the org planning tab"
    denied
    # a Latin name is a whole word: a longer word holding it is not the name
    tell plain "the acmes of the season"
    passed
}

@test "peers: --covers says whether the receiver knows every area the sender has read inside" {
    run python3 "${PEERS}" --to plain --covers "${ID_CLIENT}"; [ "${status}" -eq 1 ]
    run python3 "${PEERS}" --to company --covers "${ID_CLIENT}"; [ "${status}" -eq 1 ]
    run python3 "${PEERS}" --to client --covers "${ID_CLIENT}"; [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to client --covers "${ID_COMPANY}"; [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to both --covers "${ID_CLIENT}"; [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to plain --covers "${ID_PLAIN}"; [ "${status}" -eq 0 ]
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
    [[ "${output}" == *": client text '"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "peers: not sent to session:${ID_PLAIN}"* ]]
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

@test "peers.py: what the operator typed goes only where the session it was typed in has read" {
    printf '%s\n' "fix the wrapped title, the client is waiting" > "${H}/said.txt"
    said() { run python3 "${PEERS}" --to "$2" --text "${H}/said.txt" --typed-in "$1"; }
    # typed in a session that has read nothing: it may go anywhere
    for to in "${ID_PLAIN}" "${ID_COMPANY}" "${ID_CLIENT}" "${ID_BOTH}"; do
        said "${ID_PLAIN}" "${to}"
        [ "${status}" -eq 0 ]
    done
    # typed inside the client: only to a session that has read inside the client too
    said "${ID_CLIENT}" "${ID_CLIENT}"
    [ "${status}" -eq 0 ]
    said "${ID_CLIENT}" "${ID_BOTH}"
    [ "${status}" -eq 0 ]
    said "${ID_CLIENT}" "${ID_PLAIN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"what the operator typed in a session that has read inside client"* ]]
    said "${ID_CLIENT}" "${ID_COMPANY}"
    [ "${status}" -eq 1 ]
    # typed in a session that has read both: not to one that has read only one of them
    said "${ID_BOTH}" "${ID_BOTH}"
    [ "${status}" -eq 0 ]
    said "${ID_BOTH}" "${ID_CLIENT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"read inside company goes only"* ]]
    said "${ID_BOTH}" "${ID_COMPANY}"
    [ "${status}" -eq 1 ]
    # sessions may be named, and the words are still scanned like any message
    said company both
    [ "${status}" -eq 0 ]
    said both plain
    [ "${status}" -eq 1 ]
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/said.txt"
    said "${ID_PLAIN}" "${ID_COMPANY}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"it carries text from a private area"* ]]
}

@test "send-scan: --session-areas judges a payload for a session, and several areas are a place inside each" {
    cat >> "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
other ~/other
AREAS
    mkdir -p "${H}/other"
    printf '%s\n' "the other client ships a pale blue enclosure next month" > "${H}/other/spec.md"
    printf '%s\n%s\n' "${CLIENT_TEXT}" "the other client ships a pale blue enclosure next month" > "${H}/message.txt"
    scan() { run python3 "${GUARD_ROOT}/scanners/destinations/send-scan.py" --dest session:x --text "${H}/message.txt" --session-areas "$1"; }
    scan "client,other"
    [ "${status}" -eq 0 ]
    scan "client"
    [ "${status}" -eq 1 ]
    # it says which run was hit, and the one line why stays the last line
    [[ "${output}" == *": other text '"*"pale blue enclosure"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "send-scan: not sent to session:x"* ]]
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

@test "local: a blocked endpoint is blocked by every name it answers to" {
    declare_also 'local:8766/pty/* block'
    local url
    for url in http://127.1:8766/pty/s/send http://2130706433:8766/pty/s/send http://0x7f.0.0.1:8766/pty/s/send \
               http://127.0.0.2:8766/pty/s/send http://localhost.:8766/pty/s/send http://a.localhost:8766/pty/s/send \
               http://0:8766/pty/s/send "http://$(hostname):8766/pty/s/send" http:/127.0.0.1:8766/pty/s/send \
               'http://[::ffff:127.0.0.1]:8766/pty/s/send' 'http://[0:0:0:0:0:0:0:1]:8766/pty/s/send' \
               http://127.0.0.1:8766/%70ty/s/send http://127.0.0.1:8766//pty/s/send http://127.0.0.1:8766/x/../pty/s/send; do
        bash_call "curl -s -X POST '${url}'"
        denied || { echo "not refused: ${url}"; return 1; }
    done
    bash_call "wget -q --post-data 'text=go' http://127.1:8766/pty/s/send"; denied
    bash_call "websocat ws://127.1:8766/pty/s/send"; denied
    bash_call "python3 -c 'import urllib.request as u; u.urlopen(\"http://[::1]:8766/pty/s/send\", b\"go\")'"; denied
    call WebFetch "$(jq -n '{url: "http://127.1:8766/pty/s/send", prompt: "read"}')"; denied
}

@test "local: a blocked endpoint is blocked however a name or a number of it is prepared" {
    declare_also 'local:8766/pty/* block' 'local:8766/tickets block'
    local url
    for url in $'http://local\u00adhost:8766/pty/s/send' $'http://local\u200bhost:8766/pty/s/send' \
               http://0127.0.0.1:8766/pty/s/send http://127.0x.0.1:8766/pty/s/send $'http://local\u3164host:8766/pty/s/send' \
               $'http://localho\ua7f1t:8766/pty/s/send' http://127.000.000.001:8766/pty/s/send http://127.0.0.1:8766/tickets/; do
        bash_call "curl -s -X POST '${url}'"
        denied || { echo "not refused: ${url}"; return 1; }
    done
    for url in $'http://127\u30020\u30020\u30021:8766/pty/s/send' 'http://127.0.0.1:8766\pty\s\send' \
               'http:127.0.0.1:8766/pty/s/send' 'http://me@127.1:8766/pty/s/send' 'http://[::1%25lo0]:8766/pty/s/send' 'http://[::1]:8766/tickets'; do
        bash_call "node -e 'fetch(\"${url}\")'"
        denied || { echo "not refused in code: ${url}"; return 1; }
    done
}

@test "local: an address no line blocks keeps the name it is written with" {
    declare_also 'local:8766/pty/* block'
    local url
    bash_call "node -e 'fetch(\"http://me@127.1:8766/sessions\")'"
    passed || { echo "refused in code"; echo "${output}"; return 1; }
    bash_call "curl -s $'http://\u4f8b\u3048.jp/pty/s/send'"
    passed || { echo "refused in code"; echo "${output}"; return 1; }
    for url in http://127.0.0.1:8766/sessions http://localhost:9999/pty/s/send 'http://[::1]:8766/agent-messages'; do
        bash_call "curl -s -X POST '${url}'"
        passed || { echo "refused: ${url}"; echo "${output}"; return 1; }
    done
    python3 - "${GUARD_ROOT}" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root / "agent-hooks/claude-code"))
import outgoing
scan = root / "scanners/destinations/send-scan.py"
for url, name in (("http://127.1:8766/sessions", "host:127.1"), ("https://example.com/pty/s", "host:example.com"),
                  ("http://127.0.0.1:8766/a%20b", "local:8766/a%20b"), ("http://localhost.example.com/pty/s", "host:localhost.example.com")):
    assert outgoing.place_of(url, scan) == name, (url, outgoing.place_of(url, scan))
PY
}

@test "local: a blocked endpoint is closed to reads through curl, wget, HTTPie, a listening client and code" {
    declare_also 'local:8766/tickets block' 'local:8766/tickets/* block' 'local:8766/stream/unified* block'
    bash_call "curl -s http://127.0.0.1:8766/tickets"
    denied
    [[ "${output}" == *"local:8766/tickets is blocked for sending and reading"* ]]
    bash_call "curl -s 'http://localhost:8766/tickets/t1?reader=ses_2'"
    denied
    bash_call "wget -qO- http://127.0.0.1:8766/tickets/t1"
    denied
    bash_call "http :8766/tickets"
    denied
    bash_call "xh GET http://127.0.0.1:8766/stream/unified"
    denied
    bash_call "curl -sN 'http://127.0.0.1:8766/stream/unified?channels=tickets'"
    denied
    bash_call "websocat ws://127.0.0.1:8766/stream/unified"
    denied
    bash_call "python3 -c 'import urllib.request as u; print(u.urlopen(\"http://127.0.0.1:8766/tickets\").read())'"
    denied
    # what no line names, and another port, still pass
    bash_call "curl -s http://127.0.0.1:8766/sessions"
    passed
    bash_call "http :8766/sessions"
    passed
    bash_call "curl -s http://127.0.0.1:9000/tickets"
    passed
}

@test "local: a WebFetch of an address on this machine is named by it when a line names it" {
    declare_also 'local:8766/tickets* block'
    call WebFetch "$(jq -n '{url: "http://127.0.0.1:8766/tickets", prompt: "list"}')"
    denied
    [[ "${output}" == *"local:8766/tickets is blocked for sending and reading"* ]]
    call WebFetch "$(jq -n '{url: "http://127.0.0.1:8766/sessions", prompt: "list"}')"
    passed
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

@test "local: a client's terminal socket is another endpoint: the line for its send call does not reach it" {
    socket() { bash_call "python3 -c 'import websockets.sync.client as w; w.connect(\"ws://localhost:8766/ws/pty/ses_1\").send(b\"go\")'"; }
    declare_also 'local:8766/pty/* block'
    socket
    passed
    bash_call "echo go | websocat ws://127.0.0.1:8766/ws/pty/ses_1"
    passed
    declare_also 'local:8766/ws/pty/* block'
    socket
    denied
    [[ "${output}" == *"local:8766/ws/pty/ses_1 is blocked for sending"* ]]
    bash_call "echo go | websocat ws://127.0.0.1:8766/ws/pty/ses_1"
    denied
    [[ "${output}" == *"not sent to local:8766/ws/pty/ses_1"* ]]
    bash_call "websocat -b ws://localhost:8766/ws/pty/ses_1 <<< go"
    denied
    [[ "${output}" == *"local:8766/ws/pty/ses_1 is blocked for sending"* ]]
    bash_call "wscat -c ws://127.0.0.1:8766/ws/pty/ses_1 -x '{\"type\": \"input\", \"data\": \"go\"}'"
    denied
    # with nothing to send, a client only listens: a reading call, and the blocked endpoint is closed to it
    bash_call "websocat ws://127.0.0.1:8766/ws/pty/ses_1"
    denied
    [[ "${output}" == *"local:8766/ws/pty/ses_1 is blocked for sending and reading"* ]]
    bash_call "websocat ws://127.0.0.1:8766/ws/other"
    passed
    bash_call "$(printf 'python3 - <<EOF\nimport websockets.sync.client as w\nw.connect("ws://127.0.0.1:8766/ws/pty/ses_1").send(b"go")\nEOF')"
    denied
    bash_call "curl -s -d '{\"text\": \"hello\"}' http://127.0.0.1:8766/agent-messages"
    passed
}

@test "tmux: a wrapped typing command is named alone by tmux:[?], since ? in a pattern is any one character" {
    fake_tmux
    declare_also 'tmux:[?] block'
    bash_call "tmux run-shell 'tmux send-keys -t agents-1 go Enter'"
    denied
    [[ "${output}" == *"tmux:? is blocked"* ]]
    bash_call "tmux send-keys -t agents-1 go Enter"
    passed
}

@test "send-scan: a name that stays on this machine is reached only by a line naming its kind" {
    where() { run python3 "${GUARD_ROOT}/scanners/destinations/send-scan.py" --where "$1"; }
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

# --- where a ticket sits: the places the client keeps its tickets in ---------------------------

# tickets_setup — a platform root (the place outside every area), and a place in each area: the
# company's and the client's (`<root>/tickets`).
tickets_setup() {
    export AGENT_PLATFORM_ROOT="${H}/platform"
    OUTSIDE_PLACE="${H}/platform/state/claude-pwa-client/tickets"
    COMPANY_PLACE="${H}/org/tickets"
    CLIENT_PLACE="${H}/org/clients/acme/tickets"
}

@test "peers.py --place-for: no area read sits in the platform's state, a chain of areas in the innermost one" {
    tickets_setup
    run python3 "${PEERS}" --place-for "${ID_PLAIN}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${OUTSIDE_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_COMPANY}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${COMPANY_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_CLIENT}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    # a session that has read inside the company and the client: the client lies inside the company
    run python3 "${PEERS}" --place-for "${ID_BOTH}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    # a session is named by its name as well
    run python3 "${PEERS}" --place-for client
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
}

@test "peers.py --place-for: the marks of the session the operator typed in count too" {
    tickets_setup
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --typed-in "${ID_CLIENT}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_COMPANY}" --typed-in "${ID_CLIENT}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --typed-in "${ID_PLAIN}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${OUTSIDE_PLACE}" ]
}

@test "peers.py --place-for: with --folder the areas holding the opening session's working folder count as read" {
    tickets_setup
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --folder "${H}/org/clients/acme"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --folder "${H}/org"
    [ "${status}" -eq 0 ]; [ "${output}" = "${COMPANY_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --folder "${H}/repos/tool"
    [ "${status}" -eq 0 ]; [ "${output}" = "${OUTSIDE_PLACE}" ]
    # the names the working folder's reads file gives are areas it may read, not ones it has read:
    # they do not count, a glob among them neither (it is no area's name)
    printf '%s\n' 'client   # the client these notes are about' 'cli*' > "${H}/repos/tool/guard-reads.txt"
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --folder "${H}/repos/tool"
    [ "${status}" -eq 0 ]; [ "${output}" = "${OUTSIDE_PLACE}" ]
    printf '%s\n' 'cli*' > "${H}/org/guard-reads.txt"
    run python3 "${PEERS}" --place-for "${ID_PLAIN}" --folder "${H}/org"
    [ "${status}" -eq 0 ]; [ "${output}" = "${COMPANY_PLACE}" ]
    # --covers-place still counts them, a glob standing for every area it matches
    run python3 "${PEERS}" --to "${ID_PLAIN}" --covers-place "${CLIENT_PLACE}" --folder "${H}/repos/tool"
    [ "${status}" -eq 0 ]
    # the session's own marks still count, and without --folder only they do
    run python3 "${PEERS}" --place-for "${ID_CLIENT}" --folder "${H}/org"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    run python3 "${PEERS}" --place-for "${ID_PLAIN}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${OUTSIDE_PLACE}" ]
}

@test "peers.py --place-for: two areas side by side inside a third sit in the place of the innermost one around them" {
    tickets_setup
    printf '%s\n' 'beta ~/org/clients/beta' 'deep ~/org/clients/beta/sub' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/org/clients/beta/sub"
    session .claude-work sides "88888888-8888-4888-8888-888888888888" client beta
    run python3 "${PEERS}" --place-for "88888888-8888-4888-8888-888888888888"
    [ "${status}" -eq 0 ]; [ "${output}" = "${COMPANY_PLACE}" ]
    # the company read as well changes nothing; a deeper area of one side neither
    session .claude-work all "99999999-9999-4999-8999-999999999999" company client beta deep
    run python3 "${PEERS}" --place-for "99999999-9999-4999-8999-999999999999"
    [ "${status}" -eq 0 ]; [ "${output}" = "${COMPANY_PLACE}" ]
    # two areas inside one client sit in that client's place, not the company's
    printf '%s\n' 'left ~/org/clients/acme/l' 'right ~/org/clients/acme/r' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/org/clients/acme/l" "${H}/org/clients/acme/r"
    session .claude-work pair "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" left right
    run python3 "${PEERS}" --place-for "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    [ "${status}" -eq 0 ]; [ "${output}" = "${CLIENT_PLACE}" ]
    # the session that opened it reads every boundary of that place, so it may add to it and pass it
    run python3 "${PEERS}" --to "88888888-8888-4888-8888-888888888888" --covers-place "${COMPANY_PLACE}"
    [ "${status}" -eq 0 ]
}

@test "peers.py --place-for: areas that do not lie one inside the next fit in no place, and exit 1 says so" {
    tickets_setup
    printf '%s\n' 'other ~/other' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/other"
    session .claude-work apart "55555555-5555-4555-8555-555555555555" client other
    run python3 "${PEERS}" --place-for "55555555-5555-4555-8555-555555555555"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"do not fit in one place"* ]]
    # the second session's marks join the first's: a company session and an unrelated area
    session .claude-work stray "66666666-6666-4666-8666-666666666666" other
    run python3 "${PEERS}" --place-for "${ID_CLIENT}" --typed-in "66666666-6666-4666-8666-666666666666"
    [ "${status}" -eq 1 ]
}

@test "peers.py --place-for: an area of several roots, or a root inside a git work tree, names its folder in tickets.txt" {
    tickets_setup
    printf '%s\n' 'shared ~/s1 ~/s2' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/s1" "${H}/s2/tix" "${H}/elsewhere" "${GUARD_CONFIG_DIR}/areas/shared"
    session .claude-work sharer "77777777-7777-4777-8777-777777777777" shared
    # two roots: no single `<root>/tickets`, and nothing declared
    run python3 "${PEERS}" --place-for "77777777-7777-4777-8777-777777777777"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"tickets.txt"* ]]
    # declared, with a comment and `~`
    printf '%s\n' '# where the tickets of shared sit' '~/s2/tix   # inside the second root' > "${GUARD_CONFIG_DIR}/areas/shared/tickets.txt"
    run python3 "${PEERS}" --place-for "77777777-7777-4777-8777-777777777777"
    [ "${status}" -eq 0 ]; [ "${output}" = "${H}/s2/tix" ]
    # a folder outside the area is no place of it
    printf '%s\n' '~/elsewhere' > "${GUARD_CONFIG_DIR}/areas/shared/tickets.txt"
    run python3 "${PEERS}" --place-for "77777777-7777-4777-8777-777777777777"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"not a folder in shared alone outside any git work tree"* ]]
    # nor is one inside a git work tree
    printf '%s\n' '~/s2/tix' > "${GUARD_CONFIG_DIR}/areas/shared/tickets.txt"
    mkdir "${H}/s2/.git"
    run python3 "${PEERS}" --place-for "77777777-7777-4777-8777-777777777777"
    [ "${status}" -eq 2 ]
}

@test "peers.py --place-for: a root that is a git work tree has no tickets folder of its own, and asks for tickets.txt" {
    tickets_setup
    mkdir "${H}/org/clients/acme/.git"
    run python3 "${PEERS}" --place-for "${ID_CLIENT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"client has a \`tickets\` folder that is not fit for it"* ]]
    [[ "${output}" == *"areas/client/tickets.txt"* ]]
    # the company's own folder is not inside it, so the company still has its place
    run python3 "${PEERS}" --place-for "${ID_COMPANY}"
    [ "${status}" -eq 0 ]; [ "${output}" = "${COMPANY_PLACE}" ]
}

@test "peers.py --place-for: a mark areas.txt no longer names, or no platform root, cannot be judged" {
    tickets_setup
    jq -n '{areas: ["retired"], tabs: {}}' > "${AREA_GUARD_STATE}/${ID_PLAIN}.json"
    run python3 "${PEERS}" --place-for "${ID_PLAIN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no longer names it"* ]]
    unset AGENT_PLATFORM_ROOT
    run python3 "${PEERS}" --place-for "${ID_COMPANY}"
    [ "${status}" -eq 0 ]
    session .claude-work fresh "88888888-8888-4888-8888-888888888888"
    run python3 "${PEERS}" --place-for "88888888-8888-4888-8888-888888888888"
    [ "${status}" -eq 2 ]
}

@test "peers.py --to-place: a copy of an area's document goes to the place of that area, not to a place outside" {
    tickets_setup
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/message.txt"
    run python3 "${PEERS}" --to-place "${OUTSIDE_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"peers: not sent to place:${OUTSIDE_PLACE}"* ]]
    run python3 "${PEERS}" --to-place "${COMPANY_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 1 ]
    run python3 "${PEERS}" --to-place "${CLIENT_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 0 ]; [ -z "${output}" ]
    # the company's text sits where the company's place is, not in the client's inside it
    printf '%s\n' "${COMPANY_TEXT}" > "${H}/message.txt"
    run python3 "${PEERS}" --to-place "${CLIENT_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 1 ]
    run python3 "${PEERS}" --to-place "${COMPANY_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to-place "${OUTSIDE_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 1 ]
    # words of the writer's own go anywhere, and so does a name nothing was read of
    printf '%s\n' "${OWN_TEXT}" > "${H}/message.txt"
    for place in "${OUTSIDE_PLACE}" "${COMPANY_PLACE}" "${CLIENT_PLACE}"; do
        run python3 "${PEERS}" --to-place "${place}" --text "${H}/message.txt"
        [ "${status}" -eq 0 ]
    done
    # the name of an area the place's boundaries lack is refused as for a session
    printf '%s\n' "the acme tab asks for a fix" > "${H}/message.txt"
    run python3 "${PEERS}" --to-place "${OUTSIDE_PLACE}" --text "${H}/message.txt"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"names 1 area that session has not read inside"* ]]
}

@test "peers.py --to-place: what the operator typed goes only to a place whose boundaries were all read where it was typed" {
    tickets_setup
    printf '%s\n' "fix the wrapped title, the client is waiting" > "${H}/said.txt"
    run python3 "${PEERS}" --to-place "${OUTSIDE_PLACE}" --text "${H}/said.txt" --typed-in "${ID_PLAIN}"
    [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to-place "${OUTSIDE_PLACE}" --text "${H}/said.txt" --typed-in "${ID_CLIENT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"goes only to a session that has read there too"* ]]
    run python3 "${PEERS}" --to-place "${COMPANY_PLACE}" --text "${H}/said.txt" --typed-in "${ID_CLIENT}"
    [ "${status}" -eq 1 ]
    run python3 "${PEERS}" --to-place "${CLIENT_PLACE}" --text "${H}/said.txt" --typed-in "${ID_CLIENT}"
    [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to-place "${CLIENT_PLACE}" --text "${H}/said.txt" --typed-in "${ID_BOTH}"
    [ "${status}" -eq 0 ]
}

@test "peers.py --covers-place: a session reads a place's boundaries by its marks, or by where its work folder reaches" {
    tickets_setup
    covers() { run python3 "${PEERS}" --to "$1" --covers-place "$2" "${@:3}"; }
    covers "${ID_CLIENT}" "${CLIENT_PLACE}"; [ "${status}" -eq 0 ]
    covers "${ID_BOTH}" "${CLIENT_PLACE}"; [ "${status}" -eq 0 ]
    covers "${ID_COMPANY}" "${CLIENT_PLACE}"; [ "${status}" -eq 1 ]
    covers "${ID_PLAIN}" "${CLIENT_PLACE}"; [ "${status}" -eq 1 ]
    covers "${ID_COMPANY}" "${COMPANY_PLACE}"; [ "${status}" -eq 0 ]
    covers "${ID_CLIENT}" "${COMPANY_PLACE}"; [ "${status}" -eq 0 ]
    # a place inside no area has no boundary to read
    covers "${ID_PLAIN}" "${OUTSIDE_PLACE}"; [ "${status}" -eq 0 ]
    # the folder a session works in reaches the areas around it
    covers "${ID_PLAIN}" "${CLIENT_PLACE}" --folder "${H}/org/clients/acme"; [ "${status}" -eq 0 ]
    covers "${ID_PLAIN}" "${CLIENT_PLACE}" --folder "${H}/repos/tool"; [ "${status}" -eq 1 ]
    # and so does a name its reads file gives
    printf '%s\n' 'client   # the client these notes are about' > "${H}/repos/tool/guard-reads.txt"
    covers "${ID_PLAIN}" "${CLIENT_PLACE}" --folder "${H}/repos/tool"; [ "${status}" -eq 0 ]
    covers "${ID_PLAIN}" "${COMPANY_PLACE}" --folder "${H}/repos/tool"; [ "${status}" -eq 0 ]
}

@test "peers.py --covers-place: with no --folder the folder the session's running record says it started in counts" {
    tickets_setup
    jq -n --arg i "99999999-9999-4999-8999-999999999999" --argjson p "$$" --arg c "${H}/org/clients/acme" \
        '{pid: $p, sessionId: $i, name: "started", cwd: $c}' > "${H}/.claude/sessions/started.json"
    run python3 "${PEERS}" --to "99999999-9999-4999-8999-999999999999" --covers-place "${CLIENT_PLACE}"
    [ "${status}" -eq 0 ]
    run python3 "${PEERS}" --to "${ID_PLAIN}" --covers-place "${CLIENT_PLACE}"
    [ "${status}" -eq 1 ]
}

@test "peers.py --places: every place there is, and with --session only those the session may read" {
    tickets_setup
    run python3 "${PEERS}" --places
    [ "${status}" -eq 0 ]
    [ "${output}" = "${OUTSIDE_PLACE}"$'\n'"${CLIENT_PLACE}"$'\n'"${COMPANY_PLACE}" ]
    run python3 "${PEERS}" --places --session "${ID_PLAIN}"
    [ "${output}" = "${OUTSIDE_PLACE}" ]
    run python3 "${PEERS}" --places --session "${ID_COMPANY}"
    [ "${output}" = "${OUTSIDE_PLACE}"$'\n'"${COMPANY_PLACE}" ]
    run python3 "${PEERS}" --places --session "${ID_CLIENT}"
    [ "${output}" = "${OUTSIDE_PLACE}"$'\n'"${CLIENT_PLACE}"$'\n'"${COMPANY_PLACE}" ]
    # an area whose place cannot be named is skipped, not an error
    printf '%s\n' 'shared ~/s1 ~/s2' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/s1" "${H}/s2"
    run python3 "${PEERS}" --places
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"s1"* ]]
}
