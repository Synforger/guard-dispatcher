#!/usr/bin/env bats
# Behavioural tests for the gh command guard.
#
# The shim shadows the real CLI on PATH, so these tests stand up two
# directories — one holding the shim, one holding a stand-in for the real
# binary that records whether it was reached. "Refused" therefore means the
# real CLI never ran, not merely that the exit code was non-zero.

load helpers

setup() {
    setup_words
    SHIM_DIR="${BATS_TEST_TMPDIR}/shim"
    REAL_DIR="${BATS_TEST_TMPDIR}/real"
    RAN_MARKER="${BATS_TEST_TMPDIR}/real-gh-ran"
    mkdir -p "${SHIM_DIR}" "${REAL_DIR}"
    ln -sf "${GUARD_ROOT}/scripts/gh-guard.sh" "${SHIM_DIR}/gh"
    cat > "${REAL_DIR}/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${RAN_MARKER}"
exit 0
STUB
    chmod +x "${REAL_DIR}/gh"
    export PATH="${SHIM_DIR}:${REAL_DIR}:${PATH}"
}

# Did the call reach the real CLI?
ran() { [ -f "${RAN_MARKER}" ]; }

# --- refusals -----------------------------------------------------------------

@test "gh-guard: a flagged identifier in the arguments is refused and never sent" {
    run gh pr comment 1 --body "deferred to ${SENTINEL}"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a flagged identifier in a body file is refused" {
    printf 'looks fine\nbut mentions %s\n' "${SENTINEL}" > "${BATS_TEST_TMPDIR}/body.md"
    run gh pr create --title "ok" --body-file "${BATS_TEST_TMPDIR}/body.md"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a payload read from stdin is scanned" {
    run bash -c "printf '%s\n' '${SENTINEL}' | gh pr create --title t --body-file -"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: an api call carrying a payload is scanned" {
    run gh api repos/owner/name/issues -f body="${SENTINEL}"
    [ "$status" -ne 0 ]
    ! ran
}

# An unrecognised subcommand must fail closed: the CLI gains commands faster
# than any allow-list of "sending" verbs can be maintained.
@test "gh-guard: an unknown subcommand is scanned, not waved through" {
    run gh frobnicate wibble --body "${SENTINEL}"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: an unresolvable scanner refuses the command (fail-closed)" {
    GUARD_SCANNER_OVERRIDE="${BATS_TEST_TMPDIR}/no-such-scanner.sh" run gh pr comment 1 --body "harmless"
    [ "$status" -ne 0 ]
    ! ran
}

# --- pass-through -------------------------------------------------------------

@test "gh-guard: a clean send reaches the real CLI" {
    run gh pr comment 1 --body "nothing to see here"
    [ "$status" -eq 0 ]
    ran
}

# Read-only calls legitimately name accounts and repositories. Blocking them
# would turn the guard into something to switch off.
@test "gh-guard: read-only subcommands are passed through unscanned" {
    run gh repo view "owner/${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}

@test "gh-guard: a plain GET api call is passed through unscanned" {
    run gh api "repos/owner/${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}

@test "gh-guard: GH_GUARD_SKIP=1 is a deliberate one-off bypass" {
    GH_GUARD_SKIP=1 run gh pr comment 1 --body "${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}
