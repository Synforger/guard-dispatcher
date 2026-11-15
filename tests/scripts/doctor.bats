#!/usr/bin/env bats
# scripts/doctor.sh --machine: every repository of the machine, and which ones the guard does not
# check, shown to a session only for the areas it reads.
#
# A throwaway HOME holds a client area with three repositories and an exempt folder of notes whose
# remote is a bare repository beside it, with no line in destinations.txt.

load ../_internal/helpers

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/acme" "${H}/notes" "${H}/.git-hooks"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset AGENT_PLATFORM_ROOT GUARD_WORK_FOLDER GIT_CONFIG_GLOBAL
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'client ~/org/acme\n_exempt ~/notes\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    for repo in own-hooks opted-out checked; do
        git init -q "${H}/org/acme/${repo}"
    done
    git -C "${H}/org/acme/own-hooks" config core.hooksPath .husky
    git -C "${H}/org/acme/opted-out" config guard.scope exempt
    git init -q "${H}/notes"
    git init -q --bare "${H}/notes/backup.git"
    git -C "${H}/notes" remote add backup "${H}/notes/backup.git"
    DOCTOR="${GUARD_ROOT}/scripts/doctor.sh"
}

@test "doctor --machine: names each repository the guard does not check, and why" {
    run bash "${DOCTOR}" --machine
    [ "$status" -eq 0 ]
    [[ "$output" == *"${H}/org/acme/own-hooks core.hooksPath .husky runs its own hooks, not the guard's"* ]]
    [[ "$output" == *"${H}/org/acme/opted-out guard.scope exempt"* ]]
    [[ "$output" == *"${H}/notes a push to backup is compared with no area"* ]]
    [[ "$output" != *"acme/checked"* ]]
    [[ "$output" == *"doctor: 3 repository(ies) outside the guard's checks, 0 kept outside on purpose"* ]]
}

@test "doctor --machine: a session sees the lines of the areas it reads, and only a count of the rest" {
    mkdir -p "${H}/elsewhere"
    export GUARD_WORK_FOLDER="${H}/elsewhere"
    run bash "${DOCTOR}" --machine
    [ "$status" -eq 0 ]
    [[ "$output" != *"org/acme"* ]]
    [[ "$output" == *"(2 more in areas this session does not read)"* ]]
    [[ "$output" == *"${H}/notes a push to backup is compared with no area"* ]]
    export GUARD_WORK_FOLDER="${H}/org/acme"
    run bash "${DOCTOR}" --machine
    [[ "$output" == *"acme/opted-out guard.scope exempt"* ]]
    [[ "$output" != *"more in areas"* ]]
}

@test "doctor --machine: a repository its owner keeps outside with a reason is said as kept, and not counted" {
    mkdir -p "${H}/.config/guard-dispatcher"
    printf '%s\n' "${H}/org/acme/opted-out  # a private record that holds no scan at all" \
        "${H}/org/acme/own-hooks" > "${H}/.config/guard-dispatcher/unchecked-kept.txt"
    run bash "${DOCTOR}" --machine --save
    [ "$status" -eq 0 ]
    [[ "$output" == *"kept on purpose: ${H}/org/acme/opted-out guard.scope exempt; kept: a private record that holds no scan at all"* ]]
    # a line without a reason keeps nothing
    [[ "$output" == *"${H}/org/acme/own-hooks core.hooksPath .husky runs its own hooks"* ]]
    [[ "$output" == *"doctor: 2 repository(ies) outside the guard's checks, 1 kept outside on purpose"* ]]
    kept="${H}/.local/state/guard-dispatcher/unchecked-repos.txt"
    [ "$(grep -c '^outside' "${kept}")" -eq 2 ]
    [ "$(grep -c '^kept' "${kept}")" -eq 1 ]
}

@test "doctor --machine --save: keeps the list, with each repository's area, for the startup screens" {
    run bash "${DOCTOR}" --machine --save
    [ "$status" -eq 0 ]
    kept="${H}/.local/state/guard-dispatcher/unchecked-repos.txt"
    [ "$(head -1 "${kept}" | cut -c1-10)" = "# written " ]
    grep -q "^outside	client	${H}/org/acme/opted-out	guard.scope exempt$" "${kept}"
    grep -q "^outside	_exempt	${H}/notes	a push to backup is compared with no area$" "${kept}"
    [ "$(grep -c '^outside' "${kept}")" -eq 3 ]
    # once every repository is checked again, the kept list says so too
    git -C "${H}/org/acme/own-hooks" config --unset core.hooksPath
    git -C "${H}/org/acme/opted-out" config --unset guard.scope
    git -C "${H}/notes" remote remove backup
    run bash "${DOCTOR}" --machine --save
    [ "$status" -eq 0 ]
    [ "$(grep -c '^outside' "${kept}")" -eq 0 ]
    [ ! -e "${kept}.new" ]
}
