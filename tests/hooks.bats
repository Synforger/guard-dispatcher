#!/usr/bin/env bats
# Integration tests for the three dispatcher hooks against fixture repos.

load helpers

setup() {
    setup_words
}

# --- pre-commit ---------------------------------------------------------------

@test "pre-commit: other repo is scanned (default-on) and blocked on a leak" {
    mk_repo other
    echo "${SENTINEL}" > leak.txt
    git add leak.txt
    run_pre_commit
    [ "$status" -ne 0 ]
}

@test "pre-commit: other repo keeps its own committer identity (no identity enforcement)" {
    mk_repo other
    git config user.email "someone-else@example.com"
    echo "clean content" > ok.txt
    git add ok.txt
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

@test "pre-commit: staged leak is caught even when the worktree copy was cleaned afterwards" {
    mk_repo synforger
    echo "contains ${SENTINEL} here" > leak.txt
    git add leak.txt
    echo "clean now" > leak.txt
    run_pre_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"STAGED content"* ]]
}

@test "pre-commit: unstaged worktree leak does not block a clean staged commit" {
    mk_repo synforger
    echo "harmless" > ok.txt
    git add ok.txt
    echo "${SENTINEL}" >> ok.txt
    run_pre_commit
    [ "$status" -eq 0 ]
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

@test "commit-msg: other repo is scanned (default-on) and blocked on a flagged message" {
    mk_repo other
    msg="${BATS_TEST_TMPDIR}/msg.txt"
    echo "feat: mention ${SENTINEL}" > "${msg}"
    run_commit_msg "${msg}"
    [ "$status" -ne 0 ]
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

@test "pre-push: other repo is scanned (default-on) and blocked on a leak" {
    mk_repo other
    base="$(git rev-parse HEAD)"
    echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: sneaky"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 1 ]
}

@test "pre-push: other repo keeps its own author (no identity enforcement)" {
    mk_repo other
    base="$(git rev-parse HEAD)"
    echo "clean content" > ok.txt
    git add ok.txt
    git -c user.email=someone-else@example.com commit -q -m "feat: third-party author"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
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

@test "pre-push: direct push to develop on a remote without pull requests is allowed" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    run_pre_push_to "ssh://rail-host/~/pipeline" "refs/heads/develop ${head} refs/heads/develop ${base}"
    [ "$status" -eq 0 ]
}

@test "pre-push: direct push to develop on a GitHub host alias is still refused" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    run_pre_push_to "github-work:org/repo.git" "refs/heads/develop ${head} refs/heads/develop ${base}"
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

@test "pre-push: new branch scans only commits missing from the remote" {
    mk_repo synforger
    # A flagged commit that is already published (reachable from a
    # remote-tracking ref) must not block a new branch whose actual
    # outgoing delta is clean.
    echo "${SENTINEL}" > old-leak.txt && git add old-leak.txt && commit_bypassing_hooks "feat: published leak"
    git update-ref refs/remotes/origin/develop HEAD
    echo "clean" > clean.txt && git add clean.txt && commit_bypassing_hooks "feat: clean on top"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${ZERO_SHA}"
    [ "$status" -eq 0 ]
}

@test "pre-push: new branch with an already-public tip is skipped" {
    mk_repo synforger
    echo "${SENTINEL}" > old-leak.txt && git add old-leak.txt && commit_bypassing_hooks "feat: published leak"
    git update-ref refs/remotes/origin/develop HEAD
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${ZERO_SHA}"
    [ "$status" -eq 0 ]
}

@test "pre-push: new branch with fresh history is scanned in full" {
    mk_repo synforger
    # No remote-tracking refs exist, so nothing is provably public —
    # the whole new history is scanned and the leak is caught.
    echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: sneaky"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${ZERO_SHA}"
    [ "$status" -eq 1 ]
}

@test "pre-push: tags on a history already scanned in the same push are not scanned again" {
    mk_repo synforger
    echo "a" > a.txt && git add a.txt && commit_bypassing_hooks "feat: a"
    git tag v1
    echo "b" > b.txt && git add b.txt && commit_bypassing_hooks "feat: b"
    git tag v2
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/main ${head} refs/heads/main ${ZERO_SHA}" \
                 "refs/tags/v1 $(git rev-parse v1) refs/tags/v1 ${ZERO_SHA}" \
                 "refs/tags/v2 $(git rev-parse v2) refs/tags/v2 ${ZERO_SHA}"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c 'anon-audit-deep --range')" -eq 1 ]
}

@test "pre-push: a ref beyond what the push already scanned is scanned for its own commits" {
    mk_repo synforger
    main="$(git rev-parse HEAD)"
    git switch -q -c side
    echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: sneaky"
    side="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/main ${main} refs/heads/main ${ZERO_SHA}" \
                 "refs/heads/side ${side} refs/heads/side ${ZERO_SHA}"
    [ "$status" -eq 1 ]
    [[ "${output}" == *"anon-audit-deep --range ${main}..${side}"* ]]
}

# mk_joined <last-commit-command...> — lines a and b off the seed, a merge of
# them, and one more commit made by the given command. Sets a, b, joined.
mk_joined() {
    local seed
    seed="$(git rev-parse HEAD)"
    echo "a" > a.txt && git add a.txt && commit_bypassing_hooks "feat: a"
    a="$(git rev-parse HEAD)"
    git switch -q -c side "${seed}"
    echo "b" > b.txt && git add b.txt && commit_bypassing_hooks "feat: b"
    b="$(git rev-parse HEAD)"
    git switch -q -c joined "${a}"
    git merge -q --no-edit side
    "$@"
    joined="$(git rev-parse HEAD)"
}

push_joined() {
    run_pre_push "refs/heads/main ${a} refs/heads/main ${ZERO_SHA}" \
                 "refs/heads/side ${b} refs/heads/side ${ZERO_SHA}" \
                 "refs/heads/joined ${joined} refs/heads/joined ${ZERO_SHA}"
}

leak_commit() { echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: sneaky"; }
stranger_commit() {
    echo "c" > c.txt && git add c.txt
    GIT_AUTHOR_EMAIL=stranger@example.com commit_bypassing_hooks "feat: c"
}

@test "pre-push: a ref joining several scanned lines is scanned for exactly its own commits" {
    mk_repo synforger
    mk_joined leak_commit
    push_joined
    [ "$status" -eq 1 ]
    [[ "${output}" == *"push range mode (${joined} ^"*", 2 commits)"* ]]
}

@test "pre-push: an unexpected author is caught in a range with several bases" {
    mk_repo synforger
    mk_joined stranger_commit
    push_joined
    [ "$status" -eq 1 ]
    [[ "${output}" == *"stranger@example.com"* ]]
}
