#!/usr/bin/env bash
# =============================================================================
# anon-fix — auto-scrub personal identifiers from the unpushed commit range
# =============================================================================
# When pre-push detects a leak in the outgoing range, running a fix commit
# just publishes what the fix removed. This script instead rewrites the
# unpushed commits in place with `git filter-repo --replace-text +
# --replace-message` so the public record shows neither the leak nor a
# repair scar.
#
# Usage:
#   bash .tooling/local-ci/anon-fix.sh --range origin/main..HEAD
#   bash .tooling/local-ci/anon-fix.sh --range origin/main..HEAD --auto
#   bash .tooling/local-ci/anon-fix.sh --range origin/main..HEAD --dry-run
#
# Env / flags:
#   --range <A>..<B>  required. Only supports two-dot ranges (`A..B`).
#   --auto            skip the interactive confirmation prompt.
#   --dry-run         print the plan (commit count + replacements file
#                     preview) without touching history.
#
# Safety guards (any failure = abort, no history mutation):
#   1. --range is required and must be `A..B` form.
#   2. B (= range tip) must NOT already be reachable from any remote ref
#      — rewriting published history is refused. If you need to fix a
#      pushed commit, use the standard revert / force-push flow with
#      operator awareness, not this script.
#   3. anon-words.txt (= real wordlist) must be present. The example /
#      fallback wordlist is refused as too weak a source of truth.
#   4. git-filter-repo must be installed.
#
# Exit code:
#   0 — history rewrite completed (or dry-run succeeded) and the range is
#       clean per anon-audit-deep --range verification.
#   1 — safety guard tripped, filter-repo failed, or verification still
#       reports a leak (partial state — inspect and re-run).
#   2 — argument / configuration error.
# =============================================================================

set -euo pipefail

RANGE=""
AUTO=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --range)      shift; RANGE="${1:-}" ;;
        --range=*)    RANGE="${1#--range=}" ;;
        --auto)       AUTO=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    sed -n '1,40p' "$0"; exit 0 ;;
        *)            echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -z "${RANGE}" ]; then
    echo "error: --range <A>..<B> is required" >&2
    exit 2
fi

case "${RANGE}" in
    *..*[.\ ]*|*[.\ ]..*|*\.\.\.*)
        echo "error: only two-dot ranges (A..B) are supported; got: ${RANGE}" >&2
        exit 2
        ;;
    *..*) : ;;
    *)
        echo "error: --range must be of the form A..B; got: ${RANGE}" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The scan target is the repository the caller stands in — not the guard
# checkout this script lives in. Hooks invoke scanners with cwd already at
# the target repo root; direct callers may be anywhere inside the repo.
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${PROJECT_ROOT}" ]; then
    echo "error: not inside a git repository" >&2
    exit 2
fi
cd "${PROJECT_ROOT}"

# Word list resolution (operator master first — the guard checkout itself
# never carries the real list):
#   1. $ANON_WORDS_FILE            explicit override
#   2. `git config guard.wordlist` scope-specific list (conditional include)
#   3. $HOME/.config/anon-words/master.txt   operator master (bootstrap-machine standard)
#   4. $SCRIPT_DIR/anon-words.txt  repo-local synced copy (legacy / repo override)
WORDS_FILE="${ANON_WORDS_FILE:-}"
if [ -z "${WORDS_FILE}" ]; then
    # Scope-specific list via `git config guard.wordlist` (set through a
    # conditional include alongside guard.scope; `~` is expanded here).
    WORDS_FILE="$(git config --get guard.wordlist 2>/dev/null || true)"
    WORDS_FILE="${WORDS_FILE/#\~/${HOME}}"
    WORDS_FILE="${WORDS_FILE/#\$HOME/${HOME}}"
fi
if [ -z "${WORDS_FILE}" ]; then
    if [ -f "${HOME}/.config/anon-words/master.txt" ]; then
        WORDS_FILE="${HOME}/.config/anon-words/master.txt"
    else
        WORDS_FILE="${SCRIPT_DIR}/anon-words.txt"
    fi
fi
if [ ! -f "${WORDS_FILE}" ]; then
    echo "error: anon-words.txt not found at ${WORDS_FILE} — run anon-sync-truth.sh first" >&2
    exit 2
fi
if ! grep -qE '^[^#[:space:]]' "${WORDS_FILE}"; then
    echo "error: anon-words.txt has no active patterns (looks like the CI fallback). Sync operator master first." >&2
    exit 2
fi

if ! command -v git-filter-repo >/dev/null 2>&1; then
    echo "error: git-filter-repo not installed. brew install git-filter-repo (or pip install git-filter-repo)." >&2
    exit 2
fi

# Resolve the range endpoints so we can safety-check the tip.
a_sha="$(git rev-parse --verify "${RANGE%..*}^{commit}" 2>/dev/null || true)"
b_sha="$(git rev-parse --verify "${RANGE#*..}^{commit}"  2>/dev/null || true)"
if [ -z "${a_sha}" ] || [ -z "${b_sha}" ]; then
    echo "error: could not resolve range ${RANGE} — check both endpoints exist." >&2
    exit 2
fi

n_commits="$(git rev-list --count "${RANGE}" 2>/dev/null || echo 0)"
if [ "${n_commits}" -eq 0 ]; then
    echo "anon-fix: range ${RANGE} is empty (0 commits) — nothing to rewrite." >&2
    exit 0
fi

# --- Safety guard 2: refuse to rewrite already-published commits --------------
# `git branch -r --contains <sha>` lists remote-tracking branches that
# already carry B. If any remote knows about it, we bail: rewriting a
# public commit produces divergent history that other clones cannot pull
# cleanly.
if remote_refs="$(git branch -r --contains "${b_sha}" 2>/dev/null)" && [ -n "${remote_refs}" ]; then
    echo "error: range tip ${b_sha:0:12} is already reachable from a remote ref:" >&2
    printf '%s\n' "${remote_refs}" | sed 's/^/    /' >&2
    echo "Refusing to rewrite published history." >&2
    exit 1
fi

# Build a filter-repo expressions file. Each active anon-words line becomes
# one `regex:<pat>==>[REDACTED]` rule. filter-repo applies it to both blob
# contents and, via --replace-message, to commit messages.
expressions_file="$(mktemp -t anon-fix-expressions.XXXXXX)"
trap 'rm -f "${expressions_file}"' EXIT

grep -v '^[[:space:]]*#' "${WORDS_FILE}" \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -v '^[[:space:]]*$' \
    | while IFS= read -r pat; do
        printf 'regex:%s==>[REDACTED]\n' "${pat}"
    done > "${expressions_file}"

n_rules="$(wc -l < "${expressions_file}" | tr -d ' ')"

cat <<INFO
anon-fix plan
  project      : ${PROJECT_ROOT}
  range        : ${RANGE}
  a (base)     : ${a_sha:0:12}
  b (tip)      : ${b_sha:0:12}
  commits      : ${n_commits}
  replacement  : ${n_rules} regex rules from anon-words.txt → [REDACTED]
  mode         : $([ "${DRY_RUN}" -eq 1 ] && echo dry-run || echo apply)
INFO

if [ "${DRY_RUN}" -eq 1 ]; then
    echo ""
    echo "-- expressions.txt preview (first 8 rules) --"
    head -8 "${expressions_file}"
    echo "..."
    exit 0
fi

# --- Confirmation -------------------------------------------------------------
if [ "${AUTO}" -ne 1 ]; then
    if [ -t 0 ]; then
        printf 'Proceed? This rewrites %s commits in place. [y/N] ' "${n_commits}"
        read -r reply
        case "${reply}" in
            y|Y|yes|YES) : ;;
            *) echo "aborted by user." >&2; exit 0 ;;
        esac
    else
        echo "error: refusing to rewrite non-interactively without --auto." >&2
        exit 2
    fi
fi

# --- filter-repo apply --------------------------------------------------------
# --refs takes a ref name (branch / tag), not a commit range. We limit the
# rewrite to the current branch and rely on filter-repo's identity behaviour:
# commits whose content the replacement rules do not touch keep their original
# sha, so already-pushed commits upstream of the range endpoint stay stable
# in practice as long as the rules only match content that lives inside the
# outgoing range. --partial + --force are required for a non-fresh clone;
# --replace-refs delete-no-add keeps refs/replace/* out of the working repo.
current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [ -z "${current_branch}" ]; then
    echo "error: HEAD is detached — check out the branch you want to rewrite first." >&2
    exit 2
fi

git-filter-repo \
    --force \
    --partial \
    --replace-refs delete-no-add \
    --refs "${current_branch}" \
    --replace-text "${expressions_file}" \
    --replace-message "${expressions_file}"

echo ""
echo "anon-fix: filter-repo pass complete. Verifying..."

# --- Verify ------------------------------------------------------------------
# The range endpoints changed shape (B was rewritten), so re-resolve them
# for the verification pass.
new_b="$(git rev-parse --verify "${current_branch}" 2>/dev/null || true)"
verify_range="${a_sha}..${new_b}"

if bash "${SCRIPT_DIR}/anon-audit-deep.sh" --range "${verify_range}"; then
    echo ""
    echo "anon-fix: verify clean. You can now push (${current_branch}) — the outgoing"
    echo "         range shows [REDACTED] wherever a match hit."
    exit 0
fi

echo "anon-fix: verification still reports leaks. Inspect and re-run." >&2
exit 1
