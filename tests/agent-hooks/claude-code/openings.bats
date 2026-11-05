#!/usr/bin/env bats
# agent-hooks/claude-code/order.py — the openings of relayed messages (`>` and `>>` lines) may sit in
# openings.txt beside orders.txt, and in a file an `include` line there names (a client's own list
# of what it types). Such a line only takes words out of what counts as the operator's, so an agent
# keeps the file under the operator's grant; nothing in it orders or approves.

load ../../_internal/helpers

ORDER_DIR="${GUARD_ROOT}/agent-hooks/claude-code"
HOOK="${ORDER_DIR}/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/tool/contracts"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER AGENT_PLATFORM_ROOT
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf '%s\n' '送信して' '!ない' '>Message from another session, relayed by the client' > "${GUARD_CONFIG_DIR}/orders.txt"
}

relayed() { run python3 -c "import sys; sys.path.insert(0, '${ORDER_DIR}'); import order; print(order.relayed(sys.argv[1]), order.from_another_machine(sys.argv[1]))" "$1"; }

@test "openings: a line of openings.txt, and of a file it includes, opens a relayed message" {
    printf '%s\n' '# what the client types' '>Sent by the client' 'include ~/tool/contracts/openings.txt' > "${GUARD_CONFIG_DIR}/openings.txt"
    printf '%s\n' '>Tab opened by the client' '>>From the other machine' > "${H}/tool/contracts/openings.txt"
    relayed $'Sent by the client\ngo on'
    [ "${output}" = "True False" ]
    relayed $'Tab opened by the client\n<tab-open>'
    [ "${output}" = "True False" ]
    relayed $'From the other machine\nhello'
    [ "${output}" = "True True" ]
    relayed $'Message from another session, relayed by the client\nhi'
    [ "${output}" = "True False" ]
    relayed 'go on'
    [ "${output}" = "False False" ]
    run python3 "${ORDER_DIR}/order.py" --openings
    [ "${status}" -eq 0 ]
    [[ "${output}" == *">>From the other machine"* ]]
    [[ "${output}" == *">Sent by the client"* ]]
    [[ "${output}" == *">Message from another session, relayed by the client"* ]]
}

@test "openings: an order, a tail or an approving phrase there is not read, nor an include in an included file" {
    printf '%s\n' '送って' '+はい' '!も' 'include ~/tool/contracts/openings.txt' > "${GUARD_CONFIG_DIR}/openings.txt"
    printf '%s\n' '送って' '+どうぞ' 'include ~/tool/contracts/more.txt' > "${H}/tool/contracts/openings.txt"
    printf '%s\n' '>Deeper' > "${H}/tool/contracts/more.txt"
    run python3 -c "import sys; sys.path.insert(0, '${ORDER_DIR}'); import order; o, t, r, f, a = order.settings(); print(o, t, r, a)"
    [ "${output}" = "['送信して'] ['ない'] ['Message from another session, relayed by the client'] ['はい', 'お願い', 'どうぞ', 'いいよ', 'いいです', 'やって', '変えて', '外して', 'OK', 'ok', 'yes', 'Yes']" ]
}

@test "openings: an agent keeps openings.txt under the operator's grant, and orders.txt stays the operator's" {
    printf '*\n' > "${GUARD_CONFIG_DIR}/agent-writes.txt"
    event="$(jq -n --arg f "${GUARD_CONFIG_DIR}/openings.txt" \
        '{session_id: "s1", tool_name: "Write", tool_input: {file_path: $f, content: ">Sent by the client\n"}, cwd: "/", hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
    [ "${status}" -eq 0 ] && [ -z "${output}" ]
    event="$(jq -n --arg f "${GUARD_CONFIG_DIR}/orders.txt" \
        '{session_id: "s1", tool_name: "Write", tool_input: {file_path: $f, content: "送って\n"}, cwd: "/", hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
    [[ "${output}" == *'"permissionDecision": "deny"'* ]]
}
