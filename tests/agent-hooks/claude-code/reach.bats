#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py reach — the areas a session of a work folder may read
# inside, for a caller that matches what it shows against them (the startup check of an agent).

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme/work" "${H}/org/hub" "${H}/agent"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export AREA_GUARD_STATE="${H}/state"
    unset GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'company ~/org\nclient ~/org/clients/acme\nhub ~/org/hub\n' > "${GUARD_CONFIG_DIR}/areas.txt"
}

@test "reach: a work folder inside an area reads it and the areas around it, one per line in name order" {
    GUARD_WORK_FOLDER="${H}/org/clients/acme/work" run python3 "${HOOK}" reach
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'client\ncompany')" ]
}

@test "reach: guard-reads.txt adds the areas it names" {
    printf 'hub   # the company folder of its own\n' > "${H}/org/clients/acme/work/guard-reads.txt"
    GUARD_WORK_FOLDER="${H}/org/clients/acme/work" run python3 "${HOOK}" reach
    [ "$output" = "$(printf 'client\ncompany\nhub')" ]
}

@test "reach: a work folder in no area reads none, and no work folder prints nothing" {
    GUARD_WORK_FOLDER="${H}/agent" run python3 "${HOOK}" reach
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run python3 "${HOOK}" reach
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
