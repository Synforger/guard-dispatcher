#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py + _common/shell_commands.py — a command line inside a
# command line is judged where it runs, as the shell reads the quotes around it.
#
# A throwaway HOME holds the guard's settings and a repository; nothing a test hands the hook runs.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    REPO="${H}/repos/tool"
    mkdir -p "${REPO}" "${H}/org" "${GUARD_CONFIG_DIR}"
    git init -q "${REPO}"
    git -C "${REPO}" remote add origin "${SYNFORGER_URL}"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL
    printf '[core]\n\thooksPath = %s\n' "${GUARD_ROOT}/git-hooks" > "${H}/.gitconfig"
    printf 'company ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    KEPT="${GUARD_CONFIG_DIR}/orders.txt"
    printf '%s\n' '送信して' > "${KEPT}"
}

# judged <passed|denied> <command>... — run the hook on each command at once, each a call of its own.
judged() {
    local want="$1" n=0 command answer waited=() out="${BATS_TEST_TMPDIR}/answers"
    shift
    mkdir -p "${out}"
    for command in "$@"; do
        n=$((n + 1))
        jq -n --arg m "${command}" --arg c "${REPO}" \
            '{session_id: "s1", tool_name: "Bash", tool_input: {command: $m}, cwd: $c, hook_event_name: "PreToolUse"}' \
            > "${out}/${n}.event"
        python3 "${HOOK}" < "${out}/${n}.event" > "${out}/${n}.answer" &
        waited+=($!)
    done
    for n in "${waited[@]}"; do wait "${n}" || return 1; done
    n=0
    for command in "$@"; do
        n=$((n + 1))
        answer=passed
        grep -q '"permissionDecision": "deny"' "${out}/${n}.answer" && answer=denied
        [ "${answer}" = "${want}" ] || { echo "not ${want}: ${command}"; cat "${out}/${n}.answer"; return 1; }
    done
}

@test "command reading: a write is found at every depth of a command line" {
    judged denied \
        "echo \"\$(echo x > ${KEPT})\"" \
        "echo \"\`echo x > ${KEPT}\`\"" \
        "v=\"\$(true; echo x >> ${KEPT})\"" \
        "echo \"\${v:-\$(echo x > ${KEPT})}\"" \
        "echo \"\$(echo \"\$(rm ${KEPT})\")\"" \
        "bash -c 'echo \"\$(echo x > ${KEPT})\"'" \
        "cd ${GUARD_CONFIG_DIR} && echo \"\$(echo x > orders.txt)\"" \
        "D=${GUARD_CONFIG_DIR}; echo \"\$(echo x > \$D/orders.txt)\"" \
        "cat <<END"$'\n'"\$(echo x > ${KEPT})"$'\n'"END"
}

@test "command reading: the hooks and a send are held at every depth of a command line" {
    judged denied \
        "echo \"\$(git config core.hooksPath .husky)\"" \
        "echo \"\$(git commit -n -m x)\"" \
        "echo \"\$(git commit --no-verify -m x)\"" \
        "echo \"\$(cd \$ELSEWHERE && git push)\""
}

@test "command reading: text the shell does not run, and everyday substitutions, pass" {
    judged passed \
        "echo '\$(echo x > ${KEPT})'" \
        "echo \"\\\$(echo x > ${KEPT})\"" \
        "cat <<'END'"$'\n'"\$(echo x > ${KEPT})"$'\n'"END" \
        "echo \"today \$(date +%F)\"" \
        "echo \"\$(cat ${KEPT})\"" \
        "n=\"\$(grep -c . ${KEPT})\"; echo \"\$n\"" \
        "(cd ${GUARD_CONFIG_DIR} && true); echo \"\$(echo x > orders.txt)\"" \
        "echo \"\$(cd /tmp && pwd)\" && git status" \
        "git commit -m \"\$(cat <<'END'"$'\n'"fix: the reader, told in two lines"$'\n\n'"it follows (and notes) what runs"$'\n'"END"$'\n'")\""
}

@test "command reading: a heredoc's inner command is written ahead of the command that opens it" {
    run python3 -c 'import sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
from shell_commands import with_inner_first
line = "cd /a && cat <<E\n$(x)\nE\nnext"
print(with_inner_first(line) == "cd /a &&  ( x\n); cat <<E\n$(x)\nE\nnext")' "${GUARD_ROOT}/_common"
    [ "${output}" = "True" ]
}

@test "command reading: the line breaks of a long line are read in one pass" {
    run python3 -c 'import sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
from shell_lines import with_line_breaks
def joins(lines):
    seen = []
    command = "echo a\n" * lines
    sys.setprofile(lambda _, event, called: seen.append(1) if event == "c_call" and getattr(called, "__name__", "") == "join" else None)
    try:
        with_line_breaks(command)
    finally:
        sys.setprofile(None)
    return len(seen)
print(joins(10) == joins(1000))' "${GUARD_ROOT}/_common"
    [ "${output}" = "True" ]
}

@test "command reading: a script reached by several ways is read once" {
    local n
    for n in 1 2 3; do
        printf 'v="$(bash s%d.sh)"\nbash s%d.sh\nbash s%d.sh\n' $((n + 1)) $((n + 1)) $((n + 1)) > "${REPO}/s${n}.sh"
    done
    printf 'git push\n' > "${REPO}/s4.sh"
    run python3 -c 'import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
sys.modules["guard"] = guard
spec.loader.exec_module(guard)
read, words = [], guard.shell_words
guard.shell_words = lambda line, **options: read.append(line) or words(line, **options)
sends = guard.send_places("bash s1.sh; bash s1.sh", sys.argv[2])[0]
print(len(read) == len(set(read)), len(sends))' "${HOOK}" "${REPO}"
    [ "${output}" = "True 1" ]
}

@test "command reading: what a command writes is named once, however often the line holds it" {
    run python3 -c 'import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
sys.modules["guard"] = guard
spec.loader.exec_module(guard)
written, removed, orders = guard.named_with_folders("v=$(echo x > out; rm gone)", sys.argv[2])
print(*(len(found) == len(set(map(repr, found))) and len(found) > 0 for found in (written, removed, orders)))' "${HOOK}" "${REPO}"
    [ "${output}" = "True True True" ]
}

@test "command reading: code a substitution runs is read once for what it writes" {
    printf 'open("out.txt", "w").write("x")\n' > "${REPO}/w.py"
    run python3 -c 'import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
sys.modules["guard"] = guard
spec.loader.exec_module(guard)
read, paths = [], guard.code_paths
guard.code_paths = lambda code, base: read.append(code) or paths(code, base)
written = guard.named_with_folders("v=$(python3 w.py)", sys.argv[2])[0]
print(len(read), any(path.name == "out.txt" for path in written))' "${HOOK}" "${REPO}"
    [ "${output}" = "1 True" ]
}

@test "command reading: the paths a script names are read once, however it is reached" {
    local n
    for n in 1 2 3; do
        printf 'v="$(bash r%d.sh)"\nbash r%d.sh\nbash r%d.sh\n' $((n + 1)) $((n + 1)) $((n + 1)) > "${REPO}/r${n}.sh"
    done
    printf 'cat %s/org/notes.md\n' "${H}" > "${REPO}/r4.sh"
    run python3 -c 'import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
sys.modules["guard"] = guard
spec.loader.exec_module(guard)
read, ran = [], guard.ran_scripts
guard.ran_scripts = lambda *at: read.append(at) or ran(*at)
for _ in range(3):
    paths = guard.named_paths("bash r1.sh; bash r1.sh", sys.argv[2])
print(len(read) == len(set(read)), any(path.name == "notes.md" for path in paths))' "${HOOK}" "${REPO}"
    [ "${output}" = "True True" ]
}
