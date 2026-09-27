#!/usr/bin/env bash
# =============================================================================
# start.sh — start a session (Claude Code by default) inside one cage
# =============================================================================
#   sandbox/start.sh <cage> [--account-dir DIR] [-- command [args...]]
#
# 1. builds the cage from areas.txt (cage-config.py); an unknown cage stops here
# 2. brings the private-document prints up to date, outside the cage: the scan
#    inside cannot open the areas the cage hides, so it compares with these
# 3. runs the command inside the cage (run.mjs), which refuses rather than run
#    it unconfined
#
# `sandbox/cage-config.py --list` names the cages. The exit status is the
# command's.
# =============================================================================
set -uo pipefail

GUARD="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "usage: sandbox/start.sh <cage> [--account-dir DIR] [-- command [args...]]" >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
cage="$1"
shift
config_args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --account-dir)
            [ "$#" -ge 2 ] || usage
            config_args+=(--account-dir "$2")
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done
[ "$#" -gt 0 ] || set -- claude

cage_file="$(mktemp "${TMPDIR:-/tmp}/cage.XXXXXX")" || exit 1
trap 'rm -f "${cage_file}"' EXIT

python3 "${GUARD}/sandbox/cage-config.py" "${cage}" ${config_args[@]+"${config_args[@]}"} > "${cage_file}" || exit 1
python3 "${GUARD}/scanners/corpus-scan.py" --update || {
    echo "start.sh: the private-document prints could not be brought up to date; not starting" >&2
    exit 1
}
node "${GUARD}/sandbox/run.mjs" "${cage_file}" -- "$@"
