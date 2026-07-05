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
#   enforced   — local opt-in via `git config guard.scope enforced`
#   exempt     — opt-out via `guard.scope=exempt`, or the repo working tree
#                sits under a prefix configured via `guard.exemptPrefix`
#                (blanket opt-out for a private state tree whose contents
#                would structurally trip the baseline word list)
#   synforger  — remote URL points at the Synforger GitHub organisation
#   other      — remote URL points elsewhere (personal / third-party / work)
#   no-remote  — no `origin` remote configured (fresh repo / detached working tree)
#
# The `synforger` / `enforced` results are what the dispatcher uses to decide
# whether to enforce baseline scans on a repo that does not carry its own
# hooks. Everything else is opt-in: it only gets whatever hooks it ships.
# `exempt` is a hard skip — dispatcher does nothing at all, and doctor stops
# flagging local hook overrides as gaps.
#
# `guard.scope` enables machine-side blanket opt-ins through git's own
# conditional include — nothing is written into any repository:
#
#   # ~/.gitconfig
#   [includeIf "gitdir:~/path/to/corp-org/"]
#       path = ~/.gitconfig-corp
#   # ~/.gitconfig-corp
#   [guard]
#       scope = enforced
#       wordlist = $HOME/.config/anon-words/corp.txt
#       allowedEmails = you@users.noreply.github.com,noreply@github.com
#
# `guard.exemptPrefix` gives every repo whose physical working-tree root
# starts with the configured absolute path the `exempt` classification —
# useful for a private state directory whose contents include the very
# words the master list flags. Set once on the machine and every clone/init
# under that tree inherits the opt-out.
dispatcher::detect_repo_kind() {
    local scope
    scope="$(git config --get guard.scope 2>/dev/null || true)"
    if [ "${scope}" = "enforced" ]; then
        echo "enforced"
        return 0
    fi
    if [ "${scope}" = "exempt" ]; then
        echo "exempt"
        return 0
    fi

    # Path-prefix opt-out. Reads the working tree root and matches it
    # against `guard.exemptPrefix`; a leading `~` is expanded to $HOME so
    # the config value can stay portable across machines.
    local exempt_prefix
    exempt_prefix="$(git config --get guard.exemptPrefix 2>/dev/null || true)"
    if [ -n "${exempt_prefix}" ]; then
        exempt_prefix="${exempt_prefix/#\~/${HOME}}"
        local top
        top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        case "${top}" in
            "${exempt_prefix}"|"${exempt_prefix}"/*)
                echo "exempt"
                return 0
                ;;
        esac
    fi

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

# Run the repo-local hook if it exists, then RETURN (AND-composition).
#
# Usage:  dispatcher::run_local_hook <hook-name> "$@"
#
# Looks for `<repo-root>/.githooks/<hook-name>` and, when present and
# executable, runs it with the original arguments and propagates its exit
# code. Unlike an exec-style delegation, control returns to the caller so
# the dispatcher's own baseline checks still run afterwards — a repo-local
# hook adds rules on top of the baseline, it can never replace it.
#
# stdin is inherited; hooks that consume ref lines (pre-push) must capture
# stdin themselves before calling this and re-feed it (see pre-push).
#
# Returns:
#   0 — no local hook, or the local hook passed
#   N — the local hook's non-zero exit code
dispatcher::run_local_hook() {
    local hook_name="$1"
    shift

    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "${repo_root}" ] || return 0

    local local_hook="${repo_root}/.githooks/${hook_name}"
    if [ -x "${local_hook}" ]; then
        "${local_hook}" "$@"
        return $?
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

# The committer identities enforced repos may use (one per line).
#
# `git config guard.allowedEmails` (comma-separated) overrides the built-in
# list — set it in the same conditional-include file as `guard.scope` so a
# work scope can carry its own identities. Without the override, the
# built-in Synforger identities apply.
dispatcher::allowed_emails() {
    local configured
    configured="$(git config --get guard.allowedEmails 2>/dev/null || true)"
    if [ -n "${configured}" ]; then
        printf '%s' "${configured}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
        return 0
    fi
    printf '%s\n' \
        'synforge.dev@gmail.com' \
        'synforger@users.noreply.github.com' \
        'noreply@github.com'
    # The last entry is GitHub itself — it is the committer on every
    # server-side squash merge, so ranges that include merged history
    # would otherwise always fail.
}

# Branches that must never receive a direct push from this machine.
# PR merges happen server-side, so a local push to these refs is always a
# process violation, except the very first push that creates the branch
# on the remote (remote sha = zeros).
dispatcher::protected_branch() {
    case "$1" in
        refs/heads/main|refs/heads/develop) return 0 ;;
        *) return 1 ;;
    esac
}

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
