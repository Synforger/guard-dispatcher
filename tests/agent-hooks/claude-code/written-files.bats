#!/usr/bin/env bats
# agent-hooks/claude-code/written_files.py (through script_files.py, area-guard.py and outgoing.py)
# — a file a command writes from text it holds, or copies from a source it can name, and then runs,
# is read as the code that runs, with what the file already holds; and the code a shell is fed on
# standard input is read as the shell's code.
#
# A throwaway HOME holds a company folder, a platform root with the tickets folder outside every
# area, and the tool repository the session works in. Nothing a test hands the hook runs.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    TOOL="${H}/repos/tool"
    PLACE="${H}/platform/state/claude-pwa-client/tickets"
    mkdir -p "${H}/org" "${TOOL}/scripts" "${PLACE}" "${GUARD_CONFIG_DIR}"
    git init -q "${TOOL}"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export AGENT_PLATFORM_ROOT="${H}/platform"
    export GUARD_CORPUS_MAX_AGE=0
    unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE
    printf '%s\n' 'company ~/org' > "${GUARD_CONFIG_DIR}/areas.txt"
    printf '%s\n' 'host:chat.example.com company order' '* outside' > "${GUARD_CONFIG_DIR}/destinations.txt"
}

# judged <passed|denied> <command>... — run the hook on each command at once, each a call of its own.
judged() {
    local want="$1" n=0 command answer waited=() out="${BATS_TEST_TMPDIR}/answers"
    shift
    mkdir -p "${out}"
    for command in "$@"; do
        n=$((n + 1))
        jq -n --arg m "${command}" --arg c "${TOOL}" \
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

# reason_of <command> — the reason the hook gives for one command.
reason_of() {
    jq -n --arg m "$1" --arg c "${TOOL}" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: $m}, cwd: $c, hook_event_name: "PreToolUse"}' \
        | python3 "${HOOK}"
}
says() { [[ "$1" == *"$2"* ]] || { echo "$1"; return 1; }; }

# script <path> <text> — write a file of code (the path relative to the tool repository).
script() { mkdir -p "$(dirname "${TOOL}/$1")"; printf '%s\n' "$2" > "${TOOL}/$1"; }

NL=$'\n'
# What code that moves a ticket away does, and what code that only writes a note does.
TICKET_CODE="from pathlib import Path
(Path.home() / 'platform/state/claude-pwa-client/tickets' / 't-1.jsonl').unlink()"
ONE_LINE="${TICKET_CODE//$'\n'/;}"
HARMLESS_CODE="print('harmless')"
TICKET_REASON='a ticket is written with `tabs ticket`'

# --- a file written and run in one command ------------------------------------------------------

@test "written files: text written into a file that the command then runs is read as that code" {
    judged denied \
        "cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "cat > fix.py <<EOF${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "cat <<'EOF' > fix.py${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "tee fix.py <<'EOF' > /dev/null${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "cat > ${TOOL}/fix.py <<'EOF' && python3 ${TOOL}/fix.py${NL}${TICKET_CODE}${NL}EOF" \
        "cat > fix.py <<-'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "cat > fix.py <<< \"${ONE_LINE}\"; python3 fix.py" \
        "echo \"${ONE_LINE}\" > fix.py && python3 fix.py" \
        "printf '%s\n' \"${ONE_LINE}\" > fix.py; python3 fix.py" \
        "printf \"${ONE_LINE}\n\" >> fix.py; python3 fix.py" \
        "echo \"${ONE_LINE}\" | tee fix.py; python3 fix.py"
    says "$(reason_of "cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py")" "${TICKET_REASON}"
}

@test "written files: a written file run by its path or by a shell is read, by its own #! line when it has one" {
    judged denied \
        "cat > run.sh <<'EOF'${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF${NL}bash run.sh" \
        "cat > run.sh <<'EOF'${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF${NL}chmod +x run.sh${NL}./run.sh" \
        "cat > run.py <<'EOF'${NL}#!/usr/bin/env python3${NL}${TICKET_CODE}${NL}EOF${NL}chmod +x run.py && ./run.py" \
        "cat > run.sh <<'EOF'${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF${NL}source run.sh"
}

@test "written files: the file is the one in the folder the command stands in when it writes and when it runs" {
    judged denied \
        "cd scripts && cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "cat > scripts/fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}cd scripts && python3 fix.py" \
        "cd scripts; cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}cd ..; python3 scripts/fix.py" \
        "F=scripts/fix.py; cat > \$F <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 \$F" \
        "(cd scripts && cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}); python3 scripts/fix.py" \
        "(cd scripts && echo \"${ONE_LINE}\" > fix.py); python3 scripts/fix.py" \
        "(cd scripts; echo \"${ONE_LINE}\" > fix.py) && python3 scripts/fix.py"
    # a file written in another folder than the one run is not the one that runs
    judged passed "cd scripts && cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}cd .. && python3 fix.py"
}

# --- a file that is already there ---------------------------------------------------------------

@test "written files: the text a file holds and the text written over it, or added to it, are both read" {
    script fix.py "${HARMLESS_CODE}"
    judged denied \
        "cat > fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py" \
        "cat >> fix.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 fix.py"
    script fix.py "${TICKET_CODE}"
    # the write may fail, and then the old file runs
    judged denied \
        "cat > fix.py <<'EOF'${NL}${HARMLESS_CODE}${NL}EOF${NL}python3 fix.py" \
        "echo \"${HARMLESS_CODE}\" >> fix.py; python3 fix.py"
}

@test "written files: a text added to a file run by its path leaves the file read by the #! line it holds" {
    script fix.py "#!/usr/bin/env python3${NL}${TICKET_CODE}"
    chmod +x "${TOOL}/fix.py"
    judged denied \
        "echo '# note' >> fix.py && ./fix.py" \
        "printf '\\nprint(2)\\n' >> fix.py; ./fix.py"
}

# --- what stays as it was -----------------------------------------------------------------------

@test "written files: a file written with harmless code and run passes, and so does one that is only written" {
    judged passed \
        "cat > job.py <<'EOF'${NL}${HARMLESS_CODE}${NL}EOF${NL}python3 job.py" \
        "cat > job.sh <<'EOF'${NL}echo hello > out.txt${NL}EOF${NL}bash job.sh" \
        "echo \"${HARMLESS_CODE}\" > job.py && python3 job.py" \
        "printf '%s\n' \"${HARMLESS_CODE}\" > job.py; python3 job.py" \
        "cat > note.md <<'EOF'${NL}${TICKET_CODE}${NL}EOF" \
        "cat > note.md <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}python3 other.py" \
        "python3 job.py; cat > job.py <<'EOF'${NL}${HARMLESS_CODE}${NL}EOF"
}

@test "written files: a file written by a download or an edit in place is judged by what it holds on disk, as before" {
    script job.py "${HARMLESS_CODE}"
    judged passed \
        "sed -i '' 's/a/b/' job.py && python3 job.py" \
        "curl -o job.py http://localhost:1/x; python3 job.py" \
        "wget -O job.py http://localhost:1/x && python3 job.py"
}

@test "written files: a written text the shell fills in as the command runs is not read" {
    judged passed "cat > job.py <<EOF${NL}\$(cat other.py)${NL}EOF${NL}python3 job.py"
}

@test "written files: a written file that sends to a declared host or writes the guard's settings is refused" {
    judged denied \
        "cat > post.sh <<'EOF'${NL}curl -d x https://chat.example.com/api${NL}EOF${NL}bash post.sh" \
        "cat > post.py <<'EOF'${NL}import urllib.request${NL}urllib.request.urlopen('https://chat.example.com/api', data=b'x')${NL}EOF${NL}python3 post.py" \
        "cat > set.sh <<'EOF'${NL}echo '* outside' >> ${GUARD_CONFIG_DIR}/destinations.txt${NL}EOF${NL}bash set.sh"
    says "$(reason_of "cat > post.sh <<'EOF'${NL}curl -d x https://chat.example.com/api${NL}EOF${NL}bash post.sh")" "chat.example.com"
    says "$(reason_of "cat > set.sh <<'EOF'${NL}echo '* outside' >> ${GUARD_CONFIG_DIR}/destinations.txt${NL}EOF${NL}bash set.sh")" "the guard's settings"
}

# --- a copy ------------------------------------------------------------------------------------

@test "written files: a file copied or moved from a source the line can name is read as the source's content" {
    script src.py "${TICKET_CODE}"
    script harmless.py "${HARMLESS_CODE}"
    judged denied \
        "cp src.py fix.py && python3 fix.py" "cp -p src.py fix.py; python3 fix.py" \
        "cp ${TOOL}/src.py scripts/ && python3 scripts/src.py" "cp src.py scripts && python3 scripts/src.py" \
        "cp src.py scripts/ && cd scripts && python3 src.py" "mv src.py fix.py; python3 fix.py" \
        "install -m 755 src.py run.py && python3 run.py"
    judged passed \
        "cp harmless.py fix.py && python3 fix.py" \
        "cp harmless.py fix.py; python3 fix.py; cp src.py other.py"
}

@test "written files: a copy of a file the command writes first, or of one it copies, is read through" {
    script harmless.py "${HARMLESS_CODE}"
    script src.py "${TICKET_CODE}"
    judged denied \
        "cat > a.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}cp a.py b.py && python3 b.py" \
        "cat > a.py <<'EOF'${NL}${TICKET_CODE}${NL}EOF${NL}cp a.py b.py && cp b.py c.py && python3 c.py" \
        "cp harmless.py fix.py; cp src.py fix.py; python3 fix.py"
}

@test "written files: a copy whose source the line cannot name is read as the file is on disk" {
    script src.py "${TICKET_CODE}"
    script fix.py "${HARMLESS_CODE}"
    judged passed \
        "cp \$(echo src.py) fix.py && python3 fix.py" "cp src.* fix.py && python3 fix.py" \
        "cp missing.py fix.py && python3 fix.py"
}

# --- code a shell is fed on standard input ---------------------------------------------------------

@test "written files: a heredoc, a here-string or a text piped into a shell is read as the shell's code" {
    judged denied \
        "bash <<'EOF'${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF" \
        "bash -s <<EOF${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF" \
        "sh - <<'EOF'${NL}rm ${PLACE}/a.jsonl${NL}EOF" \
        "bash <<< 'echo x >> ${PLACE}/a.jsonl'" \
        "cat <<'EOF' | bash${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF" \
        "echo 'echo x >> ${PLACE}/a.jsonl' | zsh" \
        "printf '%s\\n' 'echo x >> ${PLACE}/a.jsonl' | bash" \
        "cd scripts && bash <<'EOF'${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF"
}

@test "written files: the shell's code fed on standard input is judged for what it sends and writes" {
    judged denied \
        "bash <<'EOF'${NL}curl -d x https://chat.example.com/api${NL}EOF" \
        "bash <<'EOF'${NL}echo '* outside' >> ${GUARD_CONFIG_DIR}/destinations.txt${NL}EOF"
    says "$(reason_of "bash <<'EOF'${NL}curl -d x https://chat.example.com/api${NL}EOF")" "chat.example.com"
    says "$(reason_of "bash <<'EOF'${NL}echo '* outside' >> ${GUARD_CONFIG_DIR}/destinations.txt${NL}EOF")" "the guard's settings"
}

@test "written files: the words after a shell's -s are the fed code's arguments, past its options and --" {
    local orders="${GUARD_CONFIG_DIR}/orders.txt"
    : > "${orders}"
    judged denied \
        "bash -s -- ${orders} <<'EOF'${NL}rm \"\$1\"${NL}EOF" \
        "bash -s -x -- ${orders} <<'EOF'${NL}rm \"\$1\"${NL}EOF" \
        "echo 'rm \"\$1\"' | bash -s -- ${orders}"
}

@test "written files: a shell fed code that only writes beside the tool passes as before" {
    judged passed \
        "bash <<'EOF'${NL}echo hello > out.txt${NL}EOF" \
        "cat <<'EOF' | bash${NL}ls${NL}EOF" \
        "echo ls | bash" \
        "cat <<'EOF' > note.md${NL}echo x >> ${PLACE}/a.jsonl${NL}EOF" \
        "bash <<'EOF' > log.txt${NL}git status${NL}EOF"
}
