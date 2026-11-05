#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py marks SESSION --carry-from EARLIER — a client that writes a
# conversation out under a new session id (a fork, a move to another account) carries what the
# earlier session read: the new session is held to those areas from its first call.
#
# A throwaway HOME holds a company with a client inside it, and a repository of the company's own
# outside the client.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
EARLIER="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
LATER="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    COMPANY_REPO="${H}/org/repos/internal"
    mkdir -p "${H}/org/clients/acme" "${COMPANY_REPO}"
    git init -q "${COMPANY_REPO}"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER PWA_SID
    mkdir -p "${GUARD_CONFIG_DIR}" "${AREA_GUARD_STATE}"
    printf 'company ~/org\nclient  ~/org/clients/acme\n' > "${GUARD_CONFIG_DIR}/areas.txt"
}

held() { printf '{"areas": [%s], "tabs": {}}' "$2" > "${AREA_GUARD_STATE}/$1.json"; }
marks() { run python3 "${HOOK}" marks "$@"; }

@test "marks carry: the later session takes the earlier one's areas, and is held to them" {
    held "${EARLIER}" '"client"'
    marks "${LATER}" --carry-from "${EARLIER}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "client" ]
    event="$(jq -n --arg f "${COMPANY_REPO}/notes.md" --arg s "${LATER}" \
        '{session_id: $s, tool_name: "Write", tool_input: {file_path: $f, content: "x"}, cwd: "/", hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
    [[ "${output}" == *'"permissionDecision": "deny"'* ]]
}

@test "marks carry: it only adds, to what the later session read itself" {
    held "${EARLIER}" '"client"'
    held "${LATER}" '"company"'
    marks "${LATER}" --carry-from "${EARLIER}"
    [ "$(printf '%s\n' "${output}" | paste -sd, -)" = "client,company" ]
    held "${EARLIER}" ''
    marks "${LATER}" --carry-from "${EARLIER}"
    [ "$(printf '%s\n' "${output}" | paste -sd, -)" = "client,company" ]
}

@test "marks carry: from a session that read nothing, the later one stays as it was" {
    marks "${LATER}" --carry-from "${EARLIER}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ ! -e "${AREA_GUARD_STATE}/${LATER}.json" ]
}
