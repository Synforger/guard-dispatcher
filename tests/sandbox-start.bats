#!/usr/bin/env bats
# sandbox/start.sh — build the cage, update the prints outside it, run inside it.
#
# `node` is a stub that records what run.mjs would have been given, so the
# suite needs neither the sandbox runtime nor an OS sandbox.

load helpers

START="${GUARD_ROOT}/sandbox/start.sh"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org" "${GUARD_CONFIG_DIR}"
    printf 'the calibration table reads seventeen at dawn\n' > "${H}/org/notes.md"
    printf 'company %s\n' "${H}/org" > "${GUARD_CONFIG_DIR}/areas.txt"
    export HOME="${H}"
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "${STUB}"
    cat > "${STUB}/node" <<'SH'
#!/bin/sh
# node run.mjs <cage.json> -- <command...>: record the cage and the command.
printf '%s\n' "$@" > "${BATS_TEST_TMPDIR}/node-args"
cp "$2" "${BATS_TEST_TMPDIR}/cage.json"
exit 7
SH
    chmod +x "${STUB}/node"
    export PATH="${STUB}:${PATH}"
}

@test "start: the cage is built, the prints updated, then Claude Code runs inside" {
    run bash "${START}" company
    [ "${status}" -eq 7 ]
    [ "$(jq -r .cage "${BATS_TEST_TMPDIR}/cage.json")" = "company" ]
    [ "$(sed -n 1p "${BATS_TEST_TMPDIR}/node-args")" = "${GUARD_ROOT}/sandbox/run.mjs" ]
    [ "$(sed -n 3,4p "${BATS_TEST_TMPDIR}/node-args" | paste -sd' ' -)" = "-- claude" ]
    [ -f "${GUARD_CORPUS_CACHE}/summary.json" ]
}

@test "start: a command after -- and the account directory are passed on" {
    mkdir -p "${H}/.claude-work"
    run bash "${START}" personal --account-dir "${H}/.claude-work" -- bash -c 'echo hi'
    [ "${status}" -eq 7 ]
    [ "$(jq -r .env.CLAUDE_CONFIG_DIR "${BATS_TEST_TMPDIR}/cage.json")" = "${H}/.claude-work" ]
    [ "$(sed -n 3,6p "${BATS_TEST_TMPDIR}/node-args" | paste -sd'|' -)" = "--|bash|-c|echo hi" ]
}

@test "start: an unknown cage or a broken areas file starts nothing" {
    run bash "${START}" nope
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/node-args" ]
    printf 'company org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    run bash "${START}" personal
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/node-args" ]
}

@test "start: no cage file is left behind" {
    run env TMPDIR="${BATS_TEST_TMPDIR}/t" bash -c "mkdir -p \"\${TMPDIR}\" && bash '${START}' company"
    [ "${status}" -eq 7 ]
    [ -z "$(ls "${BATS_TEST_TMPDIR}/t")" ]
}

@test "start: no cage name is a usage error" {
    run bash "${START}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage"* ]]
}
