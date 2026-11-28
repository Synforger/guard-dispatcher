#!/usr/bin/env bats
# Which repositories get their own `.githooks/<hook>` run by the dispatcher: a repository the
# machine trusts (the Synforger org, an owner named in `guard.hookOwners`, or a repository that
# `guard.localHooks` allows) and no other. The hook of a repository that is not trusted is not
# run; the dispatcher's own checks run either way.

load ../_internal/helpers

HOOK_JUDGE="${GUARD_ROOT}/git-hooks/_internal/hook_trust.py"

setup() {
    setup_words
    # The settings of the machine this runs on are not the fixtures': a test gives its own.
    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/global.gitconfig"
    : > "${GIT_CONFIG_GLOBAL}"
    export GIT_CONFIG_NOSYSTEM=1
    MARK="${BATS_TEST_TMPDIR}/hook-ran"
}

# add_hook <hook name> [exit code] — a repo hook that only writes the mark file.
add_hook() {
    mkdir -p .githooks
    printf '#!/bin/bash\nprintf ran >> "%s"\nexit %s\n' "${MARK}" "${2:-0}" > ".githooks/$1"
    chmod +x ".githooks/$1"
}

# judge <fetch url> [owners] — the verdict of the judging file alone: exit 0 = trusted.
judge() {
    run python3 "${HOOK_JUDGE}" --local-hooks unset --owners "${2:-}" --url "$1"
}

# --- the dispatcher's three hooks ------------------------------------------------

@test "a repository of another owner: its pre-commit hook is not run, and the commit goes on" {
    mk_repo other
    add_hook pre-commit 1
    echo "harmless" > ok.txt
    git add ok.txt
    run_pre_commit
    [ "$status" -eq 0 ]
    [ ! -e "${MARK}" ]
}

@test "a repository of another owner: the line says what was not run and which settings allow it" {
    mk_repo other
    add_hook pre-commit
    run_pre_commit
    [[ "$output" == *"not run"* ]]
    [[ "$output" == *".githooks/pre-commit"* ]]
    [[ "$output" == *"guard.localHooks"* ]]
    [[ "$output" == *"guard.hookOwners"* ]]
}

@test "a repository of another owner: a repository with no hook gets no line" {
    mk_repo other
    run_pre_commit
    [[ "$output" != *"not run"* ]]
}

@test "a repository of another owner: the dispatcher's own scan still runs" {
    mk_repo other
    add_hook pre-commit
    echo "contains ${SENTINEL} here" > leak.txt
    git add leak.txt
    run_pre_commit
    [ "$status" -ne 0 ]
    [ ! -e "${MARK}" ]
}

@test "a repository of another owner: its commit-msg hook is not run" {
    mk_repo other
    add_hook commit-msg 1
    printf 'a message\n' > "${BATS_TEST_TMPDIR}/message"
    run_commit_msg "${BATS_TEST_TMPDIR}/message"
    [ "$status" -eq 0 ]
    [ ! -e "${MARK}" ]
    [[ "$output" == *".githooks/commit-msg"* ]]
}

@test "a repository of another owner: its pre-push hook is not run" {
    mk_repo other
    add_hook pre-push 1
    local head
    head="$(git rev-parse HEAD)"
    run_pre_push_to "${OTHER_URL}" "refs/heads/feature ${head} refs/heads/feature 0000000000000000000000000000000000000000"
    [ ! -e "${MARK}" ]
    [[ "$output" == *".githooks/pre-push"* ]]
}

@test "the Synforger org: its pre-commit hook is run and a failing one fails the commit" {
    mk_repo synforger
    add_hook pre-commit 1
    run_pre_commit
    [ "$status" -eq 1 ]
    [ -e "${MARK}" ]
}

@test "the Synforger org: its pre-push hook is run and gets the ref lines on stdin" {
    mk_repo synforger
    mkdir -p .githooks
    printf '#!/bin/bash\ncat > "%s"\n' "${MARK}" > .githooks/pre-push
    chmod +x .githooks/pre-push
    local head line
    head="$(git rev-parse HEAD)"
    line="refs/heads/feature ${head} refs/heads/feature 0000000000000000000000000000000000000000"
    run_pre_push "${line}"
    [ "$(cat "${MARK}")" = "${line}" ]
}

@test "a repository with no origin: its hook is not run" {
    mk_repo no-remote
    add_hook pre-commit
    run_pre_commit
    [ ! -e "${MARK}" ]
    [[ "$output" == *"not run"* ]]
}

# --- the settings that allow a repository -----------------------------------------

@test "guard.localHooks in the repository's own config allows its hook" {
    mk_repo other
    add_hook pre-commit
    git config guard.localHooks true
    run_pre_commit
    [ -e "${MARK}" ]
}

@test "guard.localHooks in the machine's config (an includeIf file) allows its hook" {
    mk_repo other
    add_hook pre-commit
    local included="${BATS_TEST_TMPDIR}/trusted.gitconfig"
    printf '[guard]\n\tlocalHooks = true\n' > "${included}"
    printf '[includeIf "gitdir:%s/"]\n\tpath = %s\n' "${BATS_TEST_TMPDIR}" "${included}" > "${GIT_CONFIG_GLOBAL}"
    run_pre_commit
    [ -e "${MARK}" ]
}

@test "guard.localHooks false does not allow a repository of another owner" {
    mk_repo other
    add_hook pre-commit
    git config guard.localHooks false
    run_pre_commit
    [ ! -e "${MARK}" ]
}

@test "guard.localHooks allows a repository with no origin" {
    mk_repo no-remote
    add_hook pre-commit
    git config guard.localHooks true
    run_pre_commit
    [ -e "${MARK}" ]
}

@test "guard.hookOwners allows the repositories of the owners it names" {
    mk_repo other
    add_hook pre-commit
    git config guard.hookOwners "first-owner, Someone-Else ,third-owner"
    run_pre_commit
    [ -e "${MARK}" ]
}

@test "guard.hookOwners in the machine's config allows the owners it names" {
    mk_repo other
    add_hook pre-commit
    printf '[guard]\n\thookOwners = someone-else\n' > "${GIT_CONFIG_GLOBAL}"
    run_pre_commit
    [ -e "${MARK}" ]
}

@test "guard.hookOwners does not allow an owner it does not name, nor a part of a name" {
    mk_repo other
    add_hook pre-commit
    git config guard.hookOwners "someone,else,someone-else-2"
    run_pre_commit
    [ ! -e "${MARK}" ]
}

@test "guard.hookOwners does not allow a repository with no origin" {
    mk_repo no-remote
    add_hook pre-commit
    git config guard.hookOwners "someone-else"
    run_pre_commit
    [ ! -e "${MARK}" ]
}

@test "a repository whose address is rewritten by the machine's config is judged by the rewritten address" {
    mk_repo no-remote
    add_hook pre-commit
    git remote add origin "fixture:repo.git"
    printf '[url "git@github.com:Synforger/"]\n\tinsteadOf = fixture:\n' > "${GIT_CONFIG_GLOBAL}"
    run_pre_commit
    [ -e "${MARK}" ]
}

# --- the address: which are of GitHub, and whose --------------------------------------

@test "address: GitHub addresses of the org, in every form and case, are trusted" {
    local url
    for url in \
        "https://github.com/Synforger/x.git" \
        "https://github.com/synforger/x" \
        "https://github.com/SYNFORGER/x/" \
        "https://someone:token@github.com/Synforger/x.git" \
        "https://GitHub.com:443/Synforger/x.git" \
        "ssh://git@github.com/Synforger/x.git" \
        "ssh://git@github.com:22/Synforger/x.git" \
        "git@github.com:Synforger/x.git" \
        "git@github.com:Synforger/x" \
        "github.com:Synforger/x.git" \
        "git@github-synforger:Synforger/x.git" \
        "ssh://git@github-work/Synforger/x.git"; do
        judge "${url}"
        [ "$status" -eq 0 ] || { echo "not trusted: ${url}"; return 1; }
    done
}

@test "address: a host that is not GitHub, or a path that is not owner/repo, is not trusted" {
    local url
    for url in \
        "https://example.com/github.com/Synforger/x.git" \
        "https://github.com@example.com/Synforger/x.git" \
        "https://github.com.example.com/Synforger/x.git" \
        "https://github-work/Synforger/x.git" \
        "https://example.com/github-work/Synforger/x.git" \
        "http://github.com/Synforger/x.git" \
        "git://github.com/Synforger/x.git" \
        "https://github.com/Synforger/x/y" \
        "https://github.com/Synforger" \
        "https://github.com/Synforger-two/x.git" \
        "https://github.com/two-Synforger/x.git" \
        "git@example.com:github/Synforger/x.git" \
        "git@example.com:github-work/Synforger/x.git" \
        "git@github.example.com:Synforger/x.git" \
        "git@github-work.example.com:Synforger/x.git" \
        "git@github-:Synforger/x.git" \
        "ssh://git@example.com/github.com/Synforger/x.git" \
        "/srv/github.com/Synforger/x.git" \
        "../github.com/Synforger/x.git" \
        "file:///srv/github.com/Synforger/x.git" \
        'https://github.com\@example.com/Synforger/x.git' \
        "" ; do
        judge "${url}"
        [ "$status" -ne 0 ] || { echo "trusted: ${url}"; return 1; }
    done
}

@test "address: an owner is judged by its first path segment, whatever the case" {
    judge "https://github.com/Someone-Else/x.git" "someone-else"
    [ "$status" -eq 0 ]
    judge "git@github-work:someone-ELSE/x.git" "Someone-Else"
    [ "$status" -eq 0 ]
    judge "https://github.com/someone-else/x.git" "someone"
    [ "$status" -ne 0 ]
    judge "https://example.com/someone-else/x.git" "someone-else"
    [ "$status" -ne 0 ]
}

@test "address: an owner list with empty entries trusts nobody extra" {
    judge "https://github.com/x/y.git" ",, ,"
    [ "$status" -ne 0 ]
}
