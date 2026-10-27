#!/usr/bin/env bats
# Behavioural tests for the two scanners themselves (not the hook wiring):
#   - anon-scan.sh   NFKC width folding on the tracked-file / staged scan
#   - anon-audit-deep.sh   PR/Issue comment threads via a gh stub

load ../../_internal/helpers

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
    ANON_SCAN_PATHS="$(pwd)/widefold.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: unrelated full-width text stays clean (folding does not over-match)" {
    mk_repo other
    printf 'ＨＥＬＬＯ　ｗｏｒｌｄ\n' > clean.txt
    ANON_SCAN_PATHS="$(pwd)/clean.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
}

# --- files that define the pattern --------------------------------------------
# A scanner cannot flag the file whose job is to name what must not appear: the
# word list does it, and so does the configuration of any other guard that bans
# paths or words. The exclusion is by basename, so the same content under any
# other name is still a leak.

DEFINITION_SENTINEL='XDefX7q3z'

@test "anon-scan: a guard's own configuration is not a leak" {
    mk_repo other
    printf '%s\n' "${DEFINITION_SENTINEL}" > "${ANON_WORDS_FILE}"
    printf 'banned = ["%s"]\n' "${DEFINITION_SENTINEL}" > guards.toml
    ANON_SCAN_PATHS="$(pwd)/guards.toml" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
}

@test "anon-scan: the same content under another name is still a leak" {
    mk_repo other
    printf '%s\n' "${DEFINITION_SENTINEL}" > "${ANON_WORDS_FILE}"
    printf 'banned = ["%s"]\n' "${DEFINITION_SENTINEL}" > settings.toml
    ANON_SCAN_PATHS="$(pwd)/settings.toml" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

# --- cs: prefix (case-sensitive fragments) ------------------------------------
# A pattern whose meaning lives in its capitalisation is prefixed `cs:` and
# must stop folding case. This is not hypothetical: the weekly audit reported
# the same finding four weeks running because a capitalised path prefix, once
# folded, matched the same word inside an ordinary URL in a PR body. The
# fixtures below use a sentinel rather than the real pattern, so the test does
# not depend on what any particular word list happens to contain.

CASE_SENTINEL='XCaseX7q3z'

@test "anon-scan: a cs: pattern does not fire on the opposite case" {
    mk_repo other
    printf 'cs:%s\n' "${CASE_SENTINEL}" > "${ANON_WORDS_FILE}"
    printf 'harmless text with %s in it\n' "$(printf '%s' "${CASE_SENTINEL}" | tr '[:upper:]' '[:lower:]')" > lower.txt
    ANON_SCAN_PATHS="$(pwd)/lower.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
}

@test "anon-scan: a cs: pattern still catches the exact case" {
    mk_repo other
    printf 'cs:%s\n' "${CASE_SENTINEL}" > "${ANON_WORDS_FILE}"
    printf 'a real leak: %s\n' "${CASE_SENTINEL}" > exact.txt
    ANON_SCAN_PATHS="$(pwd)/exact.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: a plain pattern keeps folding case (names are caught however written)" {
    mk_repo other
    printf '%s\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    printf '%s\n' "$(printf '%s' "${SENTINEL}" | tr '[:lower:]' '[:upper:]')" > upper.txt
    ANON_SCAN_PATHS="$(pwd)/upper.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

# --- a flag written in one line stays in that line ------------------------------
# The list is joined into one alternation. An inline flag written bare in a
# line — `(?-i)` in front of a token whose case is fixed — used to run on into
# every alternative after it: one such line, and every name listed below it was
# matched case-sensitively, so the name in capitals passed every scan. It was
# found on a real list, eleven lines into a section of key formats, with the
# names of whole sections below it going through unseen. Each line is now a
# group of its own.

@test "anon-scan: a flag opened in one line does not run on into the lines after it" {
    mk_repo other
    printf '(?-i)XTokX[0-9]{4}\n%s\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    printf '%s\n' "$(printf '%s' "${SENTINEL}" | tr '[:lower:]' '[:upper:]')" > upper.txt
    ANON_SCAN_PATHS="$(pwd)/upper.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: the flag still holds inside the line that wrote it" {
    mk_repo other
    printf '(?-i)XTokX[0-9]{4}\n%s\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    printf 'xtokx1234\n' > lower.txt
    ANON_SCAN_PATHS="$(pwd)/lower.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
    printf 'XTokX1234\n' > exact.txt
    ANON_SCAN_PATHS="$(pwd)/exact.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: a line that lists alternatives of its own keeps every one of them" {
    mk_repo other
    printf 'XAltOneX|XAltTwoX\n' > "${ANON_WORDS_FILE}"
    printf 'the second: xalttwox\n' > second.txt
    ANON_SCAN_PATHS="$(pwd)/second.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

# --- text-bearing data formats stay in scope ----------------------------------
# .csv and .ipynb are text with real leak surface (free-text columns,
# notebook outputs with usernames / local paths) — they must be scanned,
# not skipped as binary.

@test "anon-scan: a leak inside a .csv is caught" {
    mk_repo other
    printf 'id,comment\n1,"mentions %s"\n' "${SENTINEL}" > data.csv
    ANON_SCAN_PATHS="$(pwd)/data.csv" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: a leak inside a .ipynb output cell is caught" {
    mk_repo other
    printf '{"cells":[{"outputs":[{"text":["path of %s"]}]}]}\n' "${SENTINEL}" > nb.ipynb
    ANON_SCAN_PATHS="$(pwd)/nb.ipynb" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
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
    ANON_SCAN_PATHS="$(pwd)/leak.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not compile"* ]]
}

@test "deep audit: malformed word-list pattern fails closed (exit 2, range mode)" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "leak ${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: leaky"
    printf '%s\nbroken(\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh" --range "${base}..HEAD"
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
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GitHub PR/Issue text"* ]]
}

@test "deep audit: clean comment threads keep the GitHub source green" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
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
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNREACHABLE"* ]]
}

@test "deep audit: a repo no credential can resolve is a finding, not a clean source" {
    mk_repo synforger
    setup_gh_stub_unresolvable
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNREACHABLE"* ]]
}

# --- what a credential helper says is not what GitHub holds -------------------
# A successful call can still write to stderr: direnv announces the .envrc it
# loads (a path under the operator's home), gh announces a new release. Mixing
# that into the scanned text turned every repository reached through direnv
# into a leak of the operator's own path.

# Every call succeeds with clean output and prints $STUB_SENTINEL on stderr.
setup_gh_stub_noisy_stderr() {
    local bindir="${BATS_TEST_TMPDIR}/stub-bin"
    mkdir -p "${bindir}"
    cat > "${bindir}/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
printf 'loading %s\n' "${STUB_SENTINEL}" >&2
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo '{}'; fi
exit 0
STUB
    chmod +x "${bindir}/gh"
    export PATH="${bindir}:${PATH}"
}

@test "deep audit: stderr of a successful GitHub call is not scanned as content" {
    mk_repo synforger
    export STUB_SENTINEL="${SENTINEL}"
    setup_gh_stub_noisy_stderr
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -eq 0 ]
}

@test "deep audit: a failing GitHub call still shows why it failed" {
    mk_repo synforger
    setup_gh_stub_api_error
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 403"* ]]
}

# --- Office documents ---------------------------------------------------------
# A .pptx is a zip. Scanning its bytes reads compressed data, so the words
# inside were never looked at while the file still reported clean.

@test "anon-scan: a word inside an Office document is found" {
    mk_repo other
    mk_office "$(pwd)/deck.pptx" "${SENTINEL}"
    ANON_SCAN_PATHS="$(pwd)/deck.pptx" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
}

@test "anon-scan: an Office document is named by its own path, not a scratch file" {
    mk_repo other
    mk_office "$(pwd)/deck.pptx" "${SENTINEL}"
    ANON_SCAN_PATHS="$(pwd)/deck.pptx" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [[ "$output" == *"deck.pptx"* ]]
    [[ "$output" != *"anon-office"* ]]
}

@test "anon-scan: an Office document with nothing to hide stays clean" {
    mk_repo other
    mk_office "$(pwd)/clean.pptx" "an ordinary heading"
    ANON_SCAN_PATHS="$(pwd)/clean.pptx" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
}

# --- binary files and archives ------------------------------------------------------

@test "anon-scan: a binary file is read by its runs of text, not by letters that fall together by chance" {
    mk_repo other
    printf 'qzx\n' > "${BATS_TEST_TMPDIR}/short.txt"
    printf '\0\001\002qzx\003\0\377\376' > chance.dat
    ANON_WORDS_FILE="${BATS_TEST_TMPDIR}/short.txt" ANON_SCAN_PATHS="$(pwd)/chance.dat" \
        run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
    printf '\0\001/home/build/qzx/out.o\0\377' > built.dat
    ANON_WORDS_FILE="${BATS_TEST_TMPDIR}/short.txt" ANON_SCAN_PATHS="$(pwd)/built.dat" \
        run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"built.dat:text 1:"*"/home/build/qzx/out.o"* ]]
    printf 'ズクヌ\n' > "${BATS_TEST_TMPDIR}/wide.txt"
    printf '\0\001ズクヌの設定\0\377' > wide.dat
    ANON_WORDS_FILE="${BATS_TEST_TMPDIR}/wide.txt" ANON_SCAN_PATHS="$(pwd)/wide.dat" \
        run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]                                   # Japanese text inside a binary is read too
}

@test "anon-scan: a zip archive is read member by member, inside a nested archive too" {
    mk_repo other
    python3 - "$(pwd)" "${SENTINEL}" <<'PY'
import io, sys, zipfile
folder, word = sys.argv[1], sys.argv[2]
inner = io.BytesIO()
with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as jar:
    jar.writestr("a/Config.class", b"\xca\xfe\xba\xbe\0\0\x10/home/" + word.encode() + b"/src\0")
with zipfile.ZipFile(f"{folder}/lib.aar", "w", zipfile.ZIP_DEFLATED) as aar:
    aar.writestr("AndroidManifest.xml", "<manifest/>\n" * 50)
    aar.writestr("classes.jar", inner.getvalue())
with zipfile.ZipFile(f"{folder}/clean.aar", "w", zipfile.ZIP_DEFLATED) as aar:
    aar.writestr("AndroidManifest.xml", "<manifest/>\n" * 50)
PY
    ANON_SCAN_PATHS="$(pwd)/lib.aar" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lib.aar!classes.jar!a/Config.class:text 1:"* ]]
    ANON_SCAN_PATHS="$(pwd)/clean.aar" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -eq 0 ]
    printf 'PK\003\004 cut short' > broken.aar
    ANON_SCAN_PATHS="$(pwd)/broken.aar" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"broken.aar"*"NOT scanned"* ]]
}

@test "anon-scan: every file of one run is read on its own, line by line" {
    mk_repo other
    printf 'one\ntwo\n' > a.txt
    printf '\0\001 no word in here at all \0' > b.dat
    printf 'first\nthe owner is %s\n' "${SENTINEL}" > c.txt
    ANON_SCAN_PATHS="$(printf '%s\n' "$(pwd)/a.txt" "$(pwd)/b.dat" "$(pwd)/c.txt")" \
        run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/c.txt:2:the owner is ${SENTINEL}"* ]]
    [[ "$output" != *"/a.txt:"* ]]
    [[ "$output" != *"/b.dat:"* ]]
}

@test "anon-scan: a text file with bytes that are not UTF-8 is scanned without a warning" {
    mk_repo other
    printf 'caf\351 au lait\n%s\n' "${SENTINEL}" > latin.txt
    ANON_SCAN_PATHS="$(pwd)/latin.txt" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"latin.txt:2:${SENTINEL}"* ]]
    [[ "$output" != *"Malformed"* ]]
}

@test "anon-scan: a file that cannot be opened as an Office document is not called clean" {
    mk_repo other
    printf 'not a zip at all\n' > broken.pptx
    ANON_SCAN_PATHS="$(pwd)/broken.pptx" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT scanned"* ]]
}

@test "anon-scan: a zip with no XML part is not called clean either" {
    mk_repo other
    work="$(mktemp -d "${BATS_TEST_TMPDIR}/office.XXXXXX")"
    printf 'just a picture\n' > "${work}/image.bin"
    ( cd "${work}" && zip -q -r "$(pwd)/../empty.pptx" . ) 2>/dev/null || true
    zip -q -j "$(pwd)/empty.pptx" "${work}/image.bin"
    rm -rf "${work}"
    ANON_SCAN_PATHS="$(pwd)/empty.pptx" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no XML part"* ]]
}

@test "anon-scan: a hit inside an Office document points at one element, not the whole part" {
    mk_repo other
    mk_office "$(pwd)/deck.pptx" "${SENTINEL}"
    ANON_SCAN_PATHS="$(pwd)/deck.pptx" run bash "${GUARD_ROOT}/scanners/words/anon-scan.sh"
    [ "$status" -ne 0 ]
    longest=$(printf '%s\n' "$output" | awk '{ if (length($0) > m) m = length($0) } END { print m }')
    [ "$longest" -lt 500 ]
}

# --- findings accepted as known ------------------------------------------------
# Old findings that will not be rewritten (history, PR text) are recorded once as known; the
# audit then reports only what appears later. New history carrying a known word is still red.

known_file() { echo "${BATS_TEST_TMPDIR}/known/repo.known"; }
audit() { run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh" "$@"; }
# leak_in_history <name> — a commit that adds the sentinel and one that removes it again.
leak_in_history() {
    echo "text ${SENTINEL}" > "$1.txt" && git add "$1.txt" && commit_bypassing_hooks "feat: $1"
    git rm -q "$1.txt" && commit_bypassing_hooks "chore: drop $1"
}

@test "deep audit: history recorded as known is not red again; a new commit with the same word is" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    leak_in_history old
    audit
    [ "$status" -ne 0 ]
    audit --record-known "$(known_file)"
    [ "$status" -eq 0 ]
    [ -f "$(known_file)" ]
    audit --known "$(known_file)"
    [ "$status" -eq 0 ]
    leak_in_history new
    audit --known "$(known_file)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"git history blob"* ]]
}

@test "deep audit: a known branch name stays quiet; a new branch with the same word is red" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    git branch "feat-${SENTINEL}"
    audit --record-known "$(known_file)"
    [ "$status" -eq 0 ]
    audit --known "$(known_file)"
    [ "$status" -eq 0 ]
    git branch "other-${SENTINEL}"
    audit --known "$(known_file)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"branch names"* ]]
}

@test "deep audit: a file in the tree is never accepted as known" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: leak"
    audit --record-known "$(known_file)"
    [ "$status" -ne 0 ]
    audit --known "$(known_file)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"tracked files: leak found"* ]]
}

@test "deep audit: GitHub records are read from the time the known findings were recorded" {
    mk_repo synforger
    local bindir="${BATS_TEST_TMPDIR}/stub-bin"
    export GH_LOG="${BATS_TEST_TMPDIR}/gh.log"
    mkdir -p "${bindir}"
    printf '#!/usr/bin/env bash\necho "$*" >> "${GH_LOG}"\n[ "$1" = repo ] && [ "$2" = view ] && echo "{}"\nexit 0\n' > "${bindir}/gh"
    chmod +x "${bindir}/gh"
    export PATH="${bindir}:${PATH}"
    audit --record-known "$(known_file)"
    [ "$status" -eq 0 ]
    : > "${GH_LOG}"
    audit --known "$(known_file)"
    [ "$status" -eq 0 ]
    local since
    since="$(sed -n 's/^since //p' "$(known_file)")"
    [ -n "${since}" ]
    grep -qF "issues?state=all&per_page=100&since=${since}" "${GH_LOG}"
}

@test "deep audit: --as-of accepts what had gone out before the time, and what came after is red at once" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    GIT_COMMITTER_DATE="2026-10-18T09:00:00Z" GIT_AUTHOR_DATE="2026-10-18T09:00:00Z" leak_in_history old
    audit --record-known "$(known_file)" --as-of 2026-10-19T15:00:00Z
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^since //p' "$(known_file)")" = "2026-10-19T15:00:00Z" ]
    GIT_COMMITTER_DATE="2026-10-21T09:00:00Z" GIT_AUTHOR_DATE="2026-10-21T09:00:00Z" leak_in_history late
    audit --record-known "$(known_file)" --as-of 2026-10-19T15:00:00Z
    [ "$status" -ne 0 ]
    [[ "$output" == *"git history blob"* ]]
    audit --known "$(known_file)"
    [ "$status" -ne 0 ]
}

@test "deep audit: --as-of is a UTC time, and only with --record-known" {
    mk_repo synforger
    audit --record-known "$(known_file)" --as-of 2026-10-20
    [ "$status" -eq 2 ]
    audit --known "$(known_file)" --as-of 2026-10-19T15:00:00Z
    [ "$status" -eq 2 ]
}

@test "deep audit: --known is refused with a push range, and a missing known file is an error" {
    mk_repo synforger
    audit --known "$(known_file)" --range "HEAD~0..HEAD"
    [ "$status" -eq 2 ]
    audit --known "${BATS_TEST_TMPDIR}/missing.known"
    [ "$status" -eq 2 ]
}

@test "weekly audit: --accept records a repository, and the next run reports only what is new" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    leak_in_history old
    local repo
    repo="$(pwd)"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/guard-dispatcher"
    printf 'REPOS_GLOB="%s"\n' "${repo}" > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -ne 0 ]
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh" --accept "${repo}"
    [ "$status" -eq 0 ]
    [ -f "${HOME}/.config/guard-dispatcher/known/$(basename "${repo}").known" ]
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -eq 0 ]
    grep -q "known findings accepted" "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log
    leak_in_history new
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -ne 0 ]
}

@test "weekly audit: --accept --as-of cuts at the time, and each repository names its innermost area" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    GIT_COMMITTER_DATE="2026-10-18T09:00:00Z" GIT_AUTHOR_DATE="2026-10-18T09:00:00Z" leak_in_history old
    local repo outside
    repo="$(pwd)"
    outside="${BATS_RUN_TMPDIR}/outside-repo-${RANDOM}"
    git init -q "${outside}"
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'company %s\nclient %s\n' "$(dirname "$(dirname "${repo}")")" "$(dirname "${repo}")" > "${GUARD_CONFIG_DIR}/areas.txt"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/guard-dispatcher"
    printf 'REPOS_GLOB="%s"\n' "${outside}" > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh" --accept --as-of 2026-10-19T15:00:00Z "${repo}"
    [ "$status" -eq 0 ]
    grep -qx "since 2026-10-19T15:00:00Z" "${HOME}/.config/guard-dispatcher/known/$(basename "${repo}").known"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    grep -qE -- "^--- .*/$(basename "${repo}") \(full, known findings accepted, area client\) ---$" "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log
    grep -qE -- "^--- .*/$(basename "${outside}") \(full, area -\) ---$" "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh" --accept --as-of 2026-10-20 "${repo}"
    [ "$status" -ne 0 ]
}

@test "weekly audit: ACCEPT_BEFORE holds every repository to one line, with no --accept run for it" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    GIT_COMMITTER_DATE="2026-10-18T09:00:00Z" GIT_AUTHOR_DATE="2026-10-18T09:00:00Z" leak_in_history old
    local repo known
    repo="$(pwd)"
    export HOME="${BATS_TEST_TMPDIR}/home"
    known="${HOME}/.config/guard-dispatcher/known/$(basename "${repo}").known"
    mkdir -p "${HOME}/.config/guard-dispatcher"
    printf 'REPOS_GLOB="%s"\nACCEPT_BEFORE="2026-10-19T15:00:00Z"\n' "${repo}" > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -eq 0 ]                                   # what went out before the line is not reported
    grep -qx "since 2026-10-19T15:00:00Z" "${known}"
    grep -qE -- "\(full, known findings accepted before 2026-10-19T15:00:00Z, area -\) ---$" \
        "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log
    GIT_COMMITTER_DATE="2026-10-21T09:00:00Z" GIT_AUTHOR_DATE="2026-10-21T09:00:00Z" leak_in_history late
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -ne 0 ]                                   # what went out after it still is
    # a record made before the line is made again at the line; one made after it is kept
    printf 'since 2026-10-01T00:00:00Z\n' > "${known}"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    grep -qx "since 2026-10-19T15:00:00Z" "${known}"
    printf 'since 2026-10-25T00:00:00Z\n' > "${known}"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    grep -qx "since 2026-10-25T00:00:00Z" "${known}"
    printf 'REPOS_GLOB="%s"\nACCEPT_BEFORE="2026-10-20"\n' "${repo}" > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -eq 2 ]
}

@test "weekly audit: an argument the run does not take stops it before anything is audited" {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/guard-dispatcher"
    printf 'REPOS_GLOB="%s"\n' "${BATS_TEST_TMPDIR}" > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh" --help
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: weekly-audit.sh"* ]]
    ! ls "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log 2>/dev/null
}

@test "weekly audit: a repository inside an area is audited though no glob lists it" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    leak_in_history old
    local repo
    repo="$(pwd)"
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'client %s\n' "$(dirname "${repo}")" > "${GUARD_CONFIG_DIR}/areas.txt"
    # someone else's code cloned into the area is not audited
    local vendored="$(dirname "${repo}")/host/third_party/someone"
    mkdir -p "${vendored}"
    git -C "${vendored}" init -q
    git -C "${vendored}" -c core.hooksPath=/dev/null -c user.name=someone -c user.email=someone@example.com \
        commit -q --allow-empty -m "someone else's history"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/guard-dispatcher"
    printf '# the repository is listed nowhere: the area holds it\n' > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -ne 0 ]
    grep -q "$(basename "${repo}"): FINDINGS" "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log
    [ "$(cat "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log | grep -c "=== source 1/11")" -eq 1 ]
    # listed by a glob as well, it is audited once
    printf 'REPOS_GLOB="%s"\n' "${repo}" > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    rm "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$(cat "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log | grep -c "=== source 1/11")" -eq 1 ]
    # left out on purpose, nothing is left to audit
    printf 'AREA_REPOS=0\n' > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -eq 2 ]
}

@test "weekly audit: a repository inside an area that the git hooks hold to no word list is left out" {
    mk_repo synforger
    export STUB_SENTINEL=""
    setup_gh_stub
    leak_in_history old
    local repo kind held
    repo="$(pwd)"
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'client %s\n' "$(dirname "${repo}")" > "${GUARD_CONFIG_DIR}/areas.txt"
    git -C "${repo}" config guard.scope enforced
    for kind in corpus exempt; do
        held="$(dirname "${repo}")/notes-${kind}"
        mkdir -p "${held}"
        git -C "${held}" init -q
        git -C "${held}" config guard.scope "${kind}"
        (cd "${held}" && leak_in_history "${kind}")
    done
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/guard-dispatcher"
    printf '# the area holds every repository\n' > "${HOME}/.config/guard-dispatcher/weekly-audit.conf"
    run bash "${GUARD_ROOT}/scripts/weekly-audit.sh"
    [ "$status" -ne 0 ]
    local log
    log="$(cat "${HOME}"/.local/state/guard-dispatcher/weekly-audit-*.log)"
    [[ "${log}" == *"left out: "*"/notes-corpus (guard.scope corpus)"* ]]
    [[ "${log}" == *"left out: "*"/notes-exempt (guard.scope exempt)"* ]]
    [[ "${log}" == *"$(basename "${repo}"): FINDINGS"* ]]
    [ "$(grep -c "=== source 1/11" <<< "${log}")" -eq 1 ]
}
