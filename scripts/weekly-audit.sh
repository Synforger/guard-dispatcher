#!/usr/bin/env bash
# =============================================================================
# weekly-audit — scheduled full deep audit across all enforced checkouts
# =============================================================================
# The push-boundary hooks only see what leaves this machine through git.
# Sources that change server-side (PR text edited in the web UI, issue
# comments, run records) and whole-history drift need a periodic sweep —
# this script is that belt-and-suspenders layer, meant to run from launchd
# (see install-weekly-audit.sh) but equally callable by hand.
#
# Configuration (operator-private, never committed) at:
#   $HOME/.config/guard-dispatcher/weekly-audit.conf
#
#   REPOS_GLOB="<glob of repos to audit>"          # required
#   MESSAGE_DIR="<dir to drop a report into>"      # optional — when set and
#                                                  # findings exist, a markdown
#                                                  # report lands there
#
# Output:
#   - full log:  $HOME/.local/state/guard-dispatcher/weekly-audit-<date>.log
#   - findings:  $MESSAGE_DIR/<date>-weekly-anon-audit.md  (only on findings)
#
# Exit:
#   0 = all audited repos clean (or nothing to audit)
#   1 = findings in at least one repo (report written if MESSAGE_DIR set)
#   2 = configuration missing / invalid
# =============================================================================

set -uo pipefail

CONF="${HOME}/.config/guard-dispatcher/weekly-audit.conf"
STATE_DIR="${HOME}/.local/state/guard-dispatcher"
GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="${GUARD_ROOT}/scanners/anon-audit-deep.sh"

if [ ! -f "${CONF}" ]; then
    echo "error: config not found at ${CONF}" >&2
    echo "Create it with at least: REPOS_GLOB=\"<glob of repos to audit>\"" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "${CONF}"

if [ -z "${REPOS_GLOB:-}" ]; then
    echo "error: REPOS_GLOB not set in ${CONF}" >&2
    exit 2
fi

mkdir -p "${STATE_DIR}"
stamp="$(date +%Y-%m-%d)"
log="${STATE_DIR}/weekly-audit-${stamp}.log"

findings=0
summary=""

{
    echo "=== weekly anon audit: ${stamp} ($(date '+%H:%M:%S')) ==="
    # shellcheck disable=SC2086 — the glob is the point
    for repo in ${REPOS_GLOB}; do
        [ -d "${repo}" ] || continue
        git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 || continue

        echo ""
        echo "--- ${repo} ---"
        if (cd "${repo}" && bash "${SCANNER}") 2>&1; then
            echo "--- ${repo}: clean ---"
        else
            echo "--- ${repo}: FINDINGS ---"
            findings=$((findings + 1))
            summary="${summary}- ${repo}
"
        fi
    done
    echo ""
    echo "=== done: ${findings} repo(s) with findings ==="
} >> "${log}" 2>&1

if [ "${findings}" -eq 0 ]; then
    exit 0
fi

if [ -n "${MESSAGE_DIR:-}" ] && [ -d "${MESSAGE_DIR}" ]; then
    report="${MESSAGE_DIR}/${stamp}-weekly-anon-audit.md"
    cat > "${report}" <<REPORT
# Weekly anon audit: findings in ${findings} repo(s) (${stamp})

The scheduled deep audit found word-list matches in:

${summary}
Full log: ${log}

Next step: inspect the log, then clean up with the usual tools
(anon-fix for unpushed ranges, filter-repo + force-push for published
history, gh api for server-side records). Do not push from the
affected repos until resolved.

-- guard-dispatcher weekly audit
REPORT
    echo "report written: ${report}" >> "${log}"
fi

exit 1
