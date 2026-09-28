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

@test "corpus: a clean scan counts the areas it compared with and names none" {
    mk_repo other
    commit_line "nothing from any document"
    scan_last
    [ "$status" -eq 0 ]
    [[ "$output" == *"built in "*"s: 2 documents in 2 areas"* ]]
    [[ "$output" == *"clean (3 lines against 2 areas)"* ]]
    [[ "$output" != *company* ]]
    [[ "$output" != *client* ]]
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
    ln -sf "${GUARD_ROOT}/gh-shim/gh-guard.sh" "${SHIM_DIR}/gh"
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

@test "corpus: a file a repository does not track is not its document" {
    mk_repo_at "${CLIENT}/repos/tool"
    printf 'a readme sentence that is only local scratch output here\n' > README.md
    mk_repo other
    commit_line "a readme sentence that is only local scratch output here"
    scan_last
    [ "$status" -eq 0 ]
}

# --- code, data and PDF ------------------------------------------------------------

CODE_LINE='    calibrated = apply_offset_table(raw_frames, acme_offsets, window=17)'

# client_code <line> — commit a file holding <line> to a repository inside the client.
client_code() {
    mk_repo_at "${CLIENT}/repos/pipeline"
    printf 'def run():\n%s\n    return x\n' "$1" > pipeline.py
    git add pipeline.py
    commit_bypassing_hooks "add pipeline"
}

@test "corpus: a whole line of a client repository's code is caught, however it is indented" {
    export GUARD_CORPUS_CODE_LINES=1
    client_code "${CODE_LINE}"
    mk_repo other
    commit_line "        calibrated = apply_offset_table(raw_frames, acme_offsets, window=17)"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"client text"* ]]
}

@test "corpus: a short line of code is too common to mean anything" {
    client_code "${CODE_LINE}"
    mk_repo other
    commit_line "    return x"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: code in a vendored folder is someone else's, not the area's" {
    export GUARD_CORPUS_CODE_LINES=1
    mk_repo_at "${CLIENT}/repos/pipeline"
    mkdir -p third_party/lib
    printf '%s\n' "${CODE_LINE}" > third_party/lib/x.py
    git add third_party
    commit_bypassing_hooks "vendor"
    mk_repo other
    commit_line "${CODE_LINE}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: a line of code also found in public code is not the area's" {
    export GUARD_CORPUS_CODE_LINES=1
    client_code "${CODE_LINE}"
    mkdir -p "${BATS_TEST_TMPDIR}/public/lib"
    printf '%s\n' "${CODE_LINE}" > "${BATS_TEST_TMPDIR}/public/lib/same.py"
    printf '%s\n' "${BATS_TEST_TMPDIR}/public" > "${GUARD_CONFIG_DIR}/background.txt"
    mk_repo other
    commit_line "${CODE_LINE}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: by default a lone common line of code passes and a copied block is caught" {
    mk_repo_at "${CLIENT}/repos/pipeline"
    printf 'def run():\n%s\n    result = merge_panels(calibrated, seam_allowance=0.35)\n' "${CODE_LINE}" > pipeline.py
    git add pipeline.py
    commit_bypassing_hooks "add pipeline"
    mk_repo other
    commit_line "${CODE_LINE}"
    scan_last
    [ "$status" -eq 0 ]
    printf '%s\n    result = merge_panels(calibrated, seam_allowance=0.35)\n' "${CODE_LINE}" > block.py
    git add block.py
    commit_bypassing_hooks "copy a block"
    scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: a license wrapped differently from its public copy is not the area's" {
    export GUARD_CORPUS_CODE_LINES=1
    mk_repo_at "${CLIENT}/repos/pipeline"
    printf '# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY\n# EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED FOREVER AND EVER\n' > header.py
    git add header.py
    commit_bypassing_hooks "header"
    mkdir -p "${BATS_TEST_TMPDIR}/public/lib"
    printf 'THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND\nCONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE\nDISCLAIMED FOREVER AND EVER\n' > "${BATS_TEST_TMPDIR}/public/lib/LICENSE"
    printf '%s\n' "${BATS_TEST_TMPDIR}/public" > "${GUARD_CONFIG_DIR}/background.txt"
    mk_repo other
    commit_line '# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY'
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: a row that is public text (a license in a .txt) is not the area's" {
    printf 'Permission is hereby granted, free of charge, to any person obtaining a copy\n' > "${CLIENT}/received/notices.txt"
    mkdir -p "${BATS_TEST_TMPDIR}/public/lib"
    printf 'Permission is hereby granted, free of charge, to any\nperson obtaining a copy of this software\n' > "${BATS_TEST_TMPDIR}/public/lib/LICENSE"
    printf '%s\n' "${BATS_TEST_TMPDIR}/public" > "${GUARD_CONFIG_DIR}/background.txt"
    mk_repo other
    commit_line "Permission is hereby granted, free of charge, to any person obtaining a copy"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: one row of a CSV is caught on its own" {
    printf 'id,label,score\n4411,acme-left-sleeve-measurement-batch,0.8731\n' > "${CLIENT}/received/table.csv"
    mk_repo other
    commit_line "4411,acme-left-sleeve-measurement-batch,0.8731"
    scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: the text of a PDF is caught" {
    command -v pdftotext >/dev/null || skip "pdftotext is not installed"
    mk_pdf "${CLIENT}/received/report.pdf" "the sleeve seam drifts four millimetres per wash cycle"
    mk_repo other
    commit_line "the sleeve seam drifts four millimetres per wash cycle"
    scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: a sentence a PDF wrapped across lines is joined again" {
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('c', '${GUARD_ROOT}/scanners/corpus-scan.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
print(c.join_wrapped(['採寸表の三段目は夜', '明けに読み直すこと', '', 'the next', 'paragraph']))"
    [ "$output" = "['採寸表の三段目は夜明けに読み直すこと', 'the next paragraph']" ]
}

@test "corpus: a run reaching past an allowed phrase is not a hit" {
    # the document and the sent line share the allowed phrase plus the few words after it
    printf 'open System Settings then Privacy and Security then Screen Recording for the app\n' > "${CLIENT}/received/howto.md"
    printf 'System Settings then Privacy and Security then Screen Recording\n' > "${GUARD_CONFIG_DIR}/allow.txt"
    mk_repo other
    commit_line "- System Settings then Privacy and Security then Screen Recording for the process"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: a repository holding the area from outside keeps its notes out of the area" {
    # an agent's state tree (a repository) with a folder for the company inside it
    STATE="${BATS_TEST_TMPDIR}/state-tree"
    mkdir -p "${STATE}/projects/co"
    git -C "${BATS_TEST_TMPDIR}" init -q "${STATE}"
    git -C "${STATE}" config user.email "${ALLOWED_EMAIL}"
    git -C "${STATE}" config user.name "Fixture"
    printf 'the agent writes its own session notes in this very folder\n' > "${STATE}/projects/co/notes.md"
    git -C "${STATE}" add -A && git -C "${STATE}" -c core.hooksPath=/dev/null commit -q -m notes
    printf 'co %s/projects/co\n' "${STATE}" >> "${GUARD_CONFIG_DIR}/areas.txt"
    mk_repo other
    commit_line "the agent writes its own session notes in this very folder"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: a license text in a repository is public boilerplate" {
    mk_repo_at "${CLIENT}/repos/pipeline"
    printf 'Redistributions of source code must retain the above copyright notice\n' > LICENSE
    git add LICENSE
    commit_bypassing_hooks "license"
    mk_repo other
    commit_line "Redistributions of source code must retain the above copyright notice"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: a folder in ignore.txt holds no documents" {
    mkdir -p "${WORK}/corpus-external"
    printf '%s\n' "${COMPANY_TEXT}" > "${WORK}/corpus-external/a.txt"
    rm "${WORK}/meetings/plan.md"
    printf '%s\n' "${WORK}/corpus-external" > "${GUARD_CONFIG_DIR}/ignore.txt"
    mk_repo other
    commit_line "${COMPANY_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

# --- a new client folder is an area at once -----------------------------------------

@test "corpus: a client folder made after the areas were written is its own area" {
    printf 'client-* %s/clients/*\n' "${WORK}" >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${WORK}/clients/beta"
    printf 'beta keeps the pattern archive under the north stairs\n' > "${WORK}/clients/beta/brief.md"
    # beta's own repository may carry it (checked first: once another client's repository
    # has committed the line, that repository holds it too)
    mk_repo_at "${WORK}/clients/beta/repos/tool"
    commit_line "beta keeps the pattern archive under the north stairs"
    scan_last
    [ "$status" -eq 0 ]
    mk_repo_at "${CLIENT}/repos/pipeline"
    commit_line "beta keeps the pattern archive under the north stairs"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"client-beta text"* ]]
}

@test "corpus: a folder named on an explicit line keeps that name" {
    printf 'client-* %s/clients/*\n' "${WORK}" >> "${GUARD_CONFIG_DIR}/areas.txt"
    mk_repo other
    commit_line "${CLIENT_TEXT}"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *" client text"* ]]
    [[ "$output" != *"client-acme"* ]]
}

# --- a machine that is the company's, less the folders in no area ---------------------

HOME_TEXT="the loading dock opens only after the second bell"

# home_is_company — every folder of a home directory joins the company; its repos folder is in no area.
home_is_company() {
    HOMEDIR="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOMEDIR}/repos"
    printf 'company %s/*\n_outside %s/repos\n' "${HOMEDIR}" "${HOMEDIR}" >> "${GUARD_CONFIG_DIR}/areas.txt"
}

@test "corpus: a folder made later under a <name> <path>/* line joins that area" {
    home_is_company
    mkdir -p "${HOMEDIR}/Desktop"
    printf '%s\n' "${HOME_TEXT}" > "${HOMEDIR}/Desktop/memo.md"
    mk_repo other
    commit_line "${HOME_TEXT}"
    scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"company text"* ]]
}

@test "corpus: a hidden folder under a <name> <path>/* line stays out of the area" {
    home_is_company
    mkdir -p "${HOMEDIR}/.config"
    printf '%s\n' "${HOME_TEXT}" > "${HOMEDIR}/.config/memo.md"
    mk_repo other
    commit_line "${HOME_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: a folder on an _outside line holds no documents" {
    home_is_company
    printf '%s\n' "${HOME_TEXT}" > "${HOMEDIR}/repos/memo.md"
    mk_repo other
    commit_line "${HOME_TEXT}"
    scan_last
    [ "$status" -eq 0 ]
}

@test "corpus: an _outside folder inside an area is cut out of it" {
    printf '_outside %s/public\n' "${WORK}" >> "${GUARD_CONFIG_DIR}/areas.txt"
    mkdir -p "${WORK}/public"
    printf '%s\n' "${HOME_TEXT}" > "${WORK}/public/notes.md"
    mk_repo_at "${WORK}/public/site"
    commit_line "${HOME_TEXT}"
    scan_last
    [ "$status" -eq 0 ]                   # its notes are not the company's documents
    commit_line "${COMPANY_TEXT}"
    scan_last
    [ "$status" -eq 1 ]                   # and a repository there is outside the company
    [[ "$output" == *"company text"* ]]
}

@test "corpus: a private destination cloned in an _outside folder inside the company is outside it" {
    printf '_outside %s/public\n' "${WORK}" >> "${GUARD_CONFIG_DIR}/areas.txt"
    seed_visibility acme/site private
    mk_clone_at "${WORK}/public/site" acme/site
    commit_line "${COMPANY_TEXT}"
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --range HEAD~1..HEAD --dest git@github.com:acme/site.git
    [ "$status" -eq 1 ]
    [[ "$output" == *"company text"* ]]
}

# --- a document changed after the build is checked at once --------------------------

# spotlight_stub <reported-file> — mdutil says indexing is on; mdfind finds any probe
# asked by name and reports <reported-file> as changed.
spotlight_stub() {
    STUB="${BATS_TEST_TMPDIR}/spotlight"; mkdir -p "${STUB}"
    printf '#!/bin/sh\necho "/:"\necho "\tIndexing enabled."\n' > "${STUB}/mdutil"
    cat > "${STUB}/mdfind" <<SH
#!/bin/sh
[ "\$3" = "-name" ] && { echo "\$2/\$4"; exit 0; }
echo "\${SPOTLIGHT_REPORTS:-}" | grep . | grep "^\$2" || true
SH
    chmod +x "${STUB}/mdutil" "${STUB}/mdfind"
    export SPOTLIGHT_REPORTS="$1"
}

@test "corpus: a document Spotlight reports as changed is caught without a full rebuild" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 0 ]
    printf 'the dye lot for the spring run arrives on the ninth\n' > "${CLIENT}/received/late.md"
    # Spotlight answers with physical paths (= /var/folders is /private/var/folders)
    SPOTLIGHT_REPORTS="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${CLIENT}/received/late.md")"
    export SPOTLIGHT_REPORTS
    commit_line "the dye lot for the spring run arrives on the ninth"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
    [[ "$output" != *"walking the private documents"* ]]
}

# index_has <path> — the index (docs/index.json) still names <path> as a document. The index
# names real paths (macOS's temp folder sits behind a symlink); a deleted file's folder still
# resolves, so the path is resolved before the lookup.
index_has() {
    python3 -c "
import json, os, sys
with open('${GUARD_CORPUS_CACHE}/docs/index.json') as fh:
    index = json.load(fh)
sys.exit(0 if os.path.realpath(sys.argv[1]) in index else 1)" "$1"
}

@test "corpus: when Spotlight cannot answer, an edited document is caught without a full rebuild" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    printf '#!/bin/sh\necho "\tIndexing disabled."\n' > "${STUB}/mdutil"
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last               # first look: nothing built yet, a full walk either way
    [ "$status" -eq 0 ]
    [[ "$output" == *"walking the private documents"* ]]
    printf 'the dye lot for the spring run arrives on the ninth\n' >> "${CLIENT}/received/notes.md"
    commit_line "the dye lot for the spring run arrives on the ninth"
    PATH="${STUB}:${PATH}" scan_last               # Spotlight is down: the stat fallback finds the edit
    [ "$status" -eq 1 ]
    [[ "$output" != *"walking the private documents"* ]]
}

@test "corpus: when Spotlight does not index an area, an edited document is still caught by the stat fallback" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    printf '#!/bin/sh\nexit 0\n' > "${STUB}/mdfind"   # finds nothing, not even a known document
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 0 ]
    printf 'the dye lot for the spring run arrives on the ninth\n' >> "${CLIENT}/received/notes.md"
    commit_line "the dye lot for the spring run arrives on the ninth"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
    [[ "$output" != *"walking the private documents"* ]]
}

@test "corpus: when Spotlight cannot answer, a deleted document drops from the index (its prints stay the safe side)" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    printf '#!/bin/sh\necho "\tIndexing disabled."\n' > "${STUB}/mdutil"
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 0 ]
    run index_has "${CLIENT}/received/notes.md"
    [ "$status" -eq 0 ]
    rm "${CLIENT}/received/notes.md"
    commit_line "the file is gone now"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 0 ]
    [[ "$output" != *"walking the private documents"* ]]
    run index_has "${CLIENT}/received/notes.md"
    [ "$status" -ne 0 ]
    # the safe side: the area's merged table is not rebuilt until the next full walk, so the
    # text the deleted document held is still caught
    commit_line "expected: ${CLIENT_TEXT}"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
}

@test "corpus: when Spotlight cannot answer, a new document and a new folder are caught without a full walk" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    printf '#!/bin/sh\necho "\tIndexing disabled."\n' > "${STUB}/mdutil"
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 0 ]
    # created since the last look: its folder's modification time moved, so only that folder is
    # listed again -- found at once, without walking everything
    printf 'the dye lot for the spring run arrives on the ninth\n' > "${CLIENT}/received/late.md"
    commit_line "the dye lot for the spring run arrives on the ninth"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
    [[ "$output" != *"walking the private documents"* ]]
    # a folder that did not exist at the last look is walked whole
    mkdir -p "${CLIENT}/received/new-batch/inner"
    printf 'the loom in bay four is retuned every second tuesday\n' > "${CLIENT}/received/new-batch/inner/note.md"
    commit_line "the loom in bay four is retuned every second tuesday"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
    [[ "$output" != *"walking the private documents"* ]]
}

# --- only one process at a time builds or writes the fingerprints -------------------

# hold_lock <cache-dir> <seconds> — take the build lock in a background process and wait
# until it is really held, so the test that follows races a lock it is sure to lose.
hold_lock() {
    python3 -c "
import fcntl, os, sys, time
cache = sys.argv[1]
os.makedirs(cache, exist_ok=True)
fh = open(os.path.join(cache, 'build.lock'), 'a+')
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(os.path.join(cache, 'lock-held'), 'w').close()
time.sleep(float(sys.argv[2]))
" "$1" "$2" &
    LOCK_PID=$!
    for _ in $(seq 1 50); do
        [ -f "$1/lock-held" ] && return 0
        sleep 0.1
    done
    return 1
}

@test "corpus: a process that cannot take the build lock uses the summary already on disk instead of waiting" {
    export GUARD_CORPUS_MAX_AGE=0      # would rebuild on every look, if it got the chance
    mk_repo other
    commit_line "nothing private"
    scan_last
    [ "$status" -eq 0 ]
    before="$(cat "${GUARD_CORPUS_CACHE}/summary.json")"
    hold_lock "${GUARD_CORPUS_CACHE}" 6
    started="$(date +%s)"
    scan_last
    elapsed=$(( $(date +%s) - started ))
    [ "$status" -eq 0 ]
    [ "${elapsed}" -lt 3 ]
    [ "$(cat "${GUARD_CORPUS_CACHE}/summary.json")" = "${before}" ]
}

@test "corpus: with nothing built yet, a second process waits for the one holding the lock" {
    rm -rf "${GUARD_CORPUS_CACHE}"
    # The git setup happens before the lock is taken, so a loaded machine being slow at that does
    # not eat into the window the test measures.
    mk_repo other
    commit_line "nothing private"
    hold_lock "${GUARD_CORPUS_CACHE}" 3
    started="$(date +%s)"
    scan_last
    elapsed=$(( $(date +%s) - started ))
    [ "$status" -eq 0 ]
    [ "${elapsed}" -ge 2 ]
    [ -f "${GUARD_CORPUS_CACHE}/summary.json" ]
}

@test "corpus: a summary.json read back is never a half-written file" {
    mk_repo other
    commit_line "nothing private"
    scan_last
    [ "$status" -eq 0 ]
    python3 -c "import json; json.load(open('${GUARD_CORPUS_CACHE}/summary.json'))"
    [ -z "$(find "${GUARD_CORPUS_CACHE}" -maxdepth 1 -name '.summary.json.*')" ]
    [ -z "$(find "${GUARD_CORPUS_CACHE}/docs" -maxdepth 1 -name '.index.json.*')" ]
}

@test "corpus: a broken areas.txt line refuses instead of guessing" {
    printf '_exempt = the text of a comment that lost its hash\n' >> "${GUARD_CONFIG_DIR}/areas.txt"
    mk_repo other
    commit_line "nothing private"
    scan_last
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
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
    ln -sf "${GUARD_ROOT}/gh-shim/gh-guard.sh" "${SHIM_DIR}/gh"
    printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "${BATS_TEST_TMPDIR}" > "${REAL_DIR}/gh"
    chmod +x "${REAL_DIR}/gh"
    mk_repo other
    PATH="${SHIM_DIR}:${REAL_DIR}:${PATH}" run gh pr comment 1 --body "see: ${CLIENT_TEXT}"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}

teardown() {
    [ -n "${LOCK_PID:-}" ] && kill "${LOCK_PID}" 2>/dev/null
    true
}

# update_prints — bring the fingerprints up to date through an ordinary clean scan
# (the changed documents, everything when a full walk is due).
update_prints() {
    printf 'nothing copied here\n' > "${BATS_TEST_TMPDIR}/prime.txt"
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --text "${BATS_TEST_TMPDIR}/prime.txt"
    [ "$status" -eq 0 ]
}

@test "corpus: only --status names an area, its folder or a document; every other output counts" {
    printf 'broken' > "${CLIENT}/received/broken.pptx"
    # named <output> — the output carries an area's name, its folder or a document of it.
    named() { [[ "$1" == *company* || "$1" == *client* || "$1" == *acme* || "$1" == *"${WORK}"* || "$1" == *broken.pptx* ]]; }
    for mode in --refresh --summary; do
        run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" "${mode}"
        [ "$status" -eq 0 ]
        [[ "$output" == *"documents / "*" prints in 2 areas"* ]]
        [[ "$output" == *"1 documents could not be read (see --status)"* ]]
        if named "$output"; then echo "${mode} named: $output"; return 1; fi
    done
    mk_repo other
    commit_line "nothing from any document"
    scan_last
    [ "$status" -eq 0 ]
    if named "$output"; then echo "scan named: $output"; return 1; fi
    # A throwaway HOME: the operator's own config dirs are no part of this test.
    run env HOME="${BATS_TEST_TMPDIR}/doctor-home" bash "${GUARD_ROOT}/scripts/doctor.sh"
    [[ "$output" == *"prints in 2 areas"* ]]
    if named "$output"; then echo "doctor named: $output"; return 1; fi
    # The operator's own look names everything.
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --status
    [[ "$output" == *"company "*" documents / "*"client "*" documents / "* ]]
    [[ "$output" == *"/received/broken.pptx"* ]]
}

# --- why a document could not be read ---------------------------------------------

@test "corpus: a time-out, a missing extractor and an exit code are told apart, not just OSError" {
    run python3 -c "
import importlib.util, subprocess
spec = importlib.util.spec_from_file_location('c', '${GUARD_ROOT}/scanners/corpus-scan.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

cases = [
    (subprocess.TimeoutExpired(cmd='pdftotext', timeout=30), 'timed out'),
    (FileNotFoundError(2, 'No such file or directory'), 'the extractor is not installed'),
    (OSError('pdftotext exited 1'), 'pdftotext exited 1'),
]
failures = []
for i, (exc, expect) in enumerate(cases):
    def reader(exc=exc):
        raise exc
    ok, why = c.document_prints(f'/nowhere/doc{i}.pdf', 'STAMP', ('runs', reader), {}, {}, 'area')
    if ok or why != expect:
        failures.append((i, ok, why))
print('ALL_OK' if not failures else f'FAILED: {failures}')
"
    [[ "$output" == *"ALL_OK"* ]]
}

@test "corpus: a PDF pdftotext cannot parse is unreadable, its reason names the exit code" {
    command -v pdftotext >/dev/null || skip "pdftotext is not installed"
    printf 'not a real pdf file at all\n' > "${CLIENT}/received/broken.pdf"
    printf 'nothing copied here\n' > "${BATS_TEST_TMPDIR}/prime.txt"
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --text "${BATS_TEST_TMPDIR}/prime.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 documents could not be read (see --status): pdftotext exited"* ]]
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --status
    [[ "$output" == *"could not read (not checked): "*"/received/broken.pdf (pdftotext exited"* ]]
}

@test "corpus: a PDF whose extractor times out is unreadable within the PDF budget, not the full 300s" {
    STUB="${BATS_TEST_TMPDIR}/pdf-stub"; mkdir -p "${STUB}"
    printf '#!/bin/sh\nsleep 5\n' > "${STUB}/pdftotext"
    chmod +x "${STUB}/pdftotext"
    printf 'placeholder\n' > "${CLIENT}/received/slow.pdf"
    export GUARD_CORPUS_PDF_TIMEOUT=1
    printf 'nothing copied here\n' > "${BATS_TEST_TMPDIR}/prime.txt"
    started="$(date +%s)"
    PATH="${STUB}:${PATH}" run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" \
        --text "${BATS_TEST_TMPDIR}/prime.txt"
    elapsed=$(( $(date +%s) - started ))
    [ "$status" -eq 0 ]
    [ "${elapsed}" -lt 4 ]
    [[ "$output" == *"1 documents could not be read (see --status): timed out"* ]]
}

@test "corpus: --summary groups documents that could not be read by why, still naming no file" {
    printf 'broken' > "${CLIENT}/received/broken.pptx"
    command -v pdftotext >/dev/null && printf 'not a real pdf file at all\n' > "${CLIENT}/received/broken.pdf"
    update_prints
    run python3 "${GUARD_ROOT}/scanners/corpus-scan.py" --summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a valid Office document: 1"* ]]
    [[ "$output" != *"broken.pptx"* ]]
    [[ "$output" != *"broken.pdf"* ]]
}
