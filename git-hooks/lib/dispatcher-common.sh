#!/usr/bin/env bash
# =============================================================================
# Global Git Hooks Dispatcher — Common Library
# =============================================================================
# Shared helpers used by every dispatcher hook (pre-commit / commit-msg /
# pre-push). Sourced, never executed directly.
#
# Contract:
#   - Kept minimal: repo classification + delegation to repo-local hooks.
#   - Never mutates the working tree or git state.
#   - No external dependencies beyond POSIX + git.
# =============================================================================

# Repo classification.
#
# Emits one of:
#   synforger  — remote URL points at the Synforger GitHub organisation
#   other      — remote URL points elsewhere (personal / third-party / work)
#   no-remote  — no `origin` remote configured (fresh repo / detached working tree)
#
# The `synforger` result is what the dispatcher uses to decide whether to
# enforce baseline scans on a repo that does not carry its own hooks. Every
# other repo is treated as opt-in: it only gets whatever hooks it ships itself.
dispatcher::detect_repo_kind() {
    local url
    url="$(git config --get remote.origin.url 2>/dev/null || true)"

    if [ -z "${url}" ]; then
        echo "no-remote"
        return 0
    fi

    # Accept both HTTPS (github.com/Synforger/…) and SSH (git@github.com:Synforger/…)
    # forms, including custom host aliases like `github-synforger`. Case-insensitive
    # to tolerate the org name being written in any case.
    if printf '%s' "${url}" | grep -Eqi '(github[^/:]*[/:])synforger/'; then
        echo "synforger"
        return 0
    fi

    echo "other"
}

# Delegate to a repo-local hook if it exists.
#
# Usage:  dispatcher::delegate_if_present <hook-name> "$@"
#
# Looks for `<repo-root>/.githooks/<hook-name>` and, when it is present and
# executable, execs it with the original arguments. stdin is inherited so
# hooks that consume ref ranges (pre-push, pre-receive) keep working.
#
# Returns:
#   0    — nothing delegated, caller should continue with its fallback logic
#   (exec) — control transferred to the local hook; this function never returns
dispatcher::delegate_if_present() {
    local hook_name="$1"
    shift

    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "${repo_root}" ] || return 0

    local local_hook="${repo_root}/.githooks/${hook_name}"
    if [ -x "${local_hook}" ]; then
        exec "${local_hook}" "$@"
    fi

    return 0
}

# Root of the guard-dispatcher checkout this library lives in. Hooks are
# symlinked into ~/.git-hooks/, so resolve through the symlink to find the
# real checkout (and its bundled scanners/).
dispatcher::guard_root() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "${src}" ]; do
        src="$(readlink "${src}")"
    done
    # cd -P resolves directory-level symlinks before walking up (the
    # installed lib is a symlinked directory, so the file inside it is not
    # itself a symlink and the readlink loop above does not fire).
    ( cd -P "$(dirname "${src}")" >/dev/null 2>&1 && cd ../.. >/dev/null 2>&1 && pwd )
}

# Locate a scanner by name. Resolution order:
#   1. repo-local  <repo-root>/.tooling/local-ci/<name>   (repo override)
#   2. bundled     <guard-root>/scanners/<name>           (machine default)
# Emits the path on stdout when found, nothing otherwise. Callers decide
# whether an absent scanner is fatal.
dispatcher::locate_scanner() {
    local name="$1"

    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "${repo_root}" ] && [ -f "${repo_root}/.tooling/local-ci/${name}" ]; then
        printf '%s' "${repo_root}/.tooling/local-ci/${name}"
        return 0
    fi

    local bundled
    bundled="$(dispatcher::guard_root)/scanners/${name}"
    if [ -f "${bundled}" ]; then
        printf '%s' "${bundled}"
    fi
}

dispatcher::locate_anon_scanner() { dispatcher::locate_scanner "anon-scan.sh"; }
dispatcher::locate_deep_scanner() { dispatcher::locate_scanner "anon-audit-deep.sh"; }

# Return the name of the default branch (best effort, no origin fetch).
# Emits the branch name on stdout; falls back to whichever of main/master
# actually exists on origin, then plain "main" as a last resort.
#
# Self-heals when refs/remotes/origin/HEAD is stale (a force-push or a
# repo rename can leave it pointing at a ref that no longer exists — the
# original bug that made pre-push scan 22 commits instead of 1).
dispatcher::default_branch() {
    local ref
    ref="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -n "${ref}" ] && git rev-parse --verify "${ref}" >/dev/null 2>&1; then
        printf '%s' "${ref#origin/}"
        return 0
    fi
    local candidate
    for candidate in main master; do
        if git rev-parse --verify "origin/${candidate}" >/dev/null 2>&1; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    printf 'main'
}
