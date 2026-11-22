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

# hook <tool> <input json> — run the hook on one call of a session that has read inside no area.
hook() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
writes() { hook Write "$(jq -n --arg f "$1" --arg c "$2" '{file_path: $f, content: $c}')"; }
shell() { hook Bash "$(jq -n --arg c "$1" '{command: $c}')"; }
# shells <passed|denied> <command>... — run the hook on each command, all at once: each is a call of its own.
shells() {
    local want="$1" n=0 out="${BATS_TEST_TMPDIR}/answers" command waited=()
    shift
    mkdir -p "${out}"
    for command in "$@"; do
        n=$((n + 1))
        jq -n --arg m "${command}" --arg c "${H}" \
            '{session_id: "s1", tool_name: "Bash", tool_input: {command: $m}, cwd: $c, hook_event_name: "PreToolUse"}' \
            > "${out}/${n}.event"
        python3 "${HOOK}" < "${out}/${n}.event" > "${out}/${n}.answer" &
        waited+=($!)
    done
    for n in "${waited[@]}"; do wait "${n}" || return 1; done
    n=0
    for command in "$@"; do
        n=$((n + 1))
        status=0 output="$(cat "${out}/${n}.answer")"
        "hook_${want}" || { echo "not ${want}: ${command}"; echo "${output}"; return 1; }
    done
}
hook_passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
hook_denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

kept_openings() {
    printf '*\n' > "${GUARD_CONFIG_DIR}/agent-writes.txt"
    OWN="${GUARD_CONFIG_DIR}/openings.txt"
    SHARED="${H}/tool/contracts/openings.txt"
    printf '%s\n' '>Sent by the client' 'include ~/tool/contracts/openings.txt' > "${OWN}"
    printf '%s\n' '>Tab opened by the client' '>>From the other machine' > "${SHARED}"
}

@test "openings: under the grant an agent adds lines to openings.txt and takes none away" {
    kept_openings
    writes "${OWN}" $'>Sent by the client\ninclude ~/tool/contracts/openings.txt\n# one more\n>A new opening\ninclude ~/tool/more.txt\n'
    hook_passed
    writes "${OWN}" $'include ~/tool/contracts/openings.txt\n'
    hook_denied
    writes "${OWN}" $'>Sent by the client\n'
    hook_denied
    shells denied "rm ${OWN}" "printf 'x\n' > ${OWN}" "mv ${OWN} ${H}/away"
}

@test "openings: a file an include line names takes added openings only" {
    kept_openings
    writes "${SHARED}" $'>Tab opened by the client\n>>From the other machine\n>A new opening\n'
    hook_passed
    writes "${SHARED}" $'>Tab opened by the client\n'
    hook_denied
    shells denied "rm ${SHARED}" "printf 'x\n' > ${SHARED}" "mv ${SHARED} ${H}/away" "rm -r ${H}/tool/contracts"
}

@test "openings: reading them, and writing beside them, stay free" {
    kept_openings
    mkdir -p "${H}/tool.worktrees/next/contracts"
    shells passed "cat ${OWN} ${SHARED}" "grep -c '>' ${SHARED}" "cp ${SHARED} ${H}/copy.txt" \
                   "python3 -c 'print(open(\"${SHARED}\").read())'" "touch ${H}/tool/contracts/other.txt" \
                   "printf 'x\n' > ${H}/tool.worktrees/next/contracts/openings.txt" \
                   "cp ${OWN} ${GUARD_CONFIG_DIR}/openings.txt.bak"
    hook Read "$(jq -n --arg f "${SHARED}" '{file_path: $f}')"
    hook_passed
}

@test "openings: a search with a quoted bracket is a read, and a redirection behind one is a write" {
    kept_openings
    shell "grep -n \">>\" ${SHARED}"
    hook_passed
    shells denied "grep -c '>' ${OWN} > ${SHARED}" "grep x ${H}/a >${SHARED}" "grep -c '>' ${SHARED}; rm ${SHARED}" \
                   "grep ' '>${SHARED} x" "grep x \$(echo y > ${SHARED})" \
                   "grep x # it's"$'\n'"printf y > ${SHARED} #'" "sh -c 'printf y > ${SHARED}'"
}
