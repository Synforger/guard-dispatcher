#!/usr/bin/env bash
# =============================================================================
# Global hooks dispatcher — installer
# =============================================================================
# Symlinks this repo's `git-hooks/` into `~/.git-hooks/` and points
# git's global `core.hooksPath` at it. Every git repo on this machine will
# then route hook execution through the dispatcher; non-Synforger repos are
# a no-op (see pre-commit dispatcher for classification logic).
#
# Idempotent: re-running the installer just re-points the symlinks at the
# clone you ran it from. Use that to switch which clone is the source of
# truth (`cd <other clone> && scripts/install.sh`).
#
# Rollback:
#   git config --global --unset core.hooksPath
#   rm -rf ~/.git-hooks
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOKS_SRC="${GUARD_ROOT}/git-hooks"
TARGET_DIR="${HOME}/.git-hooks"

if [ ! -d "${HOOKS_SRC}/lib" ]; then
    echo "error: expected dispatcher source at ${HOOKS_SRC}, but lib/ is missing." >&2
    exit 1
fi

mkdir -p "${TARGET_DIR}"

# Replace any prior entries — a plain overwrite is safer than trying to
# preserve unknown state, since the target is a dispatcher owned by this
# script. doctor.sh is not a git hook but symlinking it here lets it be
# invoked as `~/.git-hooks/doctor.sh` from anywhere.
for entry in pre-commit commit-msg pre-push lib doctor.sh; do
    src="${HOOKS_SRC}/${entry}"
    [ "${entry}" = "doctor.sh" ] && src="${SCRIPT_DIR}/${entry}"
    dst="${TARGET_DIR}/${entry}"

    if [ ! -e "${src}" ]; then
        echo "error: source missing: ${src}" >&2
        exit 1
    fi

    if [ -e "${dst}" ] || [ -L "${dst}" ]; then
        rm -rf "${dst}"
    fi

    ln -s "${src}" "${dst}"
done

# Ensure hook executables are, in fact, executable in the source tree —
# ln -s does not fix mode bits, and a freshly cloned checkout may have
# lost the +x bit if the user re-created files via editor.
chmod +x "${HOOKS_SRC}/pre-commit" "${HOOKS_SRC}/commit-msg" "${HOOKS_SRC}/pre-push" "${SCRIPT_DIR}/doctor.sh"

# Expose the scanners and helper scripts alongside the hooks so Taskfiles
# and shells can invoke them via a stable path (git only executes known
# hook names, so extra entries here are inert to git itself).
for entry in scanners scripts; do
    dst="${TARGET_DIR}/${entry}"
    if [ -e "${dst}" ] || [ -L "${dst}" ]; then
        rm -rf "${dst}"
    fi
    ln -s "${GUARD_ROOT}/${entry}" "${dst}"
done

git config --global core.hooksPath "${TARGET_DIR}"

cat <<MSG
[global-hooks] installed
  source : ${HOOKS_SRC}
  target : ${TARGET_DIR}
  git    : core.hooksPath (global) = ${TARGET_DIR}

Next steps for repos that had a local core.hooksPath override:
  git -C <repo> config --unset core.hooksPath

The dispatcher will still delegate to any repo-local .githooks/<name>.
MSG
