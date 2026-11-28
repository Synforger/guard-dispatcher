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

# judged <passed|denied> <command>... — run the hook on each command at once, each a call of its own.
judged() {
    local want="$1" n=0 command waited=() out="${BATS_TEST_TMPDIR}/answers"
    shift
    mkdir -p "${out}"
    for command in "$@"; do
        n=$((n + 1))
        jq -n --arg c "${command}" --arg d "${H}/repos/tool" \
            '{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}' \
            > "${out}/${n}.event"
        python3 "${HOOK}" < "${out}/${n}.event" > "${out}/${n}.answer" &
        waited+=($!)
    done
    for n in "${waited[@]}"; do wait "${n}" || return 1; done
    n=0
    for command in "$@"; do
        n=$((n + 1))
        output="$(cat "${out}/${n}.answer")" status=0
        "${want}" || { echo "not ${want}: ${command}"; echo "${output}"; return 1; }
    done
}

# places <command>... — the destination names the sends of each command are named by, one line a
# command (`-` for none), read in one process: a call through the hook takes a second each.
places() {
    run python3 - "${GUARD_ROOT}" "$@" <<'PY'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
hooks = root / "agent-hooks/claude-code"
sys.path.insert(0, str(hooks))
spec = importlib.util.spec_from_file_location("outgoing", hooks / "outgoing.py")
outgoing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(outgoing)
scan = root / "scanners/destinations/send-scan.py"
for command in sys.argv[2:]:
    names = sorted({send.dest for send in outgoing.sends("Bash", {"command": command}, "/", scan)})
    print(" ".join(names) or "-")
PY
    [ "${status}" -eq 0 ]
}

# --- where the scheme is -----------------------------------------------------------------------

@test "destination reading: an address without a scheme is read by its head, whatever its query holds" {
    bash_call "curl -s -d x 'blocked.example/p?next=https://a.example'"
    blocked
    places "curl -s -d x 'blocked.example:8080/p?next=https://a.example'" \
        "curl -s -d x 'fine.example/p?next=https://blocked.example'" \
        "wget -q --post-data x 'blocked.example/p?next=https://a.example'" \
        "http POST 'blocked.example/p?next=https://a.example' a=b" \
        "websocat -t 'ws://blocked.example/p?next=https://a.example' <<< x"
    [ "${lines[0]}" = "host:blocked.example" ]
    [ "${lines[1]}" = "host:fine.example" ]
    [ "${lines[2]}" = "host:blocked.example" ]
    [ "${lines[3]}" = "host:blocked.example" ]
    [ "${lines[4]}" = "host:blocked.example" ]
}

@test "destination reading: an endpoint of this machine is held when the address has no scheme and a query with one" {
    bash_call "curl -s 127.0.0.1:18999/api/s/input?next=https://a.example"
    denied
    [[ "${output}" == *"local:18999/api/s/input"* ]]
    places "curl -s 'localhost:18999/api/s/input?next=https://a.example'" \
        "curl -s 'localhost:18998/api/s/input?next=https://a.example'"
    [ "${lines[0]}" = "local:18999/api/s/input" ]
    [ "${lines[1]}" = "local:18998/api/s/input" ]
}

# --- the patterns curl expands -----------------------------------------------------------------

@test "destination reading: every host a range or a set stands for is a destination" {
    bash_call "curl -s -d x 'http://blocked.exampl[a-z]/p'"
    blocked
    places "curl -s -d x 'http://{fine,blocked}.example/p'" \
        "curl -s -d x 'http://blocked.exampl[e-e]/p'" \
        "curl -s -d x 'http://{fine.example,x.example}/p'" \
        "curl -s -d x 'http://h[01-03].example/p'" \
        "curl -s -d x 'http://h[1-9:4].example/p'"
    [ "${lines[0]}" = "host:blocked.example host:fine.example" ]
    [ "${lines[1]}" = "host:blocked.example" ]
    [ "${lines[2]}" = "host:fine.example host:x.example" ]
    [ "${lines[3]}" = "host:h01.example host:h02.example host:h03.example" ]
    [ "${lines[4]}" = "host:h1.example host:h5.example host:h9.example" ]
}

@test "destination reading: a pattern in the path or the query of a host out of this machine leaves the host as it is" {
    places "curl -s -d x 'https://fine.example/img[1-5000].png'" \
        "curl -s -d x 'https://fine.example/a?filter[name]=b'" \
        "curl -s -d x 'https://blocked.example/img[1-5000].png'"
    [ "${lines[0]}" = "host:fine.example" ]
    [ "${lines[1]}" = "host:fine.example" ]
    [ "${lines[2]}" = "host:blocked.example" ]
}

@test "destination reading: a pattern curl takes no further is read as the address it is written with" {
    places "curl -s -d x 'http://[::1]:18999/api/s/input'" \
        "curl -s -g -d x 'http://[::1]:18999/api/s/input'" \
        "curl -s -d x 'http://\\{blocked.example\\}/p'"
    [ "${lines[0]}" = "local:18999/api/s/input" ]
    [ "${lines[1]}" = "local:18999/api/s/input" ]
    [ "${lines[2]}" = "host:{blocked.example}" ]
}

@test "destination reading: more hosts than can be listed are a destination that is not known" {
    bash_call "curl -s -d x 'http://h[1-5000].example/p'"
    not_known
    places "curl -s -d x 'http://h[1-99999999999999].example/p'" \
        "curl -s -d x 'http://[a-z][a-z][a-z].example/p'" \
        "curl -s -d x 'http://127.0.0.1:18999/[1-5000]'"
    [ "${lines[0]}" = "host:?" ]
    [ "${lines[1]}" = "host:?" ]
    [ "${lines[2]}" = "host:?" ]
}

@test "destination reading: a host that is a pattern curl cannot expand is a destination that is not known" {
    places "curl -s -d x 'http://h[x.example/p'" \
        "curl -s -d x 'http://{a,b.example/p'" \
        "curl -s -d x 'http://h{}.example/p'" \
        "curl -s -d x 'http://h[3-1].example/p'"
    [ "${lines[0]}" = "host:?" ]
    [ "${lines[1]}" = "host:?" ]
    [ "${lines[2]}" = "host:?" ]
    [ "${lines[3]}" = "host:?" ]
}

@test "destination reading: with the pattern turned off the address is read as written" {
    places "curl -s -g -d x 'http://blocked.exampl[e-e]/p'" \
        "curl -s -d x -g 'http://blocked.example/p?a[1]=2'" \
        "curl -s -g -d x --next -d y 'http://blocked.exampl[e-e]/p'"
    [ "${lines[0]}" = "host:blocked.exampl[e-e]" ]
    [ "${lines[1]}" = "host:blocked.example" ]
    [ "${lines[2]}" = "host:blocked.exampl[e-e] host:blocked.example" ]
}

# --- an address urlsplit refuses ---------------------------------------------------------------

@test "destination reading: the host is read from the address when its user information holds a character urlsplit refuses" {
    bash_call "curl -s -d x 'http://u＠x@blocked.example/p'"
    blocked
    places "curl -s -d x 'http://u：x@blocked.example/p'" \
        "curl -s -d x 'http://u℀x@blocked.example/p'" \
        "curl -s -g -d x 'http://u[x@blocked.example/p'" \
        "curl -s -d x 'http://u＠x@fine.example:8080/p'" \
        "wget -q --post-data x 'http://u＠x@blocked.example/p'"
    [ "${lines[0]}" = "host:blocked.example" ]
    [ "${lines[1]}" = "host:blocked.example host:ua" ]      # and as the text reads once a client prepares it
    [ "${lines[2]}" = "host:blocked.example" ]
    [ "${lines[3]}" = "host:fine.example" ]
    [ "${lines[4]}" = "host:blocked.example" ]
}

@test "destination reading: an endpoint of this machine is held when its user information holds such a character" {
    bash_call "curl -s 'http://u＠x@127.0.0.1:18999/api/s/input'"
    denied
    places "curl -s -g 'http://u[x@127.0.0.1:18999/api/s/input'" \
        "curl -s 'http://u＠x@127.0.0.1:18998/api/s/input'"
    [ "${lines[0]}" = "local:18999/api/s/input" ]
    [ "${lines[1]}" = "local:18998/api/s/input" ]
}

@test "destination reading: an address with no host that can be read is a destination that is not known" {
    bash_call "curl -s -g -d x 'http://[::1/p'"
    not_known
}

@test "destination reading: a word that is no address is no destination" {
    places "curl -s -d '[1,2]' -H 'Content-Type: application/json' https://fine.example/p" \
        "curl -s --data-raw '{\"a\":[1' https://fine.example/p" \
        "curl -s -d x file:///etc/hosts"
    [ "${lines[0]}" = "host:fine.example" ]
    [ "${lines[1]}" = "host:fine.example" ]
    [ "${lines[2]}" = "-" ]
}

@test "destination reading: a send to a host that is not blocked passes, a search by POST among them" {
    bash_call "curl -s -X POST -d x 'https://fine.example/v1/search?next=https://a.example'"
    passed
    bash_call "curl -s -d x 'https://fine.example/img[1-5000].png'"
    passed
}

# --- a remote path of scp and rsync --------------------------------------------------------------

@test "destination reading: a remote path with a scheme in its path is read by its head" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    places "scp f.txt 'u@blocked.example:/tmp/x?next=https://a.example'" \
        "scp f.txt 'u@fine.example:/tmp/x?next=https://a.example'"
    [ "${lines[0]}" = "host:blocked.example:/tmp/x?next=https://a.example" ]
    [ "${lines[1]}" = "host:fine.example:/tmp/x?next=https://a.example" ]
}

@test "destination reading: scp and rsync read a URL of their own whose user information holds such a character" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    bash_call "scp f.txt 'scp://u＠x@blocked.example/tmp/x'"
    blocked
    bash_call "rsync f.txt 'rsync://u＠x@blocked.example/mod'"
    blocked
}

# --- a machine or a source a variable names -----------------------------------------------------

@test "destination reading: a variable the command line sets to a literal is written out in scp, rsync and ssh" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    places 'H=blocked.example; scp f.txt "u@$H:/tmp/x"' \
        'H=blocked.example; rsync f.txt "$H:/tmp/x"' \
        'H=blocked.example; ssh "$H" ls' \
        'H=blocked.example && ssh -p 22 u@${H} ls /tmp'
    [ "${lines[0]}" = "host:blocked.example:/tmp/x" ]
    [ "${lines[1]}" = "host:blocked.example:/tmp/x" ]
    [ "${lines[2]}" = "host:blocked.example" ]
    [ "${lines[3]}" = "host:blocked.example" ]
    bash_call 'H=blocked.example; scp f.txt "u@$H:/tmp/x"'
    blocked
}

@test "destination reading: the file an scp sends is read when a variable the command line set names it" {
    printf '%s\n' "${SENTINEL}" > "${H}/repos/tool/f.txt"
    bash_call 'F=f.txt; scp "$F" u@fine.example:/tmp/x'
    denied
    [[ "${output}" == *"flagged identifier"* ]]
}

@test "destination reading: a machine or a source only known as the command runs is a destination that is not known" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    places 'scp f.txt "u@$H:/tmp/x"' \
        'H=a.example; H=b.example; ssh "$H" ls' \
        'scp "$F" u@fine.example:/tmp/x' \
        'scp f.txt u@fine.example:"$DIR/x"'
    [ "${lines[0]}" = "host:?" ]
    [ "${lines[1]}" = "host:?" ]
    [ "${lines[2]}" = "host:fine.example:/tmp/x" ]
    [[ "${lines[3]}" == "host:fine.example:"* ]]
    bash_call 'scp "$F" u@fine.example:/tmp/x'
    denied
    [[ "${output}" == *"only known when the command runs"* ]]
    bash_call 'scp f.txt "u@$H:/tmp/x"'
    denied
}

@test "destination reading: only a word the shell fills in is filled, and it keeps the quoting it was typed with" {
    printf 'x\n' > "${H}/repos/tool/a[1].txt"
    judged passed "scp 'a[1].txt' u@fine.example:/tmp/x" 'D=.; scp "$D/a[1].txt" u@fine.example:/tmp/x'
}

@test "destination reading: a file named from \$HOME or \$PWD is read where it is" {
    printf 'x\n' > "${H}/clean.txt"
    printf '%s\n' "${SENTINEL}" > "${H}/marked.txt"
    printf 'x\n' > "${H}/repos/tool/f.txt"
    judged passed 'scp "$HOME/clean.txt" u@fine.example:/tmp/x' 'rsync -a "$PWD/f.txt" u@fine.example:/tmp/x'
    # a folder the line moved to, and a name the line sets another way, stay unknown
    judged denied 'cd .. && scp "$PWD/f.txt" u@fine.example:/tmp/x' \
        'HOME=$(pwd); scp "$HOME/clean.txt" u@fine.example:/tmp/x'
    bash_call 'scp "${HOME}/marked.txt" u@fine.example:/tmp/x'
    denied
    [[ "${output}" == *"flagged identifier"* ]]
}

@test "destination reading: a value built from \$HOME or \$PWD is written out" {
    mkdir -p "${H}/notes"
    printf 'x\n' > "${H}/notes/clean.txt"
    printf '%s\n' "${SENTINEL}" > "${H}/notes/marked.txt"
    printf 'x\n' > "${H}/repos/tool/f.txt"
    judged passed 'D=$HOME; scp "$D/notes/clean.txt" u@fine.example:/tmp/x' \
        'D="$HOME/notes"; scp "$D/clean.txt" u@fine.example:/tmp/x' \
        'D=${HOME}/notes; scp "${D}/clean.txt" u@fine.example:/tmp/x' \
        'D=$PWD; rsync -a "$D/f.txt" u@fine.example:/tmp/x'
    # single quotes keep the name as text, and a folder the line moved to stays unknown
    judged denied "D='\$HOME'; scp \"\$D/notes/clean.txt\" u@fine.example:/tmp/x" \
        'cd .. && D=$PWD; scp "$D/f.txt" u@fine.example:/tmp/x' \
        'HOME=$(pwd); D=$HOME; scp "$D/notes/clean.txt" u@fine.example:/tmp/x'
    bash_call 'D=$HOME/notes; scp "$D/marked.txt" u@fine.example:/tmp/x'
    denied
    [[ "${output}" == *"flagged identifier"* ]]
}

@test "destination reading: a copy to a folder a variable names stays a copy on this machine" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    places 'rsync -a f.txt "$d/"' \
        'd=$(mktemp -d); rsync -a f.txt "$d/"' \
        'rsync -a "$SRC/" "$DST/"' \
        'scp f.txt "$DEST"' \
        'scp u@fine.example:/tmp/x "$d/"'
    for line in 0 1 2 3 4; do [ "${lines[line]}" = "-" ] || { echo "${line}: ${lines[line]}"; return 1; }; done
    # a `:` inside the shell's own expansion is not the one of a remote path
    judged passed 'rsync -a f.txt "${d:-/tmp}/x"' 'rsync -a f.txt "$(date +%H:%M)/x"'
}

@test "destination reading: a remote path whose machine a variable names is a destination that is not known" {
    printf 'x\n' > "${H}/repos/tool/f.txt"
    places 'rsync f.txt "$H::module"' \
        'rsync f.txt "${H:-a.example}:x"' \
        'scp f.txt "$(cat host.txt):/tmp/x"'
    [ "${lines[0]}" = "host:?" ]
    [ "${lines[1]}" = "host:?" ]
    [ "${lines[2]}" = "host:?" ]
}

# --- what the shell or a placeholder fills in -----------------------------------------------------

@test "destination reading: the shell's own expansions and a lone {} after the host are no pattern of curl" {
    judged passed 'curl -s "http://127.0.0.1:18998/items/${ids[0]}"' \
        "curl -s \"http://127.0.0.1:18998/items/\$(jq -r '.[0]' f.json)\"" \
        'seq 3 | xargs -I{} curl -s http://127.0.0.1:18998/api/{}'
    # an endpoint a line closes stays closed with them in its path
    judged denied 'seq 3 | xargs -I{} curl -s http://127.0.0.1:18999/api/{}/input' \
        'curl -s "http://127.0.0.1:18999/api/${ids[0]}/input"'
    # and the patterns beside them are still read
    places "curl -s -d x \"http://{fine,blocked}.example/\$(date +%s)\""
    [ "${lines[0]}" = "host:blocked.example host:fine.example" ]
}
