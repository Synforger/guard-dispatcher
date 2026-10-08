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
    # The personal repository is public: what it holds is outside every area.
    git -C "${PERSONAL}" remote add origin git@github.com:me/public-tool.git
    seed_visibility me/public-tool public
}

# agent <tool> <key> <value> [cwd] [session] — run the hook on one tool call. The call names the
# session's transcript when a test has set TRANSCRIPT.
agent() {
    local event
    event="$(jq -n --arg tool "$1" --arg key "$2" --arg value "$3" --arg cwd "${4:-${H}}" --arg session "${5:-s1}" \
        --arg transcript "${TRANSCRIPT:-}" \
        '{session_id: $session, tool_name: $tool, tool_input: {($key): $value}, cwd: $cwd,
          hook_event_name: "PreToolUse", transcript_path: (if $transcript == "" then null else $transcript end)}')"
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

origin() { git -C "$1" remote remove origin 2>/dev/null || true; git -C "$1" remote add origin "git@github.com:$2.git"; }

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

@test "area-guard: a line that lets an area's repositories hold others is no area here, and changes no mark" {
    mkdir -p "${H}/org/hub"
    printf 'hub ~/org/hub\n_carries hub company client\n' >> "${GUARD_CONFIG_DIR}/areas.txt"
    write_to "${PERSONAL}/a.py"; passed
    read_case
    write_to "${PERSONAL}/a.py"; denied
    write_to "${CASE}/received/note.md"; passed
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

# --- each git runs where the command stands at that point -------------------

@test "area-guard: a push after a cd elsewhere is judged by the repository it runs in" {
    read_case
    origin "${CASE_REPO}" acme/pipeline
    seed_visibility acme/pipeline public
    local c
    for c in "cd ${PERSONAL}; ls; cd ${CASE_REPO} && git push origin main" \
             "cd ${PERSONAL} && git -C ${CASE_REPO} push origin main" \
             "bash -c 'cd ${PERSONAL}; cd ${CASE_REPO} && git push origin main'" \
             "for r in pipeline; do git -C ${CASE_REPO} push origin main; done" \
             "sudo -E git -C ${CASE_REPO} push origin main"; do
        bash_in "${H}" "${c}"
        denied || { echo "passed: ${c}"; return 1; }
    done
}

@test "area-guard: a push from a repository the hooks do not reach is refused after a cd elsewhere" {
    origin "${CASE_REPO}" acme/pipeline
    git -C "${CASE_REPO}" config guard.scope exempt
    bash_in "${H}" "cd ${PERSONAL}; ls; cd ${CASE_REPO} && git push origin main"; denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
    bash_in "${H}" "cd ${CASE_REPO}; cd ${PERSONAL} && git push origin main"; passed
}

@test "area-guard: a commit after a cd elsewhere is judged by the repository it runs in" {
    read_case
    bash_in "${H}" "cd ${PERSONAL} && ls; cd ${CASE_REPO} && git commit -m x"; passed
    bash_in "${H}" "cd ${CASE_REPO} && git commit -m x; cd ${PERSONAL} && git commit -m y"; denied
}

@test "area-guard: a cd inside a subshell does not move the commands after it" {
    read_case
    bash_in "${CASE_REPO}" "(cd ${PERSONAL} && ls); git commit -m x"; passed
    bash_in "${CASE_REPO}" "(cd ${PERSONAL} && git commit -m x)"; denied
    bash_in "${CASE_REPO}" "pushd ${PERSONAL} && popd && git commit -m x"; passed
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
                   "git -c core.hooksPath=/dev/null commit -m x" "HUSKY=0 git commit -m x" \
                   "echo x;git commit -n -m x" "git commit -nm x;echo done"; do
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
                   "git config --file .gitmodules core.hooksPath" \
                   "git config --global core.hooksPath; echo done" "git config core.hooksPath&&echo x" \
                   "git config core.hooksPath|cat" "git config --global core.hooksPath 2>/dev/null" \
                   "(git config core.hooksPath)" "git config core.hooksPath >out.txt 2>&1"; do
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
                   "git -C ${PERSONAL} config guard.scope exempt" \
                   "echo x;git config core.hooksPath /dev/null" "git config core.hooksPath /dev/null;echo x" \
                   "(git config --global guard.scope exempt)" "git config core.hooksPath /dev/null 2>&1"; do
        bash_in "${PERSONAL}" "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
}

@test "area-guard: clearing the marks is refused" {
    bash_in "${H}" "rm -f ~/.cache/area-guard/s1.json"; denied
    write_to "${H}/.cache/area-guard/s1.json"; denied
}

@test "area-guard: a send from a repository the hooks do not reach is refused" {
    origin "${PERSONAL}" o/r
    git -C "${PERSONAL}" config core.hooksPath .husky
    bash_in "${PERSONAL}" "git commit -m x"; denied
    git -C "${PERSONAL}" config --unset core.hooksPath
    bash_in "${PERSONAL}" "git commit -m x"; passed
    git -C "${PERSONAL}" config guard.scope exempt
    bash_in "${PERSONAL}" "git push"; denied
}

@test "area-guard: a heredoc's body is text, not the command's words, unless the program it feeds runs it" {
    bash_in "${PERSONAL}" $'bash -n run.sh && echo ok; git add -A && git commit -q -F - <<\'EOF\'\nchecked with bash -n and -nq\nEOF'
    passed
    bash_in "${PERSONAL}" $'git commit -m "$(cat <<\'EOF\'\nfix: the -n flag\nEOF\n)"'
    passed
    bash_in "${PERSONAL}" $'cat > notes.md <<\'EOF\'\ngit config core.hooksPath /dev/null\nEOF'
    passed
    bash_in "${PERSONAL}" $'bash <<\'EOF\'\ngit config core.hooksPath /dev/null\nEOF'
    denied
    bash_in "${PERSONAL}" $'sudo python3 - <<-EOF\n\tgit config core.hooksPath /dev/null\n\tEOF'
    denied
    bash_in "${PERSONAL}" $'git commit -n -F - <<\'EOF\'\ntext\nEOF'
    denied
}

@test "area-guard: a hooksPath brought in past the global config (an include) is refused" {
    origin "${PERSONAL}" o/r
    mkdir -p "${H}/elsewhere"
    printf '#!/bin/sh\n' > "${H}/elsewhere/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/elsewhere" > "${H}/included.cfg"
    git -C "${PERSONAL}" config include.path "${H}/included.cfg"
    bash_in "${PERSONAL}" "git commit -m x"; denied
    [[ "${output}" == *"past the global config"* ]]
    git -C "${PERSONAL}" config --unset include.path
    bash_in "${PERSONAL}" "git commit -m x"; passed
}

@test "area-guard: on a machine with no areas, a repository the hooks do not reach still cannot send" {
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    origin "${PERSONAL}" o/r
    git -C "${PERSONAL}" config core.hooksPath .husky
    bash_in "${PERSONAL}" "git push"; denied
    git -C "${PERSONAL}" config --unset core.hooksPath
    bash_in "${PERSONAL}" "git push"; passed
    # the operator's own opt-out stands against the areas; with none, an exempt repository still sends
    git -C "${PERSONAL}" config guard.scope exempt
    bash_in "${PERSONAL}" "git commit -m x && git push"; passed
}

@test "area-guard: no global hooks means the repository is unguarded" {
    origin "${PERSONAL}" o/r
    : > "${H}/.gitconfig"
    bash_in "${PERSONAL}" "git commit -m x"; denied
}

# A commit stays in its repository. With no remote there is nowhere for it to go, so a repository
# the hooks do not reach may still commit; its push is held as before.
@test "area-guard: a commit in a repository with no remote is not held to the hooks" {
    git -C "${COMPANY_REPO}" config guard.scope exempt
    agent Read file_path "${COMPANY_REPO}/notes.md"        # a company session, as the case that asked
    bash_in "${COMPANY_REPO}" "git add -A && git commit -m x"; passed
    bash_in "${H}" "git -C ${COMPANY_REPO} commit -m x"; passed
    git -C "${COMPANY_REPO}" config core.hooksPath .husky
    bash_in "${COMPANY_REPO}" "git commit -m x"; passed
}

@test "area-guard: a repository with no remote still cannot push past the hooks" {
    git -C "${COMPANY_REPO}" config guard.scope exempt
    bash_in "${COMPANY_REPO}" "git push git@github.com:o/r.git HEAD"; denied
    [[ "${output}" == *"guard.scope = exempt"* ]]
    origin "${COMPANY_REPO}" o/r
    bash_in "${COMPANY_REPO}" "git commit -m x"; denied
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

# --- a machine that is the company's, less the folders in no area ------------

# home_is_company — every folder of the home directory joins the company; its repos folder is in no area.
home_is_company() {
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<AREAS
company  ~/*
client   ~/org/clients/acme
_outside ${H}/repos
_exempt  ~/notes
AREAS
}

@test "area-guard: a folder made later in a home that is the company's joins the company" {
    home_is_company
    mkdir -p "${H}/Desktop"
    agent Read file_path "${H}/Desktop/shot.png"; passed
    write_to "${PERSONAL}/a.py"; denied
    write_to "${COMPANY_REPO}/a.py"; passed
}

@test "area-guard: a hidden folder of a home that is the company's marks nothing" {
    home_is_company
    agent Read file_path "${H}/.config/guard/areas.txt"; passed
    write_to "${PERSONAL}/a.py"; passed
}

@test "area-guard: reading an _outside folder marks nothing" {
    home_is_company
    agent Read file_path "${PERSONAL}/README.md"; passed
    write_to "${COMPANY_REPO}/a.py"; passed
    write_to "${CASE_REPO}/a.py"; passed
}

@test "area-guard: a repository in an _outside folder is in no area: a marked session writes it unless it publishes outside" {
    printf '_outside ~/org/public\n' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${H}/org/public/site"
    git init -q "${H}/org/public/site"
    agent Read file_path "${COMPANY_REPO}/notes.md"
    write_to "${H}/org/public/site/a.py"; passed
    origin "${H}/org/public/site" me/site
    seed_visibility me/site public
    write_to "${H}/org/public/site/b.py"; denied
    write_to "${COMPANY_REPO}/b.py"; passed
}

# --- a place in no area is not held back ------------------------------------

@test "area-guard: a client reader writes and commits a repository in no area that publishes nowhere outside" {
    mkdir -p "${H}/scratch/tool"
    git init -q "${H}/scratch/tool"
    read_case
    write_to "${H}/scratch/tool/a.py"; passed
    bash_in "${H}/scratch/tool" "git commit -m x"; passed
    origin "${H}/scratch/tool" o/r
    write_to "${H}/scratch/tool/b.py"; passed
}

@test "area-guard: a shell's -c line that only reads a file in a personal repository is not a write" {
    read_case
    printf 'x=1\n' > "${PERSONAL}/env.sh"
    bash_in "${H}" "bash -c '. ${PERSONAL}/env.sh; echo \$x'"; passed
    bash_in "${H}" "bash -c 'echo 1 > ${PERSONAL}/out.txt'"; denied
}

# --- the operator's switch ---------------------------------------------------

@test "area-guard: while the operator's switch is off every call passes, and the agent cannot switch it" {
    read_case
    write_to "${PERSONAL}/a.py"; denied
    bash_in "${H}" "touch ${GUARD_CONFIG_DIR}/agent-off"; denied
    agent Write file_path "${GUARD_CONFIG_DIR}/agent-off"; denied
    bash_in "${H}" "ls ${GUARD_CONFIG_DIR}/agent-off"; passed
    touch "${GUARD_CONFIG_DIR}/agent-off"
    write_to "${PERSONAL}/a.py"; passed
    bash_in "${H}" "git commit --no-verify -m x"; passed
    rm "${GUARD_CONFIG_DIR}/agent-off"
    write_to "${PERSONAL}/a.py"; denied
}

@test "area-guard: a marked session commits and pushes the exempt notes, even to a repository declared outside" {
    git -C "${NOTES}" remote add origin git@github.com:me/notes.git
    printf 'repo:me/* outside\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
    read_case
    bash_in "${NOTES}" "git commit -m x"; passed
    bash_in "${NOTES}" "git push origin main"; passed
    bash_in "${PERSONAL}" "git push origin main"; denied
}

@test "area-guard: the agent does not remove the installed hooks" {
    bash_in "${H}" "rm ~/.git-hooks/agent-hooks"; denied
    bash_in "${H}" "rm -rf ~/.git-hooks"; denied
    bash_in "${H}" "ls ~/.git-hooks/agent-hooks"; passed
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

@test "area-guard: a company reader writes neither a client's repository nor a personal one" {
    agent Read file_path "${COMPANY_REPO}/notes.md"
    write_to "${CASE_REPO}/a.py"; denied
    write_to "${PERSONAL}/a.py"; denied
    write_to "${COMPANY_REPO}/ok.py"; passed
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
        # a session that read the client does not write the company's repository
        write_to "${COMPANY_REPO}/c.py" "m${n}"
        denied || { echo "not marked by: ${command}"; return 1; }
    done
}

# --- a name inside text is not a read ---------------------------------------
# A path counts where it stands by itself: a word of the command line, a string of inline code,
# a line of what a program is fed. Inside a sentence it is text, and nothing opens it.

@test "area-guard: an area path written inside text marks nothing" {
    local c="~/org/clients/acme" n=0 command
    local -a commands=(
        "python3 -c \"print('the notes moved under ${c} last week')\""
        "python3 -c \"print('置き場(${c})の直下に在る')\""
        "python3 -c \"s = 'the format is in \`${c}/received/memo.md\`, read it there'\""
        "node -e \"console.log('the copy of ${c} is gone')\""
        $'python3 - notes.md <<\'EOF\'\nimport sys\np = sys.argv[1]\ns = open(p).read().replace("TODO", "the format is kept in '"${c}"$'/received/memo.md now")\nopen(p, "w").write(s)\nEOF'
        $'python3 - <<\'EOF\'\ntext = """\nThe format is kept in '"${c}"$'/received/memo.md now.\n- see `'"${c}"$'` for the rest\n"""\nprint(text)\nEOF'
        $'cat > notes.md <<\'EOF\'\nThe format is kept in '"${c}"$'/received/memo.md now.\n- see `'"${c}"$'` for the rest\nEOF'
        "echo \"moved the notes under ${c} today\""
        "git log --grep=\"moved to ${c}\""
    )
    for command in "${commands[@]}"; do
        n=$((n + 1))
        bash_in "${H}" "${command}" "t${n}"
        passed
        write_to "${PERSONAL}/a.py" "t${n}"
        passed || { echo "marked by: ${command}"; return 1; }
    done
}

@test "area-guard: an area path that stands by itself in code, or in what a command is fed, still marks" {
    local p="${H}/org/clients/acme/received/memo.md" c="~/org/clients/acme" n=0 command
    local -a commands=(
        "python3 -c \"print(open('${p}').read())\""
        "python3 -c \"from pathlib import Path; print(Path('${c}/received/memo.md').expanduser().read_text())\""
        $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run(["cat", "'"${p}"$'"])\nEOF'
        "node -e \"console.log(require('fs').readFileSync(\`${p}\`, 'utf8'))\""
        "perl -e 'open(F, \"<${p}\"); print <F>'"
        "python3 -c \"import urllib.request as u; print(u.urlopen('file://${p}').read())\""
        "python3 -c \"open('${H}/org/acme-link/received/memo.md')\""
        $'python3 - <<\'EOF\'\nfor name in """\n'"${p}"$'\n""".split():\n    print(open(name).read())\nEOF'
        $'xargs cat <<\'EOF\'\n'"${p}"$'\nEOF'
        $'while read f; do cat "$f"; done <<\'EOF\'\n'"${p}"$'\nEOF'
        "xargs cat <<< \"${p}\""
        "bash -c 'cat ${p}'"
        $'bash <<\'EOF\'\ncat '"${p}"$'\nEOF'
        "echo \"\$(cat ${p})\""
        "echo \"\`cat ${p}\`\""
        "env F=${p} sh -c 'cat \$F'"
        "grep -c x --file=${p} notes.md"
        "tar -cf - -C${H}/org/clients/acme ."
        "PATH=/usr/bin:${H}/org/clients/acme/bin run"
        "cat < ${p}"
        "cat ~/org/clients/ac*/received/memo.md"
        "A=1"$'\n'"cat ${p}"
    )
    for command in "${commands[@]}"; do
        n=$((n + 1))
        bash_in "${H}" "${command}" "k${n}"
        # a session that read the client does not write the company's repository
        write_to "${COMPANY_REPO}/c.py" "k${n}"
        denied || { echo "not marked by: ${command}"; return 1; }
    done
    # a glob that matches the company's folder marks the company, whose reader does not write the client's
    bash_in "${H}" "ls ~/or*" g1
    write_to "${CASE_REPO}/c.py" g1
    denied
}

@test "area-guard: a Bash command marks the area its path is in, as a Read of the path does" {
    bash_in "${H}" "cat ~/org/clients/acme/received/memo.md"
    passed
    [ "$(jq -c .areas "${AREA_GUARD_STATE}/s1.json")" = '["client"]' ]
    # a folder whose name only begins like an area's is not the area
    mkdir -p "${H}/organics"
    printf 'x\n' > "${H}/organics/list.txt"
    bash_in "${H}" "cat ~/organics/list.txt" s2
    passed
    write_to "${COMPANY_REPO}/c.py" s2
    passed
    write_to "${PERSONAL}/a.py" s2
    passed
}

# --- writes a Bash command names ---------------------------------------------
# Edit and Write are judged by their target; a shell command writes too. Its named targets are
# judged the same way: a redirection, tee / touch, cp / mv, sed -i, dd of=, and paths inside
# inline code.

@test "area-guard: a client reader cannot write a personal repository from the shell" {
    printf 'x\n' > "${PERSONAL}/existing.txt"
    read_case
    local c n=0
    for c in "echo x > ${PERSONAL}/a.txt" "echo x >> ${PERSONAL}/a.txt" "date &> ${PERSONAL}/a.txt" \
             "echo x | tee ${PERSONAL}/a.txt" "touch ${PERSONAL}/a.txt" \
             "cp ${CASE}/received/memo.md ${PERSONAL}/" "mv /tmp/x ${PERSONAL}/b.txt" \
             "sed -i '' s/x/y/ ${PERSONAL}/existing.txt" "dd if=/dev/zero of=${PERSONAL}/z bs=1 count=1" \
             "python3 -c \"open('${PERSONAL}/c.txt','w').write('x')\"" \
             "node -e \"require('fs').writeFileSync('${PERSONAL}/d.txt','x')\"" \
             "bash -c 'echo x > ${PERSONAL}/e.txt'" "cd /tmp && echo x > \$HOME/repos/public-tool/f.txt"; do
        n=$((n + 1))
        bash_in "${H}" "${c}"
        denied || { echo "passed: ${c}"; return 1; }
    done
}

@test "area-guard: a client reader still writes from the shell inside the client, the notes and outside repositories" {
    read_case
    local c
    for c in "echo x > ${CASE_REPO}/ok.txt" "echo x > ${NOTES}/n.md" "echo x > ${H}/scratch.txt" \
             "ls ${PERSONAL} > ${H}/list.txt" "cat ${PERSONAL}/README 2>&1" "echo x 2>&1 >/dev/null" \
             "sed -n 1p ${PERSONAL}/x" "python3 build.py"; do
        bash_in "${H}" "${c}"
        passed || { echo "refused: ${c}"; return 1; }
    done
}

@test "area-guard: an unmarked session writes anywhere from the shell" {
    bash_in "${H}" "echo x > ${PERSONAL}/a.txt; python3 -c \"open('${PERSONAL}/b','w')\""
    passed
}

@test "area-guard: a lone check run from inside an area still marks by its folder" {
    bash_in "${CASE}" "test -d received"
    write_to "${PERSONAL}/a.py"; denied
}

# --- the marks file ------------------------------------------------------------

state_of() { cat "${AREA_GUARD_STATE}/${1:-s1}.json"; }

@test "area-guard: a read inside an area lands in the marks file" {
    read_case
    jq -e '.areas == ["client"]' <<< "$(state_of)" > /dev/null
}

@test "area-guard: a marks file of the older form (a bare list) is still read" {
    mkdir -p "${AREA_GUARD_STATE}"
    printf '["client"]' > "${AREA_GUARD_STATE}/s1.json"
    write_to "${PERSONAL}/a.md"
    denied
}

# --- what a call costs -----------------------------------------------------------------------

@test "area-guard: a call that passes loads nothing that only a scan, a send or a git call uses" {
    # The hook runs before every tool call, so every call pays for what it loads. What only some
    # calls use is loaded where it is used.
    local event module
    event="$(jq -n --arg cwd "${H}" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: "ls"}, cwd: $cwd, hook_event_name: "PreToolUse"}')"
    run python3 -X importtime "${HOOK}" <<< "${event}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *permissionDecision* ]]
    for module in subprocess tempfile hashlib zipfile shutil uuid; do
        ! grep -qE "\| +${module}\$" <<< "${output}" || { echo "loaded: ${module}"; return 1; }
    done
}

# --- when the destination check itself times out, a deny says so, not that it found it outside ---

@test "area-guard: a destination check that times out says so instead of pretending the sending repository was found" {
    run python3 -c "
import importlib.util, subprocess
spec = importlib.util.spec_from_file_location('ag', '${HOOK}')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def fake_run(cmd, **kw):
    raise subprocess.TimeoutExpired(cmd=cmd, timeout=kw.get('timeout'))
subprocess.run = fake_run      # the hook loads subprocess where it calls out, so the module itself is patched
place, note = m.destination(m.Path('${CASE_REPO}'), ['--dest', 'git@github.com:acme/pipeline.git'])
print(place == m.Path('${CASE_REPO}'), note)
"
    [[ "$output" == *"True"* ]]
    [[ "$output" == *"did not finish within 60s"* ]]
    [[ "$output" == *"not that it was found outside every area"* ]]
}

# --- inline code and heredocs in a Bash command -----------------------------------------------

@test "area-guard: inline code naming a relative path writes it where the command runs" {
    mkdir -p "${PERSONAL}/src"
    printf 'x\n' > "${PERSONAL}/Makefile"
    read_case
    local c
    for c in "python3 -c \"open('src/a.py','w').write('x')\"" \
             $'python3 - <<\'EOF\'\nfrom pathlib import Path\nPath(\'src/a.py\').write_text(\'x\')\nEOF' \
             $'python3 - <<EOF\nopen("notes.md", "a").write("x")\nEOF' \
             $'bash <<\'EOF\'\necho x > out.txt\nEOF' \
             "python3 <<< \"open('a.txt','w')\"" "node -e \"require('fs').writeFileSync(\`b.txt\`, 'x')\"" \
             "ruby -e \"File.write('c.txt', 'x')\"" "python3 -c \"open('Makefile','a')\"" \
             "bash -lc 'echo x > d.txt'" "sudo tee e.txt" "LANG=C env A=1 cp /tmp/x f.txt"; do
        bash_in "${PERSONAL}" "${c}"
        denied || { echo "passed: ${c}"; return 1; }
        bash_in "${CASE_REPO}" "${c}"
        passed || { echo "refused inside the client: ${c}"; return 1; }
    done
}

@test "area-guard: inline code that names no path is not a write" {
    read_case
    local c
    for c in "python3 -c \"print('.'.join(['a', 'b']), 'utf-8', 'w')\"" \
             "python3 -c \"import sys; print(sys.version)\"" \
             "node -e \"console.log('https://example.com/a.txt')\"" \
             $'python3 - <<\'EOF\'\nprint("a b", \'c\')\nEOF'; do
        bash_in "${PERSONAL}" "${c}"
        passed || { echo "refused: ${c}"; return 1; }
    done
}

@test "area-guard: a word quoted inside a string of inline code is text, not a path the code writes" {
    mkdir -p "${PERSONAL}/src"
    printf 'x\n' > "${PERSONAL}/Makefile"
    read_case
    local c
    local -a commands=(
        $'python3 - <<\'EOF\'\ns = "see `vision.md` and `src/a.py` for the rest"\nprint(s)\nEOF'
        "python3 -c \"print('the file \`Makefile\` builds it, and \`src\` holds the rest')\""
        $'python3 - <<\'EOF\'\nprint(\'rename "notes.md" to "src/notes.md" one day\')\nEOF'
        "python3 -c \"print('it used to live in ${PERSONAL}/old.txt, look there')\""
        $'python3 - <<\'EOF\'\ntext = """\n- `vision.md`: where things stand\n- src/a.py holds the rest\n"""\nprint(text)\nEOF'
    )
    for c in "${commands[@]}"; do
        bash_in "${PERSONAL}" "${c}"
        passed || { echo "refused: ${c}"; return 1; }
    done
}

@test "area-guard: a heredoc's body is text, not a place the command writes; the line that opens it still is" {
    read_case
    bash_in "${CASE_REPO}" "$(printf "git commit -q -F - <<'EOF'\nmove a > %s/b and don't stop\nEOF" "${PERSONAL}")"
    passed
    bash_in "${CASE_REPO}" "$(printf "cat > notes.md <<'EOF'\nsee %s/a.txt > %s/b.txt\nEOF" "${PERSONAL}" "${PERSONAL}")"
    passed
    # an apostrophe in the body does not hide the redirection on the line that opens the heredoc
    bash_in "${H}" "$(printf "cat > %s/a.txt <<'EOF'\ndon't\nEOF" "${PERSONAL}")"
    denied
}

# --- what the guard judges from is the operator's to write --------------------------------------

# session_files — the guard's send settings and a session's transcript, as the machine keeps them.
session_files() {
    TRANSCRIPT="${H}/.claude/projects/-home-tool/s1.jsonl"
    mkdir -p "$(dirname "${TRANSCRIPT}")/memory" "${H}/.claude-work/projects/p"
    : > "${TRANSCRIPT}"
    : > "${H}/.claude-work/projects/p/other.jsonl"
    printf '*slack* company order\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
    printf 'send it\n' > "${GUARD_CONFIG_DIR}/orders.txt"
}

@test "area-guard: the agent writes neither the guard's settings nor a transcript with Write or Edit" {
    session_files
    local f g="${GUARD_CONFIG_DIR}"
    # Every file of the settings folder, the ones that are there and one made tomorrow.
    for f in "${g}/destinations.txt" "${g}/orders.txt" "${g}/ORDERS.TXT" "${g}/areas.txt" "${g}/allow.txt" \
             "${g}/background.txt" "${g}/ignore.txt" "${g}/patterns/client.txt" "${g}/notes.txt"; do
        write_to "${f}"
        denied || { echo "written: ${f}"; return 1; }
        [[ "${output}" == *"what the guard lets through is judged from it"* ]]
        agent Edit file_path "${f}"
        denied || { echo "edited: ${f}"; return 1; }
    done
    for f in "${TRANSCRIPT}" "${H}/.claude-work/projects/p/other.jsonl" "${H}/.claude/projects/-home-tool/new.jsonl"; do
        write_to "${f}"
        denied || { echo "written: ${f}"; return 1; }
        [[ "${output}" == *"an order for a send is judged from it"* ]]
        agent Edit file_path "${f}"
        denied || { echo "edited: ${f}"; return 1; }
    done
    # A folder whose name only begins like the settings folder's is not it.
    for f in "${g}-notes/areas.txt" "${H}/.claude/projects/-home-tool/memory/fact.md" \
             "${H}/scratch/log.jsonl" "${H}/.claude/settings.json"; do
        write_to "${f}"
        passed || { echo "refused: ${f}"; return 1; }
    done
    agent Read file_path "${g}/areas.txt"; passed
    agent Read file_path "${GUARD_CONFIG_DIR}/orders.txt"; passed
    agent Read file_path "${TRANSCRIPT}"; passed
    # with the file gone, another case of its name would be the file on a file system that folds case
    rm "${GUARD_CONFIG_DIR}/orders.txt"
    write_to "${GUARD_CONFIG_DIR}/ORDERS.TXT"; denied
    bash_in "${H}" "echo 'send it' > ${GUARD_CONFIG_DIR}/Orders.txt"; denied
}

@test "area-guard: a transcript kept anywhere else is still the session's: the call names it" {
    session_files
    TRANSCRIPT="${H}/elsewhere/s1.jsonl"
    mkdir -p "${H}/elsewhere"
    : > "${TRANSCRIPT}"
    write_to "${TRANSCRIPT}"; denied
    bash_in "${H}" "echo '{}' >> ${TRANSCRIPT}"; denied
    write_to "${H}/elsewhere/s2.jsonl"; passed
}

@test "area-guard: the agent writes neither of them from the shell, nor removes the settings" {
    session_files
    ln -s "${GUARD_CONFIG_DIR}/orders.txt" "${H}/shortcut"
    ln -s "${GUARD_CONFIG_DIR}" "${H}/settings-by-another-name"
    local c g="${GUARD_CONFIG_DIR}"
    for c in "echo 'send it' >> ${g}/orders.txt" "echo x > ~/.config/guard/destinations.txt" \
             "printf '' | tee ${g}/destinations.txt" "sudo tee -a ${g}/orders.txt" \
             "cp /tmp/mine ${g}/destinations.txt" "sed -i '' 's/ order//' ${g}/destinations.txt" \
             "rm ${g}/destinations.txt" "rm -f ${g}/*.txt" "rm -rf ${g}" "rm -rf ~/.config" \
             "mv ${g}/destinations.txt ${g}/destinations.off" "mv ${g} ${H}/old" "truncate -s 0 ${g}/destinations.txt" \
             "echo x >> ${H}/shortcut" "echo x >> ${g}/Orders.txt" \
             "python3 -c \"open('${g}/orders.txt','a').write('ok')\"" \
             "bash -c 'echo x >> ${g}/orders.txt'" \
             "echo 'hub ~/org' >> ${g}/areas.txt" "sed -i '' '/client/d' ${g}/areas.txt" "rm ${g}/areas.txt" \
             "echo 'a phrase the agent would like to send' >> ${g}/allow.txt" \
             "echo ~/org >> ${g}/background.txt" "echo ~/org/clients >> ${g}/ignore.txt" \
             "rm -rf ${g}/patterns" "echo 'QX[0-9]+' > ${g}/patterns/client.txt" "echo x > ${g}/notes.txt" \
             "echo x >> ${H}/settings-by-another-name/areas.txt" \
             "python3 -c \"open('${g}/areas.txt','a').write('x')\""; do
        bash_in "${H}" "${c}"
        denied || { echo "passed: ${c}"; return 1; }
        [[ "${output}" == *"what the guard lets through is judged from it"* ]]
    done
    for c in "echo '{}' >> ${TRANSCRIPT}" "cp /tmp/forged.jsonl ${TRANSCRIPT}" \
             "python3 -c \"open('${TRANSCRIPT}','a').write('{}')\"" \
             "echo '{}' >> ~/.claude-work/projects/p/other.jsonl"; do
        bash_in "${H}" "${c}"
        denied || { echo "passed: ${c}"; return 1; }
        [[ "${output}" == *"an order for a send is judged from it"* ]]
    done
    # a relative path, from the folder that holds them
    bash_in "${g}" "echo x >> orders.txt"; denied
    bash_in "${g}" $'python3 - <<\'EOF\'\nopen("orders.txt", "a").write("send it")\nEOF'; denied
    bash_in "$(dirname "${TRANSCRIPT}")" "python3 -c \"open('s1.jsonl','a').write('{}')\""; denied
}

@test "area-guard: reading them and copying them out pass" {
    session_files
    local c g="${GUARD_CONFIG_DIR}"
    for c in "cat ${g}/destinations.txt ${g}/orders.txt" "grep -c order ${g}/destinations.txt" \
             "cp ${g}/destinations.txt ${H}/destinations.copy" "jq -c . ${TRANSCRIPT}" "wc -l ${TRANSCRIPT}" \
             "tail -n 3 ${TRANSCRIPT} > ${H}/tail.jsonl.txt" "ls -la ${g}" "cat ${g}/areas.txt" \
             "wc -l ${g}/areas.txt ${g}/allow.txt" "cp ${g}/areas.txt ${H}/areas.copy" "echo x > ${g}-notes.txt" \
             "rm ${H}/destinations.copy" "echo destinations.txt orders.txt areas.txt"; do
        bash_in "${H}" "${c}"
        passed || { echo "refused: ${c}"; return 1; }
    done
}

# --- a script asks before it writes where its arguments say ----------------------

# may_write <session> <path>... — ask the guard as a script would, from HOME.
may_write() { run bash -c 'cd "$1" && shift && python3 "$@"' _ "${H}" "${HOOK}" may-write "$@"; }

@test "area-guard may-write: a session with no marks may write anywhere" {
    may_write s1 "${COMPANY_REPO}/notes.md" "${CASE_REPO}/a.md" "${PERSONAL}/a.md"
    [ "${status}" -eq 0 ] && [ -z "${output}" ]
}

@test "area-guard may-write: the answer is the one an Edit of the path gets" {
    read_case
    local target
    for target in "${CASE_REPO}/a.md" "${NOTES}/journal/a.md" "${H}/scratch/a.md"; do
        may_write s1 "${target}"
        [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "refused: ${target}"; return 1; }
        write_to "${target}"; passed
    done
    for target in "${COMPANY_REPO}/journal/a.md" "${PERSONAL}/a.md"; do
        may_write s1 "${target}"
        [ "${status}" -eq 1 ] || { echo "allowed: ${target}"; return 1; }
        [[ "${output}" == *"has read inside client"*"cannot write ${target}"* ]]
        write_to "${target}"; denied
    done
}

@test "area-guard may-write: one refused path refuses the call and names only that path" {
    read_case
    may_write s1 "${CASE_REPO}/a.md" "${COMPANY_REPO}/a.md"
    [ "${status}" -eq 1 ]
    [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" = "1" ]
    [[ "${output}" == *"cannot write ${COMPANY_REPO}/a.md"* ]]
}

@test "area-guard may-write: a relative path resolves where the script runs, not where the session stands" {
    read_case
    run bash -c 'cd "$1" && python3 "$2" may-write s1 journal/a.md' _ "${COMPANY_REPO}" "${HOOK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot write ${COMPANY_REPO}/journal/a.md"* ]]
    run bash -c 'cd "$1" && python3 "$2" may-write s1 journal/a.md' _ "${CASE_REPO}" "${HOOK}"
    [ "${status}" -eq 0 ]
}

@test "area-guard may-write: it only answers (no mark is added, another session is not judged by these marks)" {
    read_case
    local before; before="$(cat "${AREA_GUARD_STATE}/s1.json")"
    may_write s1 "${COMPANY_REPO}/a.md"; [ "${status}" -eq 1 ]
    may_write s2 "${COMPANY_REPO}/a.md"; [ "${status}" -eq 0 ]
    may_write s2 "${CASE}/received/memo.md"; [ "${status}" -eq 0 ]
    [ "$(cat "${AREA_GUARD_STATE}/s1.json")" = "${before}" ]
    [ ! -e "${AREA_GUARD_STATE}/s2.json" ]
}

@test "area-guard may-write: with the operator's switch off, or with no areas, every path may be written" {
    read_case
    touch "${GUARD_CONFIG_DIR}/agent-off"
    may_write s1 "${COMPANY_REPO}/a.md"; [ "${status}" -eq 0 ]
    rm "${GUARD_CONFIG_DIR}/agent-off"
    may_write s1 "${COMPANY_REPO}/a.md"; [ "${status}" -eq 1 ]
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    may_write s1 "${COMPANY_REPO}/a.md"; [ "${status}" -eq 0 ]
}

@test "area-guard may-write: a call that names no session or no path is a usage error, not a yes" {
    local args
    for args in "may-write" "may-write s1" "can-write s1 ${COMPANY_REPO}/a.md"; do
        run python3 "${HOOK}" ${args}
        [ "${status}" -eq 2 ] || { echo "status ${status}: ${args}"; return 1; }
        [[ "${output}" == *"usage:"* ]]
    done
    run python3 "${HOOK}" may-write "" "${COMPANY_REPO}/a.md"
    [ "${status}" -eq 2 ]
}
