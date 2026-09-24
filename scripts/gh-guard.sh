#!/usr/bin/env bash
# =============================================================================
# gh-guard — scan what `gh` is about to send, before it is sent
# =============================================================================
# Installed as `gh` earlier on PATH than the real CLI, so every invocation
# passes through here. No per-call discipline, and no wrapper anyone can
# forget to reach for.
#
# Why not keep wrapping one command at a time: `scripts/pr-create.sh` guards
# only the path someone remembers to call it on. PR bodies, issue and review
# comments, release notes, repository descriptions and API payloads never
# pass through git, so the hooks cannot see them either — each is its own
# hole, and the list grows every time the CLI gains a subcommand. Wrapping
# the CLI itself is the one place where "everything this machine sends to
# GitHub" is a single choke point.
#
# Scanned: the whole argument vector, the contents of any file passed as a
# body / notes / template / request payload, and stdin when the command asks
# to read the payload from it.
#
# Passed straight through: read-only subcommands. `gh repo view <owner>/<repo>`
# legitimately names accounts, and blocking it would make the guard something
# to disable rather than something to keep.
#
# Fail-closed: an unresolvable scanner refuses the command. An unknown
# subcommand is scanned, not waved through.
#
# Deliberate bypass: GH_GUARD_SKIP=1 for a single call.
# =============================================================================

set -uo pipefail

INVOKED_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

# The real CLI carries the same name, so look everywhere except the directory
# this copy was invoked from.
CLEAN_PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -vx "${INVOKED_DIR}" | paste -sd: - || true)"
REAL_GH="$(PATH="${CLEAN_PATH}" command -v gh 2>/dev/null || true)"
if [ -z "${REAL_GH}" ]; then
    printf '[gh-guard] the real gh CLI is not on PATH (searched every entry except %s)\n' "${INVOKED_DIR}" >&2
    exit 127
fi

if [ "${GH_GUARD_SKIP:-0}" = "1" ]; then
    exec "${REAL_GH}" "$@"
fi

# Resolve the guard checkout through whatever symlink this was invoked as.
GUARD_ROOT="$(python3 - "$0" <<'PY' 2>/dev/null || true
import os, sys
print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))
PY
)"
SCANNER="${GUARD_SCANNER_OVERRIDE:-${GUARD_ROOT}/scanners/anon-scan.sh}"

# --- decide whether this invocation sends anything ---------------------------
# The command is the first non-option argument, the verb the next one.
cmd=""
verb=""
for arg in "$@"; do
    case "${arg}" in
        -*) continue ;;
    esac
    if [ -z "${cmd}" ]; then
        cmd="${arg}"
        continue
    fi
    verb="${arg}"
    break
done

needs_scan=1
case "${cmd}" in
    "")
        # Bare `gh` prints help.
        needs_scan=0
        ;;
    api)
        # GET by default. Only a payload or a mutating method sends content.
        needs_scan=0
        for arg in "$@"; do
            case "${arg}" in
                -X|--method|-f|--raw-field|-F|--field|--input)
                    needs_scan=1
                    break
                    ;;
                -X*|--method=*|-f=*|--raw-field=*|-F=*|--field=*|--input=*)
                    needs_scan=1
                    break
                    ;;
            esac
        done
        ;;
    *)
        # Read-only verbs send nothing; everything else — including verbs this
        # script has never heard of — is scanned.
        case "${verb}" in
            view|list|status|checks|diff|download|clone|watch|token|show)
                needs_scan=0
                ;;
        esac
        ;;
esac

if [ "${needs_scan}" -eq 0 ]; then
    exec "${REAL_GH}" "$@"
fi

if [ ! -f "${SCANNER}" ]; then
    printf '[gh-guard] scanner not found at %s — refusing to send.\n' "${SCANNER}" >&2
    printf '           Re-run bootstrap-machine.sh from a healthy guard checkout.\n' >&2
    exit 1
fi

# --- collect everything this call would transmit -----------------------------
payload="$(mktemp)"
stdin_file=""
cleanup() { rm -f "${payload}" "${stdin_file}"; }
trap cleanup EXIT

# The argument vector — minus the paths of files whose *contents* are the
# thing being sent. A body file's path stays on this machine, so scanning it
# refuses legitimate sends whenever the temp directory happens to sit under a
# flagged word. The contents are collected further down.
: > "${payload}"
prev=""
for arg in "$@"; do
    skip=0
    case "${prev}" in
        --body-file|--notes-file|--template|--input)
            skip=1
            ;;
        -F|--field|-f|--raw-field)
            # `key=@path` sends the key and the file's contents, never the path.
            case "${arg}" in
                *=@*)
                    printf '%s=\n' "${arg%%=@*}" >> "${payload}"
                    skip=1
                    ;;
                @*) skip=1 ;;
            esac
            ;;
    esac
    case "${arg}" in
        --body-file=*|--notes-file=*|--template=*|--input=*) skip=1 ;;
    esac
    [ "${skip}" -eq 1 ] || printf '%s\n' "${arg}" >> "${payload}"
    prev="${arg}"
done

# A payload read from stdin has to be captured to be scanned, then replayed to
# the real CLI. Only drain stdin when an argument actually asks for it —
# draining unconditionally would hang every ordinary call.
wants_stdin=0
prev=""
for arg in "$@"; do
    case "${prev}" in
        --body-file|--notes-file|--input)
            [ "${arg}" = "-" ] && wants_stdin=1
            ;;
    esac
    case "${arg}" in
        --body-file=-|--notes-file=-|--input=-) wants_stdin=1 ;;
    esac
    prev="${arg}"
done

if [ "${wants_stdin}" -eq 1 ]; then
    stdin_file="$(mktemp)"
    cat > "${stdin_file}"
    cat "${stdin_file}" >> "${payload}"
fi

# File-backed bodies, notes, templates and API fields.
add_file() {
    [ -n "${1}" ] && [ -f "${1}" ] && cat "${1}" >> "${payload}"
}
prev=""
for arg in "$@"; do
    case "${prev}" in
        --body-file|--notes-file|--template|--input|-F|--field|-f|--raw-field)
            case "${arg}" in
                *=@*) add_file "${arg#*=@}" ;;
                @*)   add_file "${arg#@}" ;;
                -)    ;;
                *)    add_file "${arg}" ;;
            esac
            ;;
    esac
    case "${arg}" in
        --body-file=*|--notes-file=*|--template=*|--input=*)
            value="${arg#*=}"
            [ "${value}" = "-" ] || add_file "${value}"
            ;;
    esac
    prev="${arg}"
done

# ⚠ 走査の報告は stderr へ。stdout は本物の CLI のもの (= `$(gh api ...)` を jq に
# 渡す呼び手が、先頭に混ざった「clean」の 1 行で JSON を読めなくなった)。
if ! ANON_SCAN_PATHS="${payload}" bash "${SCANNER}" >&2; then
    printf '\n[gh-guard] refusing to send: this command carries a flagged identifier.\n' >&2
    printf '           Fix the text (or the file it points at) and run it again.\n' >&2
    exit 1
fi

if [ -n "${stdin_file}" ]; then
    exec "${REAL_GH}" "$@" < "${stdin_file}"
fi
exec "${REAL_GH}" "$@"
