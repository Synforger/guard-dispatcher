#!/usr/bin/env bats
# Integration tests for the three dispatcher hooks against fixture repos.

load ../_internal/helpers

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

# in_agent_folder <path below the agent> — a repository with no remote inside an agent's own
# folder of a made-up platform, and cd into it; its committer is no one the guard allows.
in_agent_folder() {
    export AGENT_PLATFORM_ROOT="${BATS_TEST_TMPDIR}/platform"
    local dir="${AGENT_PLATFORM_ROOT}/agents/agent-a/$1"
    mkdir -p "${dir}"
    git init -q "${dir}"
    cd "${dir}" || return 1
    git config user.email "someone@example.com"
    git config user.name "Someone"
}

@test "pre-commit: a repository in an agent's own folder with no scope is corpus, so its first commit passes" {
    in_agent_folder projects/tier-a
    echo "${SENTINEL} in the agent's notes" > journal.md
    git add journal.md
    run_pre_commit
    [ "$status" -eq 0 ]
    printf 'journal: %s\n' "${SENTINEL}" > "${BATS_TEST_TMPDIR}/message"
    run_commit_msg "${BATS_TEST_TMPDIR}/message"
    [ "$status" -eq 0 ]
}

@test "pre-commit: a scope a repository in an agent's folder names wins, and outside it no-remote stays enforced" {
    in_agent_folder projects/tier-b
    git config guard.scope enforced
    echo "harmless" > ok.txt
    git add ok.txt
    run_pre_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"identity mismatch"* ]]
    mk_repo no-remote
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

@test "commit-msg: a corpus-scope repository's messages are not word-scanned" {
    mk_repo other
    git config guard.scope corpus
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
    run_pre_push_to "$(git remote get-url origin)" "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
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

@test "pre-push: direct push to develop is refused when only the destination is the org's" {
    # A clone made from a bundle or a local path: origin names no host.
    mk_repo other
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    run_pre_push_to "git@github.com:Synforger/some-tool.git" "refs/heads/develop ${head} refs/heads/develop ${base}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"direct push to refs/heads/develop refused"* ]]
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

@test "pre-push: a colleague's commit another remote already holds passes on to a new remote" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "theirs" > theirs.txt && git add theirs.txt
    git -c core.hooksPath=/dev/null -c user.email=12345+colleague@users.noreply.github.com commit -q -m "feat: a colleague's work"
    # fetched from the org: a tracking ref of another remote holds it
    git update-ref refs/remotes/upstream/develop HEAD
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/develop ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
    # a commit made here on top of it is still checked
    echo "mine" > mine.txt && git add mine.txt
    git -c core.hooksPath=/dev/null -c user.email=intruder@example.com commit -q -m "feat: wrong identity"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/develop ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"intruder@example.com"* ]]
    [[ "$output" != *"colleague"* ]]
}

@test "pre-push: GitHub's own workflow bot, with no id in front, is a bot account" {
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "1.2.3" > VERSION && git add VERSION
    git -c core.hooksPath=/dev/null -c user.name='github-actions[bot]' \
        -c user.email='github-actions[bot]@users.noreply.github.com' commit -q -m "chore: bump the version"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
}

@test "pre-push: a history rewritten to take a word out keeps the authors its destination already holds" {
    mk_repo synforger
    dest="${BATS_TEST_TMPDIR}/dest.git"
    git init -q --bare "${dest}"
    echo "theirs" > theirs.txt && git add theirs.txt
    git -c core.hooksPath=/dev/null -c user.email=12345+colleague@users.noreply.github.com commit -q -m "feat: a colleague's work"
    git -c core.hooksPath=/dev/null push -q "${dest}" HEAD:refs/heads/develop
    old="$(git rev-parse HEAD)"
    # the rewrite: same author and tree, a new message, so a new hash; no remote holds it
    new="$(git -c user.email=12345+colleague@users.noreply.github.com commit-tree "HEAD^{tree}" -p HEAD~1 -m "feat: the colleague's work, reworded")"
    git update-ref refs/heads/develop "${new}"
    run bash -c "printf '%s\n' 'refs/heads/develop ${new} refs/heads/develop ${old}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${dest}'"
    [ "$status" -eq 0 ]
    # someone the destination has never carried is still stopped
    other="$(git -c user.email=intruder@example.com -c user.name=x commit-tree "HEAD^{tree}" -p "${new}" -m "feat: wrong identity")"
    run bash -c "printf '%s\n' 'refs/heads/develop ${other} refs/heads/develop ${old}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${dest}'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"intruder@example.com"* ]]
    [[ "$output" != *"colleague"* ]]
    # the fetched refs are not left behind
    [ -z "$(git for-each-ref refs/guard-dest)" ]
}

@test "pre-push: what a push sends is decided in dest-known.py alone, and every check is handed it" {
    hook="${GUARD_ROOT}/git-hooks/pre-push"
    # no check reads the history on its own (= the range, the rewrite and the authors come from it)
    run grep -nE '\bgit +(log|rev-list|merge-base|rev-parse|diff|show|cat-file)\b' "${hook}"
    [ "$status" -eq 1 ]
    # every check of the outgoing range is handed what the destination holds; a check added
    # without it makes the two counts differ (the repair that rewrites the range is no check)
    checks="$(grep -F -- '--range "${revspec}"' "${hook}" | grep -vc 'fixer')"
    handed="$(grep -F -- '--range "${revspec}"' "${hook}" | grep -v 'fixer' | grep -cF 'GUARD_DEST_KNOWN="${dest_env}"')"
    [ "${checks}" -ge 2 ]
    [ "${handed}" -eq "${checks}" ]
    # and the checks read a push range only through it, however the git call is spelled (the deep
    # scan counts the range's commits with rev-list, which judges nothing)
    run grep -nE 'git +(log|show|diff|diff-tree|cat-file|format-patch)\b.*RANGE' \
        "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -eq 1 ]
    run grep -nE '(git\(|"git",).*"(log|rev-list|diff|diff-tree|format-patch|cat-file)"' \
        "${GUARD_ROOT}/scanners/corpus/corpus-scan.py"
    [ "$status" -eq 1 ]
}

# rewrite_under_colleague — a colleague's commit that carries a word of the list in a file, in its
# text and in its author's name, already on the destination; then the history under it rewritten
# (the seed reworded), so the colleague's commit comes back with a new hash and nothing else new.
# Sets dest, old (the destination's tip) and new (the rewritten tip).
rewrite_under_colleague() {
    mk_repo synforger
    dest="${BATS_TEST_TMPDIR}/dest.git"
    git init -q --bare "${dest}"
    export GIT_AUTHOR_NAME="colleague ${SENTINEL}" GIT_AUTHOR_EMAIL=12345+colleague@users.noreply.github.com
    export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}" GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
    echo "the colleague wrote ${SENTINEL}" > theirs.txt && git add theirs.txt
    commit_bypassing_hooks "feat: ${SENTINEL} support"
    git -c core.hooksPath=/dev/null push -q "${dest}" HEAD:refs/heads/develop
    old="$(git rev-parse HEAD)"
    local seed
    seed="$(GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL="${ALLOWED_EMAIL}" GIT_COMMITTER_NAME=Fixture \
        GIT_COMMITTER_EMAIL="${ALLOWED_EMAIL}" git commit-tree "HEAD~1^{tree}" -m "seed, reworded")"
    new="$(git commit-tree "HEAD^{tree}" -p "${seed}" -m "feat: ${SENTINEL} support")"
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

@test "pre-push: a rewritten history is not word-scanned again for what its destination already holds" {
    rewrite_under_colleague
    run bash -c "printf '%s\n' 'refs/heads/develop ${new} refs/heads/develop ${old}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${dest}'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"hit(s)"* ]]
    [ -z "$(git for-each-ref refs/guard-dest)" ]
}

@test "pre-push: what a rewrite made new is word-scanned (a file, a commit text, an author's name)" {
    rewrite_under_colleague
    echo "fresh ${SENTINEL}" > fresh.txt && git add fresh.txt
    blob="$(git commit-tree "$(git write-tree)" -p "${new}" -m "feat: a fresh file")"
    text="$(git commit-tree "${new}^{tree}" -p "${new}" -m "fix: ${SENTINEL} again")"
    name="$(GIT_AUTHOR_NAME="someone ${SENTINEL}" git commit-tree "${new}^{tree}" -p "${new}" -m "fix: renamed")"
    for tip in "${blob}:git history blob" "${text}:commit messages" "${name}:author/committer"; do
        run bash -c "printf '%s\n' 'refs/heads/develop ${tip%%:*} refs/heads/develop ${old}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${dest}'"
        [ "$status" -eq 1 ]
        [[ "$output" == *"${tip#*:}: 1 hit(s)"* ]]
        [ "$(printf '%s\n' "$output" | grep -c 'hit(s)')" -eq 1 ]
    done
}

# own_identity_commit — a commit under a made-up account's handle and noreply address, the handle
# being a word of the list. Sets base, tip and the URL of that account's repository.
own_identity_commit() {
    mk_repo other
    base="$(git rev-parse HEAD)"
    echo "clean" > clean.txt && git add clean.txt
    local address="12345+${SENTINEL}@users.noreply.github.com"
    GIT_AUTHOR_NAME="${SENTINEL}" GIT_COMMITTER_NAME="${SENTINEL}" GIT_AUTHOR_EMAIL="${address}" \
        GIT_COMMITTER_EMAIL="${address}" commit_bypassing_hooks "feat: clean"
    tip="$(git rev-parse HEAD)"
    own_url="git@github.com:${SENTINEL}/notes.git"
    seed_visibility "$(printf '%s' "${SENTINEL}/notes" | tr '[:upper:]' '[:lower:]')" private
}

# push_to <url> <branch>... — pre-push for the tip of own_identity_commit under each branch name.
push_to() {
    local url="$1" branch lines=""
    shift
    for branch in "$@"; do
        lines+="refs/heads/${branch} ${tip} refs/heads/${branch} ${base}"$'\n'
    done
    run bash -c "printf '%s' '${lines}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${url}'"
}

@test "pre-push: an account's own handle and noreply address pass to its own repository" {
    own_identity_commit
    push_to "${own_url}" topic
    [ "$status" -eq 0 ]
    [[ "$output" == *"author/committer: clean"* ]]
}

@test "pre-push: the same identity is blocked on the way to another account's repository" {
    own_identity_commit
    push_to "${OTHER_URL}" topic
    [ "$status" -eq 1 ]
    [[ "$output" == *"author/committer: 1 hit(s)"* ]]
}

@test "pre-push: a push of several refs hands the destination to the one check over all of them" {
    own_identity_commit
    push_to "${own_url}" topic other-topic
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c 'anon-audit-deep --range')" -eq 1 ]
    [[ "$output" == *"2 refs at once"* ]]
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

@test "pre-push: a push from a bare repository is scanned, not refused by a crash" {
    mk_repo synforger
    echo "clean" > clean.txt && git add clean.txt && commit_bypassing_hooks "feat: clean"
    git clone -q --bare . "${BATS_TEST_TMPDIR}/clean.git"
    cd "${BATS_TEST_TMPDIR}/clean.git"
    run_pre_push "refs/heads/main $(git rev-parse HEAD) refs/heads/main ${ZERO_SHA}"
    [ "$status" -eq 0 ]
    [[ "${output}" != *"Traceback"* ]]
}

@test "pre-push: a leak pushed from a bare repository is still caught" {
    mk_repo synforger
    echo "${SENTINEL}" > leak.txt && git add leak.txt && commit_bypassing_hooks "feat: sneaky"
    git clone -q --bare . "${BATS_TEST_TMPDIR}/leak.git"
    cd "${BATS_TEST_TMPDIR}/leak.git"
    run_pre_push "refs/heads/main $(git rev-parse HEAD) refs/heads/main ${ZERO_SHA}"
    [ "$status" -eq 1 ]
    [[ "${output}" != *"Traceback"* ]]
    [[ "${output}" != *"not inside a git repository"* ]]
    [[ "${output}" == *"${SENTINEL}"* ]]
}

@test "deep audit: a bare repository refuses the full audit instead of calling it clean" {
    mk_repo synforger
    git clone -q --bare . "${BATS_TEST_TMPDIR}/full.git"
    cd "${BATS_TEST_TMPDIR}/full.git"
    run bash "${GUARD_ROOT}/scanners/words/anon-audit-deep.sh"
    [ "$status" -eq 2 ]
    [[ "${output}" == *"use --range"* ]]
}

@test "pre-push: an unexpected author is caught in a range with several bases" {
    mk_repo synforger
    mk_joined stranger_commit
    push_joined
    [ "$status" -eq 1 ]
    [[ "${output}" == *"stranger@example.com"* ]]
}

# mk_lines <leaking line> — five lines off the seed, one commit each, the given one carrying a word
# of the list. Sets seed and refs (the pre-push lines of a push that creates them all).
mk_lines() {
    local i
    seed="$(git rev-parse HEAD)"
    refs=()
    for i in 1 2 3 4 5; do
        git switch -q -c "b${i}" "${seed}"
        if [ "${i}" = "$1" ]; then echo "${SENTINEL}" > "b${i}.txt"; else echo "b${i}" > "b${i}.txt"; fi
        git add "b${i}.txt" && commit_bypassing_hooks "feat: b${i}"
        refs+=("refs/heads/b${i} $(git rev-parse HEAD) refs/heads/b${i} ${ZERO_SHA}")
    done
}

@test "pre-push: a push of several clean refs is checked once over all they send" {
    mk_repo synforger
    mk_lines none
    run_pre_push "${refs[@]}"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c 'anon-audit-deep --range')" -eq 1 ]
    [[ "${output}" == *"(5 refs at once)"* ]]
}

@test "pre-push: a red in a push of several refs is named ref by ref" {
    mk_repo synforger
    mk_lines 3
    run_pre_push "${refs[@]}"
    [ "$status" -eq 1 ]
    [[ "${output}" == *"(ref refs/heads/b3)"* ]]
    [[ "${output}" != *"refs at once"* ]]
}

@test "pre-push: a direct push to develop among several refs is still refused" {
    mk_repo synforger
    mk_lines none
    run_pre_push "${refs[@]}" "refs/heads/develop $(git rev-parse b1) refs/heads/develop ${seed}"
    [ "$status" -eq 1 ]
    [[ "${output}" == *"direct push to refs/heads/develop refused"* ]]
}

@test "pre-push: a rewritten history sent as several refs leaves out what its destination holds, all at once" {
    rewrite_under_colleague
    run bash -c "printf '%s\n' 'refs/heads/develop ${new} refs/heads/develop ${old}' 'refs/tags/v1 ${new} refs/tags/v1 ${ZERO_SHA}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${dest}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(2 refs at once)"* ]]
    [[ "$output" != *"hit(s)"* ]]
    # what the rewrite made new on one of the refs is still caught, and named by its ref
    echo "fresh ${SENTINEL}" > fresh.txt && git add fresh.txt
    fresh="$(git commit-tree "$(git write-tree)" -p "${new}" -m "feat: a fresh file")"
    run bash -c "printf '%s\n' 'refs/heads/develop ${new} refs/heads/develop ${old}' 'refs/heads/side ${fresh} refs/heads/side ${ZERO_SHA}' | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${dest}'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git history blob: 1 hit(s)"* ]]
    [[ "$output" == *"(ref refs/heads/side)"* ]]
    [ -z "$(git for-each-ref refs/guard-dest)" ]
}

# --- pre-push: a push that rewrites history, from the agent's shell, to a repository held to `order` ---

# held_repo — the fixture remote's `repo:` line ends with `order`; the grants sit beside the marks.
held_repo() {
    export AREA_GUARD_STATE="${BATS_TEST_TMPDIR}/state"
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'repo:synforger/fixture-repo company order\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
}

# rewrite — in the fixture repository, a commit that does not descend from the seed: the seed is
# `${old}` and the commit that replaces it `${new}`.
rewrite() {
    old="$(git rev-parse HEAD)"
    echo "again" > again.txt && git add again.txt
    new="$(git commit-tree "$(git write-tree)" -m "feat: another root")"
}

# give_grant <url> [now] — the operator's approval of a forced push of this repository to <url>.
give_grant() {
    python3 -I -c 'import sys; from pathlib import Path
sys.path.insert(0, sys.argv[1]); import force_push
force_push.give(Path(sys.argv[2]), sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else None)' \
        "${GUARD_ROOT}/git-hooks/_internal" "$(git rev-parse --show-toplevel)" "$1" ${2:+"$2"}
}

grants_left() { find "${BATS_TEST_TMPDIR}/force-grants" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

@test "force-push hook: a rewrite is held whoever pushes, with or without the agent's shell variable" {
    local value
    held_repo
    mk_repo synforger
    rewrite
    for value in "" 0 1; do
        CLAUDECODE="${value}" run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
        [ "$status" -eq 1 ] || { echo "passed with CLAUDECODE='${value}'"; return 1; }
        [[ "$output" == *"--no-verify"* ]]
    done
}

@test "force-push hook: a repository without order is not held" {
    mk_repo synforger
    rewrite
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 0 ]
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf 'repo:synforger/fixture-repo company\n' > "${GUARD_CONFIG_DIR}/destinations.txt"
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 0 ]
}

@test "force-push hook: a fast-forward, a new branch and a deletion pass" {
    held_repo
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    head="$(git rev-parse HEAD)"
    run_pre_push "refs/heads/feature/x ${head} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
    run_pre_push "refs/heads/feature/y ${head} refs/heads/feature/y ${ZERO_SHA}"
    [ "$status" -eq 0 ]
    run_pre_push "(delete) ${ZERO_SHA} refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
}

@test "force-push hook: a rewrite stops without a grant and says how to ask" {
    held_repo
    mk_repo synforger
    rewrite
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"rewrites refs/heads/feature/x on ${SYNFORGER_URL}"* ]]
    [[ "$output" == *"--force-with-lease"* ]]
    [[ "$output" == *'```guard'* ]]
}

@test "force-push hook: a remote commit this repository does not hold counts as a rewrite" {
    held_repo
    mk_repo synforger
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    run_pre_push "refs/heads/feature/x $(git rev-parse HEAD) refs/heads/feature/x 1111111111111111111111111111111111111111"
    [ "$status" -eq 1 ]
}

@test "force-push hook: a grant lets one rewrite through and is used up" {
    held_repo
    mk_repo synforger
    rewrite
    give_grant "${SYNFORGER_URL}"
    [ "$(grants_left)" -eq 1 ]
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 0 ]
    [ "$(grants_left)" -eq 0 ]
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 1 ]
}

@test "force-push hook: one grant covers every rewritten ref of one push" {
    held_repo
    mk_repo synforger
    rewrite
    give_grant "${SYNFORGER_URL}"
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}" "refs/heads/feature/y ${new} refs/heads/feature/y ${old}"
    [ "$status" -eq 0 ]
    [ "$(grants_left)" -eq 0 ]
}

@test "force-push hook: a grant that ended, or one for another URL or repository, lets nothing through" {
    held_repo
    mk_repo synforger
    rewrite
    give_grant "${SYNFORGER_URL}" 1000
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 1 ]
    give_grant "git@github.com:Synforger/other-repo.git"
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 1 ]
    other="${BATS_TEST_TMPDIR}/another-clone"
    git clone -q . "${other}"
    ( cd "${other}" && give_grant "${SYNFORGER_URL}" )
    run_pre_push "refs/heads/feature/x ${new} refs/heads/feature/x ${old}"
    [ "$status" -eq 1 ]
}

@test "force-push hook: a push that rewrites nothing leaves the grant for the push it was given for" {
    held_repo
    mk_repo synforger
    base="$(git rev-parse HEAD)"
    echo "more" > more.txt && git add more.txt && commit_bypassing_hooks "feat: clean"
    give_grant "${SYNFORGER_URL}"
    run_pre_push "refs/heads/feature/x $(git rev-parse HEAD) refs/heads/feature/x ${base}"
    [ "$status" -eq 0 ]
    [ "$(grants_left)" -eq 1 ]
}
