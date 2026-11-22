#!/usr/bin/env bats
# agent-hooks/claude-code/outgoing.py + destination_words.py (through area-guard.py) — the machine an
# address names is read from the address itself: the host is found whatever else the address carries,
# every host a curl pattern stands for is a destination, and an address whose host cannot be read is
# judged as a send to a destination that is not known.
#
# A throwaway HOME holds the destination lines; `blocked.example` and one endpoint of this machine are
# blocked, everything else is declared outside every area.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/repos/tool" "${GUARD_CONFIG_DIR}"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export GUARD_CORPUS_MAX_AGE=0
    printf 'company ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' 'host:blocked.example block' 'local:18999/api/*/input block' '* outside' \
        > "${GUARD_CONFIG_DIR}/destinations.txt"
}

bash_call() {
    local event
    event="$(jq -n --arg c "$1" --arg d "${H}/repos/tool" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }
blocked() { denied && [[ "${output}" == *"is blocked for sending"* ]]; }
not_known() { denied && [[ "${output}" == *"host:?"* ]]; }

# --- where the scheme is -----------------------------------------------------------------------

@test "destination reading: an address without a scheme is read by its head, whatever its query holds" {
    bash_call "curl -s -d x 'blocked.example/p?next=https://a.example'"
    blocked
    bash_call "curl -s -d x 'blocked.example:8080/p?next=https://a.example'"
    blocked
    bash_call "curl -s -d x 'fine.example/p?next=https://blocked.example'"
    passed
}

@test "destination reading: an endpoint of this machine is held when the address has no scheme and a query with one" {
    bash_call "curl -s 127.0.0.1:18999/api/s/input?next=https://a.example"
    denied
    [[ "${output}" == *"local:18999/api/s/input"* ]]
    bash_call "curl -s 'localhost:18999/api/s/input?next=https://a.example'"
    denied
    bash_call "curl -s 'localhost:18998/api/s/input?next=https://a.example'"
    passed
}

@test "destination reading: wget, HTTPie and a WebSocket client read an address by its head too" {
    bash_call "wget -q --post-data x 'blocked.example/p?next=https://a.example'"
    blocked
    bash_call "http POST 'blocked.example/p?next=https://a.example' a=b"
    blocked
    bash_call "websocat -t 'ws://blocked.example/p?next=https://a.example' <<< x"
    blocked
}

# --- the patterns curl expands -----------------------------------------------------------------

@test "destination reading: every host a range or a set stands for is a destination" {
    bash_call "curl -s -d x 'http://blocked.exampl[e-e]/p'"
    blocked
    bash_call "curl -s -d x 'http://{fine,blocked}.example/p'"
    blocked
    bash_call "curl -s -d x 'http://[a-c].blocked.example/p'"
    blocked
    bash_call "curl -s -d x 'http://{fine.example,x.example}/p'"
    passed
}

@test "destination reading: a pattern in the path or the query of a host out of this machine leaves the host as it is" {
    bash_call "curl -s -d x 'https://fine.example/img[1-5000].png'"
    passed
    bash_call "curl -s -d x 'https://fine.example/a?filter[name]=b'"
    passed
    bash_call "curl -s -d x 'https://blocked.example/img[1-5000].png'"
    blocked
}

@test "destination reading: a pattern curl takes no further is read as the address it is written with" {
    bash_call "curl -s -g -d x 'http://[::1]:18999/api/s/input'"
    denied
    bash_call "curl -s -d x 'http://[::1]:18999/api/s/input'"
    denied
    bash_call "curl -s -d x 'http://\\{blocked.example\\}/p'"
    passed
}

@test "destination reading: more hosts than can be listed are a destination that is not known" {
    bash_call "curl -s -d x 'http://h[1-5000].example/p'"
    not_known
    bash_call "curl -s -d x 'http://h[1-99999999999999].example/p'"
    not_known
    bash_call "curl -s -d x 'http://[a-z][a-z][a-z].example/p'"
    not_known
}

@test "destination reading: a host that is a pattern curl cannot expand is a destination that is not known" {
    bash_call "curl -s -d x 'http://h[x.example/p'"
    not_known
    bash_call "curl -s -d x 'http://{a,b.example/p'"
    not_known
}

@test "destination reading: with the pattern turned off the address is read as written" {
    bash_call "curl -s -g -d x 'http://blocked.exampl[e-e]/p'"
    passed
    bash_call "curl -s -d x -g 'http://blocked.example/p?a[1]=2'"
    blocked
}

# --- an address urlsplit refuses ---------------------------------------------------------------

@test "destination reading: the host is read from the address when its user information holds a character urlsplit refuses" {
    bash_call "curl -s -d x 'http://u＠x@blocked.example/p'"
    blocked
    bash_call "curl -s -d x 'http://u：x@blocked.example/p'"
    blocked
    bash_call "curl -s -d x 'http://u℀x@blocked.example/p'"
    blocked
    bash_call "curl -s -g -d x 'http://u[x@blocked.example/p'"
    blocked
    bash_call "curl -s -d x 'http://u＠x@fine.example/p'"
    passed
}

@test "destination reading: an endpoint of this machine is held when its user information holds such a character" {
    bash_call "curl -s 'http://u＠x@127.0.0.1:18999/api/s/input'"
    denied
    bash_call "curl -s -g 'http://u[x@127.0.0.1:18999/api/s/input'"
    denied
    bash_call "curl -s 'http://u＠x@127.0.0.1:18998/api/s/input'"
    passed
}

@test "destination reading: an address with no host that can be read is a destination that is not known" {
    bash_call "curl -s -g -d x 'http://[::1/p'"
    not_known
}

@test "destination reading: a word that is no address is no destination" {
    bash_call "curl -s -d '[1,2]' -H 'Content-Type: application/json' https://fine.example/p"
    passed
    bash_call "curl -s --data-raw '{\"a\":[1' https://fine.example/p"
    passed
    bash_call "curl -s -d x file:///etc/hosts"
    passed
}

@test "destination reading: a fetch with a read-only path to a host that is not blocked is still a reading" {
    bash_call "curl -s -X POST -d x 'https://fine.example/v1/search?next=https://a.example'"
    passed
}

# --- a remote path of scp and rsync --------------------------------------------------------------

@test "destination reading: a remote path with a scheme in its path is read by its head" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    bash_call "scp f.txt 'u@blocked.example:/tmp/x?next=https://a.example'"
    blocked
    bash_call "scp f.txt 'u@fine.example:/tmp/x?next=https://a.example'"
    passed
}

@test "destination reading: scp and rsync read a URL of their own whose user information holds such a character" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    bash_call "scp f.txt 'scp://u＠x@blocked.example/tmp/x'"
    blocked
    bash_call "rsync f.txt 'rsync://u＠x@blocked.example/mod'"
    blocked
}
