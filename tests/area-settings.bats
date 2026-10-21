#!/usr/bin/env bats
# The settings an area keeps for itself (`$GUARD_CONFIG_DIR/areas/<area>/`): each line works inside
# the area only, a line that would reach outside it is not read and is named by `--settings`, and
# the machine's own files come first.

load helpers

CLIENT_TEXT="the calibration table reads seventeen at dawn"
COMPANY_TEXT="quarterly planning keeps the bench schedule"

setup() {
    setup_words
    export GUARD_CORPUS_MAX_AGE=0
    WORK="${BATS_TEST_TMPDIR}/work"
    CLIENT="${WORK}/clients/acme"
    OWN="${GUARD_CONFIG_DIR}/areas/company"
    mkdir -p "${CLIENT}/received" "${WORK}/meetings" "${WORK}/lab" "${OWN}/patterns" \
        "${BATS_TEST_TMPDIR}/elsewhere"
    printf '# notes\n%s\n' "${CLIENT_TEXT}" > "${CLIENT}/received/notes.md"
    printf '%s\n' "${COMPANY_TEXT}" > "${WORK}/meetings/plan.md"
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<EOF
company ${WORK}
client  ${CLIENT}
EOF
}

corpus() { run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" "$@"; }
send() { run python3 "${GUARD_ROOT}/scanners/send-scan.py" "$@"; }

@test "area settings: a sub-area inside the area joins the areas; a line reaching outside is not read" {
    cat > "${OWN}/areas.txt" <<EOF
lab        ${WORK}/lab
stray      ${BATS_TEST_TMPDIR}/elsewhere
_exempt    ${WORK}/meetings
EOF
    run python3 -c "
import importlib.util, sys
s = importlib.util.spec_from_file_location('c', '${GUARD_ROOT}/scanners/corpus-scan.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(' '.join(sorted(m.load_areas())))"
    [[ "$output" == *"lab"* ]]
    [[ "$output" != *"stray"* ]]
    [[ "$output" != *"_exempt"* ]]
    corpus --settings
    [ "$status" -eq 0 ]
    [[ "$output" == *"stray"*"is not a folder inside company"* ]]
    [[ "$output" == *"_exempt"*"sets a folder apart from every area"* ]]
}

@test "area settings: a destination the area places inside itself is read; outside and catch-alls are not" {
    cat > "${OWN}/destinations.txt" <<EOF
*svc_calendar*    company    order
*svc_mail*        outside
*                 client
*svc_drive*       nowhere
EOF
    send --where mcp__x__svc_calendar__create_event
    [ "$output" = "company order" ]
    send --where mcp__x__svc_mail__send
    [ "$output" = "undeclared" ]
    send --where some_other_tool
    [ "$output" = "undeclared" ]
    corpus --settings
    [[ "$output" == *"only the machine's own destinations.txt puts a destination outside every area"* ]]
    [[ "$output" == *"catches every destination"* ]]
    [[ "$output" == *"nowhere is no area within company"* ]]
    # the machine's own line comes first and wins
    printf '*svc_calendar*    block\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
    send --where mcp__x__svc_calendar__create_event
    [ "$output" = "block" ]
}

@test "area settings: a phrase the area keeps is fine to send of the areas within it only" {
    printf '%s\n' "${CLIENT_TEXT}" > "${BATS_TEST_TMPDIR}/payload.txt"
    corpus --text "${BATS_TEST_TMPDIR}/payload.txt" --dest-area OUTSIDE
    [ "$status" -eq 1 ]
    printf '%s\n' "${CLIENT_TEXT}" > "${OWN}/allow.txt"
    corpus --text "${BATS_TEST_TMPDIR}/payload.txt" --dest-area OUTSIDE
    [ "$status" -eq 0 ]
    # a phrase the client keeps does not reach the company around it
    mkdir -p "${GUARD_CONFIG_DIR}/areas/client"
    printf '%s\n' "${COMPANY_TEXT}" > "${GUARD_CONFIG_DIR}/areas/client/allow.txt"
    printf '%s\n' "${COMPANY_TEXT}" > "${BATS_TEST_TMPDIR}/payload.txt"
    corpus --text "${BATS_TEST_TMPDIR}/payload.txt" --dest-area OUTSIDE
    [ "$status" -eq 1 ]
}

@test "area settings: a shape the area keeps is an identifier of the areas within it" {
    printf 'part ZQ4711 ships\n' > "${BATS_TEST_TMPDIR}/payload.txt"
    corpus --text "${BATS_TEST_TMPDIR}/payload.txt" --dest-area OUTSIDE
    [ "$status" -eq 0 ]
    printf 'ZQ\\d{4}\n(unclosed\n' > "${OWN}/patterns/client.txt"
    corpus --text "${BATS_TEST_TMPDIR}/payload.txt" --dest-area OUTSIDE
    [ "$status" -eq 1 ]
    [[ "$output" == *"client shape"* ]]
    # a shape that does not compile is not read, and stops nothing else
    corpus --settings
    [[ "$output" == *"(unclosed"*"does not compile"* ]]
}

@test "area settings: a folder kept out of the walk is read only inside the area" {
    printf '%s\n%s\n' "${WORK}/lab" "${BATS_TEST_TMPDIR}/elsewhere" > "${OWN}/ignore.txt"
    corpus --settings
    [[ "$output" == *"elsewhere"*"is not a folder inside company"* ]]
    [[ "$output" != *"/lab'"* ]]
}

@test "area settings: a folder for no area is not read at all" {
    mkdir -p "${GUARD_CONFIG_DIR}/areas/ghost"
    printf '*svc_ghost*    company\n' > "${GUARD_CONFIG_DIR}/areas/ghost/destinations.txt"
    send --where mcp__x__svc_ghost__send
    [ "$output" = "undeclared" ]
    corpus --settings
    [[ "$output" == *"ghost is no area"* ]]
}

@test "area settings: a repository the area declares its own sits in the area for a push" {
    seed_visibility acme/tool private
    corpus --where --dest git@github.com:acme/tool.git
    [ "${lines[-1]}" = "OUTSIDE" ]
    printf 'repo:acme/*    company\n' > "${OWN}/destinations.txt"
    corpus --where --dest git@github.com:acme/tool.git
    [ "${lines[-1]}" = "$(cd -P "${WORK}" && pwd)" ]
    # an area cannot declare a repository outside every area: the line is not read
    printf 'repo:acme/*    outside\n' > "${OWN}/destinations.txt"
    corpus --settings
    [[ "$output" == *"repo:acme/*"*"outside every area"* ]]
}
