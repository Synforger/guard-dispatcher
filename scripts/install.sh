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
# Usage:
#   scripts/install.sh [--claude-settings <settings.json>]...
#
# --claude-settings registers the agent-side entry guard
# (agent-hooks/claude-code/area-guard.py) as a PreToolUse hook in that Claude
# Code settings file, creating the file if needed. Repeat it for every config
# dir. Re-running leaves exactly one entry, and an entry pointing at another
# copy of area-guard.py is replaced.
#
# Rollback:
#   git config --global --unset core.hooksPath
#   rm -rf ~/.git-hooks
# =============================================================================
set -euo pipefail

claude_settings=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --claude-settings)
            [ "$#" -ge 2 ] || { echo "error: --claude-settings needs a file" >&2; exit 2; }
            claude_settings+=("$2")
            shift 2
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

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

# Expose the scanners, helper scripts and agent hooks alongside the git hooks
# so Taskfiles, shells and agent settings can invoke them via a stable path
# (git only executes known hook names, so extra entries here are inert to git
# itself).
for entry in scanners scripts agent-hooks; do
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

# The agent hook is called through ~/.git-hooks, so the settings entry stays
# valid whichever clone was installed last. When the hook is missing (the
# checkout was removed, or predates agent-hooks/) the entry passes silently:
# Claude Code reads a failing hook's exit 2 as a refusal, which would stop
# every tool call. doctor.sh reports the missing hook instead.
AGENT_HOOK_COMMAND='f="$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py"; [ -f "$f" ] || exit 0; exec python3 "$f"'
for settings in ${claude_settings[@]+"${claude_settings[@]}"}; do
    python3 - "${settings}" "${AGENT_HOOK_COMMAND}" <<'PY'
import json
import sys
from pathlib import Path

path, command = Path(sys.argv[1]).expanduser(), sys.argv[2]
text = path.read_text() if path.is_file() else ""
settings = json.loads(text) if text.strip() else {}
pre = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
for group in pre:
    group["hooks"] = [h for h in group.get("hooks", []) if "area-guard.py" not in h.get("command", "")]
pre[:] = [g for g in pre if g["hooks"]]
pre.append({"matcher": "Read|Grep|Glob|Bash|Edit|Write|MultiEdit|NotebookEdit",
            "hooks": [{"type": "command", "command": command}]})
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
PY
    echo "[global-hooks] agent entry guard registered in ${settings}"
done
