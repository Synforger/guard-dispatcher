#!/usr/bin/env bash
# =============================================================================
# Global hooks dispatcher — installer
# =============================================================================
# Symlinks this repo's `_core/git-hooks/` into `~/.git-hooks/` and points
# git's global `core.hooksPath` at it. Every git repo on this machine will
# then route hook execution through the dispatcher; non-Synforger repos are
# a no-op (see pre-commit dispatcher for classification logic).
#
# Idempotent: re-running the installer just re-points the symlinks at the
# clone you ran it from. Use that to switch which clone is the source of
# truth (`cd <other clone> && _core/git-hooks/install.sh`).
#
# Rollback:
#   git config --global --unset core.hooksPath
#   rm -rf ~/.git-hooks
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.git-hooks"

if [ ! -d "${SCRIPT_DIR}/lib" ]; then
    echo "error: expected dispatcher source at ${SCRIPT_DIR}, but lib/ is missing." >&2
    exit 1
fi

mkdir -p "${TARGET_DIR}"

# Replace any prior entries — a plain overwrite is safer than trying to
# preserve unknown state, since the target is a dispatcher owned by this
# script. doctor.sh is not a git hook but symlinking it here lets it be
# invoked as `~/.git-hooks/doctor.sh` from anywhere.
for entry in pre-commit commit-msg pre-push lib doctor.sh; do
    src="${SCRIPT_DIR}/${entry}"
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
chmod +x "${SCRIPT_DIR}/pre-commit" "${SCRIPT_DIR}/commit-msg" "${SCRIPT_DIR}/pre-push" "${SCRIPT_DIR}/doctor.sh"

git config --global core.hooksPath "${TARGET_DIR}"

cat <<MSG
[global-hooks] installed
  source : ${SCRIPT_DIR}
  target : ${TARGET_DIR}
  git    : core.hooksPath (global) = ${TARGET_DIR}

Next steps for repos that had a local core.hooksPath override:
  git -C <repo> config --unset core.hooksPath

The dispatcher will still delegate to any repo-local .githooks/<name>.
MSG
