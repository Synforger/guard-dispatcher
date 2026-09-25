#!/usr/bin/env bash
# =============================================================================
# bootstrap-machine — 新マシンの防御一式を 1 コマンドで配備する
# =============================================================================
# 「機構は強いのに、 このマシンには配備されていなかった」 という状態を潰す。
# 実際に起きた failure mode: dispatcher 未 arm + operator master 不在のまま
# 数週間運用され、 その間の commit が一切 scan されていなかった。
#
# やること (= 冪等、 何度実行しても安全):
#   1. global hooks dispatcher の arm (= scripts/install.sh)
#   2. gh command guard の設置 (= ~/.local/bin/gh を shim に、 CLI が送る
#      本文 / コメント / payload を hook の外側で scan)
#   3. operator master word list の存在確認 (= 不在なら配置手順を案内、
#      scanner は master 直読するので per-repo 配信は不要)
#   4. 外部 binary の存在確認 (= gitleaks / git-filter-repo / task / gh /
#      perl、 不在は install ヒント表示。 hard fail にはしない)
#   5. 総仕上げの診断 (= hooks doctor、 マシン診断軸込み)
#
# Exit:
#   0 = 配備完了 + doctor clean
#   1 = doctor に findings あり (= 出力の指示に従って解消)
#   2 = operator master 不在 (= 手動配置が必要、 案内を表示済み)
#
# 使い方 (guard-dispatcher checkout から):
#   bash scripts/bootstrap-machine.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../scanners/setup-lib.sh
source "${GUARD_ROOT}/scanners/setup-lib.sh"

TRUTH_PATH="${ANON_TRUTH_PATH:-${HOME}/.config/anon-words/master.txt}"

echo "=== bootstrap-machine: arming this machine ==="

# --- 1. dispatcher arm ------------------------------------------------------
bash "${GUARD_ROOT}/scripts/install.sh"

# --- 2. gh command guard ------------------------------------------------------
# The hooks only see what leaves through git. Everything the CLI sends —
# PR and issue bodies, comment threads, release notes, repository
# descriptions, API payloads — bypasses them entirely, and a wrapper for one
# command only covers the path someone remembers to call. Shadow the binary
# instead, so the scan happens wherever the call comes from.
GH_SHIM_DIR="${HOME}/.local/bin"
GH_SHIM="${GH_SHIM_DIR}/gh"
mkdir -p "${GH_SHIM_DIR}"
if [ -e "${GH_SHIM}" ] && [ ! -L "${GH_SHIM}" ]; then
    log_warn "${GH_SHIM} exists and is not a symlink — left alone, so gh calls stay unscanned"
elif [ "$(readlink "${GH_SHIM}" 2>/dev/null || true)" = "${GUARD_ROOT}/gh-shim/gh-guard.sh" ]; then
    log_ok "gh command guard already installed (${GH_SHIM})"
else
    ln -sf "${GUARD_ROOT}/gh-shim/gh-guard.sh" "${GH_SHIM}"
    log_ok "gh command guard installed (${GH_SHIM})"
fi

# A shim the shell never resolves to is the same as no shim at all — and
# PATH order is per-shell, not per-machine: a login bash rebuilds PATH from
# the system defaults and never reads a zsh profile, so a shim that sits
# first in one shell can sit behind the real binary in another. Checking
# only the shell that happens to run this script would report a coverage
# that does not exist. Ask each shell installed here.
shim_gaps=0
for sh_bin in zsh bash sh; do
    command -v "${sh_bin}" >/dev/null 2>&1 || continue
    resolved="$("${sh_bin}" -lc 'command -v gh' 2>/dev/null | tail -1 || true)"
    [ -n "${resolved}" ] || continue
    if [ "${resolved}" = "${GH_SHIM}" ]; then
        log_ok "login ${sh_bin} resolves gh to the shim"
    else
        shim_gaps=$((shim_gaps + 1))
        log_warn "login ${sh_bin} resolves gh to ${resolved} — gh calls from ${sh_bin} go unscanned"
    fi
done
if [ "${shim_gaps}" -gt 0 ]; then
    cat >&2 <<MSG
    To close a gap, put the shim directory ahead of the real CLI in that
    shell's own startup file, e.g. for bash:

        echo 'export PATH="${GH_SHIM_DIR}:\$PATH"' >> ~/.bash_profile

MSG
fi

# --- 3. operator master -----------------------------------------------------
if [ ! -f "${TRUTH_PATH}" ]; then
    log_warn "operator master word list not found: ${TRUTH_PATH}"
    cat >&2 <<MSG

  The master word list is private operator data and is never committed
  anywhere public. Place your personal master list at:

      ${TRUTH_PATH}

  (or export ANON_TRUTH_PATH to point elsewhere). Format: one PCRE
  fragment per line, '#' comments. See scanners/anon-words.example.txt
  for the format. Scanners read this master directly — no per-repo
  copies are needed.

  Then re-run this script.
MSG
    exit 2
fi
log_ok "operator master present (${TRUTH_PATH})"

# --- 4. external binaries ----------------------------------------------------
missing=0
need() {
    local bin="$1" hint="$2"
    if command -v "${bin}" >/dev/null 2>&1; then
        log_ok "${bin} available"
    else
        log_warn "${bin} MISSING — ${hint}"
        missing=$((missing + 1))
    fi
}
need gitleaks        "brew install gitleaks  (secret scan in pre-commit)"
need git-filter-repo "brew install git-filter-repo  (anon-fix range scrub)"
need task            "brew install go-task  (Taskfile entrypoint)"
need gh              "brew install gh  (deep audit sources 7-11)"
need perl            "ships with macOS / apt install perl  (scanner core)"
if [ "${missing}" -gt 0 ]; then
    log_warn "${missing} optional binaries missing — features degrade gracefully but install them for full coverage"
fi

# --- 5. final diagnosis -------------------------------------------------------
echo ""
bash "${GUARD_ROOT}/scripts/doctor.sh" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
