# Shared fixtures for the guard-dispatcher test suite.
#
# Every test gets a throwaway git repo under $BATS_TEST_TMPDIR and a
# sentinel-only word list, so no real operator data is ever touched and
# the suite runs identically on any machine.

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The sentinel the fixture word list flags. Deliberately gibberish so it
# can never collide with legitimate repo content.
SENTINEL="XLEAKX7q3z"

ALLOWED_EMAIL="synforger@users.noreply.github.com"
SYNFORGER_URL="git@github.com:Synforger/fixture-repo.git"
OTHER_URL="git@github.com:someone-else/fixture-repo.git"

setup_words() {
    export ANON_WORDS_FILE="${BATS_TEST_TMPDIR}/words.txt"
    printf '%s\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
}

# mk_repo <kind> — create a fixture repo and cd into it.
#   kind: synforger | other | no-remote
mk_repo() {
    local kind="$1"
    local dir="${BATS_TEST_TMPDIR}/repo-${kind}-${RANDOM}"
    git init -q "${dir}"
    cd "${dir}" || return 1
    git config user.email "${ALLOWED_EMAIL}"
    git config user.name "Fixture"
    git config commit.gpgsign false
    case "${kind}" in
        synforger) git remote add origin "${SYNFORGER_URL}" ;;
        other)     git remote add origin "${OTHER_URL}" ;;
        no-remote) : ;;
    esac
    echo "seed" > seed.txt
    git add seed.txt
    git -c core.hooksPath=/dev/null commit -q -m "seed"
}

# commit_bypassing_hooks <msg> — commit whatever is staged without any hooks
# (fixtures need to create "bad" history that the hooks would block).
commit_bypassing_hooks() {
    git -c core.hooksPath=/dev/null commit -q -m "$1"
}

run_pre_commit() { run bash "${GUARD_ROOT}/git-hooks/pre-commit"; }
run_commit_msg() { run bash "${GUARD_ROOT}/git-hooks/commit-msg" "$@"; }

# run_pre_push <stdin-line...> — feed ref lines to the pre-push dispatcher.
run_pre_push() {
    local input=""
    local line
    for line in "$@"; do
        input="${input}${line}
"
    done
    run bash -c "printf '%s' \"\$1\" | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${SYNFORGER_URL}'" _ "${input}"
}

ZERO_SHA="0000000000000000000000000000000000000000"
