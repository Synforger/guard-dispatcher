#!/usr/bin/env bash
# =============================================================================
# operator master → repo 内 anon-words.txt 同期 (= 真値 1 箇所原則)
# =============================================================================
# <operator master path> を repo 内 .tooling/local-ci/anon-words.txt
# に cp で複製。 真値は operator configにのみ存在し、 各 repo は読み取り専用 mirror。
#
# 派生 repo / 既存 repo どちらでも実行可。 the operator masterしない環境 (= deriver の
# 他人 PC) では skip 警告 + example.txt を anon-words.txt にコピーする
# fallback で動作確保。
#
# 使い方:
#   bash _core/.tooling/local-ci/anon-sync-truth.sh
#   task audit:sync-truth   (= Taskfile 経由)
#
# Exit:
#   0 = 同期成功 (= operator masterあり) or fallback 成功 (= example で初期化)
#   1 = fallback 失敗 (= example.txt も無い設定崩れ)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup-lib.sh
source "${SCRIPT_DIR}/setup-lib.sh"

TRUTH_PATH="${ANON_TRUTH_PATH:-${HOME}/.config/anon-words/master.txt}"
TARGET_PATH="${SCRIPT_DIR}/anon-words.txt"
EXAMPLE_PATH="${SCRIPT_DIR}/anon-words.example.txt"

if [ -f "${TRUTH_PATH}" ]; then
    cp "${TRUTH_PATH}" "${TARGET_PATH}"
    log_ok "synced anon-words.txt from operator master (${TRUTH_PATH})"
    echo "  → ${TARGET_PATH}"
    line_count=$(grep -vc '^#\|^$' "${TARGET_PATH}" || true)
    log_info "active pattern count: ${line_count} 行"
    exit 0
fi

log_warn "operator master not found at ${TRUTH_PATH}"
log_info "set ANON_TRUTH_PATH to override, or fallback to example placeholder"

if [ -f "${EXAMPLE_PATH}" ] && [ ! -f "${TARGET_PATH}" ]; then
    cp "${EXAMPLE_PATH}" "${TARGET_PATH}"
    log_warn "initialised anon-words.txt from example placeholder"
    log_warn "  edit ${TARGET_PATH} manually with your real wordlist"
    exit 0
fi

if [ -f "${TARGET_PATH}" ]; then
    log_info "existing anon-words.txt preserved at ${TARGET_PATH} (= no sync source)"
    exit 0
fi

log_fail "no operator master, no example.txt, no existing anon-words.txt — set up manually"
exit 1
