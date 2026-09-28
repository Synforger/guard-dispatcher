#!/usr/bin/env bats
# sandbox/seatbelt.mjs + sandbox/seatbelt-exec.sh — the cage's extra Seatbelt rules reach the end
# of the profile sandbox-runtime built, or the cage is not started at all.

load helpers

SEATBELT="${GUARD_ROOT}/sandbox/seatbelt.mjs"
EXEC="${GUARD_ROOT}/sandbox/seatbelt-exec.sh"

# with_rules <wrapped> <platform> <rule>... — print withRules()'s result, or fail with its error.
with_rules() {
    run node --input-type=module -e '
const { withRules } = await import(process.argv[1])
const [wrapped, platform, ...rules] = process.argv.slice(2)
console.log(withRules(wrapped, rules, "/guard/seatbelt-exec.sh", platform))' "${SEATBELT}" "$@"
}

@test "seatbelt: sandbox-exec is replaced by the wrapper carrying the rules, once" {
    with_rules "env A=1 /usr/bin/sandbox-exec -p '(version 1)' /bin/bash -c true" darwin '(allow x)' '(allow y)'
    [ "${status}" -eq 0 ]
    [ "${output}" = "env A=1 '/guard/seatbelt-exec.sh' '(allow x)' '(allow y)' '--' -p '(version 1)' /bin/bash -c true" ]
}

@test "seatbelt: no rules or not macOS leaves the command as it is" {
    with_rules "env /usr/bin/sandbox-exec -p p sh" darwin
    [ "${output}" = "env /usr/bin/sandbox-exec -p p sh" ]
    with_rules "bwrap --ro-bind / / sh" linux '(allow x)'
    [ "${output}" = "bwrap --ro-bind / / sh" ]
}

@test "seatbelt: a command without sandbox-exec, or with it twice, is a refusal" {
    with_rules "env sh -c true" darwin '(allow x)'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"exactly once"* ]]
    with_rules "/usr/bin/sandbox-exec -p p /usr/bin/sandbox-exec" darwin '(allow x)'
    [ "${status}" -ne 0 ]
}

@test "seatbelt-exec: the rules end the profile and the command follows untouched" {
    # A copy that calls a recorder instead of the real sandbox-exec (it cannot nest in a sandbox).
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "${BATS_TEST_TMPDIR}/recorder"
    chmod +x "${BATS_TEST_TMPDIR}/recorder"
    sed "s#/usr/bin/sandbox-exec#${BATS_TEST_TMPDIR}/recorder#" "${EXEC}" > "${BATS_TEST_TMPDIR}/exec.sh"
    run bash "${BATS_TEST_TMPDIR}/exec.sh" '(allow x)' '(allow "y")' -- -p "$(printf '(version 1)\n(deny default)')" /bin/bash -c 'echo a b'
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '[-p]\n[(version 1)\n(deny default)\n(allow x)\n(allow "y")]\n[/bin/bash]\n[-c]\n[echo a b]')" ]
}

@test "seatbelt-exec: anything but <rule>... -- -p <profile> <command> is refused" {
    run bash "${EXEC}" '(allow x)' -p p sh
    [ "${status}" -eq 2 ]
    run bash "${EXEC}" -- -f p sh
    [ "${status}" -eq 2 ]
}
