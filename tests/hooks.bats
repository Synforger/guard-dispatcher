#!/usr/bin/env bats
# Integration tests for the three dispatcher hooks against fixture repos.

load helpers

setup() {
    setup_words
}

# --- pre-commit ---------------------------------------------------------------

@test "pre-commit: other repo is a no-op" {
    mk_repo other
    echo "${SENTINEL}" > leak.txt
    git add leak.txt
    run_pre_commit
    [ "$status" -eq 0 ]
}

@test "pre-commit: exempt repo is a no-op even with a flagged file" {
    mk_repo synforger
    git config guard.scope exempt
    echo "${SENTINEL}" > leak.txt
    git add leak.txt
    run_pre_commit
    [ "$status" -eq 0 ]
}

@test "pre-commit: clean staged file passes on enforced repo" {
    mk_repo synforger
    echo "harmless" > ok.txt
    git add ok.txt
    run_pre_commit
    [ "$status" -eq 0 ]
}

@test "pre-commit: flagged staged file is blocked" {
    mk_repo synforger
    echo "contains ${SENTINEL} here" > leak.txt
    git add leak.txt
    run_pre_commit
    [ "$status" -eq 1 ]
}

@test "pre-commit: wrong user.email is blocked" {
    mk_repo synforger
    git config user.email "someone@example.com"
    echo "harmless" > ok.txt
    git add ok.txt
    run_pre_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"identity mismatch"* ]]
}

@test "pre-commit: failing repo-local hook fails the commit (AND)" {
    mk_repo synforger
    mkdir -p .githooks
    printf '#!/bin/bash\nexit 1\n' > .githooks/pre-commit
    chmod +x .githooks/pre-commit
    run_pre_commit
    [ "$status" -eq 1 ]
}

@test "pre-commit: passing repo-local hook does not skip the baseline (AND)" {
    mk_repo synforger
    mkdir -p .githooks
    printf '#!/bin/bash\nexit 0\n' > .githooks/pre-commit
    chmod +x .githooks/pre-commit
    echo "contains ${SENTINEL} here" > leak.txt
    git add leak.txt
    run_pre_commit
    [ "$status" -eq 1 ]
}

# --- commit-msg ---------------------------------------------------------------

@test "commit-msg: clean message passes" {
    mk_repo synforger
    msg="${BATS_TEST_TMPDIR}/msg.txt"
    echo "feat: harmless change" > "${msg}"
    run_commit_msg "${msg}"
    [ "$status" -eq 0 ]
}

@test "commit-msg: flagged message is blocked" {
    mk_repo synforger
    msg="${BATS_TEST_TMPDIR}/msg.txt"
    echo "feat: mention ${SENTINEL}" > "${msg}"
    run_commit_msg "${msg}"
    [ "$status" -eq 1 ]
}

@test "commit-msg: other repo is a no-op even with a flagged message" {
    mk_repo other
    msg="${BATS_TEST_TMPDIR}/msg.txt"
    echo "feat: mention ${SENTINEL}" > "${msg}"
    run_commit_msg "${msg}"
    [ "$status" -eq 0 ]
}

# --- pre-push -----------------------------------------------------------------

@test "pre-push: clean outgoing range passes" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
}

@test "pre-push: flagged blob in outgoing range is blocked" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: sneaky"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 1 ]
}

@test "pre-push: direct push to main is refused" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/main ${head} refs/heads/main ${base}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refused"* ]]
}

@test "pre-push: initial branch-creating push to main is allowed" {
    mk_repo synforger
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/main ${head} refs/heads/main ${ZERO_SHA}"
    [ "$status" -eq 0 ]
}

@test "pre-push: GUARD_ALLOW_PROTECTED_PUSH=1 overrides the refusal" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    GUARD_ALLOW_PROTECTED_PUSH=1 run_pre_push "refs/heads/main ${head} refs/heads/main ${base}"
    [ "$status" -eq 0 ]
}

@test "pre-push: delete push is skipped" {
    mk_repo synforger
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${ZERO_SHA} refs/heads/feature/x ${head}"
    [ "$status" -eq 0 ]
}

@test "pre-push: flagged branch name is blocked" {
    mk_repo synforger
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/${SENTINEL} ${head} refs/heads/feature/${SENTINEL} ${ZERO_SHA}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ref name"* ]]
}

@test "pre-push: unexpected author in outgoing range is blocked" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt
    git -c core.hooksPath=/dev/null -c user.email=intruder@example.com commit -q -m "feat: wrong identity"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unexpected author"* ]]
}

@test "pre-push: empty stdin passes" {
    mk_repo synforger
    run_pre_push ""
    [ "$status" -eq 0 ]
}

@test "pre-push: rewritten-history force push falls back to full scan" {
    mk_repo synforger
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    unknown_sha="1111111111111111111111111111111111111111"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${unknown_sha}"
    [ "$status" -eq 0 ]
}
