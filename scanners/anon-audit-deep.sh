#!/usr/bin/env bash
# =============================================================================
# 全 source 横断の deep anon audit (= scanner 強化版)
# =============================================================================
# 通常の anon-scan.sh (= tracked file 内 literal scan) に加えて、 公開可能性
# に関わる全 source を一気に走査する deep audit。
#
# 検査範囲 (= 11 source、 full mode):
#   1. 全 tracked file (= anon-scan.sh 経由)
#   2. 全 git history blob (= git log --all -p)
#   3. 全 commit message + body
#   4. 全 branch 名 (= local + remote)
#   5. 全 tag 名 + tag annotation 本文
#   6. 全 commit author + committer email + name
#   7. GitHub PR title / body + comment threads (= gh api)
#   8. GitHub Issue title / body + comment threads
#   9. GitHub repo description / topics / homepage
#  10. GitHub releases (= title + body + tag)
#
# gh CLI 未 install / 未認証なら 7-11 を skip 警告。 git 履歴系 1-6 は git
# だけで実行可能。
#
# --range <A>..<B> (= pre-push mode):
#   push 境界の壁として毎 push で走らせる用途。 range 内 commit だけを対象に
#   source 2/3/6 を走らせ、 それ以外 (1/4/5/7-11) は skip する:
#     - 1 (tracked files) は pre-commit 段階で staged 単位に scan 済で二重
#     - 4/5 は push 境界と別軸 (= 週次 belt-and-suspenders で拾う)
#     - 7-11 は GitHub API 依存 + push 境界と直交
#   これにより push 前検査を数百 ms 以下に抑え、 過去 leak の repeated
#   findings で人間 fatigue を起こさない。
#
# 使い方:
#   bash .tooling/local-ci/anon-audit-deep.sh
#   bash .tooling/local-ci/anon-audit-deep.sh --range origin/main..HEAD
#   task audit:deep    (= Taskfile 経由、 full mode)
#
# Exit:
#   0 = 全 source clean
#   1 = どこかに leak (= source 別件数 + 内訳を表示)
#   2 = 設定エラー (= anon-words.txt 不在 / --range に不正な revspec 等)
# =============================================================================

set -uo pipefail

RANGE=""
GITHUB_SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --range)
            shift
            RANGE="${1:-}"
            if [ -z "${RANGE}" ]; then
                echo "error: --range requires a revspec (e.g. origin/main..HEAD)" >&2
                exit 2
            fi
            ;;
        --range=*)
            RANGE="${1#--range=}"
            ;;
        --github-since)
            shift
            GITHUB_SINCE="${1:-}"
            ;;
        --github-since=*)
            GITHUB_SINCE="${1#--github-since=}"
            ;;
        -h|--help)
            sed -n '1,50p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The scan target is the repository the caller stands in — not the guard
# checkout this script lives in. Hooks invoke scanners with cwd already at
# the target repo root; direct callers may be anywhere inside the repo.
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${PROJECT_ROOT}" ]; then
    echo "error: not inside a git repository" >&2
    exit 2
fi
cd "${PROJECT_ROOT}"

# shellcheck source=setup-lib.sh
source "${SCRIPT_DIR}/setup-lib.sh"

# Word list resolution (operator master first — the guard checkout itself
# never carries the real list):
#   1. $ANON_WORDS_FILE            explicit override
#   2. `git config guard.wordlist` scope-specific list (conditional include)
#   3. $HOME/.config/anon-words/master.txt   operator master (bootstrap-machine standard)
#   4. $SCRIPT_DIR/anon-words.txt  repo-local synced copy (legacy / repo override)
WORDS_FILE="${ANON_WORDS_FILE:-}"
if [ -z "${WORDS_FILE}" ]; then
    # Scope-specific list via `git config guard.wordlist` (set through a
    # conditional include alongside guard.scope; `~` is expanded here).
    WORDS_FILE="$(git config --get guard.wordlist 2>/dev/null || true)"
    WORDS_FILE="${WORDS_FILE/#\~/${HOME}}"
    WORDS_FILE="${WORDS_FILE/#\$HOME/${HOME}}"
fi
if [ -z "${WORDS_FILE}" ]; then
    if [ -f "${HOME}/.config/anon-words/master.txt" ]; then
        WORDS_FILE="${HOME}/.config/anon-words/master.txt"
    else
        WORDS_FILE="${SCRIPT_DIR}/anon-words.txt"
    fi
fi
if [ ! -f "${WORDS_FILE}" ]; then
    log_fail "anon-words.txt not found (${WORDS_FILE}): sync from the operator master (bash ${SCRIPT_DIR}/anon-sync-truth.sh)"
    exit 2
fi

# 真値を 1 行 1 pattern として読み、 | で連結して PCRE 化
ANON_PATTERN="$(grep -v '^#' "${WORDS_FILE}" | grep -v '^$' | sed -E 's/[[:space:]]+#.*$//' | tr '\n' '|' | sed 's/|$//')"
if [ -z "${ANON_PATTERN}" ]; then
    log_fail "anon-words.txt contains no active patterns"
    exit 2
fi
export ANON_PATTERN

# range mode の検証: revspec を git rev-list に食わせて合法か確認。 空 range
# (= push 対象 commit ゼロ) は clean 扱いで即 exit 0。
if [ -n "${RANGE}" ]; then
    if ! git rev-list "${RANGE}" >/dev/null 2>&1; then
        echo "error: invalid --range revspec: ${RANGE}" >&2
        exit 2
    fi
    n_commits="$(git rev-list --count "${RANGE}" 2>/dev/null || echo 0)"
    if [ "${n_commits}" -eq 0 ]; then
        printf '(deep audit: push range %s has no commits, skipping)\n' "${RANGE}" >&2
        exit 0
    fi
    printf '\n=== deep audit: push range mode (%s, %s commits) ===\n' "${RANGE}" "${n_commits}" >&2
fi

# 共通 perl scanner (= 全 source で再利用)
# NFKC で全角 / 互換文字を canonical 形に畳んでから照合する (= 半角 word list
# を全角表記がすり抜けるのを防ぐ)。 (?i) で大小も畳む。
scan_perl() {
    perl -CSD -MUnicode::Normalize -MEncode -ne 'BEGIN { my $pat = NFKC(decode_utf8($ENV{ANON_PATTERN})); $re = qr{(?i)$pat} } my $n = NFKC($_); if ($n =~ /$re/) { print "$&\n" }' 2>/dev/null | sort -u
}

count_hits() {
    local label="$1" hits="$2"
    local n
    n=$(printf "%s" "${hits}" | grep -c . 2>/dev/null || true)
    if [ "${n}" -eq 0 ]; then
        log_ok "${label}: clean"
    else
        log_fail "${label}: ${n} hit(s) = $(printf "%s" "${hits}" | tr '\n' ' ')"
    fi
    echo "${n}"
}

total=0

# --- source 1: tracked file (= anon-scan.sh 経由) ---
# range mode では skip (= pre-commit 段階で既に staged 単位に scan 済)
if [ -z "${RANGE}" ]; then
    printf '\n=== source 1/11: tracked files (= anon-scan.sh) ===\n' >&2
    if bash "${SCRIPT_DIR}/anon-scan.sh" >/dev/null 2>&1; then
        log_ok "tracked files: clean"
    else
        log_fail "tracked files: leak found (run bash anon-scan.sh for details)"
        total=$((total + 1))
    fi
fi

# --- source 2: git history blob ---
# full mode = 全 history の全 diff (= 削除行も対象、 「履歴に残っているか」 が主題)。
# range mode = これから公開される「新規内容」 のみ = 追加行 (+) と新パス (+++)。
#   削除行 (-) / context 行を含めると「既公開の leak を除去する commit」 が
#   自分の削除 diff で検出され、 修正 PR が構造的に push 不能になるため除外。
#   range 内で追加→削除されたものは追加時の + 行で検出されるので漏れない。
printf '
=== source 2/11: git history blob (all diffs of all commits) ===
' >&2
if [ -n "${RANGE}" ]; then
    hits=$(git log "${RANGE}" -p 2>/dev/null | grep -E '^\+' | scan_perl)
else
    hits=$(git log --all -p 2>/dev/null | scan_perl)
fi
n=$(count_hits "git history blob" "${hits}")
total=$((total + n))

# --- source 3: commit message ---
printf '\n=== source 3/11: commit messages ===\n' >&2
if [ -n "${RANGE}" ]; then
    hits=$(git log "${RANGE}" --pretty='format:%H %s%n%b' 2>/dev/null | scan_perl)
else
    hits=$(git log --all --pretty='format:%H %s%n%b' 2>/dev/null | scan_perl)
fi
n=$(count_hits "commit messages" "${hits}")
total=$((total + n))

# --- source 4: branch 名 ---
# range mode では skip (= push 境界と別軸、 週次 audit で拾う)
if [ -z "${RANGE}" ]; then
    printf '\n=== source 4/11: branch names ===\n' >&2
    hits=$(git branch -a 2>/dev/null | scan_perl)
    n=$(count_hits "branch names" "${hits}")
    total=$((total + n))
fi

# --- source 5: tag 名 + annotation ---
# range mode では skip
if [ -z "${RANGE}" ]; then
    printf '\n=== source 5/11: tag names + annotations ===\n' >&2
    tag_text=$(git tag -l 2>/dev/null; for t in $(git tag -l 2>/dev/null); do git tag -l --format='%(contents)' "$t" 2>/dev/null; done)
    hits=$(printf "%s" "${tag_text}" | scan_perl)
    n=$(count_hits "tags" "${hits}")
    total=$((total + n))
fi

# --- source 6: author + committer ---
printf '\n=== source 6/11: author + committer email / name ===\n' >&2
if [ -n "${RANGE}" ]; then
    hits=$(git log "${RANGE}" --pretty='format:%an <%ae> / %cn <%ce>' 2>/dev/null | scan_perl)
else
    hits=$(git log --all --pretty='format:%an <%ae> / %cn <%ce>' 2>/dev/null | scan_perl)
fi
n=$(count_hits "author/committer" "${hits}")
total=$((total + n))

# --- source 7-11: GitHub metadata (= gh CLI 経由) ---
# range mode では skip (= 全部 push 境界と直交)
if [ -z "${RANGE}" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        log_warn "gh CLI not installed, skipping GitHub-side sources 7-11"
    elif ! gh auth status >/dev/null 2>&1; then
        log_warn "gh CLI not authenticated, skipping GitHub-side sources 7-11"
    else
        # repo 名を git remote から推定。 github.com / github-* SSH alias 両対応。
        # BSD sed の ERE が alternation + quantifier で詰むので python に逃す。
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")
        repo=$(printf '%s' "${remote_url}" | python3 -c "
import re, sys
m = re.match(r'^(?:git@[^:]+:|https?://[^/]+/)([^/]+)/([^/.]+)(?:\.git)?$', sys.stdin.read().strip())
print(f'{m.group(1)}/{m.group(2)}' if m else '')
")

        if [ -z "${repo}" ]; then
            log_warn "remote origin is not a GitHub URL, skipping GitHub-side sources 7-11"
        else
            # --- source 7-8: PR + Issue title/body + comment threads ---
            # The issues endpoint returns PRs too, so one paginated walk
            # covers both title + body. Comment threads are the one public
            # text surface that never passes through git or pr-create.sh, so
            # they are folded into this source: `issues/comments` catches PR
            # conversation + Issue comments (a PR comment is an issue comment
            # server-side), `pulls/comments` catches inline diff review
            # comments. Residual = a PR review *summary* body, which only a
            # per-PR endpoint exposes (rare, left out to keep the walk cheap).
            # With --github-since every endpoint is filtered to records
            # updated after that instant (edits bump updated_at), keeping the
            # weekly cost proportional to activity, not repo age.
            if [ -n "${GITHUB_SINCE}" ]; then
                printf '\n=== source 7-8/11: GitHub PR+Issue title/body/comments (updated since %s) ===\n' "${GITHUB_SINCE}" >&2
                hits=$( {
                    gh api --paginate "repos/${repo}/issues?state=all&per_page=100&since=${GITHUB_SINCE}" --jq '.[] | .title, .body'
                    gh api --paginate "repos/${repo}/issues/comments?per_page=100&since=${GITHUB_SINCE}" --jq '.[].body'
                    gh api --paginate "repos/${repo}/pulls/comments?per_page=100&since=${GITHUB_SINCE}" --jq '.[].body'
                } 2>/dev/null | scan_perl)
            else
                printf '\n=== source 7-8/11: GitHub PR+Issue title/body/comments (full) ===\n' >&2
                hits=$( {
                    gh api --paginate "repos/${repo}/issues?state=all&per_page=100" --jq '.[] | .title, .body'
                    gh api --paginate "repos/${repo}/issues/comments?per_page=100" --jq '.[].body'
                    gh api --paginate "repos/${repo}/pulls/comments?per_page=100" --jq '.[].body'
                } 2>/dev/null | scan_perl)
            fi
            n=$(count_hits "GitHub PR/Issue text" "${hits}")
            total=$((total + n))

            # --- source 9: repo description + topics + homepage ---
            printf '\n=== source 9/11: GitHub repo description / topics / homepage ===\n' >&2
            hits=$(gh repo view "${repo}" --json description,topics,homepageUrl 2>/dev/null | scan_perl)
            n=$(count_hits "GitHub repo metadata" "${hits}")
            total=$((total + n))

            # --- source 10: releases ---
            printf '\n=== source 10/11: GitHub releases ===\n' >&2
            hits=$(gh api --paginate "repos/${repo}/releases?per_page=100" --jq '.[] | .name, .body, .tag_name' 2>/dev/null | scan_perl)
            n=$(count_hits "GitHub releases" "${hits}")
            total=$((total + n))

            # --- source 11: GitHub Actions run records (= displayTitle) ---
            # `gh run` の run record は force-push で書き換わらない: 元 commit
            # oid を保持したまま original message を title 表示する。 過去 leak
            # scrub で history + PR title を rename しても、 ここに残ると
            # 公開状態で参照可能 (= 実 事故を起こしたのでこの source が追加された)。
            printf '\n=== source 11/11: GitHub Actions run records (= displayTitle) ===\n' >&2
            if [ -n "${GITHUB_SINCE}" ]; then
                # Run titles are immutable, so a created-date filter loses
                # nothing. The API accepts date-only bounds.
                since_date="${GITHUB_SINCE%%T*}"
                hits=$(gh api --paginate "repos/${repo}/actions/runs?per_page=100&created=%3E%3D${since_date}" --jq '.workflow_runs[].display_title' 2>/dev/null | scan_perl)
            else
                hits=$(gh api --paginate "repos/${repo}/actions/runs?per_page=100" --jq '.workflow_runs[].display_title' 2>/dev/null | scan_perl)
            fi
            n=$(count_hits "GitHub runs" "${hits}")
            total=$((total + n))
        fi
    fi
fi

printf '\n' >&2
if [ "${total}" -eq 0 ]; then
    if [ -n "${RANGE}" ]; then
        log_ok "deep audit (push range): clean (0 hits)"
    else
        log_ok "deep audit: all sources clean (0 hits)"
    fi
    exit 0
fi
log_fail "deep audit: ${total} leak(s) in total"
exit 1
