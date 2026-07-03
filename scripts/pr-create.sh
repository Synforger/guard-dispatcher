#!/usr/bin/env bash
# =============================================================================
# pr-create — anon-scan を通してから gh pr create する wrapper
# =============================================================================
# PR title / body は git hook が構造的に通らない唯一の公開経路 (= commit /
# push は dispatcher が守るが、 PR text は gh CLI から GitHub へ直行する)。
# この wrapper が最後の隙間を塞ぐ: title + body を scanner に通し、 clean の
# 時だけ gh pr create を実行する。
#
# 使い方:
#   bash scripts/pr-create.sh --title "..." --body-file body.md [--base main] [gh 追加引数...]
#   task pr:create TITLE="..." BODY_FILE=body.md [BASE=main]
#
# Exit:
#   0 = PR 作成成功
#   1 = anon-scan が leak を検出 (= PR は作られない)
#   2 = 引数 / 環境エラー
# =============================================================================

set -uo pipefail

TITLE=""
BODY_FILE=""
BASE="main"
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --title)      shift; TITLE="${1:-}" ;;
        --body-file)  shift; BODY_FILE="${1:-}" ;;
        --base)       shift; BASE="${1:-}" ;;
        -h|--help)    sed -n '1,20p' "$0"; exit 0 ;;
        *)            EXTRA_ARGS+=("$1") ;;
    esac
    shift
done

if [ -z "${TITLE}" ] || [ -z "${BODY_FILE}" ]; then
    echo "error: --title and --body-file are required" >&2
    exit 2
fi
if [ ! -f "${BODY_FILE}" ]; then
    echo "error: body file not found: ${BODY_FILE}" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${REPO_ROOT}" ]; then
    echo "error: not inside a git repository" >&2
    exit 2
fi

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="${REPO_ROOT}/.tooling/local-ci/anon-scan.sh"
if [ ! -f "${SCANNER}" ]; then
    SCANNER="${GUARD_ROOT}/scanners/anon-scan.sh"
fi
if [ ! -f "${SCANNER}" ]; then
    echo "error: anon-scan.sh not found (repo-local or guard bundled)" >&2
    exit 2
fi

# title + body を 1 つの一時ファイルに束ねて scan (= tmpdir は shell が掃除)
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
{
    printf '%s\n\n' "${TITLE}"
    cat "${BODY_FILE}"
} > "${tmp}"

if ! ANON_SCAN_PATHS="${tmp}" bash "${SCANNER}"; then
    echo "" >&2
    echo "[pr-create] PR text contains a flagged identifier — fix the title/body and retry." >&2
    exit 1
fi

exec gh pr create --base "${BASE}" --title "${TITLE}" --body-file "${BODY_FILE}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
