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
