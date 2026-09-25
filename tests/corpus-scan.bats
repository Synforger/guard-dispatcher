#!/usr/bin/env bats
# Behavioural tests for corpus-scan.py: text copied out of a private document
# must not leave the area the document lives in.
#
# Every test builds its own areas under $BATS_TEST_TMPDIR — a company, a client
# nested inside it, and a personal repo outside both — so no operator document
# is ever read. Sentences are made up and long enough to form 12-character runs.

load helpers

# Japanese counts as copied from 12 characters, text without Japanese from 40
# (twelve characters of English are two common words).
CLIENT_TEXT="the calibration table reads seventeen at dawn"
COMPANY_TEXT="quarterly planning keeps the bench schedule"
CLIENT_JA="採寸表の三段目は夜明けに読み直すこと"

setup() {
    setup_words
    export GUARD_CORPUS_MAX_AGE=0          # always rebuild: documents change inside a test
    WORK="${BATS_TEST_TMPDIR}/work"
    CLIENT="${WORK}/clients/acme"
    mkdir -p "${CLIENT}/received" "${WORK}/meetings" "${GUARD_CONFIG_DIR}/patterns" \
        "${BATS_TEST_TMPDIR}/public"
    printf '# notes\n%s\n%s\n' "${CLIENT_TEXT}" "${CLIENT_JA}" > "${CLIENT}/received/notes.md"
    printf '%s\n' "${COMPANY_TEXT}" > "${WORK}/meetings/plan.md"
    cat > "${GUARD_CONFIG_DIR}/areas.txt" <<EOF
company ${WORK}
client  ${CLIENT}
_exempt ${BATS_TEST_TMPDIR}/private
EOF
    printf '(?<![A-Za-z0-9])QX\\d{4}(?![0-9])\n' > "${GUARD_CONFIG_DIR}/patterns/client.txt"
}

# commit_line <text> — add one line in the current repo and commit it past the hooks.
commit_line() {
    printf '%s\n' "$1" >> sent.txt
    git add sent.txt
    commit_bypassing_hooks "add a line"
}

# scan_last — run the scanner over the newest commit of the current repo.
scan_last() {
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD
}

# mk_repo_at <dir> — a fixture repo at a chosen place (areas are decided by place).
mk_repo_at() {
    mkdir -p "$1"
    cd "$1" || return 1
    git init -q .
    git config user.email "${ALLOWED_EMAIL}"
    git config user.name "Fixture"
    git config commit.gpgsign false
    echo seed > seed.txt
    git add seed.txt
    commit_bypassing_hooks seed
}

# --- a personal repo is outside every area -------------------------------------

@test "corpus: a client sentence copied into a personal repo is caught" {
    mk_repo other
    commit_line "expected: ${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"client text"* ]]
}

@test "corpus: a company sentence copied into a personal repo is caught" {
    mk_repo other
    commit_line "${COMPANY_TEXT}"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"company text"* ]]
}

@test "corpus: text inside an Office document is read, not its compressed bytes" {
    mk_office "${CLIENT}/received/deck.pptx" "第七頁は仮縫いの台帳を示している"
    mk_repo other
    commit_line "資料どおり: 第七頁は仮縫いの台帳を示している"
    scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: a commit message is scanned too" {
    mk_repo other
    printf 'ok\n' > ok.txt
    git add ok.txt
    commit_bypassing_hooks "port ${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"message"* ]]
}

@test "corpus: a full-width re-typing is folded and still caught" {
    mk_repo other
    commit_line "ｔｈｅ ｃａｌｉｂｒａｔｉｏｎ ｔａｂｌｅ ｒｅａｄｓ ｓｅｖｅｎｔｅｅｎ ａｔ ｄａｗｎ"
    scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: 12 copied characters of Japanese are caught, 11 pass" {
    mk_repo other
    commit_line "メモ: 三段目は夜明けに読み直す"
    scan_last
    [ "$status" -eq 1 ]
    commit_line "メモ: 三段目は夜明けに読み"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: common English shorter than 40 characters passes" {
    mk_repo other
    commit_line "the calibration table reads seventeen"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: an identifier of the client's shape is caught, a longer number is not" {
    mk_repo other
    commit_line "sample qx1234 again"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"shape"* ]]
    commit_line "order QX12345 is a different thing"
    scan_last
    [ "$status" -eq 0 ]
}

# --- where the repo lives decides what it may carry ------------------------------

@test "corpus: a company repo may carry company text but not client text" {
    mk_repo_at "${WORK}/repos/internal"
    commit_line "${COMPANY_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
    commit_line "${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: a client repo may carry its own text and the company's" {
    mk_repo_at "${CLIENT}/repos/pipeline"
    commit_line "${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
    commit_line "${COMPANY_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: an exempt repo is never scanned" {
    mk_repo_at "${BATS_TEST_TMPDIR}/private/state"
    commit_line "${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

# --- what is not specific to an area ---------------------------------------------

@test "corpus: a phrase in allow.txt passes" {
    printf '%s\n' "${CLIENT_TEXT}" > "${GUARD_CONFIG_DIR}/allow.txt"
    mk_repo other
    commit_line "${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: text that also appears in public background text passes" {
    printf 'from a public readme: %s\n' "${COMPANY_TEXT}" > "${BATS_TEST_TMPDIR}/public/README.md"
    printf '%s\n' "${BATS_TEST_TMPDIR}/public" > "${GUARD_CONFIG_DIR}/background.txt"
    mk_repo other
    commit_line "${COMPANY_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: Markdown inside a git repository is not treated as a document" {
    mk_repo_at "${CLIENT}/repos/tool"
    printf 'a readme sentence that is only code documentation\n' > README.md
    mk_repo other
    commit_line "a readme sentence that is only code documentation"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: no areas on this machine says NOT CHECKED and passes" {
    rm "${GUARD_CONFIG_DIR}/areas.txt"
    mk_repo other
    commit_line "${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT CHECKED"* ]]
}

# --- wiring -----------------------------------------------------------------------

@test "pre-push: a push carrying client text is blocked" {
    mk_repo other
    base="$(git rev-parse HEAD)"
    commit_line "${CLIENT_TEXT}"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"private area"* ]]
}

@test "pre-push: GUARD_CORPUS_SKIP=1 lets one push through" {
    mk_repo other
    base="$(git rev-parse HEAD)"
    commit_line "${CLIENT_TEXT}"
    head="$(git rev-parse HEAD)"
    GUARD_CORPUS_SKIP=1 run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
}

@test "gh-guard: a body carrying client text is refused and never sent" {
    SHIM_DIR="${BATS_TEST_TMPDIR}/shim"; REAL_DIR="${BATS_TEST_TMPDIR}/real"
    mkdir -p "${SHIM_DIR}" "${REAL_DIR}"
    ln -sf "${GUARD_ROOT}/scripts/gh-guard.sh" "${SHIM_DIR}/gh"
    printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "${BATS_TEST_TMPDIR}" > "${REAL_DIR}/gh"
    chmod +x "${REAL_DIR}/gh"
    mk_repo other
    PATH="${SHIM_DIR}:${REAL_DIR}:${PATH}" run gh pr comment 1 --body "see: ${CLIENT_TEXT}"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}
