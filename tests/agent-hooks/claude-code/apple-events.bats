#!/usr/bin/env bats
# agent-hooks/claude-code/apple_events.py + outgoing.py (through area-guard.py) — a script for
# osascript sends Apple events to the applications it names, and is judged as a send to each.
#
# A throwaway HOME holds an area with one made-up document. Every call feeds the hook the JSON
# Claude Code sends before a tool runs.

load ../../_internal/helpers

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"
CHAT="bring the folding chairs and the blue cooler to the lake on sunday"

setup() {
    setup_words
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/chats" "${H}/personal" "${H}/work" "${GUARD_CONFIG_DIR}"
    printf '%s\n' "${CHAT}" > "${H}/chats/talk.md"
    export HOME="${H}"
    export AREA_GUARD_STATE="${H}/state"
    export GUARD_CORPUS_MAX_AGE=0
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
chats    ~/chats
personal ~/personal
AREAS
    printf '%s\n' 'app:calendar personal' 'app:com.apple.ical personal' > "${GUARD_CONFIG_DIR}/destinations.txt"
}

# bash_call <command> — run the hook on one Bash call.
bash_call() {
    local event
    event="$(jq -n --arg c "$1" --arg d "${H}/work" \
        '{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
    run python3 "${HOOK}" <<< "${event}"
}

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
denied() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]]; }

@test "apple events: the applications a script names, AppleScript and JavaScript, each once in lower case" {
    run python3 -c "
import sys; sys.path.insert(0, '${GUARD_ROOT}/agent-hooks/claude-code')
import apple_events
print(apple_events.applications('''tell application \"Calendar\" to make new event
tell application id \"com.apple.iCal\" to activate
Application(\"Reminders\").lists()
Application('CALENDAR').calendars()
Application.currentApplication()'''))"
    [ "${output}" = "['calendar', 'com.apple.ical', 'reminders']" ]
}

@test "apple events: a chat line written into an event by osascript -e is refused, the agent's own words pass" {
    bash_call "osascript -l JavaScript -e 'Application(\"Calendar\").calendars[0].events.push(Application(\"Calendar\").Event({summary: \"${CHAT}\"}))'"
    denied
    [[ "${output}" == *"app:calendar"* ]]
    bash_call "osascript -l JavaScript -e 'Application(\"Calendar\").calendars[0].events.push(Application(\"Calendar\").Event({summary: \"lake trip\"}))'"
    passed
}

@test "apple events: an AppleScript naming the app by its bundle id is the same send" {
    bash_call "osascript -e 'tell application id \"com.apple.iCal\" to make new event with properties {summary:\"${CHAT}\"}'"
    denied
    [[ "${output}" == *"app:com.apple.ical"* ]]
}

@test "apple events: a script fed on a here-string or a heredoc is read too" {
    bash_call "osascript <<< 'tell application \"Calendar\" to make new event with properties {summary:\"${CHAT}\"}'"
    denied
    bash_call "osascript <<'EOF'
tell application \"Calendar\"
  make new event with properties {summary:\"${CHAT}\"}
end tell
EOF"
    denied
}

@test "apple events: a script piped in is only known as it runs" {
    printf 'app:? block\n' >> "${GUARD_CONFIG_DIR}/destinations.txt"
    bash_call "cat script.applescript | osascript"
    denied
    [[ "${output}" == *"app:?"* ]]
}

@test "apple events: an application no line names is undeclared and passes" {
    bash_call "osascript -e 'tell application \"Finder\" to display dialog \"${CHAT}\"'"
    passed
}
