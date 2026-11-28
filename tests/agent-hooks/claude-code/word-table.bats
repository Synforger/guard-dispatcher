#!/usr/bin/env bats
# agent-hooks/claude-code/word_table.py (through `area-guard.py words`) — the table of which words
# may go where, built from the word lists and destinations.txt, shows a session only the areas it
# may read; a word-list refusal points at it.
#
# A throwaway HOME holds a company with a client inside it and a folder outside every area; the
# operator's list and the company's own list hold made-up words.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme/work" "${H}/org/hub" "${H}/agent" "${H}/words"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export AREA_GUARD_STATE="${H}/state"
    export ANON_TRUTH_PATH="${H}/words/master.txt"
    unset GUARD_WORK_FOLDER AGENT_PLATFORM_ROOT
    mkdir -p "${GUARD_CONFIG_DIR}/areas/client"
    printf 'company ~/org\nclient ~/org/clients/acme\nhub ~/org/hub\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' 'repo:example-org/* company' 'repo:someone/* outside' 'host:paste.example block' \
        > "${GUARD_CONFIG_DIR}/destinations.txt"
    printf '%s\n' 'host:tracker.acme.example client' > "${GUARD_CONFIG_DIR}/areas/client/destinations.txt"
    printf '%s\n' '# a comment line' 'tarohandle' 'taro example   # the full name' > "${H}/words/master.txt"
    printf '%s\n' 'tarohandle' 'nickname-zz' > "${H}/words/company.txt"
    printf '%s\n' 'acme-codename' > "${H}/words/client.txt"
}

words() { GUARD_WORK_FOLDER="$1" run python3 "${HOOK}" words; }

@test "word table: a session in a client reads its lists and the areas around it, each word with where it passes" {
    words "${H}/org/clients/acme/work"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"master (the operator's list): a send outside every area"* ]]
    [[ "${output}" == *"destinations: repo:someone/*, Artifact*"* ]]
    [[ "${output}" == *"company: a send into company, and a write into the folders of company and of client"*"destinations: repo:example-org/*"* ]]
    [[ "${output}" == *"client: a send into client"*"destinations: host:tracker.acme.example"* ]]
    [[ "${output}" =~ tarohandle\ +stopped\ by:\ master,\ company\;\ passes:\ a\ send\ into\ client\ \(not\ a\ write\ into\ its\ folders\),\ another\ session ]]
    [[ "${output}" =~ taro\ example\ +stopped\ by:\ master\;\ passes:\ into\ client,\ into\ company,\ another\ session ]]
    [[ "${output}" =~ nickname-zz\ +stopped\ by:\ company\;\ passes:\ outside\ every\ area,\ a\ send\ into\ client\ \(not ]]
    [[ "${output}" =~ acme-codename\ +stopped\ by:\ client\;\ passes:\ outside\ every\ area,\ into\ company ]]
    [[ "${output}" == *"Blocked for every send, whatever it holds: host:paste.example"* ]]
    [[ "${output}" != *"a comment line"* ]] && [[ "${output}" != *"the full name"* ]]
    [[ "${output}" != *"hub"* ]]
}

@test "word table: a session outside every area is shown the operator's list and no area's name" {
    words "${H}/agent"
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ tarohandle\ +stopped\ by:\ master\;\ passes:\ another\ session ]]
    local name
    for name in company client hub nickname-zz acme-codename example-org tracker.acme; do
        [[ "${output}" != *"${name}"* ]] || { echo "shows ${name}"; return 1; }
    done
}

@test "word table: a session with no work folder named is the operator's shell, and sees every area" {
    run python3 "${HOOK}" words
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"client: a send into client"* ]]
    [[ "${output}" =~ nickname-zz\ +stopped\ by:\ company\;\ passes:\ outside\ every\ area,\ a\ send\ into\ client\ \(not\ a\ write\ into\ its\ folders\),\ a\ send\ into\ hub ]]
}

@test "word table: a refusal for a word the list holds names the command that prints the table" {
    mkdir -p "${H}/out"
    printf 'a line from tarohandle\n' > "${H}/out/note.txt"
    ANON_WORDS_FILE="${H}/words/master.txt" ANON_SCAN_PATHS="${H}/out/note.txt" \
        run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"area-guard.py words"* ]]
}
