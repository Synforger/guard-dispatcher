#!/usr/bin/env bats
# tests/contracts.txt — every test file has a row saying what it keeps, and every row names a
# target and a test file that exist (tests/_internal/contracts.py).

load _internal/helpers

CHECK="${GUARD_ROOT}/tests/_internal/contracts.py"

@test "contracts: every test file of the repository has a row, and every row names what exists" {
    run python3 "${CHECK}" "${GUARD_ROOT}"
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
}

@test "contracts: a test file with no row, a row for a gone file and a broken row are each named" {
    local root="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${root}/tests/a" "${root}/src"
    : > "${root}/src/kept.py"
    : > "${root}/tests/a/kept.bats"
    : > "${root}/tests/a/new.bats"
    printf '%s\n' '# a comment' \
        'src/kept.py | tests/a/kept.bats | Something kept.' \
        'src/gone.py | tests/a/gone.bats | Something gone.' \
        'src/kept.py | tests/a/kept.bats' > "${root}/tests/contracts.txt"
    run python3 "${CHECK}" "${root}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"tests/contracts.txt:3: the target src/gone.py is gone"* ]]
    [[ "${output}" == *"tests/contracts.txt:3: the test file tests/a/gone.bats is gone"* ]]
    [[ "${output}" == *"tests/contracts.txt:4: not"* ]]
    [[ "${output}" == *"tests/a/new.bats: no row"* ]]
    [[ "${output}" != *"tests/a/kept.bats: no row"* ]]
}
