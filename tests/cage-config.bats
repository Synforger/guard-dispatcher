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
    unset GUARD_HOME GUARD_TMP_ROOT ANON_TRUTH_PATH
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
    # The login keychain's folder: a token refresh rewrites the keychain file (401 without it).
    lists allowWrite "${H}/Library/Keychains"
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

@test "no cage writes the guards: their install, the hooks directory, the global git config, the areas, the word list, Claude Code's settings" {
    for cage in personal company client; do
        build "${cage}"
        lists denyWrite "${H}/.local/share/guard-dispatcher"
        lists denyWrite "$(cd -P "${GUARD_ROOT}" && pwd)"
        lists denyWrite "${H}/.config/git"
        lists denyWrite "${H}/.git-hooks"
        lists denyWrite "${GUARD_CONFIG_DIR}"
        lists denyWrite "${H}/.config/anon-words"
        lists denyWrite "${H}/**/.claude*/settings*.json"
        # What a program loads from the folder it starts in, in every repository, not only the cage's own
        for g in .mcp.json .claude/commands .claude/agents .idea .ripgreprc; do
            lists denyWrite "${H}/**/${g}"
        done
        # The global git config (core.hooksPath) and the shells' startup files (the launchers)
        for f in .gitconfig .zshrc .zshenv .zprofile .zlogin .bashrc .bash_profile .profile; do
            lists denyWrite "${H}/${f}"
        done
    done
}

@test "no cage writes what runs outside it: login items, PATH folders under HOME and the installs their links lead into" {
    mkdir -p "${H}/.local/bin" "${H}/.local/pipx/venvs/tool/bin" "${H}/.local/share/claude/versions" \
        "${H}/forge/condabin" "${H}/forge/bin" "${H}/forge/lib" "${H}/forge/conda-meta" "${H}/forge/envs" \
        "${H}/relay/src" "${H}/Library/LaunchAgents"
    touch "${H}/.local/pipx/venvs/tool/bin/tool" "${H}/.local/share/claude/versions/9.9.9" "${H}/forge/condabin/conda"
    ln -s "${H}/.local/pipx/venvs/tool/bin/tool" "${H}/.local/bin/tool"
    ln -s "${H}/.local/share/claude/versions/9.9.9" "${H}/.local/bin/claude"
    ln -s /usr/bin/true "${H}/.local/bin/outside-home"
    touch "${H}/forge/bin/mamba"
    ln -s "${H}/forge/bin/mamba" "${H}/.local/bin/mamba"          # a link into the conda base, not its envs
    printf '~/relay   # a server a relay starts outside the cage\n\n' > "${GUARD_CONFIG_DIR}/outside-run.txt"
    export PATH="${H}/.local/bin:${H}/forge/condabin:${PATH}"
    for cage in personal company client; do
        build "${cage}"
        lists denyWrite "${H}/Library/LaunchAgents"
        lists denyWrite "${H}/.local/bin"
        lists denyWrite "${H}/.local/pipx/venvs/tool"              # the venv the link's bin/ sits in
        lists denyWrite "${H}/.local/share/claude/versions"        # the folder of versions: no planted next one
        [ "$(env_of DISABLE_AUTOUPDATER)" = "1" ]                   # updates happen outside, where the link is written
        lists denyWrite "${H}/forge/condabin"
        for base in bin lib conda-meta; do lists denyWrite "${H}/forge/${base}"; done
        lacks denyWrite "${H}/forge/envs"                          # environments are made from a session
        lacks denyWrite "${H}/forge"
        lists denyWrite "${H}/relay"
        lacks denyWrite /usr/bin/true
    done
}

@test "a cage carries the digest of the files it was built from, and it follows them" {
    build personal
    first="$(env_of GUARD_CAGE_BUILD)"
    [[ "${first}" =~ ^[0-9a-f]{16}$ ]]
    build company
    [ "$(env_of GUARD_CAGE_BUILD)" = "${first}" ]          # the same install, whatever the cage
    copy="${BATS_TEST_TMPDIR}/guard"
    mkdir -p "${copy}/sandbox" "${copy}/scanners"
    cp "${GUARD_ROOT}"/sandbox/*.py "${GUARD_ROOT}"/sandbox/*.mjs "${GUARD_ROOT}"/sandbox/*.sh "${GUARD_ROOT}"/sandbox/*.json "${copy}/sandbox/"
    cp "${GUARD_ROOT}"/scanners/corpus-scan.py "${copy}/scanners/"
    printf '\n' >> "${copy}/sandbox/run.mjs"
    run python3 "${copy}/sandbox/cage-config.py" personal
    [ "$(env_of GUARD_CAGE_BUILD)" != "${first}" ]
}

@test "no cage writes the scanners' master word list directory, wherever ANON_TRUTH_PATH points" {
    for cage in personal company client; do
        build "${cage}"
        lists denyWrite "${H}/.config/anon-words"
    done
    export ANON_TRUTH_PATH="${H}/elsewhere/company.txt"
    build personal
    lists denyWrite "${H}/elsewhere"
    lacks denyWrite "${H}/.config/anon-words"
}

@test "GUARD_TMP_ROOT moves every cage's temp directory together, and nothing else" {
    export GUARD_TMP_ROOT="${H}/cage-tmp"
    build company
    [ "$(env_of TMPDIR)" = "${H}/cage-tmp/company" ]
    lists allowWrite "${H}/cage-tmp/company"
    lists denyRead "${H}/cage-tmp/personal"
    lists denyRead "${H}/cage-tmp/client"
    lacks denyRead "${T}/claude-cage/personal"
    # The temp folders every session would share stay hidden wherever the root is.
    lists denyRead "${T}/claude-$(id -u)"
    lists denyRead "${T}/claude"
}

@test "the session starts with its cage's temp directory; an area with its own config directory and the account's login" {
    build personal
    [ "$(env_of CLAUDE_CODE_TMPDIR)" = "${T}/claude-cage/personal" ]
    [ "$(env_of TMPDIR)" = "${T}/claude-cage/personal" ]
    # zsh's here-documents too (they go under TMPPREFIX, not TMPDIR).
    [ "$(env_of TMPPREFIX)" = "${T}/claude-cage/personal/zsh" ]
    # When the cage was entered, in the form of a record's row times (UTC, milliseconds, Z).
    [[ "$(env_of GUARD_CAGED_SINCE)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
    [ -z "$(env_of CLAUDE_CONFIG_DIR)" ]
    jq -e '.env | has("CLAUDE_SECURESTORAGE_CONFIG_DIR") | not' <<< "${output}" > /dev/null
    build company
    [ "$(env_of CLAUDE_CONFIG_DIR)" = "${H}/.claude@company" ]
    jq -e '.env.CLAUDE_SECURESTORAGE_CONFIG_DIR == ""' <<< "${output}" > /dev/null
    mkdir -p "${H}/.claude-work"
    build company --account-dir "${H}/.claude-work"
    [ "$(env_of CLAUDE_CONFIG_DIR)" = "${H}/.claude-work@company" ]
    [ "$(env_of CLAUDE_SECURESTORAGE_CONFIG_DIR)" = "${H}/.claude-work" ]
    build personal --account-dir "${H}/.claude-work"
    [ "$(env_of CLAUDE_CONFIG_DIR)" = "${H}/.claude-work" ]
    jq -e '.env | has("CLAUDE_SECURESTORAGE_CONFIG_DIR") | not' <<< "${output}" > /dev/null
}

@test "every cage lets Security.framework learn it is sandboxed, so keychain writes (the login) work" {
    for cage in personal company; do
        build "${cage}"
        jq -e '.seatbelt | index("(allow sysctl-read (sysctl-name \"security.mac.sandbox.sentinel\"))") != null' <<< "${output}" > /dev/null
    done
}

@test "the network is left open (no allowlist), the session keeps a terminal, and file-watch and audio-device lookups pass" {
    build company
    jq -e '.sandbox.network | has("allowedDomains") | not' <<< "${output}" > /dev/null
    jq -e '.sandbox.network.allowMachLookup == ["com.apple.trustd.agent", "com.apple.FSEvents", "com.apple.audio.audiohald", "com.apple.audio.coreaudiod"]' <<< "${output}" > /dev/null
    jq -e '.sandbox.allowPty == true' <<< "${output}" > /dev/null
}

@test "only the personal cage reaches the clipboard (an area cage could carry its content out through it)" {
    build personal
    jq -e '.sandbox.network.allowMachLookup | index("com.apple.pasteboard.1") != null' <<< "${output}" > /dev/null
    for cage in company client; do
        build "${cage}"
        jq -e '.sandbox.network.allowMachLookup | index("com.apple.pasteboard.1") == null' <<< "${output}" > /dev/null
    done
}

@test "every cage lets a language runtime read the CPU feature it checks before starting" {
    build company
    jq -e '.seatbelt | index("(allow sysctl-read (sysctl-name \"hw.optional.neon\"))") != null' <<< "${output}" > /dev/null
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

@test "--of: a path belongs to the innermost area holding it, else to personal" {
    of() { run python3 "${CAGE}" --of "$1"; [ "${status}" -eq 0 ]; echo "${output}"; }
    [ "$(of "${H}/org")" = "company" ]
    [ "$(of "${H}/org/clients/globex")" = "company" ]
    [ "$(of "${H}/org/clients/acme")" = "client" ]
    [ "$(of "${H}/notes/projects/org/clients/acme/plan.md")" = "client" ]
    [ "$(of "${H}/notes/projects/org")" = "company" ]
    # _exempt is not a cage: the notes outside every area are personal.
    [ "$(of "${H}/notes/journal")" = "personal" ]
    [ "$(of "${H}/repos/public-tool")" = "personal" ]
    # A path that does not exist yet, a ~ path and a path through a link are placed the same.
    [ "$(of "${H}/org/clients/acme/new/deeper")" = "client" ]
    [ "$(of "~/org/clients/acme")" = "client" ]
    ln -s "${H}/org/clients/acme" "${H}/repos/acme-link"
    [ "$(of "${H}/repos/acme-link")" = "client" ]
    # A sibling whose name starts with an area's name is not inside it.
    mkdir -p "${H}/org-archive"
    [ "$(of "${H}/org-archive")" = "personal" ]
}

@test "--of: a folder-per-client area names the client; no areas or a broken file" {
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
company   ~/org
client-*  ~/org/clients/*
AREAS
    run python3 "${CAGE}" --of "${H}/org/clients/globex/deck"
    [ "${output}" = "client-globex" ]
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    run python3 "${CAGE}" --of "${H}/org/clients/globex"
    [ "${status}" -eq 0 ]
    [ "${output}" = "personal" ]
    printf 'company org\n' > "${GUARD_CONFIG_DIR}/areas.txt"
    run python3 "${CAGE}" --of "${H}/org"
    [ "${status}" -ne 0 ]
}

@test "--record: a past conversation's cage and account come from where its record lives" {
    mkdir -p "${H}/.claude/projects/-w" "${H}/.claude-work@client/projects/-w" "${H}/.claude@company/projects/-w"
    touch "${H}/.claude/projects/-w/plain.jsonl" "${H}/.claude-work@client/projects/-w/caged.jsonl"
    run python3 "${CAGE}" --record caged
    [ "${status}" -eq 0 ]
    [ "$(jq -r .cage <<< "${output}")" = "client" ]
    [ "$(jq -r .account_dir <<< "${output}")" = "${H}/.claude-work" ]
    [ "$(jq -r .config_dir <<< "${output}")" = "${H}/.claude-work@client" ]
    run python3 "${CAGE}" --record plain
    [ "$(jq -r .cage <<< "${output}")" = "personal" ]
    [ "$(jq -r .account_dir <<< "${output}")" = "${H}/.claude" ]
    run python3 "${CAGE}" --record nowhere
    [ "${status}" -eq 1 ]
}

@test "--config-dirs: every account's cage directories that exist, and only those" {
    mkdir -p "${H}/.claude@company" "${H}/.claude-work@client" "${H}/.claude-work"
    touch "${H}/.claude@stray-file"
    run python3 "${CAGE}" --config-dirs
    [ "${output}" = "$(printf '%s\n%s' "${H}/.claude-work@client" "${H}/.claude@company")" ]
}
