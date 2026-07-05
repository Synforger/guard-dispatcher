#!/usr/bin/env bats
# Unit tests for git-hooks/lib/dispatcher-common.sh helpers.

load helpers

setup() {
    setup_words
    . "${GUARD_ROOT}/git-hooks/lib/dispatcher-common.sh"
}

@test "detect_repo_kind: synforger org URL (ssh)" {
    mk_repo synforger
    [ "$(dispatcher::detect_repo_kind)" = "synforger" ]
}

@test "detect_repo_kind: synforger via custom host alias" {
    mk_repo no-remote
    git remote add origin "git@github-synforger:Synforger/x.git"
    [ "$(dispatcher::detect_repo_kind)" = "synforger" ]
}

@test "detect_repo_kind: https form" {
    mk_repo no-remote
    git remote add origin "https://github.com/Synforger/x.git"
    [ "$(dispatcher::detect_repo_kind)" = "synforger" ]
}

@test "detect_repo_kind: other org" {
    mk_repo other
    [ "$(dispatcher::detect_repo_kind)" = "other" ]
}

@test "detect_repo_kind: no remote is fail-safe" {
    mk_repo no-remote
    [ "$(dispatcher::detect_repo_kind)" = "no-remote" ]
}

@test "protected_branch: main and develop are protected, feature is not" {
    dispatcher::protected_branch "refs/heads/main"
    dispatcher::protected_branch "refs/heads/develop"
    ! dispatcher::protected_branch "refs/heads/feature/x"
    ! dispatcher::protected_branch "refs/tags/v1.0.0"
}

@test "allowed_emails: contains the GitHub squash-merge committer" {
    dispatcher::allowed_emails | grep -Fxq "noreply@github.com"
}

@test "locate_scanner: bundled fallback when repo has no local toolkit" {
    mk_repo synforger
    [ "$(dispatcher::locate_scanner anon-scan.sh)" = "${GUARD_ROOT}/scanners/anon-scan.sh" ]
}

@test "locate_scanner: repo-local copy wins over bundled" {
    mk_repo synforger
    mkdir -p .tooling/local-ci
    echo '#!/bin/bash' > .tooling/local-ci/anon-scan.sh
    # Compare against git's physical toplevel — on macOS $BATS_TEST_TMPDIR
    # sits behind the /tmp symlink, so pwd and rev-parse can disagree.
    [ "$(dispatcher::locate_scanner anon-scan.sh)" = "$(git rev-parse --show-toplevel)/.tooling/local-ci/anon-scan.sh" ]
}

@test "guard_root: resolves through a symlinked hooks dir" {
    fake="${BATS_TEST_TMPDIR}/fake-git-hooks"
    mkdir -p "${fake}"
    ln -s "${GUARD_ROOT}/git-hooks/lib" "${fake}/lib"
    result="$(bash -c ". '${fake}/lib/dispatcher-common.sh'; dispatcher::guard_root")"
    [ "${result}" = "${GUARD_ROOT}" ]
}

@test "default_branch: falls back to an existing origin branch when origin/HEAD is stale" {
    mk_repo synforger
    git branch -q main 2>/dev/null || true
    git update-ref refs/remotes/origin/main HEAD
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone-branch
    [ "$(dispatcher::default_branch)" = "main" ]
}

@test "detect_repo_kind: guard.scope=enforced wins over URL classification" {
    mk_repo other
    git config guard.scope enforced
    [ "$(dispatcher::detect_repo_kind)" = "enforced" ]
}

@test "detect_repo_kind: unrelated guard.scope value falls through" {
    mk_repo other
    git config guard.scope observer
    [ "$(dispatcher::detect_repo_kind)" = "other" ]
}

@test "detect_repo_kind: guard.scope=exempt overrides no-remote fail-safe" {
    mk_repo no-remote
    git config guard.scope exempt
    [ "$(dispatcher::detect_repo_kind)" = "exempt" ]
}

@test "detect_repo_kind: guard.scope=exempt overrides synforger URL" {
    mk_repo synforger
    git config guard.scope exempt
    [ "$(dispatcher::detect_repo_kind)" = "exempt" ]
}

@test "detect_repo_kind: guard.exemptPrefix opts a repo out by working-tree path" {
    # Resolve the tmpdir to its physical path — on macOS /tmp is a symlink
    # to /private/tmp and git rev-parse --show-toplevel emits the resolved
    # form, so the exemptPrefix must match that form.
    local root="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
    local sandbox="${root}/private-state"
    mkdir -p "${sandbox}"
    git init -q "${sandbox}/inner"
    cd "${sandbox}/inner"
    git remote add origin "https://github.com/someone-else/x.git"
    git config --local guard.exemptPrefix "${sandbox}"
    [ "$(dispatcher::detect_repo_kind)" = "exempt" ]
}

@test "detect_repo_kind: guard.exemptPrefix does not match a sibling path" {
    local root="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
    mk_repo other
    # Point the prefix at a directory the repo does NOT sit under.
    git config --local guard.exemptPrefix "${root}/somewhere-else"
    [ "$(dispatcher::detect_repo_kind)" = "other" ]
}

@test "detect_repo_kind: guard.exemptPrefix expands a leading tilde" {
    export HOME="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
    local sandbox="${HOME}/private-state"
    mkdir -p "${sandbox}"
    git init -q "${sandbox}/inner"
    cd "${sandbox}/inner"
    git remote add origin "https://github.com/someone-else/x.git"
    git config --local guard.exemptPrefix "~/private-state"
    [ "$(dispatcher::detect_repo_kind)" = "exempt" ]
}

@test "allowed_emails: guard.allowedEmails overrides the built-in list" {
    mk_repo no-remote
    git config guard.allowedEmails "a@users.noreply.github.com, noreply@github.com"
    run dispatcher::allowed_emails
    [ "${lines[0]}" = "a@users.noreply.github.com" ]
    [ "${lines[1]}" = "noreply@github.com" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "allowed_emails: built-in list without the override" {
    mk_repo no-remote
    run dispatcher::allowed_emails
    [ "${lines[0]}" = "synforge.dev@gmail.com" ]
    [ "${#lines[@]}" -eq 3 ]
}
