#!/usr/bin/env bats
# sandbox/cage-config.py — the cage a Claude Code session runs in.
#
# A throwaway HOME holds a company folder with a client inside it, the
# operator's own notes (_exempt) and a personal repository. The notes hold the
# company's and the client's notes too, nested the same way. Each test builds
# one cage and reads the sandbox-runtime config it prints.

load helpers

CAGE="${GUARD_ROOT}/sandbox/cage-config.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    T="$(cd -P /tmp && pwd)"
    mkdir -p "${H}/org/clients/acme" "${H}/org/clients/globex" "${H}/repos/public-tool" \
        "${H}/notes/journal" "${H}/notes/projects/org/clients/acme" "${H}/notes/projects/hobby"
    touch "${H}/notes/README.md" "${H}/notes/projects/org/plan.md"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    mkdir -p "${GUARD_CONFIG_DIR}"
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company ~/org ~/notes/projects/org
client  ~/org/clients/acme ~/notes/projects/org/clients/acme
_exempt ~/notes
AREAS
}

build() { run python3 "${CAGE}" "$@"; }

# lists <field> <path> — the path is one of the field's entries.
lists() { jq -e --arg p "$2" ".sandbox.filesystem.$1 | index(\$p) != null" <<< "${output}" > /dev/null; }
# lacks <field> <path> — the path is not among the field's entries. (A bare `! lists`
# never fails a bats test: `set -e` ignores a negated command.)
lacks() { if lists "$@"; then return 1; fi; }
env_of() { jq -r ".env.$1 // empty" <<< "${output}"; }

@test "personal: the areas are neither read nor written; the rest of HOME is writable" {
    build personal
    [ "${status}" -eq 0 ]
    lists denyRead "${H}/org"
    lists denyRead "${H}/org/clients/acme"
    lists denyWrite "${H}/org"
    lists denyWrite "${H}/org/clients/acme"
    lists allowWrite "${H}"
    lacks denyRead "${H}/notes"
    lacks denyRead "${H}/repos/public-tool"
}

@test "an area: the areas inside it are hidden; it writes only itself, _exempt and its own directories" {
    build company
    [ "${status}" -eq 0 ]
    lists denyRead "${H}/org/clients/acme"
    lacks denyRead "${H}/org"
    lists allowWrite "${H}/org"
    lists allowWrite "${H}/notes"
    lists denyWrite "${H}/notes/projects/org/clients/acme"
    lists allowWrite "${H}/.claude@company"
    lists allowWrite "${T}/claude-cage/company"
    lacks allowWrite "${H}"
    lists denyWrite "${H}/org/clients/acme"
}

@test "a client: the company around it stays readable but is not written" {
    build client
    [ "${status}" -eq 0 ]
    lacks denyRead "${H}/org"
    lacks denyRead "${H}/org/clients/acme"
    lists allowWrite "${H}/org/clients/acme"
    lacks allowWrite "${H}/org"
    # A write-deny would win over the client inside it: the company is left out instead.
    lacks denyWrite "${H}/org"
    lacks denyWrite "${H}/notes/projects/org"
}

@test "a client: the notes are opened around the company's notes, down to the client's own" {
    build client
    lists allowWrite "${H}/notes/projects/org/clients/acme"
    lists allowWrite "${H}/notes/journal"
    lists allowWrite "${H}/notes/README.md"
    lists allowWrite "${H}/notes/projects/hobby"
    lacks allowWrite "${H}/notes"
    lacks allowWrite "${H}/notes/projects"
    lacks allowWrite "${H}/notes/projects/org"
    lacks allowWrite "${H}/notes/projects/org/plan.md"
    lacks allowWrite "${H}/notes/projects/org/clients"
    # A link is not opened: it may lead anywhere.
    ln -s "${H}/org" "${H}/notes/projects/org-link"
    build client
    lacks allowWrite "${H}/notes/projects/org-link"
}

@test "every cage hides the other cages' config and temp directories and the uncaged temp directory" {
    for cage in personal company client; do
        build "${cage}"
        [ "${status}" -eq 0 ]
        lists denyRead "${H}/.claude*@*"
        lists denyRead "${T}/claude-$(id -u)"
        lists denyRead "${T}/claude"
        lists denyWrite "${T}/claude"
        for other in personal company client; do
            [ "${other}" = "${cage}" ] || lists denyRead "${T}/claude-cage/${other}"
        done
        lacks denyRead "${T}/claude-cage/${cage}"
    done
    # An area re-opens its own config directory inside the hidden glob.
    build company
    lists allowRead "${H}/.claude@company"
    # personal keeps the account directory, which no glob hides.
    build personal
    lists allowWrite "${H}/.claude.json"
    lists denyWrite "${H}/.claude*@*"
    lacks denyWrite "${H}/.claude/debug"
    # sandbox-runtime keeps the personal account's debug folder writable everywhere.
    build company
    lists denyWrite "${H}/.claude/debug"
}

@test "no cage writes the global git config, the hooks directory or the areas" {
    for cage in personal company client; do
        build "${cage}"
        lists denyWrite "${H}/.config/git"
        lists denyWrite "${H}/.git-hooks"
        lists denyWrite "${GUARD_CONFIG_DIR}"
    done
}

@test "the session starts with its cage's temp directory, and an area with its own config directory" {
    build personal
    [ "$(env_of CLAUDE_CODE_TMPDIR)" = "${T}/claude-cage/personal" ]
    [ "$(env_of TMPDIR)" = "${T}/claude-cage/personal" ]
    [ -z "$(env_of CLAUDE_CONFIG_DIR)" ]
    build company
    [ "$(env_of CLAUDE_CONFIG_DIR)" = "${H}/.claude@company" ]
    mkdir -p "${H}/.claude-work"
    build company --account-dir "${H}/.claude-work"
    [ "$(env_of CLAUDE_CONFIG_DIR)" = "${H}/.claude-work@company" ]
    build personal --account-dir "${H}/.claude-work"
    [ "$(env_of CLAUDE_CONFIG_DIR)" = "${H}/.claude-work" ]
}

@test "the network is left open (no allowlist) and the session keeps a terminal" {
    build company
    jq -e '.sandbox.network | has("allowedDomains") | not' <<< "${output}" > /dev/null
    jq -e '.sandbox.allowPty == true' <<< "${output}" > /dev/null
}

@test "a folder-per-client area: every client is its own cage and cannot see its siblings" {
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company   ~/org
client-*  ~/org/clients/*
AREAS
    build --list
    [ "${output}" = "$(printf 'personal\nclient-acme\nclient-globex\ncompany')" ]
    build client-acme
    [ "${status}" -eq 0 ]
    lists denyRead "${H}/org/clients/globex"
    lists denyWrite "${H}/org/clients/globex"
    lists allowWrite "${H}/org/clients/acme"
}

@test "an unknown cage, a broken areas file or an area named personal is a refusal" {
    build nope
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no area named 'nope'"* ]]
    printf 'company org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    build personal
    [ "${status}" -ne 0 ]
    printf 'personal ~/org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    build personal
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"rename that area"* ]]
}

@test "a machine without areas has the personal cage only, and it hides nothing of HOME" {
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    build --list
    [ "${output}" = "personal" ]
    build personal
    [ "${status}" -eq 0 ]
    lists allowWrite "${H}"
    build company
    [ "${status}" -ne 0 ]
}
