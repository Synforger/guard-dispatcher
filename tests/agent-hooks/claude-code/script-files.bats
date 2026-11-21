#!/usr/bin/env bats
# agent-hooks/claude-code/script_files.py (through area-guard.py and outgoing.py) — a file of code
# a command hands to a program is read as that code written into the command, by every reader: the
# tickets folder, the guard's settings, the areas a call reads, a recursive read, a switch of the
# guards, and a send.
#
# A throwaway HOME holds a company folder with a client inside it, a platform root with the tickets
# folder outside every area, and the tool repository the session works in.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    TOOL="${H}/repos/tool"
    PLACE="${H}/platform/state/claude-pwa-client/tickets"
    mkdir -p "${H}/org/clients/acme/received" "${TOOL}/scripts" "${PLACE}" "${GUARD_CONFIG_DIR}"
    printf 'client value 12.3456\n' > "${H}/org/clients/acme/received/memo.md"
    git init -q "${TOOL}"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export AGENT_PLATFORM_ROOT="${H}/platform"
    export GUARD_CORPUS_MAX_AGE=0
    unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE
    printf '%s\n' 'company ~/org' 'client  ~/org/clients/acme' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' 'host:chat.example.com company order' 'app:mail block' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
}

bash_in() {
    local event
    event="$(jq -n --arg c "$2" --arg d "$1" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}
bash_call() { bash_in "${TOOL}" "$1"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }
says() { [[ "${output}" == *"$1"* ]] || { echo "${output}"; return 1; }; }

# script <path> <text> — write a file of code (the path relative to the tool repository).
script() { mkdir -p "$(dirname "${TOOL}/$1")"; printf '%s\n' "$2" > "${TOOL}/$1"; }

# The shape the client's tab ran: the folder put together from the home folder, the files moved
# and removed through names bound to it.
TICKET_FIX='from pathlib import Path
import shutil
TICKETS = Path.home() / "platform/state/claude-pwa-client/tickets"
def main():
    for ticket in ("t-1", "t-2"):
        shutil.move(str(TICKETS / f"{ticket}.jsonl"), "/tmp/elsewhere")
    (TICKETS / "t-3.jsonl").unlink()
main()'

# --- the tickets folder -------------------------------------------------------------------------

@test "script files: code in a file that writes into the tickets folder is refused, however the file is run" {
    script fix.py "${TICKET_FIX}"
    script scripts/run.sh "python3 ${TOOL}/fix.py"
    script inner/self.py "#!/usr/bin/env python3
${TICKET_FIX}"
    chmod +x "${TOOL}/inner/self.py"
    script inner/uv.py "#!/usr/bin/env -S uv run --script
${TICKET_FIX}"
    chmod +x "${TOOL}/inner/uv.py"
    local command
    for command in "python3 fix.py" "python3.11 -X dev -u fix.py --dry-run" "python fix.py" \
                   "uv run fix.py" "uv run --with requests python3 fix.py" "./inner/self.py" "inner/uv.py" \
                   "bash scripts/run.sh" "sh -x scripts/run.sh" "source scripts/run.sh" ". scripts/run.sh" \
                   "bash -c 'python3 fix.py'" "cd ${H} && python3 repos/tool/fix.py" \
                   "cd scripts && bash run.sh" "env A=1 nohup python3 ${TOOL}/fix.py" \
                   "echo start; (cd ${H}/repos && python3 tool/fix.py)"; do
        bash_call "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
        says 'a ticket is written with `tabs ticket`'
    done
}

@test "script files: a shell script that writes into the tickets folder is refused" {
    script w.sh "echo x >> ${PLACE}/a.jsonl"
    bash_call "bash w.sh"; denied
    script w.sh 'cp notes.md "$HOME/platform/state/claude-pwa-client/tickets/b.jsonl"'
    bash_call "zsh w.sh"; denied
    script w.sh "rm ~/platform/state/claude-pwa-client/tickets/a.jsonl"
    bash_call "bash w.sh"; denied
}

@test "script files: code written into the command that puts the folder together from home is refused too" {
    local code
    for code in 'from pathlib import Path; (Path.home() / "platform/state/claude-pwa-client/tickets" / "a.jsonl").write_text("{}")' \
                'import os; open(os.path.join(os.path.expanduser("~"), "platform", "state/claude-pwa-client/tickets", "a.jsonl"), "w")' \
                'import os; open(os.environ["HOME"] + "/platform/state/claude-pwa-client/tickets/a.jsonl", "w")' \
                'from pathlib import Path; Path.home().joinpath("platform/state", "claude-pwa-client/tickets").joinpath("x").touch()'; do
        bash_call "python3 -c '${code}'"
        denied || { echo "not refused: ${code}"; return 1; }
    done
    bash_call "node -e 'fs.writeFileSync(path.join(os.homedir(), \"platform/state/claude-pwa-client/tickets/a.jsonl\"), \"x\")'"
    denied
}

@test "script files: a script that only reads the tickets folder, or writes beside it, passes" {
    script read.py 'from pathlib import Path
import json
TICKETS = Path.home() / "platform/state/claude-pwa-client/tickets"
for p in TICKETS.glob("*.jsonl"):
    print(json.loads(p.read_text()))
(Path.home() / "repos/tool/out.md").write_text("x")'
    bash_call "python3 read.py"; passed
    script r.sh "cat ${PLACE}/*.jsonl > ${TOOL}/all.txt"
    bash_call "bash r.sh"; passed
}

@test "script files: what is not a file of code handed to a program runs unread" {
    script fix.py "${TICKET_FIX}"
    local command
    # a module by name, a file that is not there, code given another way, a program found on PATH
    for command in "python3 -m json.tool fix.py" "python3 missing.py" "python3 -c 'print(1)' fix.py" \
                   "cat fix.py" "bash -s < /dev/null" "uv run pytest" "ls fix.py"; do
        bash_call "${command}"
        passed || { echo "refused: ${command}"; return 1; }
    done
    # a file that is not text, and one past the size a script is read up to
    printf 'shutil.move(x, "%s/a.jsonl")\0\n' "${PLACE}" > "${TOOL}/blob.py"
    bash_call "python3 blob.py"; passed
}

@test "script files: a script that runs itself is followed a few steps and then left" {
    script loop.sh "echo hi; bash ${TOOL}/loop.sh"
    bash_call "bash loop.sh"; passed
    script loop.sh "bash ${TOOL}/loop.sh; echo x > ${PLACE}/a.jsonl"
    bash_call "bash loop.sh"; denied
}

# --- the guard's settings, the areas read, the guards themselves --------------------------------

@test "script files: a script that writes the guard's settings is refused" {
    script set.py "import os
open(os.path.join('${GUARD_CONFIG_DIR}', 'destinations.txt'), 'a').write('* outside\n')"
    bash_call "python3 set.py"; denied
    says "the guard's settings"
    script set.sh "echo '* outside' >> ${GUARD_CONFIG_DIR}/destinations.txt"
    bash_call "bash set.sh"; denied
}

@test "script files: a script that reads inside an area the tab does not read is refused before it runs" {
    export GUARD_WORK_FOLDER="${TOOL}"
    script peek.py 'from pathlib import Path
print((Path.home() / "org/clients/acme/received/memo.md").read_text())'
    bash_call "python3 peek.py"; denied
    says "reads inside client"
    script peek.sh "cat ~/org/clients/acme/received/memo.md"
    bash_call "bash peek.sh"; denied
    script walk.sh "grep -rn value ${H}/org"
    bash_call "bash walk.sh"; denied
    says "reads inside client, company"
    script fine.sh "cat ${TOOL}/fix.py"
    bash_call "bash fine.sh"; passed
}

@test "script files: a shell script that switches the guards off on a send is refused" {
    script land.sh "git commit --no-verify -m x"
    bash_call "bash land.sh"; denied
    says "--no-verify"
    # a file run by its path: by the program its #! line names, or by the shell when it has none
    script land.sh "git -c core.hooksPath=/dev/null commit -m x"
    bash_call "./land.sh"; denied
    printf '#!/bin/bash\n%s\n' "git commit -n -m x" > "${TOOL}/land.sh"
    bash_call "${TOOL}/land.sh"; denied
    # a comment line is not a command: an installer that says how to remove the hooks runs
    printf '#!/bin/bash\n%s\n%s\n' "# to undo:   rm -rf ~/.git-hooks" "echo installed" > "${TOOL}/land.sh"
    bash_call "${TOOL}/land.sh"; passed
    printf '#!/bin/bash\n%s\n' "rm -rf ~/.git-hooks" > "${TOOL}/land.sh"
    bash_call "${TOOL}/land.sh"; denied
}

# --- sends --------------------------------------------------------------------------------------

@test "script files: a script that sends to a declared host is judged as the same code in the command" {
    script post.py "import urllib.request
urllib.request.urlopen('https://chat.example.com/api', data=b'x')"
    bash_call "python3 post.py"; denied
    says "chat.example.com"
    script post.sh "curl -d x https://chat.example.com/api"
    bash_call "bash post.sh"; denied
    script post.sh "cd ${H} && curl -d x https://chat.example.com/api"
    bash_call "cd scripts && bash ../post.sh"; denied
    # code that only computes and writes this machine's files holds its URLs as text
    script note.py "from pathlib import Path
Path('${TOOL}/note.md').write_text('see https://chat.example.com/archives/C000/p1')"
    bash_call "python3 note.py"; passed
}

@test "script files: an osascript file sends to the applications it names" {
    script mail.applescript 'tell application "Mail" to activate'
    bash_call "osascript mail.applescript"; denied
    script notes.applescript 'tell application "Notes" to activate'
    bash_call "osascript notes.applescript"; passed
}

# --- what the reading of #199 left open ------------------------------------------------------------

@test "script files: a script fed on standard input is read" {
    script w.sh "echo x >> ${PLACE}/a.jsonl"
    script fix.py "${TICKET_FIX}"
    local command
    for command in "bash < w.sh" "cat w.sh | bash" "cat w.sh | bash -s" "sh -s < w.sh" \
                   "python3 < fix.py" "python3 - < fix.py" "cat fix.py | python3 -"; do
        bash_call "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
    script post.sh "curl -d x https://chat.example.com/api"
    bash_call "bash < post.sh"; denied
    bash_call "cat post.sh | bash"; denied
    script land.sh "git commit --no-verify -m x"
    bash_call "bash < land.sh"; denied
    # a pipe from something other than a plain cat is only known as it runs
    bash_call "grep -v '^#' w.sh | bash"; passed
}

@test "script files: an option's value is not taken for the file, nor a #! line's env option for the program" {
    script fix.py "${TICKET_FIX}"
    bash_call "python3 --check-hash-based-pycs never fix.py"; denied
    script inner/env.py "#!/usr/bin/env -S -u FOO python3
${TICKET_FIX}"
    chmod +x "${TOOL}/inner/env.py"
    bash_call "./inner/env.py"; denied
    script inner/chdir.py "#!/usr/bin/env -S --chdir=/tmp -P /usr/bin python3
${TICKET_FIX}"
    chmod +x "${TOOL}/inner/chdir.py"
    bash_call "./inner/chdir.py"; denied
}

@test "script files: another shell and a free-threaded Python are read too" {
    script w.csh "echo x >> ${PLACE}/a.jsonl"
    local shell
    for shell in csh tcsh fish ksh; do
        bash_call "${shell} w.csh"
        denied || { echo "not refused: ${shell}"; return 1; }
    done
    script fix.py "${TICKET_FIX}"
    bash_call "python3.14t fix.py"; denied
}

@test "script files: the home folder said through an imported name, str(), a name given it or an f-string" {
    local T="platform/state/claude-pwa-client/tickets" code
    for code in "from os.path import expanduser
open(expanduser('~') + '/${T}/a.jsonl', 'w')" \
                "from os import environ
open(environ['HOME'] + '/${T}/a.jsonl', 'w')" \
                "from pathlib import Path
open(str(Path.home()) + '/${T}/a.jsonl', 'w')" \
                "from pathlib import Path
h = Path.home()
(h / 'platform' / 'state' / 'claude-pwa-client' / 'tickets' / 'a.jsonl').touch()" \
                "import os
open(f\"{os.environ['HOME']}/${T}/a.jsonl\", 'w')"; do
        script home.py "${code}"
        bash_call "python3 home.py"
        denied || { echo "not refused: ${code}"; return 1; }
    done
    script home.js "const {homedir} = require('os'); require('fs').writeFileSync(homedir() + '/${T}/a.jsonl', 'x')"
    bash_call "node home.js"; denied
    script home.js "require('fs').writeFileSync(require('os').homedir() + '/${T}/a.jsonl', 'x')"
    bash_call "node home.js"; denied
    # a relative path in code that speaks of home is under home only where that folder is there
    script note.py "import os
print(os.path.expanduser('~'))
open('out/report.md', 'w').write('x')"
    bash_call "python3 note.py"; passed
}
