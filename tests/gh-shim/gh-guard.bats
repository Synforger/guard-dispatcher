#!/usr/bin/env bats
# Behavioural tests for the gh command guard.
#
# The shim shadows the real CLI on PATH, so these tests stand up two
# directories — one holding the shim, one holding a stand-in for the real
# binary that records whether it was reached. "Refused" therefore means the
# real CLI never ran, not merely that the exit code was non-zero.

load ../_internal/helpers

setup() {
    setup_words
    SHIM_DIR="${BATS_TEST_TMPDIR}/shim"
    REAL_DIR="${BATS_TEST_TMPDIR}/real"
    RAN_MARKER="${BATS_TEST_TMPDIR}/real-gh-ran"
    mkdir -p "${SHIM_DIR}" "${REAL_DIR}"
    ln -sf "${GUARD_ROOT}/gh-shim/gh-guard.sh" "${SHIM_DIR}/gh"
    cat > "${REAL_DIR}/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${RAN_MARKER}"
exit 0
STUB
    chmod +x "${REAL_DIR}/gh"
    export PATH="${SHIM_DIR}:${REAL_DIR}:${PATH}"
}

# Did the call reach the real CLI?
ran() { [ -f "${RAN_MARKER}" ]; }

# --- refusals -----------------------------------------------------------------

@test "gh-guard: a flagged identifier in the arguments is refused and never sent" {
    run gh pr comment 1 --body "deferred to ${SENTINEL}"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a flagged identifier in a body file is refused" {
    printf 'looks fine\nbut mentions %s\n' "${SENTINEL}" > "${BATS_TEST_TMPDIR}/body.md"
    run gh pr create --title "ok" --body-file "${BATS_TEST_TMPDIR}/body.md"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a payload read from stdin is scanned" {
    run bash -c "printf '%s\n' '${SENTINEL}' | gh pr create --title t --body-file -"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: an api call carrying a payload is scanned" {
    run gh api repos/owner/name/issues -f body="${SENTINEL}"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a gist file carrying a flagged identifier is refused" {
    printf 'notes\n%s\n' "${SENTINEL}" > "${BATS_TEST_TMPDIR}/notes.txt"
    run gh gist create "${BATS_TEST_TMPDIR}/notes.txt"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a gist read from stdin is scanned" {
    run bash -c "printf '%s\n' '${SENTINEL}' | gh gist create -"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: gh search only reads and is passed through" {
    run gh search commits --author "${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}

# An unrecognised subcommand must fail closed: the CLI gains commands faster
# than any allow-list of "sending" verbs can be maintained.
@test "gh-guard: an unknown subcommand is scanned, not waved through" {
    run gh frobnicate wibble --body "${SENTINEL}"
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: an unresolvable scanner refuses the command (fail-closed)" {
    GUARD_SCANNER_OVERRIDE="${BATS_TEST_TMPDIR}/no-such-scanner.sh" run gh pr comment 1 --body "harmless"
    [ "$status" -ne 0 ]
    ! ran
}

# --- pass-through -------------------------------------------------------------

@test "gh-guard: a clean send reaches the real CLI" {
    run gh pr comment 1 --body "nothing to see here"
    [ "$status" -eq 0 ]
    ran
}

# A caller reads the real CLI's stdout (`$(gh api ... )` into jq). The guard's
# own report of a clean scan went there too and broke a script that parsed the
# JSON a write returned, so the guard keeps stdout for the real CLI alone.
@test "gh-guard: a clean send leaves the real CLI's stdout untouched" {
    cat > "${REAL_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '{"id":1}\n'
STUB
    chmod +x "${REAL_DIR}/gh"
    out=$(gh api repos/owner/name/rulesets --method POST -f name=ordinary 2>/dev/null)
    [ "${out}" = '{"id":1}' ]
}

# Read-only calls legitimately name accounts and repositories. Blocking them
# would turn the guard into something to switch off.
@test "gh-guard: read-only subcommands are passed through unscanned" {
    run gh repo view "owner/${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}

# The path of a body file stays on this machine — only its contents are sent.
# Scanning the path refuses legitimate sends whenever the temp directory sits
# under a flagged word, which is exactly how this was found.
@test "gh-guard: the path of a body file is not itself scanned, only its contents" {
    mkdir -p "${BATS_TEST_TMPDIR}/${SENTINEL}-dir"
    printf 'perfectly ordinary text\n' > "${BATS_TEST_TMPDIR}/${SENTINEL}-dir/body.md"
    run gh pr create --title "ok" --body-file "${BATS_TEST_TMPDIR}/${SENTINEL}-dir/body.md"
    [ "$status" -eq 0 ]
    ran
}

@test "gh-guard: a plain GET api call is passed through unscanned" {
    run gh api "repos/owner/${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}

@test "gh-guard: GH_GUARD_SKIP=1 is a deliberate one-off bypass" {
    GH_GUARD_SKIP=1 run gh pr comment 1 --body "${SENTINEL}"
    [ "$status" -eq 0 ]
    ran
}

# --- the word list follows the repository the call sends to ---------------------------------------

# A company folder holding a clone of a company repository whose git settings name the company's word
# list (where the company's own name is a right word), a personal clone outside every area, and the
# operator's whole list (the company's name is flagged there).
words_by_destination() {
    unset ANON_WORDS_FILE
    export GUARD_CORPUS_MAX_AGE=0
    WORK="${BATS_TEST_TMPDIR}/work"
    COMPANY_CLONE="${WORK}/repos/tool"
    PERSONAL="${BATS_TEST_TMPDIR}/personal"
    mkdir -p "${WORK}" "${PERSONAL}" "${GUARD_CONFIG_DIR}"
    printf 'company %s\n' "${WORK}" > "${GUARD_CONFIG_DIR}/areas.txt"
    export ANON_TRUTH_PATH="${BATS_TEST_TMPDIR}/master.txt"
    printf '%s\nAcmeCorpX\n' "${SENTINEL}" > "${ANON_TRUTH_PATH}"
    printf '%s\n' "${SENTINEL}" > "${BATS_TEST_TMPDIR}/company-words.txt"
    git init -q "${COMPANY_CLONE}"
    git -C "${COMPANY_CLONE}" remote add origin git@github.com:acmecorpx/tool.git
    git -C "${COMPANY_CLONE}" config guard.wordlist "${BATS_TEST_TMPDIR}/company-words.txt"
    git init -q "${PERSONAL}"
    git -C "${PERSONAL}" remote add origin git@github.com:me/notes.git
    seed_visibility acmecorpx/tool private
    seed_visibility me/notes private
    seed_visibility me/elsewhere private
}

@test "gh-guard: a call naming a company repository with -R is scanned with that repository's list, from any folder" {
    words_by_destination
    cd "${BATS_TEST_TMPDIR}"
    run gh pr comment 13 -R acmecorpx/tool --body "a correction of the count"
    [ "$status" -eq 0 ]
    ran
    rm -f "${RAN_MARKER}"
    cd "${PERSONAL}"
    run gh pr comment 13 --repo=acmecorpx/tool --body "AcmeCorpX tool, a correction"
    [ "$status" -eq 0 ]
    ran
    # its own list still flags what it flags
    run gh pr comment 13 -R acmecorpx/tool --body "deferred to ${SENTINEL}"
    [ "$status" -ne 0 ]
}

@test "gh-guard: a call typed in a company clone that names another repository is scanned with the whole list" {
    words_by_destination
    cd "${COMPANY_CLONE}"
    run gh pr comment 1 --body "AcmeCorpX tool, a correction"
    [ "$status" -eq 0 ]
    ran
    rm -f "${RAN_MARKER}"
    run gh pr comment 1 -R me/notes --body "AcmeCorpX tool, a correction"
    [ "$status" -ne 0 ]
    ! ran
    GH_REPO=me/elsewhere run gh issue create --title "AcmeCorpX" --body x
    [ "$status" -ne 0 ]
    ! ran
}

@test "gh-guard: a call naming a repository with no clone in an area is scanned with the whole list" {
    words_by_destination
    cd "${COMPANY_CLONE}"
    run gh api repos/me/elsewhere/issues -f body="AcmeCorpX"
    [ "$status" -ne 0 ]
    ! ran
    # a list the caller names is kept
    ANON_WORDS_FILE="${BATS_TEST_TMPDIR}/company-words.txt" run gh pr comment 1 -R me/notes --body "AcmeCorpX"
    [ "$status" -eq 0 ]
}
