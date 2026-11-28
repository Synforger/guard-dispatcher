#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py — where a git or gh send runs from when the command spells
# the folder with a variable: one set to a literal earlier in the command (or in the session's
# environment) is written out, and one only known as the command runs is refused with a reason.
#
# A throwaway HOME holds an agent's own repository (exempt, with a remote: a send from it is
# judged as going around the hooks), a tool's repository the hooks reach, and one whose own
# core.hooksPath switches them off.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    AGENT="${H}/agents/me"
    TOOL="${H}/repos/tool"
    HUSKY="${H}/repos/husky"
    for r in "${AGENT}" "${TOOL}" "${HUSKY}"; do
        mkdir -p "${r}"
        git init -q "${r}"
        git -C "${r}" remote add origin "git@github.com:o/$(basename "${r}").git"
    done
    git -C "${AGENT}" config guard.scope exempt
    git -C "${HUSKY}" config core.hooksPath .husky
    mkdir -p "${H}/org"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER
    mkdir -p "${GUARD_CONFIG_DIR}" "${H}/hooks"
    printf 'company ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    for r in me tool husky; do seed_visibility "o/${r}" private; done
}

# bash_in <cwd> <command> — run the hook on one Bash call made from <cwd>.
bash_in() {
    local event
    event="$(jq -n --arg c "$2" --arg d "$1" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }
unread() { denied && [[ "${output}" == *"sends from a folder only known as it runs"* ]]; }

@test "send places: a send from the agent's own repository is still judged as going around the hooks" {
    bash_in "${AGENT}" "git commit -m x"
    denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
}

@test "send places: a folder set to a literal earlier in the command is where the send runs" {
    bash_in "${AGENT}" "W=${TOOL}; cd \$W && git commit -m x"; passed
    bash_in "${AGENT}" "W=${TOOL}; git -C \"\$W\" commit -m x"; passed
    bash_in "${AGENT}" "export W=${TOOL} && git -C \${W} push origin HEAD"; passed
    bash_in "${AGENT}" "R=${H}/repos; cd \$R/tool && git commit -m x"; passed
}

@test "send places: a folder of the session's environment is written out" {
    bash_in "${AGENT}" "cd \$HOME/repos/tool && git commit -m x"; passed
}

@test "send places: a variable set to a folder whose hooks are off still lands there, and is refused" {
    bash_in "${TOOL}" "W=${HUSKY}; cd \$W && git commit -m x"
    denied
    [[ "${output}" == *"overrides core.hooksPath"* ]]
}

@test "send places: a folder only known as the command runs is refused with how to write it" {
    bash_in "${TOOL}" "cd \$ELSEWHERE && git commit -m x"; unread
    [[ "${output}" == *"(\$ELSEWHERE)"* ]]
    bash_in "${TOOL}" "git -C \"\$(git rev-parse --show-toplevel)\" commit -m x"; unread
    bash_in "${TOOL}" "W=\$(pwd); cd \$W && git push"; unread
    bash_in "${TOOL}" "cd \$ELSEWHERE && cd sub && gh pr create --title t --body b"; unread
    bash_in "${TOOL}" "bash -c 'cd \$ELSEWHERE && git commit -m x'"; unread
}

@test "send places: the place comes back once the command goes to a folder written out" {
    bash_in "${TOOL}" "cd \$ELSEWHERE && cd ${TOOL} && git commit -m x"; passed
    bash_in "${TOOL}" "(cd \$ELSEWHERE && make); git commit -m x"; passed
    bash_in "${TOOL}" "pushd \$ELSEWHERE && popd && git commit -m x"; passed
    bash_in "${TOOL}" "cd \$ELSEWHERE && ls && cat notes.md"; passed
}

@test "send places: a wrapper's option that takes a value hides no send, and env -C runs it in that folder" {
    # From the tool's repository a commit passes; each send below stands in the agent's own one.
    for command in "env -u HOME git -C ${AGENT} commit -m x" "sudo -u me git -C ${AGENT} commit -m x" \
                   "nice -n 10 git -C ${AGENT} commit -m x" "env -C ${AGENT} git commit -m x" \
                   "env --chdir=${AGENT} git commit -m x" "env -S 'git -C ${AGENT} commit -m x'" \
                   "xargs -I {} git -C ${AGENT} commit -m x"; do
        bash_in "${TOOL}" "${command}"
        denied || { echo "not judged: ${command}"; return 1; }
    done
    # env -C moves only the command it runs: the line stands where it stood after it.
    bash_in "${AGENT}" "env -C ${TOOL} true; cd ${TOOL} && git commit -m x"; passed
    bash_in "${TOOL}" "env -C ${AGENT} true; git commit -m x"; passed
}

# --- code written into the command is not a command line ---------------------------------------

# A python (or node) heredoc that rewrites a test script holds shell lines as strings. A quote it
# leaves open for the shell (`\'` in a single-quoted python string) turned the whole body into words
# split on spaces, and the ` && git commit` in the string was read as a send from `$WORK`.
EDIT_STRINGS=$'python3 - <<\'PY\'\ns = open("t.sh").read()\ns = s.replace("A", \'it\\\'s \' + \'x && cd "${WORK}/repo" && git commit -m z\')\nPY'

@test "send places: shell lines held in a python heredoc's strings are no send" {
    bash_in "${TOOL}" "${EDIT_STRINGS}"; passed
    bash_in "${TOOL}" $'node - <<\'JS\'\nconst s = \'it\\\'s \' + \'x && cd $WORK && git push\';\nJS'; passed
    bash_in "${TOOL}" $'python3 - <<\'PY\'\nt = """\ncd $WORK\ngit commit -m x\n"""\nPY'; passed
}

@test "send places: a send written around such a heredoc still stops" {
    bash_in "${TOOL}" "${EDIT_STRINGS}"$'\ncd $ELSEWHERE && git commit -m x'; unread
    bash_in "${TOOL}" $'cd $ELSEWHERE && python3 - <<\'PY\'\nprint(1)\nPY\ngit commit -m x'; unread
    bash_in "${TOOL}" $'python3 - <<\'PY\' && cd $ELSEWHERE && git commit -m x\nprint(1)\nPY'; unread
    bash_in "${TOOL}" "python3 -c 'print(1)' && cd \$ELSEWHERE && git push"; unread
}

@test "send places: a shell fed a heredoc sends from where its lines say, as a line of the command does" {
    bash_in "${TOOL}" $'bash <<\'SH\'\ncd $ELSEWHERE\ngit commit -m x\nSH'; unread
    bash_in "${TOOL}" $'sh <<\'SH\'\ngit -C "$(pwd)" push\nSH'; unread
    bash_in "${TOOL}" $'zsh -e <<SH\nsleep 1\ncd $ELSEWHERE && gh pr create --title t --body b\nSH'; unread
    bash_in "${TOOL}" $'cd $ELSEWHERE && bash <<\'SH\'\ngit commit -m x\nSH'; unread
    bash_in "${TOOL}" $'bash <<\'SH\'\ncd '"${AGENT}"$'\ngit commit -m x\nSH'; denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
    bash_in "${TOOL}" $'bash <<\'SH\'\ncd '"${HUSKY}"$'\ngit commit -m x\nSH'; denied
    [[ "${output}" == *"overrides core.hooksPath"* ]]
}

@test "send places: a shell heredoc that sends nothing, or one written out, passes" {
    bash_in "${TOOL}" $'bash <<\'SH\'\ncd $ELSEWHERE\nls\nSH'; passed
    bash_in "${TOOL}" $'bash <<\'SH\'\ncd '"${TOOL}"$'\ngit commit -m x\nSH'; passed
    bash_in "${TOOL}" $'bash -e <<\'SH\' && git commit -m y\nls\nSH'; passed
    bash_in "${TOOL}" $'cat <<\'NOTE\'\ncd $ELSEWHERE\ngit commit -m x\nNOTE'; passed
    bash_in "${TOOL}" $'bash <<\'SH\'\ncd $ELSEWHERE\nSH\ngit commit -m x'; passed
}

@test "send places: a substitution in a heredoc the shell fills in runs before the program it feeds, and is read" {
    bash_in "${TOOL}" $'node <<JS\nconsole.log("$(cd $ELSEWHERE && git commit -m x)")\nJS'; unread
    bash_in "${TOOL}" $'python3 <<PY\nprint("`cd $ELSEWHERE && git push`")\nPY'; unread
    bash_in "${TOOL}" $'node <<\'JS\'\nconsole.log("$(cd $ELSEWHERE && git commit -m x)")\nJS'; passed
}

# --- a value the command line gives a script it runs ---------------------------------------------

# pick.sh sends from the folder DEST names, else from one only known as it runs.
pick_script() {
    printf '%s\n' "${1:-}" \
        'if [ -n "${DEST:-}" ]; then' '    D="$DEST"' \
        'elif [ -n "$OTHER" ] && true; then' '    D="$OTHER/x"' \
        'else' '    D="$(mktemp -d)"' 'fi' \
        'cd "$D" && git commit -m x' > "${TOOL}/pick.sh"
}

@test "send places: a value the command line gives a script picks the branch its if tests, and the folder it names" {
    pick_script
    bash_in "${TOOL}" "DEST=${TOOL} bash pick.sh"; passed
    bash_in "${TOOL}" "DEST=${AGENT} bash pick.sh"; denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
}

@test "send places: without a value written out, or with a script that may change it, every branch is read" {
    pick_script
    bash_in "${TOOL}" "bash pick.sh"; unread
    bash_in "${TOOL}" "DEST= bash pick.sh"; unread
    bash_in "${TOOL}" "DEST=\$ELSEWHERE bash pick.sh"; unread
    bash_in "${TOOL}" "DEST='${TOOL} x' bash pick.sh"; unread
    local line
    for line in "BASH_ENV=/dev/null DEST=${TOOL} bash pick.sh" "export BASH_ENV=/dev/null; DEST=${TOOL} bash pick.sh" \
                "B=/dev/null; BASH_ENV=\$B; export BASH_ENV; DEST=${TOOL} bash pick.sh" \
                "declare -x BASH_ENV=/dev/null; DEST=${TOOL} bash pick.sh" \
                "export BASH_ENV=/dev/null && DEST=${TOOL} bash pick.sh" "export ENV=/dev/null; DEST=${TOOL} sh pick.sh"; do
        bash_in "${TOOL}" "${line}"
        unread || { echo "not read whole: ${line}"; return 1; }
    done
    local change
    for change in 'DEST=/tmp' 'unset DEST' 'read -r DEST' ': "${DEST:=/tmp}"' 'source ./env.sh' 'export DEST=/tmp' \
                  '(( DEST = 1 ))' 'declare -n R=DEST' 'trap "DEST=/tmp" EXIT' 'DEST[0]=/tmp' 'test() { true; }' \
                  'alias test=true' 'wait -p DEST' 'exec env -u DEST bash "$0"' 'builtin source ./env.sh' \
                  'command unset DEST' 'builtin eval true'; do
        pick_script "${change}"
        bash_in "${TOOL}" "DEST=${TOOL} bash pick.sh"
        unread || { echo "not read whole after: ${change}"; return 1; }
    done
}

@test "send places: an if that tests more than the given value is read whole, and its condition is always read" {
    printf '%s\n' 'if [ -n "${DEST:-}" ] && true; then' '    D="$DEST"' 'else' '    D="$(mktemp -d)"' 'fi' \
        'cd "$D" && git commit -m x' > "${TOOL}/more.sh"
    bash_in "${TOOL}" "DEST=${TOOL} bash more.sh"; unread
    printf '%s\n' 'if git -C "$DEST" commit -m x; then :; fi' > "${TOOL}/cond.sh"
    bash_in "${TOOL}" "DEST=${AGENT} bash cond.sh"; denied
    printf '%s\n' 'if [ -z "${DEST:-}" ]; then' '    cd "$(mktemp -d)" && git commit -m x' 'fi' \
        'git -C "$DEST" commit -m y' > "${TOOL}/skip.sh"
    bash_in "${TOOL}" "DEST=${TOOL} bash skip.sh"; passed
    bash_in "${TOOL}" "DEST=${AGENT} bash skip.sh"; denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
}

@test "send places: a commit in a folder mktemp -d makes is judged where that folder lies" {
    export TMPDIR="${H}/tmp"
    local c
    for c in 'T="$(mktemp -d)"; REPO="${T}/repos/tool"; git init -q "${REPO}"; git -C "${REPO}" commit -q --allow-empty -m base' \
             'T=$(mktemp -d); cd "$T" && git init -q && git commit -q --allow-empty -m x' \
             'T=$(mktemp -d -t guard); git -C "$T/r" commit -m x' \
             'T=`mktemp -d`; git -C "$T" commit -m x'; do
        bash_in "${TOOL}" "${c}"
        passed || { echo "held: ${c}: ${output}"; return 1; }
    done
}

@test "send places: a push from a folder mktemp makes, and a commit in a file it makes, stay unknown until they run" {
    export TMPDIR="${H}/tmp"
    local c
    for c in 'T=$(mktemp -d); git -C "$T" push origin main' 'T=$(mktemp -d); cd $T; git push' \
             'T=$(mktemp); git -C "$T" commit -m x' 'echo "T=$(mktemp -d)"; git -C "$T" commit -m x'; do
        bash_in "${TOOL}" "${c}"
        unread || { echo "not refused as unknown: ${c}: ${output}"; return 1; }
    done
}

