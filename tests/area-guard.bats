#!/usr/bin/env bats
# agent-hooks/claude-code/area-guard.py — the agent-side entry guard.
#
# A throwaway HOME holds a company folder with a client inside it, a personal
# repository, and the operator's own notes (_exempt). Every call feeds the hook
# the JSON Claude Code sends before a tool runs.

load helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    CASE="${H}/org/clients/acme"
    CASE_REPO="${CASE}/repos/pipeline"
    COMPANY_REPO="${H}/org/repos/internal"
    PERSONAL="${H}/repos/public-tool"
    NOTES="${H}/notes"
    for r in "${CASE_REPO}" "${COMPANY_REPO}" "${PERSONAL}" "${NOTES}"; do
        mkdir -p "${r}"
        git init -q "${r}"
    done
    mkdir -p "${CASE}/received"
    printf 'client value 12.3456\n' > "${CASE}/received/memo.md"
    printf 'internal\n' > "${COMPANY_REPO}/notes.md"
    ln -s "${CASE}" "${H}/org/acme-link"

    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL
    mkdir -p "${GUARD_CONFIG_DIR}"
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org
client  ~/org/clients/acme
_exempt ~/notes
AREAS
    # The machine's git hooks: the global hooksPath points at a pre-push.
    mkdir -p "${H}/hooks"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    # Whether a destination is public is answered from the scan's cache, never GitHub.
    seed_visibility o/r private
}

# agent <tool> <key> <value> [cwd] [session] — run the hook on one tool call.
agent() {
    local event
    event="$(python3 -c 'import json, sys
tool, key, value, cwd, session = sys.argv[1:]
print(json.dumps({"session_id": session, "tool_name": tool, "tool_input": {key: value},
                  "cwd": cwd, "hook_event_name": "PreToolUse"}))' "$1" "$2" "$3" "${4:-${H}}" "${5:-s1}")"
    run python3 "${HOOK}" <<< "${event}"
}

bash_in() { agent Bash command "$2" "$1" "${3:-s1}"; }
write_to() { agent Write file_path "$1" "${H}" "${2:-s1}"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

read_case() {
    agent Read file_path "${CASE}/received/memo.md" "${H}" "${1:-s1}"
    passed
}

origin() { git -C "$1" remote add origin "git@github.com:$2.git"; }

# --- an unmarked session is never refused -----------------------------------

@test "area-guard: an unmarked session writes and commits anywhere, silently" {
    write_to "${PERSONAL}/a.py"; passed
    bash_in "${PERSONAL}" "git commit -m x"; passed
}

# --- a session that read a client's folder ----------------------------------

@test "area-guard: a client reader cannot write a personal repository" {
    read_case
    write_to "${PERSONAL}/a.py"; denied
    agent Edit file_path "${PERSONAL}/b.py"; denied
}

@test "area-guard: a client reader cannot write a company repository" {
    read_case
    write_to "${COMPANY_REPO}/c.py"; denied
}

@test "area-guard: a client reader writes inside the client and the exempt notes" {
    read_case
    write_to "${CASE_REPO}/ok.py"; passed
    write_to "${NOTES}/journal/x.md"; passed
}

@test "area-guard: a client reader writes files outside any repository" {
    read_case
    write_to "${H}/scratch/n.txt"; passed
}

@test "area-guard: a client reader cannot commit or push outside" {
    read_case
    bash_in "${PERSONAL}" "git commit -m x"; denied
    bash_in "${H}" "git -C ${PERSONAL} push"; denied
    bash_in "${H}" "cd ${PERSONAL} && git push origin x"; denied
}

@test "area-guard: a client reader commits inside the client" {
    read_case
    bash_in "${CASE_REPO}" "git commit -m x"; passed
}

@test "area-guard: a sending gh call is refused, a reading one passes" {
    read_case
    bash_in "${PERSONAL}" "gh pr create --fill"; denied
    bash_in "${PERSONAL}" "gh api -X POST repos/o/r/issues"; denied
    bash_in "${PERSONAL}" "gh pr view 3"; passed
    bash_in "${PERSONAL}" "gh api repos/o/r"; passed
}

# --- the destination decides, not the folder the command is typed in --------

@test "area-guard: gh from inside the client to a public repository is refused" {
    read_case
    seed_visibility someone/public-tool public
    bash_in "${CASE_REPO}" "gh pr create -R someone/public-tool --fill"; denied
    bash_in "${CASE_REPO}" "gh api -XPOST repos/someone/public-tool/issues -f body=x"; denied
}

@test "area-guard: a push from the client repository to a public remote is refused" {
    read_case
    origin "${CASE_REPO}" acme/pipeline
    seed_visibility acme/pipeline public
    bash_in "${CASE_REPO}" "git push origin main"; denied
}

@test "area-guard: sends to the client's own private repository pass" {
    read_case
    origin "${CASE_REPO}" acme/pipeline
    seed_visibility acme/pipeline private
    bash_in "${CASE_REPO}" "git push"; passed
    bash_in "${CASE_REPO}" "gh pr create --fill"; passed
}

@test "area-guard: commit then push on one line is judged by the push" {
    read_case
    origin "${CASE_REPO}" acme/pipeline
    seed_visibility acme/pipeline public
    bash_in "${CASE_REPO}" "git add -A && git commit -m x && git push"; denied
}

@test "area-guard: cd with a trailing semicolon names the folder" {
    read_case
    bash_in "${H}" "cd ${NOTES}; git add -A && git commit -m x"; passed
    bash_in "${H}" "cd ${PERSONAL}; git commit -m x"; denied
}

@test "area-guard: gh search is a read" {
    read_case
    bash_in "${PERSONAL}" "gh search code secret"; passed
}

# --- switching the guards off or around is refused, marked or not -----------

@test "area-guard: skip flags on a send are refused" {
    for command in "GH_GUARD_SKIP=1 gh pr create --fill" "GUARD_CORPUS_SKIP=1 git push" \
                   "git push --no-verify" "git commit --no-verify -m x" "git commit -nm x" \
                   "git -c core.hooksPath=/dev/null commit -m x" "HUSKY=0 git commit -m x"; do
        bash_in "${PERSONAL}" "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
}

@test "area-guard: skip flags on a read pass" {
    bash_in "${PERSONAL}" "GH_GUARD_SKIP=1 gh search code x"; passed
    bash_in "${PERSONAL}" "git commit -m 'mention -n in text'"; passed
}

@test "area-guard: turning the hooks off by git config is refused" {
    for command in "git config core.hooksPath .husky" "git config --local guard.scope exempt" \
                   "git config --global guard.exemptPrefix ~/x"; do
        bash_in "${PERSONAL}" "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
    bash_in "${PERSONAL}" "git config --get core.hooksPath"; passed
}

@test "area-guard: reading a guard key passes, however it is spelled" {
    for command in "git config core.hooksPath" "git config --global core.hooksPath" \
                   "git config get core.hooksPath" "git config --show-origin guard.scope" \
                   "git -C ${PERSONAL} config --list" "git config --get-regexp 'guard\\..*'" \
                   "git config --file .gitmodules core.hooksPath"; do
        bash_in "${PERSONAL}" "${command}"
        passed || { echo "refused: ${command}"; return 1; }
    done
}

@test "area-guard: writing a guard key is refused, even beside a read" {
    for command in "git config set core.hooksPath .husky" "git config --unset core.hooksPath" \
                   "git config --replace-all guard.scope exempt" "git config --add guard.exemptPrefix ~/x" \
                   "git config --file .git/config core.hooksPath /dev/null" \
                   "git config --type=path core.hooksPath /dev/null" \
                   "git config --list; git config core.hooksPath /dev/null" \
                   "git config --get core.hooksPath && git config --global core.hooksPath /dev/null" \
                   "git -C ${PERSONAL} config guard.scope exempt"; do
        bash_in "${PERSONAL}" "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
}

@test "area-guard: clearing the marks is refused" {
    bash_in "${H}" "rm -f ~/.cache/area-guard/s1.json"; denied
    write_to "${H}/.cache/area-guard/s1.json"; denied
}

@test "area-guard: a send from a repository the hooks do not reach is refused" {
    git -C "${PERSONAL}" config core.hooksPath .husky
    bash_in "${PERSONAL}" "git commit -m x"; denied
    git -C "${PERSONAL}" config --unset core.hooksPath
    bash_in "${PERSONAL}" "git commit -m x"; passed
    git -C "${PERSONAL}" config guard.scope exempt
    bash_in "${PERSONAL}" "git push"; denied
}

@test "area-guard: no global hooks means the repository is unguarded" {
    : > "${H}/.gitconfig"
    bash_in "${PERSONAL}" "git commit -m x"; denied
}

@test "area-guard: the exempt notes are not held to it" {
    git -C "${NOTES}" config guard.scope exempt
    bash_in "${NOTES}" "git commit -m x"; passed
}

# --- a client folder is an area from the moment it exists -------------------

@test "area-guard: a client folder made later is its own area" {
    printf 'client-* ~/org/clients/*\n' >> "${GUARD_CONFIG_DIR}/areas.txt"
    local beta="${H}/org/clients/beta"
    mkdir -p "${beta}/repos/tool"
    git init -q "${beta}/repos/tool"
    printf 'beta\n' > "${beta}/brief.md"
    agent Read file_path "${beta}/brief.md"
    write_to "${CASE_REPO}/a.py"; denied
    write_to "${beta}/repos/tool/a.py"; passed
}

# --- how a session is marked ------------------------------------------------

@test "area-guard: a Bash command naming an area with ~ marks the session" {
    bash_in "${H}" "cat ~/org/clients/acme/received/memo.md"
    write_to "${PERSONAL}/a.py"; denied
}

@test "area-guard: reading through a shortcut symlink marks the session" {
    agent Read file_path "${H}/org/acme-link/received/memo.md"
    write_to "${COMPANY_REPO}/c.py"; denied
}

@test "area-guard: a Bash cwd inside an area marks the session" {
    bash_in "${CASE}" "ls"
    write_to "${PERSONAL}/a.py"; denied
}

@test "area-guard: marks belong to one session" {
    read_case s1
    write_to "${PERSONAL}/a.py" s2; passed
}

# --- a session that read only the company (company > client) ----------------

@test "area-guard: a company reader writes the client but not a personal repository" {
    agent Read file_path "${COMPANY_REPO}/notes.md"
    write_to "${CASE_REPO}/ok.py"; passed
    write_to "${PERSONAL}/a.py"; denied
}

@test "area-guard: reading the exempt notes marks nothing" {
    agent Read file_path "${NOTES}/README.md"
    write_to "${PERSONAL}/a.py"; passed
}

# --- naming an area path without reading it ---------------------------------

@test "area-guard: a lone existence or attribute check on an area path marks nothing" {
    local c="~/org/clients/acme" n=0 command
    for command in "test -d ${c}" "test -f ${c}/received/memo.md" "[ -d ${c} ]" \
                   "stat ${c}/received/memo.md" "stat -f %z ${c}/received/memo.md" \
                   "realpath ${c}" "readlink ${H}/org/acme-link" \
                   "ls -d ${c}" "ls -ld ${c}" "ls -l -d ${c}" "ls --directory ${c}" \
                   "test -d \$HOME/org/clients/acme" "test -d \${HOME}/org/clients/acme" \
                   "stat -f %N ${c}/received/memo.md" "test -d '${H}/org/clients/acme'"; do
        n=$((n + 1))
        bash_in "${H}" "${command}" "p${n}"
        passed
        write_to "${PERSONAL}/a.py" "p${n}"
        passed || { echo "marked by: ${command}"; return 1; }
    done
}

@test "area-guard: anything more than a lone check on an area path still marks" {
    local c="~/org/clients/acme" n=0 command
    for command in "ls ${c}" "ls -l ${c}" "ls -dR ${c}" "ls -d ${c}/*" "ls -d ${c}/re?eived" \
                   "cat ${c}/received/memo.md" "test -d ${c} && cat ${c}/received/memo.md" \
                   "test -d ${c}; cat ${c}/received/memo.md" "stat ${c}/received/memo.md | head" \
                   "stat \$(cat ${c}/received/memo.md)" "test -n \`cat ${c}/received/memo.md\`" \
                   "stat ${c}/received/memo.md > out.txt" "test -d ${c} || cat ${c}/received/memo.md" \
                   "FOO=1 test -d ${c}" "test -d ${c}
cat ${c}/received/memo.md" "[ -d ${c} ] && cat ${c}/received/memo.md" "stat ${c}/{received,x}" \
                   "[ -d ${c}" "realpath ${c}/[r]eceived" "cd ${c}" "file ${c}/received/memo.md" \
                   "stat ${c}/received/\$NAME" "test -d ${c} -a -n \$X" "/bin/ls -d ${c}" \
                   "ls -d ${c} --color" "ls -d -R ${c}" "head ${c}/received/memo.md"; do
        n=$((n + 1))
        bash_in "${H}" "${command}" "m${n}"
        write_to "${PERSONAL}/a.py" "m${n}"
        denied || { echo "not marked by: ${command}"; return 1; }
    done
}

@test "area-guard: a lone check run from inside an area still marks by its folder" {
    bash_in "${CASE}" "test -d received"
    write_to "${PERSONAL}/a.py"; denied
}
