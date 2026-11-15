#!/usr/bin/env bats
# git-hooks/_internal/staged_places.py through the pre-commit dispatcher: a commit an agent's
# session makes takes no path another tab left in its own work folder.
#
# A fixture repository stands for an agent's checkout: `projects/<p>` and
# `projects/<p>/subprojects/<s>` are the tabs' work folders, the rest is shared.

load ../../_internal/helpers

setup() {
    setup_words
    mk_repo other
    REPO="$(pwd -P)"
    mkdir -p projects/alpha/subprojects/one projects/alpha/subprojects/two projects/beta rules "${GUARD_CONFIG_DIR}"
    printf '%s\n' "# the tabs' work folders" "${REPO}/projects/*" "${REPO}/projects/*/**/subprojects/*" \
        > "${GUARD_CONFIG_DIR}/work-folders.txt"
    export GUARD_WORK_FOLDER="${REPO}/projects/alpha/subprojects/one"
}

stage() {
    local path
    for path in "$@"; do
        echo "notes" > "${path}"
        git add -- "${path}"
    done
}

@test "staged places: a path another tab left in its work folder stops the commit, and is named" {
    stage projects/alpha/subprojects/one/journal.md projects/beta/picture.md projects/alpha/subprojects/two/memo.md
    run_pre_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"projects/beta/picture.md lies in another tab's work folder ${REPO}/projects/beta"* ]]
    [[ "$output" == *"projects/alpha/subprojects/two/memo.md lies in another tab's work folder"* ]]
    [[ "$output" != *"subprojects/one/journal.md lies"* ]]
}

@test "staged places: the session's own folder, the tiers around it and below it, and shared files pass" {
    mkdir -p projects/alpha/subprojects/one/subprojects/deeper
    stage projects/alpha/subprojects/one/journal.md projects/alpha/vision.md \
        projects/alpha/subprojects/one/subprojects/deeper/notes.md rules/always.md
    run_pre_commit
    [ "$status" -eq 0 ]
}

@test "staged places: a removed file of another tab stops the commit too" {
    stage projects/beta/picture.md
    git -c core.hooksPath=/dev/null commit -q -m "beta's picture"
    git rm -q projects/beta/picture.md
    run_pre_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"projects/beta/picture.md lies in another tab's work folder"* ]]
}

@test "staged places: a commit with no work folder named, or no work-folders.txt, is not judged" {
    stage projects/beta/picture.md
    GUARD_WORK_FOLDER="" run_pre_commit
    [ "$status" -eq 0 ]
    rm "${GUARD_CONFIG_DIR}/work-folders.txt"
    run_pre_commit
    [ "$status" -eq 0 ]
}

@test "staged places: the normal tier, working at the checkout's top, takes every path" {
    export GUARD_WORK_FOLDER="${REPO}"
    stage projects/beta/picture.md projects/alpha/subprojects/two/memo.md
    run_pre_commit
    [ "$status" -eq 0 ]
}
