#!/bin/bash
set -euo pipefail

# =============================================================================
# Local Dev Platform - Anonymity Scanner (local)
# =============================================================================
# Scans the repository for personal identifiers and operator-internal stack
# names that must never appear in committed files.
#
# Single source of truth: the forbidden-word list lives in `anon-words.txt`
# (next to this script), one PCRE fragment per line. This scanner reads that
# file, strips comments / blank lines, and joins the fragments with `|` to
# build the (?i) case-insensitive pattern. The GitHub Action
# (.github/workflows/anon-check.yml) runs THIS SAME script, so the CI and the
# pre-commit hook can never drift — there is no second copy of the pattern.
#
# Word boundaries + negative lookaheads in the word list keep accessibility
# attributes (`aria-label`, `aria-hidden`) and npm package names (`aria-query`,
# `ark-*`) out of the false-positive lane.
#
# Called from two places:
#   - .githooks/pre-commit       (= staged-file scan before each commit)
#   - .tooling/os/<os>/lint.sh   (= full-tree scan via `task lint`)
#
# Exit code:
#   0 = clean
#   1 = personal identifier found
#   2 = word list missing / empty (configuration error)
#
# Optional env:
#   ANON_SCAN_PATHS  newline-separated subset of files to scan (used by the
#                    pre-commit hook to limit the scan to staged files).
#                    Empty = scan the whole tree.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Word list resolution (operator master first — the guard checkout itself
# never carries the real list):
#   1. $ANON_WORDS_FILE            explicit override
#   2. $HOME/.config/anon-words/master.txt   operator master (bootstrap-machine standard)
#   3. $SCRIPT_DIR/anon-words.txt  repo-local synced copy (legacy / repo override)
WORDS_FILE="${ANON_WORDS_FILE:-}"
if [ -z "${WORDS_FILE}" ]; then
    if [ -f "${HOME}/.config/anon-words/master.txt" ]; then
        WORDS_FILE="${HOME}/.config/anon-words/master.txt"
    else
        WORDS_FILE="${SCRIPT_DIR}/anon-words.txt"
    fi
fi

if [ ! -f "${WORDS_FILE}" ]; then
    echo "error: word list not found at ${WORDS_FILE}" >&2
    exit 2
fi

# Build the PCRE alternation from the word list. Each non-comment, non-blank
# line is one fragment; the trailing " #..." inline comment and surrounding
# whitespace are stripped.
fragments=()
while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"                                   # drop comments
    line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "${line}" ] && continue
    fragments+=("${line}")
done < "${WORDS_FILE}"

if [ "${#fragments[@]}" -eq 0 ]; then
    echo "error: ${WORDS_FILE} contains no patterns" >&2
    exit 2
fi

ANON_PATTERN="$(IFS='|'; echo "${fragments[*]}")"
export ANON_PATTERN

# Files / dirs that legitimately contain string fragments matching the
# pattern (build artefacts, lockfiles, and the policy files that define the
# pattern itself).
EXCLUDES=(
    '.git'
    'node_modules'
    'dist'
    'build'
    '.venv'
    'venv'
    '__pycache__'
    '.next'
    'logs'             # runtime log dir (= gitignored) — local PATH / sid noise
    'target'           # rust build artefacts
    '.gradle'          # kotlin build artefacts
    'obj'              # csharp build artefacts (= dotnet)
    'bin'              # csharp build artefacts (= dotnet)
    'DerivedData'      # swift / Xcode build artefacts
)
EXCLUDE_GLOBS=(
    '*.lock'
    'package-lock.json'
    'yarn.lock'
    'Cargo.lock'      # rust lockfile — pinned versions only, no secrets
    '*.min.js'
    'anon-check.yml'  # the workflow file is allowed to reference the scanner
    'anon-words.txt'  # the word list is the pattern definition itself
    'config.json'     # gitignored per-deriver config (= config.example.json is public)
)

scan_with_perl() {
    local file="$1"
    perl -ne 'BEGIN { $re = qr/(?i)$ENV{ANON_PATTERN}/ }
              if (/$re/) { print "$ARGV:$.:$_"; $found = 1 }
              END { exit($found ? 1 : 0) }' "$file"
}

# Returns 0 if `basename($1)` is in EXCLUDE_GLOBS, 1 otherwise. Used to keep
# the word list / scanner / policy README out of the false-positive lane both
# in full-tree scans and in the staged-file mode driven by the pre-commit hook.
is_excluded_basename() {
    local base
    base="$(basename "$1")"
    for glob in "${EXCLUDE_GLOBS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "${base}" == ${glob} ]]; then
            return 0
        fi
    done
    return 1
}

scan_paths=()
if [ -n "${ANON_SCAN_PATHS:-}" ]; then
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -f "$p" ] || continue
        is_excluded_basename "$p" && continue
        scan_paths+=("$p")
    done <<< "${ANON_SCAN_PATHS}"
elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    # Full-tree mode in a git repo: scan only tracked files. This respects
    # `.gitignore` automatically — runtime data dirs (= backend/data/,
    # secrets/, logs/, .venv/) that hold real personal strings never enter
    # the scan, which would otherwise produce noise + leak local paths into
    # the scan output itself.
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -f "$p" ] || continue
        is_excluded_basename "$p" && continue
        scan_paths+=("$p")
    done < <(git ls-files)
else
    # Non-git fallback: walk the working tree with EXCLUDES.
    find_args=(.)
    for dir in "${EXCLUDES[@]}"; do
        find_args+=(-not -path "*/${dir}/*")
    done
    for glob in "${EXCLUDE_GLOBS[@]}"; do
        find_args+=(-not -name "${glob}")
    done
    find_args+=(-type f)
    while IFS= read -r -d '' p; do
        scan_paths+=("$p")
    done < <(find "${find_args[@]}" -print0)
fi

found=0
for path in "${scan_paths[@]}"; do
    # Skip non-text files quickly.
    case "$path" in
        *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.zip|*.gz|*.tar|*.so|*.dylib|*.dll|*.exe|*.bin|*.csv|*.npy|*.ipynb)
            continue
            ;;
    esac
    if ! scan_with_perl "$path"; then
        found=1
    fi
done

if [ "${found}" -ne 0 ]; then
    echo ""
    echo "Personal identifiers detected. Remove or move to gitignored config."
    exit 1
fi

echo "anon-scan: clean"
exit 0
