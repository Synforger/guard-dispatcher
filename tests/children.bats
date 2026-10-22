#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py — a session that hands work to a child of its own.
#
# A parent opens a child in another tab. The parent says where the child may write, the child
# starts with what the parent had read, it talks to the parent only, and a child that mends a
# tool (a repository that publishes outside every area) starts with nothing but its task.
#
# The tab a session runs in is `PWA_SID`, which the client gives every tab and which outlives
# the session (a tab is given a new session when it rolls over). The client registers a child
# once it has opened its tab:
#
#     area-guard.py child check --parent TAB [--writes FILE] --text FILE
#         judge the task text the parent hands over; prints `area` or `tool`; exit 0 passes
#     area-guard.py child add --child TAB --parent TAB [--writes FILE]
#         register the child; prints `area` or `tool`; exit 0 registered, 1 refused
#     area-guard.py marks SESSION
#         the areas a session is held to, one per line
#
# FILE lists the places the child may write, one folder per line. The register is kept in the
# guard's state folder, which an agent does not write.
#
# A throwaway HOME holds a company with a client inside it, each with one made-up document, a
# repository per kind of place, and the files Claude Code keeps for its running sessions.

load helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
PEERS="${GUARD_ROOT}/agent-hooks/claude-code/peers.py"
CLIENT_TEXT="the calibration table reads seventeen at dawn"
COMPANY_TEXT="quarterly planning keeps the bench schedule"
OWN_TEXT="the page builder drops the last row when a title wraps"
PARENT=ses_parent
CHILD=ses_child
STRANGER=ses_stranger
ID_PARENT="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ID_PARENT_NEXT="aaaaaaaa-aaaa-4aaa-8aaa-bbbbbbbbbbbb"
ID_CHILD="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
ID_STRANGER="dddddddd-dddd-4ddd-8ddd-dddddddddddd"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    CASE_REPO="${H}/org/clients/acme/repos/pipeline"
    COMPANY_REPO="${H}/org/repos/internal"
    TOOL="${H}/repos/tool"
    TOOL_FIX="${H}/repos/tool.worktrees/fix"
    OTHER_TOOL="${H}/repos/other-tool"
    SCRATCH_REPO="${H}/repos/scratch"
    AGENT_REPO="${H}/agent"
    for r in "${CASE_REPO}" "${COMPANY_REPO}" "${TOOL}" "${TOOL_FIX}" "${OTHER_TOOL}" "${SCRATCH_REPO}" "${AGENT_REPO}"; do
        mkdir -p "${r}"
        git init -q "${r}"
    done
    mkdir -p "${H}/org/clients/acme/received" "${H}/org/meetings" "${H}/scratch" "${AGENT_REPO}/notes" "${GUARD_CONFIG_DIR}"
    printf '%s\n' "${CLIENT_TEXT}" > "${H}/org/clients/acme/received/notes.md"
    printf '%s\n' "${COMPANY_TEXT}" > "${H}/org/meetings/plan.md"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export GUARD_CORPUS_MAX_AGE=0
    unset GIT_CONFIG_GLOBAL CLAUDE_CONFIG_DIR TMUX TMUX_PANE
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org
client  ~/org/clients/acme
AREAS
    # The machine's git hooks: the global hooksPath points at a pre-push.
    mkdir -p "${H}/hooks"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    # The two tools publish outside every area; the scratch repository has no remote.
    for r in "${TOOL}" "${TOOL_FIX}"; do git -C "${r}" remote add origin git@github.com:me/tool.git; done
    git -C "${OTHER_TOOL}" remote add origin git@github.com:me/other-tool.git
    seed_visibility me/tool public
    seed_visibility me/other-tool public
    NOTE_PATH="${AGENT_REPO}/notes/${CHILD}.md"
    printf '# note\n' > "${NOTE_PATH}"
}

# --- fixtures ---------------------------------------------------------------------------

# call_as <tab> <session> <tool> <input json> [cwd] — one tool call of a tab's session.
call_as() {
    local event
    event="$(jq -n --arg t "$3" --argjson i "$4" --arg c "${5:-${H}}" --arg s "$2" \
        '{session_id: $s, tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse"}')"
    run env PWA_SID="$1" PWA_NOTE="${NOTE_AS:-}" python3 "${HOOK}" <<< "${event}"
}
read_as() { call_as "$1" "$2" Read "$(jq -n --arg p "$3" '{file_path: $p}')"; }
write_as() { call_as "$1" "$2" Write "$(jq -n --arg p "$3" '{file_path: $p, content: "x"}')"; }
bash_as() { call_as "$1" "$2" Bash "$(jq -n --arg c "$4" '{command: $c}')" "$3"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

# places <name> <folder>... — a file listing the places a child may write, as the client hands it over.
places() {
    local file="${BATS_TEST_TMPDIR}/places-$1.txt"
    shift
    printf '%s\n' "$@" > "${file}"
    PLACES="${file}"
}

# register <child tab> <parent tab> [folder ...] — what the client does once the child's tab is open.
register() {
    local child="$1" parent="$2"
    shift 2
    if [ "$#" -gt 0 ]; then
        places "${child}" "$@"
        run python3 "${HOOK}" child add --child "${child}" --parent "${parent}" --writes "${PLACES}"
    else
        run python3 "${HOOK}" child add --child "${child}" --parent "${parent}"
    fi
}

# task <text> — the task text a parent hands over, in a file.
task() { TASK="${BATS_TEST_TMPDIR}/task.txt"; printf '%s\n' "$1" > "${TASK}"; }

# the parent has read the client's folder, as its tier's start has it do
parent_read_client() { read_as "${PARENT}" "${ID_PARENT}" "${H}/org/clients/acme/received/notes.md"; passed; }
# the child's first call, which tells the guard which session the tab runs
child_starts() { read_as "${CHILD}" "${ID_CHILD}" "${SCRATCH_REPO}/seed.txt"; }

# session <config dir> <name> <id> — a running session, as Claude Code keeps it.
session() {
    mkdir -p "${H}/$1/sessions"
    jq -n --arg n "$2" --arg i "$3" --argjson p "$$" '{pid: $p, sessionId: $i, name: $n}' > "${H}/$1/sessions/$2-${RANDOM}.json"
}

# to_session <id> <text> — judge a message to a running session, as the client's check does.
to_session() {
    printf '%s\n' "$2" > "${BATS_TEST_TMPDIR}/message.txt"
    run python3 "${PEERS}" --to "$1" --text "${BATS_TEST_TMPDIR}/message.txt"
}

# --- 1. the parent says where the child may write --------------------------------------

@test "children: a child with no declared place writes in no repository" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}/a.py"
    denied
    [[ "${output}" == *"declared"* ]]
    write_as "${CHILD}" "${ID_CHILD}" "${COMPANY_REPO}/a.md"
    denied
}

@test "children: a child writes inside the places its parent declared" {
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}/a.py"
    passed
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}/lib/deep/b.py"
    passed
}

@test "children: a child writes nowhere else, in a repository the guard has no line about either" {
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL}/a.py"
    denied
    write_as "${CHILD}" "${ID_CHILD}" "${SCRATCH_REPO}/a.txt"
    denied
    write_as "${CHILD}" "${ID_CHILD}" "${COMPANY_REPO}/a.md"
    denied
}

@test "children: a commit counts as a write of its repository" {
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    bash_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}" "git commit -qm fix"
    passed
    bash_as "${CHILD}" "${ID_CHILD}" "${OTHER_TOOL}" "git commit -qm fix"
    denied
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" "git -C ${SCRATCH_REPO} commit -qm fix"
    denied
}

@test "children: a command that writes a file names the place it writes" {
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    bash_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}" "echo x > a.txt"
    passed
    bash_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}" "echo x > ${SCRATCH_REPO}/a.txt"
    denied
}

@test "children: a child always writes its own note, and no other" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    NOTE_AS="${NOTE_PATH}"
    write_as "${CHILD}" "${ID_CHILD}" "${NOTE_PATH}"
    passed
    write_as "${CHILD}" "${ID_CHILD}" "${AGENT_REPO}/notes/${PARENT}.md"
    denied
}

@test "children: files outside every repository stay writable for a child" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${H}/scratch/body.txt"
    passed
}

@test "children: a declaration cannot reach where the parent itself may not write" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${CASE_REPO}" "${COMPANY_REPO}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${COMPANY_REPO}"* ]]
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "area" ]
}

@test "children: a parent the guard has not seen cannot declare a child" {
    register "${CHILD}" "${STRANGER}" "${CASE_REPO}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${STRANGER}"* ]]
}

@test "children: with no areas on the machine, registering a child passes and changes nothing" {
    : > "${GUARD_CONFIG_DIR}/areas.txt"
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${OTHER_TOOL}/a.py"
    passed
}

@test "children: a session does not register a child, nor edit the register" {
    places mine "${TOOL_FIX}"
    bash_as "${PARENT}" "${ID_PARENT}" "${H}" "python3 ${HOOK} child add --child ${CHILD} --parent ${PARENT} --writes ${PLACES}"
    denied
    write_as "${CHILD}" "${ID_CHILD}" "${AREA_GUARD_STATE}/children/${CHILD}.json"
    denied
}

# --- 2. a child starts with what its parent had read ------------------------------------

@test "children: a child is held to the areas its parent had read when it started" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    child_starts
    run python3 "${HOOK}" marks "${ID_CHILD}"
    [ "${output}" = "client" ]
}

@test "children: a parent that had read nothing hands its child nothing" {
    read_as "${PARENT}" "${ID_PARENT}" "${H}/scratch/anything"
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    child_starts
    run python3 "${HOOK}" marks "${ID_CHILD}"
    [ "${status}" -eq 0 ] && [ -z "${output}" ]
}

@test "children: what the parent reads after the child started is not the child's" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    read_as "${PARENT}" "${ID_PARENT}" "${H}/org/meetings/plan.md"
    passed
    child_starts
    run python3 "${HOOK}" marks "${ID_CHILD}"
    [ "${output}" = "client" ]
}

@test "children: what the child reads is its own mark, and the parent's marks stay as they were" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    read_as "${CHILD}" "${ID_CHILD}" "${H}/org/meetings/plan.md"
    passed
    run python3 "${HOOK}" marks "${ID_CHILD}"
    [ "$(printf '%s\n' "${output}" | paste -sd, -)" = "client,company" ]
    run python3 "${HOOK}" marks "${ID_PARENT}"
    [ "${output}" = "client" ]
}

@test "children: the child keeps what its parent had read after the parent's tab starts a new session" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    read_as "${PARENT}" "${ID_PARENT_NEXT}" "${H}/scratch/anything"
    child_starts
    run python3 "${HOOK}" marks "${ID_CHILD}"
    [ "${output}" = "client" ]
}

@test "children: the parent's text goes to a child that has read what the parent had" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    child_starts
    session .claude child "${ID_CHILD}"
    to_session "${ID_CHILD}" "seen there: ${CLIENT_TEXT}"
    [ "${status}" -eq 0 ]
    to_session "${ID_CHILD}" "seen there: ${COMPANY_TEXT}"
    [ "${status}" -eq 1 ]
}

@test "children: the task text is judged against what the parent had read" {
    parent_read_client
    places child "${CASE_REPO}"
    task "start from this: ${CLIENT_TEXT}"
    run python3 "${HOOK}" child check --parent "${PARENT}" --writes "${PLACES}" --text "${TASK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "area" ]
    task "start from this: ${COMPANY_TEXT}"
    run python3 "${HOOK}" child check --parent "${PARENT}" --writes "${PLACES}" --text "${TASK}"
    [ "${status}" -eq 1 ]
}

# --- 3. a child talks to its parent only ------------------------------------------------

@test "children: a child sends to its parent's tab" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    printf 'done\n' > "${BATS_TEST_TMPDIR}/body.txt"
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" "tabs send ${PARENT} ${BATS_TEST_TMPDIR}/body.txt"
    passed
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" "tabs report done ${BATS_TEST_TMPDIR}/body.txt"
    passed
}

@test "children: a child sends to no other tab" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    printf 'hello\n' > "${BATS_TEST_TMPDIR}/body.txt"
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" "tabs send ${STRANGER} ${BATS_TEST_TMPDIR}/body.txt"
    denied
    [[ "${output}" == *"${PARENT}"* ]]
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" "tabs send 'Main tab' ${BATS_TEST_TMPDIR}/body.txt"
    denied
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" "tabs send home:${PARENT} ${BATS_TEST_TMPDIR}/body.txt"
    denied
}

@test "children: a child does not reach another session through the client's message endpoint" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    bash_as "${CHILD}" "${ID_CHILD}" "${H}" \
        "curl -s -X POST http://127.0.0.1:8765/agent-messages -F to=${STRANGER} -F from=${CHILD} -F text=hi"
    denied
}

@test "children: a child does not message a running session by name either" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    session .claude stranger "${ID_STRANGER}"
    call_as "${CHILD}" "${ID_CHILD}" SendMessage "$(jq -n --arg t stranger --arg m "${OWN_TEXT}" '{to: $t, message: $m}')"
    denied
}

@test "children: a child messages its parent's running session by name" {
    register "${CHILD}" "${PARENT}"
    [ "${status}" -eq 0 ]
    read_as "${PARENT}" "${ID_PARENT}" "${H}/scratch/anything"
    session .claude boss "${ID_PARENT}"
    call_as "${CHILD}" "${ID_CHILD}" SendMessage "$(jq -n --arg t boss --arg m "${OWN_TEXT}" '{to: $t, message: $m}')"
    passed
}

@test "children: a tab that is no child sends to any tab, as before" {
    printf 'hello\n' > "${BATS_TEST_TMPDIR}/body.txt"
    bash_as "${PARENT}" "${ID_PARENT}" "${H}" "tabs send ${STRANGER} ${BATS_TEST_TMPDIR}/body.txt"
    passed
    session .claude stranger "${ID_STRANGER}"
    call_as "${PARENT}" "${ID_PARENT}" SendMessage "$(jq -n --arg t stranger --arg m "${OWN_TEXT}" '{to: $t, message: $m}')"
    passed
}

# --- 4. a child that mends a tool starts with nothing but its task ----------------------

@test "children: a child whose places all publish outside every area is a tool child, whatever its parent read" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "tool" ]
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}/a.py"
    passed
    bash_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}" "git commit -qm fix"
    passed
}

@test "children: a tool child is held to nothing its parent had read" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    child_starts
    run python3 "${HOOK}" marks "${ID_CHILD}"
    [ "${status}" -eq 0 ] && [ -z "${output}" ]
    session .claude child "${ID_CHILD}"
    to_session "${ID_CHILD}" "seen there: ${CLIENT_TEXT}"
    [ "${status}" -eq 1 ]
    to_session "${ID_CHILD}" "${OWN_TEXT}"
    [ "${status}" -eq 0 ]
}

@test "children: a tool child is bound to its places like any child" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${OTHER_TOOL}/a.py"
    denied
    write_as "${CHILD}" "${ID_CHILD}" "${COMPANY_REPO}/a.md"
    denied
}

@test "children: a tool child that reads an area is held to it from then on" {
    parent_read_client
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    read_as "${CHILD}" "${ID_CHILD}" "${H}/org/clients/acme/received/notes.md"
    passed
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}/a.py"
    denied
}

@test "children: the task text for a tool child is scanned for copies as for a session that read nothing" {
    parent_read_client
    places child "${TOOL_FIX}"
    task "mend the parser; the table reads: ${CLIENT_TEXT}"
    run python3 "${HOOK}" child check --parent "${PARENT}" --writes "${PLACES}" --text "${TASK}"
    [ "${status}" -eq 1 ]
    task "mend the parser; a row is dropped when a title wraps"
    run python3 "${HOOK}" child check --parent "${PARENT}" --writes "${PLACES}" --text "${TASK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "tool" ]
}

@test "children: one place in an area, or one that is no tool, makes the child an area child" {
    read_as "${PARENT}" "${ID_PARENT}" "${H}/scratch/anything"
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}" "${CASE_REPO}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "area" ]
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}" "${SCRATCH_REPO}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "area" ]
}

@test "children: a tool child's parent need not be a session that may write the tool" {
    parent_read_client
    write_as "${PARENT}" "${ID_PARENT}" "${TOOL_FIX}/a.py"
    denied
    register "${CHILD}" "${PARENT}" "${TOOL_FIX}"
    [ "${status}" -eq 0 ]
    write_as "${CHILD}" "${ID_CHILD}" "${TOOL_FIX}/a.py"
    passed
}
