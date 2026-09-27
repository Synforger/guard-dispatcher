#!/usr/bin/env bats
# sandbox/seed-config.py — a cage's config directory starts from its account's.
#
# The throwaway HOME is the one cage-config.bats uses: a company folder with a
# client inside it. The account's state file has been through the first-run
# screens and trusts folders in every cage; each test builds a cage with
# cage-config.py and seeds its config directory from the account.

load helpers

CAGE="${GUARD_ROOT}/sandbox/cage-config.py"
SEED="${GUARD_ROOT}/sandbox/seed-config.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/org/clients/acme" "${H}/repos/public-tool" "${H}/.claude"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    unset GUARD_HOME
    mkdir -p "${GUARD_CONFIG_DIR}"
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org
client  ~/org/clients/acme
AREAS
    account_state "${H}/.claude.json"
    printf '{"theme": "dark"}\n' > "${H}/.claude/settings.json"
}

# account_state <file> — an account that has been through the first run and
# trusts one folder in each cage.
account_state() {
    jq -n --arg org "${H}/org" --arg acme "${H}/org/clients/acme" --arg tool "${H}/repos/public-tool" '{
        hasCompletedOnboarding: true, lastOnboardingVersion: "2.1.0", numStartups: 40,
        oauthAccount: {emailAddress: "someone@example.com"},
        projects: {
            ($org): {hasTrustDialogAccepted: true, allowedTools: ["Bash"]},
            ($acme): {hasTrustDialogAccepted: true},
            ($tool): {hasTrustDialogAccepted: true},
            "/elsewhere": {hasTrustDialogAccepted: false}
        }
    }' > "$1"
}

# seed <cage> [--account-dir DIR] — build the cage and seed it from the account.
seed() {
    local cage="$1"
    shift
    python3 "${CAGE}" "${cage}" "$@" > "${BATS_TEST_TMPDIR}/cage.json"
    run python3 "${SEED}" "${2:-${H}/.claude}" "${BATS_TEST_TMPDIR}/cage.json"
}

trusted() { jq -e --arg p "$2" '.projects[$p].hasTrustDialogAccepted == true' "$1" > /dev/null; }
untrusted() { jq -e --arg p "$2" '.projects[$p] == null' "$1" > /dev/null; }

@test "seed: the first-run markers and settings are carried over, nothing else of the account" {
    seed company
    [ "${status}" -eq 0 ]
    state="${H}/.claude@company/.claude.json"
    jq -e '.hasCompletedOnboarding == true and .lastOnboardingVersion == "2.1.0"' "${state}" > /dev/null
    # Counters, the signed-in account and a project's other answers stay the account's.
    jq -e 'has("numStartups") or has("oauthAccount") | not' "${state}" > /dev/null
    jq -e --arg p "${H}/org" '.projects[$p] | has("allowedTools") | not' "${state}" > /dev/null
    [ "$(jq -r .theme "${H}/.claude@company/settings.json")" = "dark" ]
}

@test "seed: a folder's trust is carried only where the cage can read it" {
    seed company
    state="${H}/.claude@company/.claude.json"
    trusted "${state}" "${H}/org"
    trusted "${state}" "${H}/repos/public-tool"
    # The client's folder is hidden from the company cage, and so is its name.
    untrusted "${state}" "${H}/org/clients/acme"
    run grep -c acme "${state}"
    [ "${output}" = "0" ]
    untrusted "${state}" "/elsewhere"
    seed client
    state="${H}/.claude@client/.claude.json"
    trusted "${state}" "${H}/org/clients/acme"
    trusted "${state}" "${H}/org"
}

@test "seed: what the cage has chosen since is kept, and a second run changes nothing" {
    mkdir -p "${H}/.claude@company"
    printf '{"theme": "light"}\n' > "${H}/.claude@company/settings.json"
    jq -n --arg org "${H}/org" '{lastOnboardingVersion: "2.2.0", projects: {($org): {allowedTools: ["Read"]}}}' \
        > "${H}/.claude@company/.claude.json"
    seed company
    state="${H}/.claude@company/.claude.json"
    [ "$(jq -r .theme "${H}/.claude@company/settings.json")" = "light" ]
    [ "$(jq -r .lastOnboardingVersion "${state}")" = "2.2.0" ]
    jq -e --arg p "${H}/org" '.projects[$p] == {allowedTools: ["Read"], hasTrustDialogAccepted: true}' "${state}" > /dev/null
    # A rewrite replaces the file (a new inode); an unchanged state is not rewritten.
    first="$(ls -i "${state}")"
    seed company
    [ "$(ls -i "${state}")" = "${first}" ]
}

@test "seed: another account seeds its own cage from its own state file" {
    mkdir -p "${H}/.claude-work"
    account_state "${H}/.claude-work/.claude.json"
    jq '.lastOnboardingVersion = "9.9.9"' "${H}/.claude-work/.claude.json" > "${BATS_TEST_TMPDIR}/w" \
        && mv "${BATS_TEST_TMPDIR}/w" "${H}/.claude-work/.claude.json"
    seed company --account-dir "${H}/.claude-work"
    [ "${status}" -eq 0 ]
    [ "$(jq -r .lastOnboardingVersion "${H}/.claude-work@company/.claude.json")" = "9.9.9" ]
    [ ! -e "${H}/.claude-work@company/settings.json" ]
}

@test "seed: the personal cage keeps the account's directory, and nothing is written" {
    before="$(cat "${H}/.claude.json")"
    seed personal
    [ "${status}" -eq 0 ]
    [ "$(cat "${H}/.claude.json")" = "${before}" ]
    [ -z "$(compgen -G "${H}/.claude*@*")" ]
    mkdir -p "${H}/.claude-work"
    seed personal --account-dir "${H}/.claude-work"
    [ "${status}" -eq 0 ]
    [ ! -e "${H}/.claude-work/.claude.json" ]
}

@test "seed: an account that has never run gives an empty start, not an error" {
    rm "${H}/.claude.json" "${H}/.claude/settings.json"
    seed company
    [ "${status}" -eq 0 ]
    [ ! -e "${H}/.claude@company/.claude.json" ]
    [ -d "${H}/.claude@company" ]
}

@test "seed: a file that is not a cage, or the wrong number of arguments, is a refusal" {
    printf 'not json\n' > "${BATS_TEST_TMPDIR}/cage.json"
    run python3 "${SEED}" "${H}/.claude" "${BATS_TEST_TMPDIR}/cage.json"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"not a cage"* ]]
    run python3 "${SEED}" "${H}/.claude"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Usage"* ]]
}
