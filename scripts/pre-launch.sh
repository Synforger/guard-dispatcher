#!/usr/bin/env bash
# =============================================================================
# pre-launch — start an agent's launcher only as committed, and say what changed
# =============================================================================
# A launcher runs outside the session cage (it is what builds the cage), yet it
# lives in a repository the agent edits from inside one. Whatever the agent
# writes there runs outside the cage at the next start. This script stands where
# no cage writes (the guard's install, called from the shell's launch function in
# a startup file no cage writes either) and does, before the launcher runs:
#
#   1. --pull: pull the repository, so what the pull brings is checked as well
#      (a launcher that pulls after this point would run unchecked code)
#   2. every watched path must match HEAD: a change no commit carries is asked
#      about on the terminal (refused when there is none), so whatever runs
#      outside a cage has a commit behind it
#   3. the watched paths are compared with what the last start saw; a change is
#      named in one line (not refused: a commit is how the agent fixes its tools)
#   4. exec the command with GUARD_PRE_LAUNCH=1 (the launcher then skips its own pull)
#
# Usage: pre-launch.sh [--pull] [--watch <path>]... <repo> -- <command> [args...]
#        --watch is relative to the repository and defaults to .tooling
# Exit:  the command's, or 1 when the start is refused, 2 on a usage error
# =============================================================================

set -uo pipefail

pull=0
repo=""
watch=()
while [ $# -gt 0 ]; do
    case "$1" in
        --pull) pull=1; shift ;;
        --watch) [ $# -ge 2 ] || { echo "pre-launch: --watch needs a path" >&2; exit 2; }
                 watch+=("$2"); shift 2 ;;
        --) shift; break ;;
        -*) echo "pre-launch: unknown option $1" >&2; exit 2 ;;
        *) repo="$1"; shift ;;
    esac
done
if [ -z "${repo}" ] || [ $# -eq 0 ]; then
    echo "usage: pre-launch.sh [--pull] [--watch <path>]... <repo> -- <command> [args...]" >&2
    exit 2
fi
[ ${#watch[@]} -gt 0 ] || watch=(.tooling)
git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 || { echo "pre-launch: ${repo} is not a git repository" >&2; exit 2; }

# --- 1. pull ------------------------------------------------------------------
if [ "${pull}" -eq 1 ]; then
    if ! err="$(git -C "${repo}" pull -q --rebase --autostash 2>&1)"; then
        echo "pre-launch: the pull of ${repo} stopped (starting anyway): $(printf '%s' "${err}" | tail -1)" >&2
    fi
fi

# --- 2. nothing uncommitted in what runs outside the cage --------------------
dirty="$( { git -C "${repo}" diff --name-only HEAD -- "${watch[@]}"
            git -C "${repo}" ls-files --others --exclude-standard -- "${watch[@]}"; } | sort -u)"
if [ -n "${dirty}" ]; then
    echo "pre-launch: these files run outside the cage, but no commit carries them:" >&2
    printf '%s\n' "${dirty}" | sed "s#^#  ${repo%/}/#" >&2
    if [ -t 0 ]; then
        printf 'pre-launch: start anyway? [y/N] ' >&2
        read -r answer || answer=""
        [ "${answer}" = "y" ] || { echo "pre-launch: not started" >&2; exit 1; }
    else
        echo "pre-launch: not started (no terminal to ask; commit or discard them first)" >&2
        exit 1
    fi
fi

# --- 3. name what changed since the last start --------------------------------
seen_dir="${GUARD_CONFIG_DIR:-${HOME}/.config/guard}/launch-seen"
key="$(cd -P "${repo}" && pwd | tr '/' '_')"
now=""
for w in "${watch[@]}"; do
    now+="${w} $(git -C "${repo}" rev-parse -q --verify "HEAD:${w}" 2>/dev/null)"$'\n'
done
before="$(cat "${seen_dir}/${key}" 2>/dev/null || true)"
if [ -n "${before}" ] && [ "${before}" != "${now%$'\n'}" ]; then
    while read -r w new; do
        old="$(printf '%s\n' "${before}" | awk -v w="${w}" '$1 == w {print $2}')"
        [ "${old}" = "${new}" ] && continue
        files="$(git -C "${repo}" diff --name-only "${old}" "${new}" 2>/dev/null | head -5 | paste -sd ' ' -)"
        last="$(git -C "${repo}" log -1 --format='%h %s' -- "${w}" 2>/dev/null | cut -c1-72)"
        echo "pre-launch: the launch entry changed since the last start: ${w} [${files:-?}] (last: ${last:-?})" >&2
    done <<< "${now%$'\n'}"
fi
mkdir -p "${seen_dir}" && printf '%s' "${now%$'\n'}" > "${seen_dir}/${key}"

# --- 4. start -------------------------------------------------------------------
GUARD_PRE_LAUNCH=1 exec "$@"
