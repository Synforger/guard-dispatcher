#!/usr/bin/env bats
# scripts/pre-launch.sh on a throwaway repository and HOME.

load helpers

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    unset GIT_CONFIG_GLOBAL
    git config --global user.name t
    git config --global user.email t@example.invalid
    REPO="${H}/agent"
    mkdir -p "${REPO}/.tooling" "${REPO}/journal"
    git init -q "${REPO}"
    printf 'echo launcher\n' > "${REPO}/.tooling/launch.sh"
    printf 'notes\n' > "${REPO}/journal/today.md"
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -q -m init
    PRE="${GUARD_ROOT}/scripts/pre-launch.sh"
}

# start [options...] — run the pre-launch in front of a command that reports it started
start() {
    run bash "${PRE}" "$@" "${REPO}" -- bash -c 'echo "started ${GUARD_PRE_LAUNCH:-}"' < /dev/null
}

commit_tool() {
    printf '%s\n' "$2" > "${REPO}/.tooling/$1"
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -q -m "tool: $1"
}

@test "pre-launch: a committed repository starts the command, marked as checked" {
    start
    [ "${status}" -eq 0 ]
    [ "${output}" = "started 1" ]
}

@test "pre-launch: an uncommitted change or a new file in the watched path is refused without a terminal" {
    printf 'curl evil\n' >> "${REPO}/.tooling/launch.sh"
    start
    [ "${status}" -eq 1 ]
    [[ "${output}" == *".tooling/launch.sh"* ]]
    [[ "${output}" != *"started 1"* ]]
    git -C "${REPO}" checkout -q -- .tooling
    printf 'x\n' > "${REPO}/.tooling/new.sh"
    start
    [ "${status}" -eq 1 ]
    [[ "${output}" == *".tooling/new.sh"* ]]
}

@test "pre-launch: a change outside the watched paths does not stop the start" {
    printf 'more\n' >> "${REPO}/journal/today.md"
    start
    [ "${status}" -eq 0 ]
    [ "${output}" = "started 1" ]
}

@test "pre-launch: --watch replaces the default path" {
    printf 'more\n' >> "${REPO}/journal/today.md"
    start --watch journal
    [ "${status}" -eq 1 ]
    printf 'y\n' >> "${REPO}/.tooling/launch.sh"
    git -C "${REPO}" checkout -q -- journal
    start --watch journal
    [ "${status}" -eq 0 ]
}

@test "pre-launch: a committed change to the watched path is named once, at the next start" {
    start
    [ "${output}" = "started 1" ]                     # the first start only records
    commit_tool helper.py 'print(1)'
    start
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"launch entry changed since the last start: .tooling"* ]]
    [[ "${output}" == *"helper.py"* ]]
    [[ "${output}" == *"tool: helper.py"* ]]
    [[ "${output}" == *"started 1" ]]
    start
    [ "${output}" = "started 1" ]
}

@test "pre-launch: --pull brings the remote's commits in before they are checked and named" {
    git clone -q --bare "${REPO}" "${H}/origin.git"
    git -C "${REPO}" remote add origin "${H}/origin.git"
    git -C "${REPO}" fetch -q origin
    git -C "${REPO}" branch -q -u origin/"$(git -C "${REPO}" branch --show-current)"
    start --pull
    git clone -q "${H}/origin.git" "${H}/other"
    printf 'echo changed\n' > "${H}/other/.tooling/launch.sh"
    git -C "${H}/other" commit -q -am "tool: pushed from elsewhere"
    git -C "${H}/other" push -q
    start --pull
    [ "${status}" -eq 0 ]
    [ "$(cat "${REPO}/.tooling/launch.sh")" = "echo changed" ]
    [[ "${output}" == *"pushed from elsewhere"* ]]
}

@test "pre-launch: a missing repository or command is a usage error" {
    run bash "${PRE}" "${REPO}"
    [ "${status}" -eq 2 ]
    run bash "${PRE}" -- true
    [ "${status}" -eq 2 ]
    run bash "${PRE}" "${H}/nowhere" -- true
    [ "${status}" -eq 2 ]
}
