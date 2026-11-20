#!/usr/bin/env bats
# scripts/client-checks.sh: one line per judgement of the guard missing from the client's
# configuration, or not asking peers.py as it must.
#
# A throwaway platform root holds the client's configuration; the guard's peers.py is installed under
# a throwaway HOME as a link to this checkout, as install.sh links it.

load ../_internal/helpers

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    ROOT="${H}/platform"
    mkdir -p "${ROOT}/config/claude-pwa-client" "${H}/.git-hooks"
    ln -s "${GUARD_ROOT}/agent-hooks" "${H}/.git-hooks/agent-hooks"
    export HOME="${H}"
    CHECKS="${GUARD_ROOT}/scripts/client-checks.sh"
    PEERS='~/.git-hooks/agent-hooks/claude-code/peers.py'
}

# config [jq filter] — the client's configuration with every judgement, changed by the filter.
config() {
    jq -n --arg p "${PEERS}" '{
        agent_message_check: ["python3", $p, "--to", "{session}", "--text", "{file}"],
        agent_message_operator_check: ["python3", $p, "--to", "{session}", "--typed-in", "{sender_session}", "--text", "{file}"],
        agent_message_sender_check: ["python3", $p, "--to", "{session}", "--covers", "{sender_session}"],
        ticket_place_check: ["python3", $p, "--place-for", "{session}", "--typed-in", "{typed_in}"],
        ticket_places_check: ["python3", $p, "--places"],
        ticket_write_check: ["python3", $p, "--to-place", "{place}", "--text", "{text_file}", "--typed-in", "{typed_in}"],
        ticket_covers_check: ["python3", $p, "--to", "{session}", "--covers-place", "{place}", "--folder", "{folder}"],
        ticket_read_check: ["python3", $p, "--to", "{session}", "--text", "{text_file}"]
    } | '"${1:-.}" > "${ROOT}/config/claude-pwa-client/config.json"
}

@test "client-checks: every judgement there passes, and a machine without the client has nothing to check" {
    run bash "${CHECKS}" --root "${ROOT}"
    [ "${status}" -eq 0 ]; [ -z "${output}" ]
    config
    run bash "${CHECKS}" --root "${ROOT}"
    [ "${status}" -eq 0 ]; [ -z "${output}" ]
}

@test "client-checks: a missing judgement is one line each, naming what passes unjudged" {
    config 'del(.ticket_place_check, .ticket_write_check) | .ticket_read_check = []'
    run bash "${CHECKS}" --root "${ROOT}"
    [ "${status}" -eq 1 ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "${output}" == *"ticket_place_check is missing, so the client does not ask the guard about where a ticket sits"* ]]
    [[ "${output}" == *"ticket_write_check is missing"* ]]
    [[ "${output}" == *"ticket_read_check is missing"* ]]
}

@test "client-checks: a judgement that runs another program, or a word that is not a list, is a problem" {
    config '.agent_message_check = ["python3", "/tmp/peers.py", "--to", "{session}", "--text", "{file}"]
            | .agent_message_sender_check = "python3 peers.py --to x --covers y"'
    run bash "${CHECKS}" --root "${ROOT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"agent_message_check does not run the guard's peers.py"* ]]
    [[ "${output}" == *"agent_message_sender_check is not a list of words"* ]]
}

@test "client-checks: a required option left out, or one peers.py does not take, is a problem" {
    config '.ticket_covers_check = ["python3", $p, "--to", "{session}", "--folder", "{folder}"]
            | .ticket_places_check = ["python3", $p, "--places", "--all"]'
    run bash "${CHECKS}" --root "${ROOT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"ticket_covers_check gives peers.py no --covers-place"* ]]
    [[ "${output}" == *"ticket_places_check gives peers.py --all, which it does not take"* ]]
}

@test "client-checks: a configuration that cannot be read is one line" {
    printf '{ not json' > "${ROOT}/config/claude-pwa-client/config.json"
    run bash "${CHECKS}" --root "${ROOT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot be read"* ]]
}
