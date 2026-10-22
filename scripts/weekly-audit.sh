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
#   (<root>/config/guard/audit/ under a platform root; scanners/guard_places.py holds every place)
#
#   REPOS_GLOB="<glob of repos to audit>"          # repositories outside every area
#   AREA_REPOS=0                                   # optional — leave out the repositories
#                                                  # found inside the areas (see below)
#   MESSAGE_DIR="<dir to drop a report into>"      # optional — when set and
#                                                  # findings exist, a markdown
#                                                  # report lands there
#
# Known findings (optional, operator-private):
#   $HOME/.config/guard-dispatcher/known/<repo folder name>.known
#   written by `weekly-audit.sh --accept <repo>...`; a repository with one is
#   audited for what appeared after it was recorded (anon-audit-deep.sh --known)
#
# Output:
#   - full log:  $HOME/.local/state/guard-dispatcher/weekly-audit-<date>.log
#                (<root>/state/guard/audit/ under a platform root)
#   - findings:  $MESSAGE_DIR/<date>-weekly-anon-audit.md  (only on findings)
#
# Exit:
#   0 = all audited repos clean (or nothing to audit)
#   1 = findings in at least one repo (report written if MESSAGE_DIR set)
#   2 = configuration missing / invalid
# =============================================================================

set -uo pipefail

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="${GUARD_ROOT}/scanners/anon-audit-deep.sh"
PLACES="${GUARD_ROOT}/scanners/guard_places.py"
CONF="$(python3 "${PLACES}" weekly-audit.conf)"
STATE_DIR="$(python3 "${PLACES}" audit-logs)"
# Findings accepted as known, one file per repository (named after its folder). The audit then
# reports only what appears after the recording; see anon-audit-deep.sh --known.
KNOWN_DIR="$(python3 "${PLACES}" known)"

# weekly-audit.sh --accept <repo>... — record each repository's current findings as known.
# For findings that will not be rewritten (history, PR text); a file in the tree is fixed instead.
if [ "${1:-}" = "--accept" ]; then
    shift
    [ $# -gt 0 ] || { echo "usage: weekly-audit.sh --accept <repo>..." >&2; exit 2; }
    status=0
    for repo in "$@"; do
        known="${KNOWN_DIR}/$(basename "$(cd "${repo}" && pwd)").known"
        (cd "${repo}" && bash "${SCANNER}" --record-known "${known}") || status=1
    done
    exit "${status}"
fi

if [ ! -f "${CONF}" ]; then
    echo "error: config not found at ${CONF}" >&2
    echo "Create it with at least: REPOS_GLOB=\"<glob of repos to audit>\"" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "${CONF}"

# Every repository inside an area is audited as well, found from areas.txt: one put in an area
# tomorrow is in the next audit without anyone listing it. A listed glob covers only what someone
# remembered to list, and a client's repository outside it went unaudited for weeks.
area_repos() {
    python3 - "${GUARD_ROOT}/scanners/corpus-scan.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("corpus_scan", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    areas = module.load_areas()
except ValueError:
    sys.exit(0)
SKIP = {"node_modules", ".build", "DerivedData", "Pods",
        "third_party", "third-party", "_deps", ".fetchcontent-cache"}
for name, roots in areas.items():
    if name in module.UNSCANNED:
        continue
    for root in roots:
        for here, dirs, files in os.walk(root):
            # Someone else's code cloned in (third_party, CMake's fetched sources) is not text the
            # agent wrote, and its history holds other people's words: it is left out
            dirs[:] = [d for d in dirs if d not in SKIP]
            if ".git" in dirs or ".git" in files:
                print(here)
                dirs.remove(".git") if ".git" in dirs else None
PY
}

repos=()
seen=" "
add_repo() {
    local real
    real="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
    case "${seen}" in *" ${real} "*) return 0 ;; esac
    seen="${seen}${real} "
    repos+=("$1")
}
# shellcheck disable=SC2086 — the glob is the point
for repo in ${REPOS_GLOB:-}; do add_repo "${repo}"; done
if [ "${AREA_REPOS:-1}" != 0 ]; then
    while IFS= read -r repo; do add_repo "${repo}"; done < <(area_repos)
fi
if [ "${#repos[@]}" -eq 0 ]; then
    echo "error: no repository to audit: set REPOS_GLOB in ${CONF}, or define areas" >&2
    exit 2
fi

mkdir -p "${STATE_DIR}/audit-state"
stamp="$(date +%Y-%m-%d)"
log="${STATE_DIR}/weekly-audit-${stamp}.log"

# Incremental GitHub scanning: per-repo state files remember the last
# successful sweep; GitHub-side sources then only walk records created or
# updated since. The first Sunday of each month runs a full walk anyway,
# as a belt-and-suspenders against anything the incremental filter missed.
run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
full_sweep=0
if [ "$(date +%d)" -le 7 ]; then
    full_sweep=1
fi

findings=0
summary=""

{
    echo "=== weekly anon audit: ${stamp} ($(date '+%H:%M:%S')) ==="
    for repo in "${repos[@]}"; do
        [ -d "${repo}" ] || continue
        git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 || continue

        state_file="${STATE_DIR}/audit-state/$(basename "${repo}").last"
        since_args=()
        if [ "${full_sweep}" -eq 0 ] && [ -f "${state_file}" ]; then
            since_args=(--github-since "$(cat "${state_file}")")
        fi
        sweep="${since_args[1]:-full}"
        known="${KNOWN_DIR}/$(basename "${repo}").known"
        known_note=""
        if [ -f "${known}" ]; then
            since_args+=(--known "${known}")
            known_note=", known findings accepted"
        fi

        echo ""
        echo "--- ${repo} (${sweep}${known_note}) ---"
        if (cd "${repo}" && bash "${SCANNER}" ${since_args[@]+"${since_args[@]}"}) 2>&1; then
            echo "--- ${repo}: clean ---"
            printf '%s' "${run_started}" > "${state_file}"
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
