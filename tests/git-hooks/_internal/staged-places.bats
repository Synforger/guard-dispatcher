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

# commit <git commit words...>: a real commit through the guard's hooks, so the hook reads the
# command it runs under. commit_here runs one without `run`, commit_unguarded one with no hooks.
commit() {
    run git -c core.hooksPath="${GUARD_ROOT}/git-hooks" commit -q -m "notes" "$@"
}

commit_here() {
    local words=()
    if [ "${1:-}" = "-C" ]; then
        words=(-C "$2")
        shift 2
    fi
    git -c core.hooksPath="${GUARD_ROOT}/git-hooks" "${words[@]}" commit -q -m "notes" "$@"
}

commit_unguarded() {
    git -c core.hooksPath=/dev/null commit -q -m "seed"
}

set_scope() {
    git config guard.scope "$1"
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

@test "staged places: the session's own folder and shared files pass" {
    stage projects/alpha/subprojects/one/journal.md rules/always.md
    run_pre_commit
    [ "$status" -eq 0 ]
}

@test "staged places: a file of the tier above or below passes when the commit names it" {
    mkdir -p projects/alpha/subprojects/one/subprojects/deeper
    stage projects/alpha/subprojects/one/journal.md projects/alpha/vision.md \
        projects/alpha/subprojects/one/subprojects/deeper/notes.md
    commit -- projects/alpha/subprojects/one/journal.md projects/alpha/vision.md \
        projects/alpha/subprojects/one/subprojects/deeper/notes.md
    [ "$status" -eq 0 ]
    [ -z "$(git status --porcelain -- projects)" ]
}

@test "staged places: the names are read from where git stands, -C included" {
    stage projects/alpha/vision.md
    (cd projects/alpha/subprojects && commit_here -- ../vision.md)
    echo "more" > projects/alpha/vision.md
    git add projects/alpha/vision.md
    commit_here -C projects -- alpha/vision.md
    [ -z "$(git status --porcelain -- projects)" ]
}

@test "staged places: a named file with a space in its name passes" {
    stage "projects/alpha/the notes.md"
    commit -- "projects/alpha/the notes.md"
    [ "$status" -eq 0 ]
}

@test "staged places: a change another tab staged in the tier above or below stops a commit that does not name it" {
    stage projects/alpha/vision.md
    echo "mine" > projects/alpha/subprojects/one/journal.md
    git add projects/alpha/subprojects/one/journal.md
    commit
    [ "$status" -ne 0 ]
    [[ "$output" == *"projects/alpha/vision.md lies in the work folder ${REPO}/projects/alpha, a tier above or below"* ]]
    [[ "$output" != *"journal.md lies"* ]]
}

@test "staged places: a removal another tab staged in the tier above stops a commit that does not name it" {
    stage projects/alpha/old.md
    commit_unguarded
    git rm -q projects/alpha/old.md
    echo "mine" > projects/alpha/subprojects/one/journal.md
    git add projects/alpha/subprojects/one/journal.md
    commit
    [ "$status" -ne 0 ]
    [[ "$output" == *"projects/alpha/old.md lies in the work folder"* ]]
}

@test "staged places: a folder or -a does not name the files of another tier inside it" {
    mkdir -p projects/alpha/subprojects/one/subprojects/deeper
    stage projects/alpha/subprojects/one/subprojects/deeper/notes.md
    commit -- projects/alpha/subprojects/one
    [ "$status" -ne 0 ]
    [[ "$output" == *"deeper/notes.md lies in the work folder"* ]]
    commit -a
    [ "$status" -ne 0 ]
}

@test "staged places: a file of a tier beside stops the commit even when named" {
    stage projects/beta/picture.md
    commit -- projects/beta/picture.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"projects/beta/picture.md lies in another tab's work folder"* ]]
}

@test "staged places: an exempt repository is judged too" {
    set_scope exempt
    stage projects/beta/picture.md
    run_pre_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"projects/beta/picture.md lies in another tab's work folder"* ]]
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

@test "staged places: the normal tier, working at the checkout's top, takes every path it names" {
    export GUARD_WORK_FOLDER="${REPO}"
    stage projects/beta/picture.md projects/alpha/subprojects/two/memo.md
    commit -- projects/beta/picture.md projects/alpha/subprojects/two/memo.md
    [ "$status" -eq 0 ]
    stage projects/beta/more.md
    commit
    [ "$status" -ne 0 ]
    [[ "$output" == *"projects/beta/more.md lies in the work folder"* ]]
}
