#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + orders_edit.py — orders.txt is the operator's, but for
# an Edit or a Write that only adds openings of relayed messages (`>` and `>>` lines), from a
# session that has read inside no area: such a line only takes words out of what counts as the
# operator's. Every other change of the file, and any change through the shell, still needs the
# operator's yes.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}" "${AREA_GUARD_STATE}"
    printf 'company ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' '送信して' '!ない' '>Message from another session, relayed by the client' > "${GUARD_CONFIG_DIR}/orders.txt"
    ORDERS="${GUARD_CONFIG_DIR}/orders.txt"
}

call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}" --arg s "${3:-s1}" \
        '{session_id: $s, tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
edit() { call Edit "$(jq -n --arg f "${ORDERS}" --arg o "$1" --arg n "$2" '{file_path: $f, old_string: $o, new_string: $n}')" "${3:-s1}"; }
write() { call Write "$(jq -n --arg f "${ORDERS}" --arg c "$1" '{file_path: $f, content: $c}')"; }
passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

LAST='>Message from another session, relayed by the client'

@test "orders edit: an Edit or a Write that only adds openings of relayed messages passes" {
    edit "${LAST}" "${LAST}
>Tab opened by the client for its tier"
    passed
    edit "${LAST}" "${LAST}

# the client's rollover
>>Message from a session on another machine"
    passed
    write "$(cat "${ORDERS}")
>Automatic session rollover, sent by the client
"
    passed
}

@test "orders edit: adding an order, an approving phrase or a tail, or changing a line, needs the operator's yes" {
    for added in '送って' '+はい' '!も' '> # only a comment' '>'; do
        edit "${LAST}" "${LAST}
${added}"
        denied
    done
    # A `>` line made `>>`, a line taken away, a line rewritten.
    edit "${LAST}" ">${LAST}"
    denied
    edit "!ない
" ""
    denied
    edit "送信して" "送信"
    denied
}

@test "orders edit: through the shell, or from a session that has read inside an area, it needs the yes" {
    call Bash "$(jq -n --arg c "printf '>Tab opened\n' >> ${ORDERS}" '{command: $c}')"
    denied
    printf '{"areas": ["company"], "tabs": {}}' > "${AREA_GUARD_STATE}/s2.json"
    edit "${LAST}" "${LAST}
>Tab opened by the client for its tier" s2
    denied
}
