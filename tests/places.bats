#!/usr/bin/env bats
# scanners/guard_places.py — where the guard keeps its settings, marks and caches.
#
# A throwaway HOME, and a throwaway platform root inside it. The same fixture is laid out the
# flat way and under the root, and the entry guard must judge both the same.

load helpers

PLACES="${GUARD_ROOT}/scanners/guard_places.py"
HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    ROOT="${H}/platform"
    mkdir -p "${H}"
    export HOME="${H}"
    unset AGENT_PLATFORM_ROOT GUARD_CONFIG_DIR AREA_GUARD_STATE GUARD_CORPUS_CACHE ANON_TRUTH_PATH
}

place() {
    run python3 "${PLACES}" "$1"
    [ "${status}" -eq 0 ]
}

@test "places: without a root, the guard keeps its six places in HOME" {
    place areas.txt;         [ "${output}" = "${H}/.config/guard/areas.txt" ]
    place background.txt;    [ "${output}" = "${H}/.config/guard/background.txt" ]
    place agent-off;         [ "${output}" = "${H}/.config/guard/agent-off" ]
    place master-words;      [ "${output}" = "${H}/.config/anon-words/master.txt" ]
    place weekly-audit.conf; [ "${output}" = "${H}/.config/guard-dispatcher/weekly-audit.conf" ]
    place known;             [ "${output}" = "${H}/.config/guard-dispatcher/known" ]
    place marks;             [ "${output}" = "${H}/.cache/area-guard" ]
    place audit-logs;        [ "${output}" = "${H}/.local/state/guard-dispatcher" ]
    place corpus;            [ "${output}" = "${H}/.cache/guard-corpus" ]
}

@test "places: under a root, every place sits in the folder of its job" {
    export AGENT_PLATFORM_ROOT="${ROOT}"
    place areas.txt;         [ "${output}" = "${ROOT}/config/guard/boundaries/areas.txt" ]
    place background.txt;    [ "${output}" = "${ROOT}/config/guard/boundaries/public.txt" ]
    place agent-writes.txt;  [ "${output}" = "${ROOT}/config/guard/entry/agent-writes.txt" ]
    place destinations.txt;  [ "${output}" = "${ROOT}/config/guard/exit/destinations.txt" ]
    place master-words;      [ "${output}" = "${ROOT}/config/guard/exit/words/master.txt" ]
    place weekly-audit.conf; [ "${output}" = "${ROOT}/config/guard/audit/weekly-audit.conf" ]
    place marks;             [ "${output}" = "${ROOT}/state/guard/marks" ]
    place audit-logs;        [ "${output}" = "${ROOT}/state/guard/audit" ]
    place corpus;            [ "${output}" = "${ROOT}/cache/guard/corpus" ]
}

@test "places: a variable that names one place wins over the root" {
    export AGENT_PLATFORM_ROOT="${ROOT}"
    export GUARD_CONFIG_DIR="${H}/flat" AREA_GUARD_STATE="${H}/marks" GUARD_CORPUS_CACHE="${H}/corpus"
    export ANON_TRUTH_PATH="${H}/words/mine.txt"
    place areas.txt;    [ "${output}" = "${H}/flat/areas.txt" ]
    place settings;     [ "${output}" = "${H}/flat" ]
    place marks;        [ "${output}" = "${H}/marks" ]
    place corpus;       [ "${output}" = "${H}/corpus" ]
    place master-words; [ "${output}" = "${H}/words/mine.txt" ]
    place words;        [ "${output}" = "${H}/words" ]
}

@test "places: an unknown name is refused" {
    run python3 "${PLACES}" nothing
    [ "${status}" -eq 2 ]
}

# decision <event> — what the entry guard decides on one call (= it prints nothing when the call passes).
decision() {
    local verdict
    verdict="$(python3 "${HOOK}" <<< "$1")"
    if [ -z "${verdict}" ]; then echo allow; else jq -r '.hookSpecificOutput.permissionDecision' <<< "${verdict}"; fi
}

# judge <session> — read a client's memo, then write into a public repository; prints both decisions
# (the reason names the settings file it read, which differs by layout).
judge() {
    local read write
    read="$(jq -n --arg file "${H}/org/clients/acme/memo.md" --arg session "$1" --arg cwd "${H}" \
        '{session_id: $session, tool_name: "Read", tool_input: {file_path: $file}, cwd: $cwd, hook_event_name: "PreToolUse"}')"
    write="$(jq -n --arg file "${H}/repos/public-tool/README.md" --arg session "$1" --arg cwd "${H}" \
        '{session_id: $session, tool_name: "Write", tool_input: {file_path: $file, content: "x"}, cwd: $cwd, hook_event_name: "PreToolUse"}')"
    echo "read=$(decision "${read}")"
    echo "write=$(decision "${write}")"
}

lay_out_fixture() {
    mkdir -p "${H}/org/clients/acme" "${H}/repos/public-tool"
    git init -q "${H}/repos/public-tool"
    git -C "${H}/repos/public-tool" remote add origin git@github.com:me/public-tool.git
    printf 'client value 12.3456\n' > "${H}/org/clients/acme/memo.md"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    mkdir -p "${H}/hooks" && printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
}

write_areas() {
    mkdir -p "$(dirname "$1")"
    printf 'company ~/org\nclient  ~/org/clients/acme\n' > "$1"
}

@test "places: the same fixture is judged the same flat and under a root" {
    lay_out_fixture
    unset GIT_CONFIG_GLOBAL

    write_areas "${H}/.config/guard/areas.txt"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    seed_visibility me/public-tool public
    unset GUARD_CORPUS_CACHE
    flat="$(judge flat-session)"

    export AGENT_PLATFORM_ROOT="${ROOT}"
    write_areas "${ROOT}/config/guard/boundaries/areas.txt"
    export GUARD_CORPUS_CACHE="${ROOT}/cache/guard/corpus"
    seed_visibility me/public-tool public
    unset GUARD_CORPUS_CACHE
    rooted="$(judge root-session)"

    [ "${flat}" = "${rooted}" ]
    [ "${flat}" = "$(printf 'read=allow\nwrite=deny')" ]
    # Each layout kept its marks in its own place, and nothing of the root's went to HOME's.
    [ -f "${H}/.cache/area-guard/flat-session.json" ]
    [ -f "${ROOT}/state/guard/marks/root-session.json" ]
    [ ! -e "${H}/.cache/area-guard/root-session.json" ]
}
