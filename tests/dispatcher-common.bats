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
