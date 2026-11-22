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

# --- a script that writes where its arguments say ------------------------------------------------

# What the guard judges from, and what it keeps for the operator: its settings and a session's transcript.
# The file is read as code, and a word handed to it is no path that code names, unless it names one of them.
SETTINGS_REASON="what the guard lets through is judged from it"
TRANSCRIPT_REASON="an order for a send is judged from it"

keep_files() {
    SETTING="${GUARD_CONFIG_DIR}/orders.txt"
    TRANSCRIPT="${H}/.claude/projects/-w/abc.jsonl"
    mkdir -p "$(dirname "${TRANSCRIPT}")"
    printf 'send it\n' > "${SETTING}"
    : > "${TRANSCRIPT}"
    : > "${H}/notes.txt"
}

@test "script files: a script that writes where its argument says is refused when the argument names the settings or a transcript" {
    keep_files
    script put.py 'import sys
open(sys.argv[1], "a").write("x")'
    script copy.py 'import sys, shutil
shutil.copy("/etc/hosts", sys.argv[1])'
    script held.py 'import sys
out = sys.argv[1]
with open(out, "a") as f:
    f.write("x")'
    script second.py 'import sys
from pathlib import Path
Path(sys.argv[2]).write_text("x")'
    script imported.py 'from sys import argv
open(argv[1], "w")'
    script each.py 'import sys
for path in sys.argv[1:]:
    open(path, "a").write("x")'
    script parsed.py 'import argparse
parser = argparse.ArgumentParser()
parser.add_argument("target")
args = parser.parse_args()
open(args.target, "a").write("x")'
    script whole.py 'import sys
for path in sys.argv:
    open(path, "a").write("x")'
    script chosen.py 'import sys
n = len(sys.argv) - 1
open(sys.argv[n], "a").write("x")'
    script handed.py 'import sys, functools
functools.reduce(open, [sys.argv[1], "w"])'
    script put.sh 'echo x >> "$1"'
    script tee.sh 'tee -a "$@" < /dev/null'
    script copy.sh 'cp /etc/hosts $2'
    local target reason command
    for target in "${SETTING}" "${TRANSCRIPT}"; do
        reason="${SETTINGS_REASON}"; [ "${target}" = "${TRANSCRIPT}" ] && reason="${TRANSCRIPT_REASON}"
        for command in "python3 put.py ${target}" "python3 copy.py ${target}" "python3 held.py ${target}" \
                       "python3 second.py -o ${target}" "python3 imported.py ${target}" "python3 each.py a ${target}" \
                       "python3 parsed.py ${target}" "python3 whole.py ${target}" "python3 chosen.py a ${target}" \
                       "python3 handed.py ${target}" "uv run put.py ${target}" \
                       "sh put.sh ${target}" "bash tee.sh ${target}" "bash copy.sh -f ${target}" \
                       "cd ${H} && python3 ${TOOL}/put.py ${target}" "bash -c 'python3 put.py ${target}'" \
                       "python3 put.py --out=${target}"; do
            bash_call "${command}"
            denied || { echo "not refused: ${command}"; return 1; }
            says "${reason}" || { echo "reason: ${command}"; return 1; }
        done
    done
}

@test "script files: a relative argument names the file where the command stands" {
    keep_files
    script put.py 'import sys
open(sys.argv[1], "a").write("x")'
    script put.sh 'echo x >> "$1"'
    bash_in "${GUARD_CONFIG_DIR}" "python3 ${TOOL}/put.py orders.txt"; denied
    bash_in "${GUARD_CONFIG_DIR}" "bash ${TOOL}/put.sh orders.txt"; denied
    bash_in "$(dirname "${TRANSCRIPT}")" "python3 ${TOOL}/put.py abc.jsonl"; denied
    bash_in "${H}" "python3 ${TOOL}/put.py orders.txt"; passed
}

@test "script files: a script that reads what its argument names, or writes elsewhere, passes" {
    keep_files
    script read.py 'import sys
print(open(sys.argv[1]).read())'
    script parsed.py 'import argparse
parser = argparse.ArgumentParser()
parser.add_argument("source")
args = parser.parse_args()
print(open(args.source).read())'
    script elsewhere.py 'import sys
data = open(sys.argv[1]).read()
open("/tmp/copy.txt", "w").write(data)'
    script stat.py 'import os, sys
print(os.path.getsize(sys.argv[1]), os.stat(sys.argv[1]).st_mtime)'
    script second.py 'import sys
open(sys.argv[2], "a").write("x")'
    script read.sh 'cat "$1"'
    script elsewhere.sh 'echo x >> /tmp/log.txt
wc -l "$1" > ${HOME}/notes.txt'
    script put.py 'import sys
open(sys.argv[1], "a").write("x")'
    local target command
    for target in "${SETTING}" "${TRANSCRIPT}"; do
        for command in "python3 read.py ${target}" "python3 parsed.py ${target}" "python3 elsewhere.py ${target}" \
                       "python3 stat.py ${target}" "python3 second.py ${target} ${H}/notes.txt" \
                       "bash read.sh ${target}" "bash elsewhere.sh ${target}"; do
            bash_call "${command}"
            passed || { echo "refused: ${command}"; return 1; }
        done
    done
    # a script handed nothing that the agent may not write is read as it was: what it writes is its own
    bash_call "python3 put.py ${H}/notes.txt"; passed
    bash_call "python3 put.py"; passed
}

@test "script files: the reason is the one the same write gets from the command" {
    keep_files
    script put.py 'import sys
open(sys.argv[1], "a").write("x")'
    bash_call "python3 put.py ${SETTING}"; denied
    says "an agent does not write or remove the guard's settings (orders.txt)"
    bash_call "python3 put.py ${TRANSCRIPT}"; denied
    says "an agent does not write or remove a session's transcript"
    bash_call "python3 -c \"open('${SETTING}', 'a').write('x')\""; denied
    says "an agent does not write or remove the guard's settings (orders.txt)"
}

# --- the words a script hands on, spells another way, or takes in another language -----------------

@test "script files: a script that hands its word to another script is read through to the write" {
    keep_files
    script put.py 'import sys
open(sys.argv[1], "a").write("x")'
    script nested.sh 'python3 put.py "$1"'
    script outer.sh 'bash nested.sh "$1"'
    script relay.sh 'bash -c "python3 put.py $1"'
    local target command
    for target in "${SETTING}" "${TRANSCRIPT}"; do
        for command in "bash nested.sh ${target}" "bash outer.sh ${target}" "bash relay.sh ${target}"; do
            bash_call "${command}"
            denied || { echo "not refused: ${command}"; return 1; }
        done
    done
    script look.py 'import sys
print(open(sys.argv[1]).read())'
    script look.sh 'python3 look.py "$1"'
    bash_call "bash look.sh ${SETTING}"; passed
}

@test "script files: a shell script that loops over its words, shifts them or defaults one is read with the words in place" {
    keep_files
    script loop.sh 'for f in "$@"; do
  echo x >> "$f"
done'
    script loop_in.sh 'for f in "$@"; do echo x >> "$f"; done'
    script bare.sh 'for f; do tee -a "$f" < /dev/null; done'
    script skip.sh 'shift
echo x >> "$1"'
    script skip_two.sh 'shift 2
echo x >> "$1"'
    script default.sh 'echo x >> "${1:-/tmp/log.txt}"'
    script braced.sh 'echo x >> "${2}"'
    script rest.sh 'cp /etc/hosts ${@:2}'
    script counted.sh 'while [ $# -gt 0 ]; do
  echo x >> "$1"
  shift
done'
    script options.sh 'while getopts o: flag; do
  echo x >> "$OPTARG"
done'
    local target command
    for target in "${SETTING}" "${TRANSCRIPT}"; do
        for command in "bash loop.sh a ${target}" "bash loop_in.sh ${target}" "bash bare.sh ${target}" \
                       "bash skip.sh a ${target}" "bash skip_two.sh a b ${target}" "bash default.sh ${target}" \
                       "bash braced.sh a ${target}" "bash rest.sh a ${target}" "bash counted.sh a ${target}" \
                       "bash options.sh -o ${target}"; do
            bash_call "${command}"
            denied || { echo "not refused: ${command}"; return 1; }
        done
    done
    # the word the script shifts away, or only reads, is no write
    bash_call "bash skip.sh ${SETTING} ${H}/notes.txt"; passed
    bash_call "bash default.sh ${H}/notes.txt"; passed
    script reading.sh 'for f in "$@"; do
  cat "$f"
done
while [ $# -gt 0 ]; do
  wc -l "$1"
  shift
done'
    bash_call "bash reading.sh ${SETTING} ${TRANSCRIPT}"; passed
}

@test "script files: a # in a word is no comment: what follows on the line is read" {
    keep_files
    bash_call "echo \$# ; echo x >> ${SETTING}"; denied
    bash_call "echo a#b; echo x >> ${SETTING}"; denied
    bash_call "echo \$#
echo x >> ${TRANSCRIPT}"; denied
    bash_call "echo \$# ; echo x >> ${H}/notes.txt"; passed
    bash_call "echo x # echo y >> ${SETTING}"; passed
}

@test "script files: node, ruby, perl and php code that takes its arguments and writes is refused, one that only reads passes" {
    keep_files
    script put.js "require('fs').appendFileSync(process.argv[2], 'x')"
    script put.rb "File.write(ARGV[0], 'x')"
    script put.pl 'open(my $out, ">>", $ARGV[0]); print $out "x";'
    script put.php '<?php file_put_contents($argv[1], "x", FILE_APPEND);'
    script run.js "require('child_process').execSync('tee -a ' + process.argv[2])"
    script look.js "console.log(require('fs').readFileSync(process.argv[2], 'utf8'))"
    script look.rb 'puts File.read(ARGV[0])'
    script look.pl 'open(my $in, "<", $ARGV[0]); print <$in>;'
    script look.php '<?php echo file_get_contents($argv[1]);'
    script fixed.js "require('fs').writeFileSync('${H}/notes.txt', 'x')"
    local target command
    for target in "${SETTING}" "${TRANSCRIPT}"; do
        for command in "node put.js a ${target}" "ruby put.rb ${target}" "perl put.pl ${target}" "php put.php ${target}" \
                       "node run.js ${target}"; do
            bash_call "${command}"
            denied || { echo "not refused: ${command}"; return 1; }
        done
        for command in "node look.js ${target}" "ruby look.rb ${target}" "perl look.pl ${target}" "php look.php ${target}" \
                       "node fixed.js ${target}"; do
            bash_call "${command}"
            passed || { echo "refused: ${command}"; return 1; }
        done
    done
}

@test "script files: a folder of transcripts handed to a script that takes it away or fills it is refused" {
    keep_files
    local records="${H}/.claude/projects"
    script drop.sh 'rm -rf "$1"'
    script move.sh 'mv "$1" /tmp/gone'
    script fill.sh 'cp -r /etc/hosts "$1"/'
    script wipe.py 'import shutil, sys
shutil.rmtree(sys.argv[1])'
    script via.sh 'bash drop.sh "$1"'
    local folder command
    for folder in "${records}" "${records}/-w" "${H}/.claude/projects/"; do
        for command in "bash drop.sh ${folder}" "bash move.sh ${folder}" "python3 wipe.py ${folder}" "bash via.sh ${folder}"; do
            bash_call "${command}"
            denied || { echo "not refused: ${command}"; return 1; }
            says "the folder holding a session's transcripts" || { echo "reason: ${command}"; return 1; }
        done
    done
    script look.sh 'ls "$1"
cp -r "$1" /tmp/copy'
    script look.py 'import os, sys
print(os.listdir(sys.argv[1]))'
    bash_call "bash look.sh ${records}"; passed
    bash_call "python3 look.py ${records}"; passed
    bash_call "bash drop.sh ${H}/notes.txt"; passed
}

@test "script files: a command behind a shell keyword is read as the command it is" {
    keep_files
    local command
    for command in "for f in a; do tee -a ${SETTING} < /dev/null; done" "for f in a; do rm ${SETTING}; done" \
                   "if true; then rm ${SETTING}; fi" "while true; do cp /etc/hosts ${SETTING}; break; done" \
                   "{ rm ${SETTING}; }" "! rm ${SETTING}" "until false; do mv ${TRANSCRIPT} ${H}/gone; done"; do
        bash_call "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
    script put.sh 'echo x >> "$1"'
    bash_call "for f in a; do bash put.sh ${SETTING}; done"; denied
    bash_call "for f in a; do rm ${H}/notes.txt; done"; passed
}

# A `cd` inside the branch of an if / for / while / until / case reaches only to the end of the branch, in a
# script file as in a command line: what follows `fi`, `done` or `esac` stands where the branch began.

@test "script files: a script that cleans up inside a branch is judged after it from where it began" {
    git -C "${TOOL}" remote add origin git@github.com:o/tool.git
    seed_visibility o/tool private
    mkdir -p "${H}/tmp-clone" "${H}/hooks"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    script promote.sh '#!/bin/bash
BASE_DIR="$1"
BASE_CLONE="$2"
if [ -z "$(git status --porcelain)" ]; then
    echo "nothing to promote"
    if [ "$MADE_WORKTREE" -eq 1 ]; then
        cd "$BASE_CLONE"
        git worktree remove "$BASE_DIR"
        git branch -q -D "$FEATURE_BRANCH"
    fi
    exit 0
fi
git add -A
git -C '"${TOOL}"' commit -m "$MSG" -q
git -C '"${TOOL}"' push origin HEAD'
    bash_call "bash promote.sh ${TOOL} \$HOME/tmp-clone"; passed
    bash_call "./promote.sh ${TOOL} \$HOME/tmp-clone"; passed
    script cases.sh 'case "$1" in
    a) cd "$2";;
    b|c) cd "$2"; ls;;
esac
for d in x y; do cd "$2"; done
while false; do cd "$2"; done
git commit -m x -q'
    bash_call "bash cases.sh a \$ELSEWHERE"; passed
}

@test "script files: a send inside a branch of a script stands where the branch cd'd to" {
    script inside.sh 'if true; then
    cd "$ELSEWHERE"
    git commit -m x -q
fi'
    bash_call "bash inside.sh"; denied; says "only known as it runs"
    script after.sh 'cd "$ELSEWHERE"
if true; then ls; fi
git commit -m x -q'
    bash_call "bash after.sh"; denied; says "only known as it runs"
    script loop.sh 'for d in a; do cd "$ELSEWHERE"; git commit -m x -q; done'
    bash_call "bash loop.sh"; denied; says "only known as it runs"
    script chosen.sh 'case "$1" in
    a) cd "$ELSEWHERE"; git commit -m x -q;;
esac'
    bash_call "bash chosen.sh a"; denied; says "only known as it runs"
}

@test "script files: a cd inside a branch is no reason to look for the next script where the branch went" {
    keep_files
    script put.sh 'echo x >> "$1"'
    bash_call "if true; then cd ${H}; fi; bash put.sh ${SETTING}"; denied
    says "the guard's settings"
    bash_call "for d in a; do cd ${H}/org; done; bash put.sh ${SETTING}"; denied
    bash_call "case x in a) cd ${H};; esac; bash put.sh ${SETTING}"; denied
    bash_call "cd ${H}; if true; then ls; fi; bash put.sh ${SETTING}"; passed
    bash_call "if true; then cd ${H}; bash put.sh ${SETTING}; fi"; passed
}

@test "script files: a write inside a branch lands in the folder the branch cd'd to" {
    keep_files
    local command
    for command in "if true; then cd ${GUARD_CONFIG_DIR}; echo x > orders.txt; fi" \
                   "if true; then ls; else cd ${GUARD_CONFIG_DIR}; echo x >> orders.txt; fi" \
                   "for d in a; do cd ${GUARD_CONFIG_DIR}; rm orders.txt; done" \
                   "case x in a) cd ${GUARD_CONFIG_DIR}; tee orders.txt < /dev/null;; esac" \
                   "cd ${GUARD_CONFIG_DIR}; if true; then ls; fi; echo x > orders.txt"; do
        bash_call "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
    script settle.sh 'if true; then cd "$1"; fi
echo x > orders.txt'
    bash_call "bash settle.sh ${GUARD_CONFIG_DIR}"; passed
    bash_call "if true; then cd ${GUARD_CONFIG_DIR}; fi; echo x > orders.txt"; passed
    bash_call "for d in a; do cd ${GUARD_CONFIG_DIR}; done; rm orders.txt"; passed
}

# The patterns of a case are what a value is matched against: `'~/'*)` is no `~/*` that names every folder of
# the home folder, and `/org/*)` no path the tab reads. What the branch after the `)` runs is read as ever.

@test "script files: a case's patterns name no path, written in the command or in a script" {
    export GUARD_WORK_FOLDER="${TOOL}"
    local command
    for command in "case \"\$c\" in '~'|'~/'*) c=x ;; esac" \
                   "case \"\$c\" in
                        '~'|'~/'*) c=x ;;
                        *) c=y ;;
                    esac" \
                   "case \$c in ${H}/org/*) c=x;; ${H}/*|~/*|~/org/*) c=y;; esac" \
                   "case \$c in (~/*) c=x;; esac" \
                   "if true; then case \"\$c\" in '~/'*) c=x ;; esac; fi"; do
        bash_call "${command}"
        passed || { echo "refused: ${command}"; echo "${output}"; return 1; }
    done
    script tilde.sh 'clone="$1"
case "$clone" in '"'~'|'~/'*"') clone="$HOME${clone#\~}" ;; esac
echo "$clone"'
    bash_call "bash tilde.sh \$X"; passed
    bash_call "./tilde.sh \$X"; passed
}

@test "script files: what a case's branch runs is still read, and a word after the patterns is still a path" {
    keep_files
    export GUARD_WORK_FOLDER="${TOOL}"
    local command
    for command in "case x in a) rm ${SETTING};; esac" \
                   "case x in '~/'*) c=1;; a|b) rm ${SETTING};; esac" \
                   "case x in a) cat ~/org/clients/acme/received/memo.md;; esac" \
                   "case x in a) c=1;; *) cat ~/org/clients/acme/received/memo.md; esac" \
                   "case ~/org/clients/acme/received/memo.md in a) c=1;; esac; cat ~/org/clients/acme/received/memo.md"; do
        bash_call "${command}"
        denied || { echo "not refused: ${command}"; return 1; }
    done
    script drop.sh "case \"\$1\" in '~/'*) c=1;; *) rm ${SETTING};; esac"
    bash_call "bash drop.sh x"; denied
    says "the guard's settings"
}

# A script that picks the folder it commits from in the branches of an `if` (the shape of the one that promotes a
# derived agent's files to its base): the folder is known when the command that runs it sets the variable
# the first condition reads, and is only known as it runs when it does not.
PICK_FOLDER='#!/bin/bash
BASE_CLONE="${BASE_CLONE:-${AGENT_PLATFORM_ROOT:+$AGENT_PLATFORM_ROOT/tools/agent-template}}"
MODE=clone
if [ -n "${BASE_REPO_PATH:-}" ]; then
    BASE_DIR="$BASE_REPO_PATH"
    MODE=path
    if [ ! -d "$BASE_DIR" ]; then
        echo "error: $BASE_DIR does not exist" >&2
        exit 1
    fi
elif [ -n "$BASE_CLONE" ] && git -C "$BASE_CLONE" rev-parse --git-dir > /dev/null 2>&1; then
    MODE=worktree
    BASE_DIR="$BASE_CLONE.worktrees/$FEATURE_BRANCH"
    git -C "$BASE_CLONE" worktree add -q "$BASE_DIR" "$FEATURE_BRANCH"
else
    TMP_DIR="$(mktemp -d)"
    BASE_DIR="$TMP_DIR/agent-template"
    git clone "$URL" "$BASE_DIR"
fi
cd "$BASE_DIR"
git add -A
git commit -m "$1" -q
if [ "$MODE" != path ]; then
    git push -u origin "$FEATURE_BRANCH"
fi'

@test "script files: a script that picks its folder in the branches of an if is read from the folder its command gives it" {
    git -C "${TOOL}" remote add origin git@github.com:o/tool.git
    seed_visibility o/tool private
    mkdir -p "${H}/hooks"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    script promote.sh "${PICK_FOLDER}"
    bash_call "BASE_REPO_PATH=${TOOL} FEATURE_BRANCH=feature/x bash promote.sh msg"; passed
    bash_call "env BASE_REPO_PATH=${TOOL} FEATURE_BRANCH=feature/x bash promote.sh msg"; passed
    bash_call "BASE_REPO_PATH=${TOOL} ./promote.sh msg"; passed
    bash_call "BASE_REPO_PATH=${TOOL} bash -c 'bash promote.sh msg'"; passed
    bash_call "bash promote.sh msg"; denied; says "only known as it runs (\$BASE_DIR)"
    bash_call "FEATURE_BRANCH=feature/x bash promote.sh msg"; denied; says "only known as it runs (\$BASE_DIR)"
    bash_call "BASE_REPO_PATH= bash promote.sh msg"; denied; says "only known as it runs (\$BASE_DIR)"
    bash_call "BASE_REPO_PATH=\$ELSEWHERE bash promote.sh msg"; denied; says "only known as it runs"
}

@test "script files: the branch a script's condition does not choose is not read, and one it cannot tell is" {
    git -C "${TOOL}" remote add origin git@github.com:o/tool.git
    seed_visibility o/tool private
    mkdir -p "${H}/hooks"
    printf '#!/bin/sh\n' > "${H}/hooks/pre-push"
    printf '[core]\n\thooksPath = %s\n' "${H}/hooks" > "${H}/.gitconfig"
    script chosen.sh 'if [ -n "$1" ]; then
    cd "$ELSEWHERE"
    git commit -m x -q
fi'
    script told.sh 'if [ -z "${FOLDER:-}" ]; then
    cd "$ELSEWHERE"
    git commit -m x -q
fi'
    bash_call "bash told.sh"; denied; says "only known as it runs"
    bash_call "FOLDER=${TOOL} bash told.sh"; passed
    bash_call "env FOLDER=${TOOL} bash told.sh"; passed
    bash_call "bash chosen.sh x"; denied
}
