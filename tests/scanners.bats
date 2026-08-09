#!/usr/bin/env bats
# Behavioural tests for the two scanners themselves (not the hook wiring):
#   - anon-scan.sh   NFKC width folding on the tracked-file / staged scan
#   - anon-audit-deep.sh   PR/Issue comment threads via a gh stub

load helpers

setup() {
    setup_words
}

# The full-width rendering of the ASCII sentinel XLEAKX7q3z. NFKC folds each
# full-width code point back to its half-width form, so a half-width word
# list must still catch it. Kept as a literal so the test breaks loudly if
# the folding regresses.
WIDE_SENTINEL='ＸＬＥＡＫＸ７ｑ３ｚ'

# --- anon-scan.sh: NFKC width folding -----------------------------------------

@test "anon-scan: full-width text is folded (NFKC) and caught by a half-width word list" {
    mk_repo other
    printf '%s\n' "${WIDE_SENTINEL}" > widefold.txt
    ANON_SCAN_PATHS="$(pwd)/widefold.txt" run bash "${GUARD_ROOT}/scanners/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: unrelated full-width text stays clean (folding does not over-match)" {
    mk_repo other
    printf 'ＨＥＬＬＯ　ｗｏｒｌｄ\n' > clean.txt
    ANON_SCAN_PATHS="$(pwd)/clean.txt" run bash "${GUARD_ROOT}/scanners/anon-scan.sh"
    [ "$status" -eq 0 ]
}

# --- text-bearing data formats stay in scope ----------------------------------
# .csv and .ipynb are text with real leak surface (free-text columns,
# notebook outputs with usernames / local paths) — they must be scanned,
# not skipped as binary.

@test "anon-scan: a leak inside a .csv is caught" {
    mk_repo other
    printf 'id,comment\n1,"mentions %s"\n' "${SENTINEL}" > data.csv
    ANON_SCAN_PATHS="$(pwd)/data.csv" run bash "${GUARD_ROOT}/scanners/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: a leak inside a .ipynb output cell is caught" {
    mk_repo other
    printf '{"cells":[{"outputs":[{"text":["path of %s"]}]}]}\n' "${SENTINEL}" > nb.ipynb
    ANON_SCAN_PATHS="$(pwd)/nb.ipynb" run bash "${GUARD_ROOT}/scanners/anon-scan.sh"
    [ "$status" -ne 0 ]
}

# --- fail-closed on a malformed word list -------------------------------------
# A fragment that does not compile as PCRE must be a loud configuration
# error (exit 2), never a silent pass: the deep audit's piped perl used to
# die inside a command substitution and report "0 hits = clean".

@test "anon-scan: malformed word-list pattern is a configuration error (exit 2)" {
    mk_repo synforger
    printf '%s\nbroken(\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    echo "leak ${SENTINEL}" > leak.txt
    ANON_SCAN_PATHS="$(pwd)/leak.txt" run bash "${GUARD_ROOT}/scanners/anon-scan.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not compile"* ]]
}

@test "deep audit: malformed word-list pattern fails closed (exit 2, range mode)" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "leak ${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: leaky"
    printf '%s\nbroken(\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    run bash "${GUARD_ROOT}/scanners/anon-audit-deep.sh" --range "${base}..HEAD"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not compile"* ]]
}

# --- anon-audit-deep.sh: comment threads --------------------------------------

# Install a fake `gh` on PATH. Every GitHub call is clean except the
# issue-comments endpoint, which echoes $STUB_SENTINEL — this proves the
# audit actually queries and scans repos/<r>/issues/comments.
setup_gh_stub() {
    local bindir="${BATS_TEST_TMPDIR}/stub-bin"
    mkdir -p "${bindir}"
    cat > "${bindir}/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo '{}'; exit 0; fi
if [ "$1" = "api" ]; then
    for arg in "$@"; do
        case "$arg" in
            */issues/comments*) printf '%s\n' "${STUB_SENTINEL}"; exit 0 ;;
            */pulls/comments*)  exit 0 ;;
            */issues*)          exit 0 ;;
            */releases*)        exit 0 ;;
            */actions/runs*)    exit 0 ;;
        esac
    done
    exit 0
fi
exit 0
STUB
    chmod +x "${bindir}/gh"
    export PATH="${bindir}:${PATH}"
}

@test "deep audit: a leaking PR/Issue comment is caught (issues/comments endpoint)" {
    mk_repo synforger
    export STUB_SENTINEL="${SENTINEL}"
    setup_gh_stub
    run bash "${GUARD_ROOT}/scanners/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GitHub PR/Issue text"* ]]
}

@test "deep audit: clean comment threads keep the GitHub source green" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    run bash "${GUARD_ROOT}/scanners/anon-audit-deep.sh"
    [ "$status" -eq 0 ]
}

# --- fail-closed on unfetchable GitHub sources --------------------------------
# An API call that errors used to collapse into empty output, and a scan of
# empty output reports "clean". A credential that cannot see an organisation
# therefore left every repo in it green forever, while the operator read the
# report as proof. Silence is not proof: an unfetchable source is a finding.

# Repository resolves, but every API call errors.
setup_gh_stub_api_error() {
    local bindir="${BATS_TEST_TMPDIR}/stub-bin"
    mkdir -p "${bindir}"
    cat > "${bindir}/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo '{}'; exit 0; fi
echo "HTTP 403: Resource not accessible by integration" >&2
exit 1
STUB
    chmod +x "${bindir}/gh"
    export PATH="${bindir}:${PATH}"
}

# No credential can resolve the repository at all.
setup_gh_stub_unresolvable() {
    local bindir="${BATS_TEST_TMPDIR}/stub-bin"
    mkdir -p "${bindir}"
    cat > "${bindir}/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
echo "GraphQL: Could not resolve to a Repository" >&2
exit 1
STUB
    chmod +x "${bindir}/gh"
    export PATH="${bindir}:${PATH}"
}

@test "deep audit: an erroring GitHub API call is a finding, not a clean source" {
    mk_repo synforger
    setup_gh_stub_api_error
    run bash "${GUARD_ROOT}/scanners/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNREACHABLE"* ]]
}

@test "deep audit: a repo no credential can resolve is a finding, not a clean source" {
    mk_repo synforger
    setup_gh_stub_unresolvable
    run bash "${GUARD_ROOT}/scanners/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNREACHABLE"* ]]
}
