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

# --- the destination decides, not the folder ---------------------------------------

# mk_clone_at <dir> <owner/repo> — a fixture repo at a place, with a GitHub origin.
mk_clone_at() {
    mk_repo_at "$1"
    git remote add origin "git@github.com:$2.git"
}

@test "corpus: a public destination is outside every area, wherever its clone lives" {
    seed_visibility acme/pipeline public
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    base="$(git rev-parse HEAD)"
    commit_line "${CLIENT_TEXT}"
    head="$(git rev-parse HEAD)"
    run_pre_push_to "git@github.com:acme/pipeline.git" "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is public on GitHub"* ]]
    [[ "$output" == *"client text"* ]]
}

@test "corpus: a public company repo inside the company folder may not carry company text" {
    seed_visibility acme/sdk public
    mk_clone_at "${WORK}/repos/sdk" acme/sdk
    commit_line "${COMPANY_TEXT}"
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD --dest git@github.com:acme/sdk.git
    [ "$status" -eq 1 ]
    [[ "$output" == *"company text"* ]]
}

@test "corpus: a private destination cloned inside the client may carry client text" {
    seed_visibility acme/pipeline private
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    commit_line "${CLIENT_TEXT}"
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD --dest git@github.com:acme/pipeline.git
    [ "$status" -eq 0 ]
}

@test "corpus: a private destination with no clone on this machine is outside every area" {
    seed_visibility acme/elsewhere private
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    commit_line "${CLIENT_TEXT}"
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD --dest git@github.com:acme/elsewhere.git
    [ "$status" -eq 1 ]
    [[ "$output" == *"no clone on this machine"* ]]
}

@test "corpus: a destination GitHub cannot be asked about is treated as public" {
    mk_clone_at "${CLIENT}/repos/pipeline" acme/unasked
    commit_line "${CLIENT_TEXT}"
    FAIL_DIR="${BATS_TEST_TMPDIR}/nogh"; mkdir -p "${FAIL_DIR}"
    printf '#!/bin/sh\nexit 1\n' > "${FAIL_DIR}/gh"; chmod +x "${FAIL_DIR}/gh"
    https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 PATH="${FAIL_DIR}:${PATH}" \
        run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD --dest git@github.com:acme/unasked.git
    [ "$status" -eq 1 ]
    [[ "$output" == *"is unknown on GitHub"* ]]
}

@test "corpus: a token in the environment that cannot see the repo does not hide gh's own accounts" {
    mk_clone_at "${CLIENT}/repos/pipeline" acme/scoped
    commit_line "${CLIENT_TEXT}"
    # gh answers 404 while GH_TOKEN is set (a token scoped to other repos) and
    # "private" from its own account store once it is not.
    FAKE_DIR="${BATS_TEST_TMPDIR}/scopedgh"; mkdir -p "${FAKE_DIR}"
    printf '#!/bin/sh\n[ -n "$GH_TOKEN" ] && exit 1\necho true\n' > "${FAKE_DIR}/gh"; chmod +x "${FAKE_DIR}/gh"
    GH_TOKEN=scoped https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 PATH="${FAKE_DIR}:${PATH}" \
        run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD --dest git@github.com:acme/scoped.git
    [ "$status" -eq 0 ]
}

@test "corpus: --where names the clone of a private destination, OUTSIDE for a public one" {
    seed_visibility acme/pipeline private
    seed_visibility acme/sdk public
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --where --dest git@github-work:acme/pipeline.git
    [ "$status" -eq 0 ]
    [[ "$output" == *"clients/acme/repos/pipeline" ]]
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --where --dest https://github.com/acme/sdk
    [[ "$output" == *"OUTSIDE" ]]
}

# gh_shim — put gh-guard in front of a fake gh that only records that it ran.
gh_shim() {
    SHIM_DIR="${BATS_TEST_TMPDIR}/shim"; REAL_DIR="${BATS_TEST_TMPDIR}/real"
    mkdir -p "${SHIM_DIR}" "${REAL_DIR}"
    ln -sf "${GUARD_ROOT}/scripts/gh-guard.sh" "${SHIM_DIR}/gh"
    printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "${BATS_TEST_TMPDIR}" > "${REAL_DIR}/gh"
    chmod +x "${REAL_DIR}/gh"
    GH_PATH="${SHIM_DIR}:${REAL_DIR}:${PATH}"
}

@test "gh-guard: client text sent from inside the client folder to a public repo is refused" {
    seed_visibility someone/public-tool public
    gh_shim
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    PATH="${GH_PATH}" run gh pr create -R someone/public-tool --title t --body "see: ${CLIENT_TEXT}"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}

@test "gh-guard: an api call naming a public repo is judged by that repo" {
    seed_visibility someone/public-tool public
    gh_shim
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    PATH="${GH_PATH}" run gh api -X POST repos/someone/public-tool/issues -f body="${CLIENT_TEXT}"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}

@test "gh-guard: client text to the client's own private repo is sent" {
    seed_visibility acme/pipeline private
    gh_shim
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    cd "${BATS_TEST_TMPDIR}"
    PATH="${GH_PATH}" run gh pr create -R acme/pipeline --title t --body "see: ${CLIENT_TEXT}"
    [ "$status" -eq 0 ]
    [ -f "${BATS_TEST_TMPDIR}/ran" ]
}

@test "gh-guard: a gist is outside every area" {
    gh_shim
    mk_clone_at "${CLIENT}/repos/pipeline" acme/pipeline
    printf '%s\n' "${CLIENT_TEXT}" > note.txt
    PATH="${GH_PATH}" run gh gist create note.txt
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
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
