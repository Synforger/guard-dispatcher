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

# The branch of an if / for / while / until / case is where a `cd` takes effect only until the branch ends:
# what follows `fi`, `done` or `esac` stands where the branch began.

@test "send places: a cd inside a branch does not carry past the branch" {
    local command
    for command in "if true; then cd \$ELSEWHERE; ls; fi; git commit -m x" \
                   "if true; then cd \$ELSEWHERE; fi; git -C ${TOOL} push origin HEAD" \
                   "if true; then ls; elif false; then cd \$ELSEWHERE; else cd \$ELSEWHERE; fi; git commit -m x" \
                   "for d in a b; do cd \$ELSEWHERE; done; git commit -m x" \
                   "while false; do cd \$ELSEWHERE; done; git commit -m x" \
                   "until true; do cd \$ELSEWHERE; done; git commit -m x" \
                   "case x in a) cd \$ELSEWHERE;; b|c) cd \$ELSEWHERE;; esac; git commit -m x" \
                   "case x in (a) cd \$ELSEWHERE;; *) cd \$ELSEWHERE; esac; git commit -m x" \
                   "if true; then (cd \$ELSEWHERE); cd \$ELSEWHERE; fi; git commit -m x" \
                   "if true; then
                        cd \$ELSEWHERE
                        ls
                    fi
                    git commit -m x"; do
        bash_in "${TOOL}" "${command}"
        passed || { echo "refused: ${command}"; echo "${output}"; return 1; }
    done
}

@test "send places: a send inside a branch stands where the branch cd'd to" {
    local command
    for command in "if true; then cd \$ELSEWHERE; git push; fi" \
                   "if true; then ls; else cd \$ELSEWHERE; git commit -m x; fi" \
                   "if true; then ls; elif false; then cd \$ELSEWHERE && git commit -m x; fi" \
                   "for d in a; do cd \$ELSEWHERE; git commit -m x; done" \
                   "case x in a) cd \$ELSEWHERE; git commit -m x;; esac" \
                   "if true; then cd \$ELSEWHERE; if true; then git commit -m x; fi; fi"; do
        bash_in "${TOOL}" "${command}"
        unread || { echo "not refused: ${command}"; echo "${output}"; return 1; }
    done
}

@test "send places: a cd outside a branch still carries past it" {
    local command
    for command in "cd \$ELSEWHERE; if true; then ls; fi; git commit -m x" \
                   "cd \$ELSEWHERE; if true; then cd ${TOOL}; fi; git commit -m x" \
                   "if true; then ls; fi; cd \$ELSEWHERE; git push" \
                   "for d in a; do ls; done; cd \$ELSEWHERE && git commit -m x"; do
        bash_in "${TOOL}" "${command}"
        unread || { echo "not refused: ${command}"; echo "${output}"; return 1; }
    done
}

@test "send places: a branch gives back the place it began at, a folder the hooks reach" {
    bash_in "${TOOL}" "if true; then cd ${AGENT}; fi; git commit -m x"; passed
    bash_in "${AGENT}" "if true; then cd ${TOOL}; fi; git commit -m x"; denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
    bash_in "${AGENT}" "if true; then cd ${TOOL}; git commit -m x; fi"; passed
}

# The shape of a script that cleans up inside a branch and then commits and pushes where it started.
@test "send places: a cleanup inside a branch is no reason to refuse the commit and push after it" {
    bash_in "${TOOL}" "BASE_DIR=${TOOL}
if [ -z \"\$(git status --porcelain)\" ]; then
    if [ \"\$MADE\" -eq 1 ]; then
        cd \"\$BASE_CLONE\"
        git worktree remove \"\$BASE_DIR\"
    fi
    exit 0
fi
git commit -m x
git push origin HEAD"
    passed
}

# What a command line knows: the variables set in front of a program, `${W:-d}` and `${W:+v}` as the shell fills
# them in, and an `if` whose condition it can tell, which runs one branch only.

@test "send places: a variable set in front of a program is one that program's own command line knows" {
    bash_in "${TOOL}" "W=${TOOL} bash -c 'cd \$W && git commit -m x'"; passed
    bash_in "${TOOL}" "env W=${TOOL} bash -c 'cd \"\$W\" && git commit -m x'"; passed
    bash_in "${TOOL}" "W=${TOOL} X=1 eval 'cd \$W && git commit -m x'"; passed
    bash_in "${TOOL}" "bash -c 'cd \$W && git commit -m x'"; unread
    bash_in "${TOOL}" "W=\$ELSEWHERE bash -c 'cd \$W && git commit -m x'"; unread
    # the variable of one command is not the next command's
    bash_in "${TOOL}" "W=${TOOL} true; bash -c 'cd \$W && git commit -m x'"; unread
}

@test "send places: a default and an alternative are filled in as the shell does" {
    bash_in "${TOOL}" "W=${TOOL}; cd \${W:-\$ELSEWHERE} && git commit -m x"; passed
    bash_in "${TOOL}" "E=; cd \${E:-${TOOL}} && git commit -m x"; passed
    bash_in "${TOOL}" "W=${TOOL}; cd \${W:+\$W} && git commit -m x"; passed
    bash_in "${TOOL}" "W=${TOOL}; cd \"\${W:+\$W/}\" && git commit -m x"; passed
    bash_in "${TOOL}" "cd \${NOWHERE:-\$ELSEWHERE} && git commit -m x"; unread
    bash_in "${TOOL}" "cd \${NOWHERE:+${TOOL}} && git commit -m x"; unread
}

@test "send places: an if whose condition can be told reads the branch that runs, and no other" {
    local command
    for command in "W=${TOOL}; if [ -n \"\$W\" ]; then D=\$W; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x" \
                   "if [ -z \"\" ]; then D=${TOOL}; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x" \
                   "W=${TOOL}; if [ -n \"\${W:-}\" ]; then cd \$W; elif [ -n \"\$X\" ]; then cd \$ELSEWHERE; else cd \$ELSEWHERE; fi; git commit -m x" \
                   "if [ -n \"\"  ]; then cd \$ELSEWHERE; git commit -m x; fi" \
                   "if [ ! -d ${H}/nowhere ]; then D=${TOOL}; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x" \
                   "if [ -d ${TOOL} ]; then D=${TOOL}; fi; cd \$D && git commit -m x" \
                   "M=path; if [ \"\$M\" != path ]; then cd \$ELSEWHERE; git push; fi; git commit -m x" \
                   "if [[ -n ${TOOL} ]]; then D=${TOOL}; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x"; do
        bash_in "${TOOL}" "${command}"
        passed || { echo "refused: ${command}"; echo "${output}"; return 1; }
    done
}

@test "send places: an if whose condition cannot be told is read branch by branch, and what its branches set is not known after" {
    local command
    for command in "if [ -n \"\$U\" ]; then D=${TOOL}; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x" \
                   "if [ -n \"\$U\" ]; then D=${TOOL}; fi; cd \$D && git commit -m x" \
                   "if [ -n \"\$U\" ]; then D=${TOOL}; else D=${TOOL}/sub; fi; cd \$D && git commit -m x" \
                   "if [ -n \"\$U\" ]; then cd \$ELSEWHERE; git commit -m x; fi" \
                   "if git rev-parse --git-dir; then D=${TOOL}; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x" \
                   "if [ -n \"\" ]; then D=${TOOL}; elif [ -n \"\$U\" ]; then D=${TOOL}; else D=\$ELSEWHERE; fi; cd \$D && git commit -m x" \
                   "if [ -n \"\$U\" ] && [ -z \"\" ]; then cd \$ELSEWHERE; git commit -m x; fi" \
                   "if [ -n \"\"  ]; then D=${TOOL}; fi; cd \$D && git commit -m x" \
                   "W=${TOOL}; if [ \"\$W\" = \"\$U\" ]; then cd \$ELSEWHERE; git commit -m x; fi" \
                   "X=; for a in 1 2; do if [ -z \"\$X\" ]; then X=1; else cd \$ELSEWHERE; git commit -m x; fi; done" \
                   "for a in 1; do D=${TOOL}; done; cd \$D && git commit -m x" \
                   "case x in a) D=${TOOL};; esac; cd \$D && git commit -m x"; do
        bash_in "${TOOL}" "${command}"
        unread || { echo "not refused: ${command}"; echo "${output}"; return 1; }
    done
}
