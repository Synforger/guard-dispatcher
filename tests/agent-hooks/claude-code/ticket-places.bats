#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + ticket_places.py — the folders a client keeps its tickets
# in are written by the client alone: an agent's Write, Edit and shell writes there are refused,
# reads pass, and `peers.py --places` is asked with a session or not at all.
#
# A throwaway HOME holds a company folder with a client inside it, and a platform root; a ticket
# folder sits outside every area, in the company and in the client.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
PEERS="${GUARD_ROOT}/agent-hooks/claude-code/peers.py"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme" "${H}/repos/tool" "${GUARD_CONFIG_DIR}" "${H}/platform/state/claude-pwa-client/tickets"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export AGENT_PLATFORM_ROOT="${H}/platform"
    export GUARD_CORPUS_MAX_AGE=0
    unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE
    printf '%s\n' 'company ~/org' 'client  ~/org/clients/acme' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
    OUTSIDE_PLACE="${H}/platform/state/claude-pwa-client/tickets"
    CLIENT_PLACE="${H}/org/clients/acme/tickets"
    COMPANY_PLACE="${H}/org/tickets"
    mkdir -p "${CLIENT_PLACE}" "${COMPANY_PLACE}"
}

call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}/repos/tool" --arg p "${H}/.claude/projects/tool/s1.jsonl" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse", transcript_path: $p}')"
    run python3 "${HOOK}" <<< "${event}"
}
bash_call() { call Bash "$(jq -n --arg c "$1" '{command: $c}')"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }
says_tabs() { [[ "${output}" == *'a ticket is written with `tabs ticket`'* ]]; }

# --- a direct write into a tickets folder ------------------------------------------------------

@test "tickets: a Write, an Edit and a NotebookEdit into a tickets folder are refused, whichever folder it is" {
    for place in "${OUTSIDE_PLACE}" "${CLIENT_PLACE}" "${COMPANY_PLACE}"; do
        call Write "$(jq -n --arg f "${place}/t-1.jsonl" '{file_path: $f, content: "{}"}')"
        denied; says_tabs
        call Edit "$(jq -n --arg f "${place}/t-1.jsonl" '{file_path: $f, old_string: "a", new_string: "b"}')"
        denied; says_tabs
        call NotebookEdit "$(jq -n --arg f "${place}/n.ipynb" '{notebook_path: $f, new_source: "x"}')"
        denied
    done
}

@test "tickets: a write in a folder of the tickets folder is refused too, a write beside it is not" {
    call Write "$(jq -n --arg f "${CLIENT_PLACE}/deeper/t-1.jsonl" '{file_path: $f, content: "{}"}')"
    denied
    call Write "$(jq -n --arg f "${H}/org/clients/acme/ticketsx/t-1.jsonl" '{file_path: $f, content: "{}"}')"
    passed
    call Write "$(jq -n --arg f "${H}/repos/tool/notes.md" '{file_path: $f, content: "x"}')"
    passed
}

@test "tickets: a shell write into a tickets folder is refused, a read of it passes" {
    bash_call "echo x >> ${OUTSIDE_PLACE}/a.jsonl"
    denied; says_tabs
    bash_call "echo x >> ${CLIENT_PLACE}/a.jsonl"
    denied
    bash_call "cd ${COMPANY_PLACE} && printf x | tee a.jsonl"
    denied
    bash_call "cp ${H}/repos/tool/a ${OUTSIDE_PLACE}/b.jsonl"
    denied
    bash_call "rm ${OUTSIDE_PLACE}/a.jsonl"
    denied
    printf '%s\n' '{}' > "${OUTSIDE_PLACE}/a.jsonl"
    bash_call "cat ${OUTSIDE_PLACE}/a.jsonl"
    passed
    bash_call "cat ${CLIENT_PLACE}/a.jsonl"
    passed
}

@test "tickets: a link into a tickets folder is no way round, and a machine with no areas keeps the folder outside them" {
    ln -s "${OUTSIDE_PLACE}" "${H}/repos/tool/tix"
    call Write "$(jq -n --arg f "${H}/repos/tool/tix/t-1.jsonl" '{file_path: $f, content: "{}"}')"
    denied
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    call Write "$(jq -n --arg f "${OUTSIDE_PLACE}/t-2.jsonl" '{file_path: $f, content: "{}"}')"
    denied; says_tabs
    call Write "$(jq -n --arg f "${H}/repos/tool/notes.md" '{file_path: $f, content: "x"}')"
    passed
}

@test "tickets: an area whose place cannot be named has no tickets folder to guard, and the rest still stand" {
    printf '%s\n' 'shared ~/s1 ~/s2' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/s1/tickets" "${H}/s2"
    call Write "$(jq -n --arg f "${H}/s1/tickets/t-1.jsonl" '{file_path: $f, content: "{}"}')"
    # an area of two roots has no `<root>/tickets` until tickets.txt names one: a folder by that name is any folder
    passed
    call Write "$(jq -n --arg f "${OUTSIDE_PLACE}/t-1.jsonl" '{file_path: $f, content: "{}"}')"
    denied
}

# --- listing every place ---------------------------------------------------------------------

@test "tickets: peers.py --places without --session is refused, with a session it passes" {
    bash_call "python3 ${PEERS} --places"
    denied
    [[ "${output}" == *"--session <your session>"* ]]
    bash_call "python3 ${PEERS} --places --session 11111111-1111-4111-8111-111111111111"
    passed
    bash_call "python3 ${PEERS} --session=11111111-1111-4111-8111-111111111111 --places"
    passed
    bash_call "python3 ${PEERS} --places --sess 11111111-1111-4111-8111-111111111111"
    passed
}

@test "tickets: the listing is read as a command, wherever it stands in the line" {
    bash_call "cd ${GUARD_ROOT} && python3 agent-hooks/claude-code/peers.py --places | sort"
    denied
    bash_call "echo go; PEERS=1 python3 -u ./peers.py --places"
    denied
    bash_call "python3 -c 'print(1)'; python3 ${PEERS} '--places'"
    denied
    bash_call "echo \"\$(python3 ${PEERS} --places)\""
    denied
    # another option of the program, or a word that only looks like it, lists nothing
    bash_call "python3 ${PEERS} --place-for 11111111-1111-4111-8111-111111111111"
    passed
    bash_call "echo peers.py is asked with a session"
    passed
    bash_call "grep -n places ${PEERS}"
    passed
}
