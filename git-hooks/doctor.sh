#!/usr/bin/env bash
# =============================================================================
# Global hooks dispatcher — doctor
# =============================================================================
# Detects the exact failure mode that let three of four Synforger repos ship
# unarmed hook state earlier this week: git's `core.hooksPath` silently
# reverting to `.git/hooks` because nobody ran `install.sh` after cloning
# fresh, or a repo-local `core.hooksPath` override still pointing at
# `.githooks` after the dispatcher rollout so the global enforcement point
# is quietly skipped.
#
# Usage:
#   _core/git-hooks/doctor.sh                       # scan ~/.git-hooks + CWD
#   _core/git-hooks/doctor.sh <repo>... [<repo>...] # scan the given repos
#   _core/git-hooks/doctor.sh --glob '<projects-root>/*'     # shell glob
#
# Exit code:
#   0 — nothing wrong (dispatcher installed globally + every scanned repo is
#       either non-Synforger or Synforger with the local anon toolkit
#       installed and routing through the dispatcher).
#   1 — one or more findings; details on stderr.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_HOOKS_DIR="${HOME}/.git-hooks"

# shellcheck source=lib/dispatcher-common.sh
. "${SCRIPT_DIR}/lib/dispatcher-common.sh"

RED=$'\033[0;31m'
YEL=$'\033[0;33m'
GRN=$'\033[0;32m'
DIM=$'\033[0;90m'
NC=$'\033[0m'

findings=0

check_global() {
    local actual
    actual="$(git config --global --get core.hooksPath 2>/dev/null || true)"
    if [ "${actual}" = "${EXPECTED_HOOKS_DIR}" ]; then
        printf '  %s✓%s global core.hooksPath = %s\n' "${GRN}" "${NC}" "${actual}"
    else
        printf '  %s✗%s global core.hooksPath = %s (expected %s)\n' "${RED}" "${NC}" "${actual:-<unset>}" "${EXPECTED_HOOKS_DIR}"
        findings=$((findings + 1))
    fi

    for hook in pre-commit commit-msg pre-push; do
        if [ -x "${EXPECTED_HOOKS_DIR}/${hook}" ]; then
            printf '  %s✓%s %s/%s is executable\n' "${GRN}" "${NC}" "${EXPECTED_HOOKS_DIR}" "${hook}"
        else
            printf '  %s✗%s %s/%s missing or not executable\n' "${RED}" "${NC}" "${EXPECTED_HOOKS_DIR}" "${hook}"
            findings=$((findings + 1))
        fi
    done

    # Machine axis: the strongest hooks are useless without the operator
    # master word list — a machine can be "armed" and still scan nothing.
    local truth="${ANON_TRUTH_PATH:-${HOME}/.config/anon-words/master.txt}"
    if [ -f "${truth}" ]; then
        printf '  %s✓%s operator master present (%s)\n' "${GRN}" "${NC}" "${truth}"
    else
        printf '  %s✗%s operator master missing (%s) — run bootstrap-machine.sh\n' "${RED}" "${NC}" "${truth}"
        findings=$((findings + 1))
    fi
}

check_repo() {
    local repo="$1"
    if [ ! -d "${repo}/.git" ] && ! git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1; then
        printf '%s(skip: not a git repo)%s\n' "${DIM}" "${NC}"
        return
    fi

    local kind
    kind="$(cd "${repo}" && dispatcher::detect_repo_kind)"
    printf 'kind=%s' "${kind}"

    local local_hp
    local_hp="$(git -C "${repo}" config --local --get core.hooksPath 2>/dev/null || true)"
    if [ -n "${local_hp}" ] && [ "${local_hp}" != "${EXPECTED_HOOKS_DIR}" ]; then
        # A local override means the dispatcher is bypassed unless the
        # override points at a directory containing the dispatcher hooks.
        printf ' %slocal-hooksPath=%s%s' "${YEL}" "${local_hp}" "${NC}"
    fi

    if [ "${kind}" = "other" ]; then
        printf ' %s(no enforcement expected)%s\n' "${DIM}" "${NC}"
        return
    fi

    # For Synforger / no-remote repos, the scanners must exist and the
    # dispatcher must be reachable from git's hook lookup path.
    local ok=1
    if [ -n "${local_hp}" ] && [ "${local_hp}" != "${EXPECTED_HOOKS_DIR}" ]; then
        printf '\n    %s✗%s local core.hooksPath (%s) overrides the dispatcher — run `git -C %s config --unset core.hooksPath`\n' "${RED}" "${NC}" "${local_hp}" "${repo}"
        findings=$((findings + 1))
        ok=0
    fi
    # Scanners resolve repo-local first, then the guard checkout's bundled
    # copies — a repo with no local toolkit is still armed as long as the
    # guard checkout is healthy.
    local guard_scanners
    guard_scanners="$(dispatcher::guard_root)/scanners"
    if [ ! -f "${repo}/.tooling/local-ci/anon-scan.sh" ] && [ ! -f "${guard_scanners}/anon-scan.sh" ]; then
        printf '\n    %s✗%s anon-scan.sh unresolvable (repo-local + guard bundled both missing)' "${RED}" "${NC}"
        findings=$((findings + 1))
        ok=0
    fi
    if [ ! -f "${repo}/.tooling/local-ci/anon-audit-deep.sh" ] && [ ! -f "${guard_scanners}/anon-audit-deep.sh" ]; then
        printf '\n    %s✗%s anon-audit-deep.sh unresolvable (repo-local + guard bundled both missing)' "${RED}" "${NC}"
        findings=$((findings + 1))
        ok=0
    fi

    # A leftover repo-local word list can shadow-drift from the operator
    # master (scanners prefer the master, but a repo-local scanner override
    # would read its neighbour). Warn on drift so the copy gets removed or
    # refreshed.
    local truth="${ANON_TRUTH_PATH:-${HOME}/.config/anon-words/master.txt}"
    local repo_words="${repo}/.tooling/local-ci/anon-words.txt"
    if [ -f "${truth}" ] && [ -f "${repo_words}" ]; then
        if ! diff -q "${truth}" "${repo_words}" >/dev/null 2>&1; then
            printf '\n    %s!%s repo-local anon-words.txt drifts from operator master — remove it or re-sync' "${YEL}" "${NC}"
            ok=0
        fi
    fi

    if [ "${ok}" -eq 1 ]; then
        printf ' %s✓ armed%s\n' "${GRN}" "${NC}"
    else
        printf '\n'
    fi
}

resolve_targets() {
    if [ "$#" -eq 0 ]; then
        printf '%s\n' "$(pwd)"
        return
    fi
    local arg
    for arg in "$@"; do
        if [ "${arg}" = "--glob" ]; then
            continue
        fi
        # Expand shell glob (`<projects-root>/*`) — leave literal paths alone.
        for expanded in ${arg}; do
            [ -e "${expanded}" ] && printf '%s\n' "${expanded}"
        done
    done
}

echo "=== global hooks dispatcher status ==="
check_global

echo ""
echo "=== per-repo status ==="
targets=()
while IFS= read -r t; do
    [ -n "${t}" ] && targets+=("${t}")
done < <(resolve_targets "$@")

for repo in "${targets[@]}"; do
    printf '%-50s ' "${repo}"
    check_repo "${repo}"
done

echo ""
if [ "${findings}" -eq 0 ]; then
    echo "doctor: clean (no armament gaps found)"
    exit 0
fi
echo "doctor: ${findings} finding(s)"
exit 1
