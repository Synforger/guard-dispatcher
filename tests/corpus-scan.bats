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

@test "corpus: one row of a CSV is caught on its own" {
    printf 'id,label,score\n4411,acme-left-sleeve-measurement-batch,0.8731\n' > "${CLIENT}/received/table.csv"
    mk_repo other
    commit_line "4411,acme-left-sleeve-measurement-batch,0.8731"
    scan_last
    [ "$status" -eq 1 ]
}

# mk_pdf <path> <text> — a one-page PDF whose text layer holds <text> (ASCII).
mk_pdf() {
    python3 - "$1" "$2" <<'PY'
import sys
path, text = sys.argv[1], sys.argv[2]
stream = f"BT /F1 10 Tf 20 700 Td ({text}) Tj ET".encode()
objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out, offsets = b"%PDF-1.4\n", []
for i, body in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(path, "wb").write(out)
PY
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

@test "corpus: when Spotlight cannot answer, everything is walked again" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    printf '#!/bin/sh\necho "\tIndexing disabled."\n' > "${STUB}/mdutil"
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last
    printf 'the dye lot for the spring run arrives on the ninth\n' > "${CLIENT}/received/late.md"
    commit_line "the dye lot for the spring run arrives on the ninth"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
    [[ "$output" == *"walking the private documents"* ]]
}

@test "corpus: when Spotlight does not index an area, everything is walked again" {
    export GUARD_CORPUS_MAX_AGE=3600
    spotlight_stub ""
    printf '#!/bin/sh\nexit 0\n' > "${STUB}/mdfind"     # finds nothing, not even a known document
    mk_repo other
    commit_line "nothing private"
    PATH="${STUB}:${PATH}" scan_last
    printf 'the dye lot for the spring run arrives on the ninth\n' > "${CLIENT}/received/late.md"
    commit_line "the dye lot for the spring run arrives on the ninth"
    PATH="${STUB}:${PATH}" scan_last
    [ "$status" -eq 1 ]
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
    ln -sf "${GUARD_ROOT}/scripts/gh-guard.sh" "${SHIM_DIR}/gh"
    printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "${BATS_TEST_TMPDIR}" > "${REAL_DIR}/gh"
    chmod +x "${REAL_DIR}/gh"
    mk_repo other
    PATH="${SHIM_DIR}:${REAL_DIR}:${PATH}" run gh pr comment 1 --body "see: ${CLIENT_TEXT}"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}
