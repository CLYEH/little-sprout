#!/bin/bash
# 分支起點乾淨度（LS-50）：工作分支自 merge-base 以來的每個非 merge commit，subject 的票號必須等於分支名的票號。
# 來源：feature/LS-38-pink-tracks 疊了 LS-31 的三個 commit（LS-31 從未開 PR），違反「一張 ticket＝一條 branch」
# 卻沒有任何機械 gate 攔到。掛 push-gate（本機）＋CI rules job（--pr-body）；自測 branch-ticket-check.test.sh。
#
# 用法：branch-ticket-check.sh --base <ref|sha> [--branch <name>] [--pr-body <file>]
#   --base     merge-base 的對象（push-gate 依方向矩陣傳 origin/development／origin/main；CI 傳 origin/$BASE）。
#              找不到即 exit 2（先 git fetch origin），不靜默跳過。
#   --branch   分支名，預設當前分支（CI 的 checkout 是 detached merge ref，必須傳 $HEAD）。不符
#              (feature|fix|hotfix)/LS-<n>-<slug> 即 exit 2——呼叫端只該對工作分支呼叫，保護分支沒有「本票」可比。
#   --pr-body  PR body 檔（CI 用）：commit body 宣告的夾帶必須同時出現在 PR body，否則 exit 1（逃生口使用須在 PR 可見）。
#
# 範圍：merge-base..HEAD、--no-merges，再排除已在任一保護分支（origin/main|development|test，存在者）上的 commit——
#   同 CI commit-message 檢查的 LS-10 做法：那些 commit 已在自己的 PR 驗過，把保護分支 merge 回來解衝突不算夾帶。
# 票號：subject 第一個 `LS-<n>`（commit 格式 `<type>(<scope>): LS-<n> …`；`Revert "…"`／`fixup! …` 也抓得到第一個）。
#   沒有票號一律違規——無從宣告，且 commit-msg gate 本來就不該放它過。
# 逃生口：任一 commit 的 body 與 PR body 各有**獨佔一行**的 `Bundles: LS-<m>[, LS-<k>…]`（比照 DESTRUCTIVE-APPROVED／
#   BREAKING: 的行錨定：散文提及、粗體包起、列點前綴皆不算；理由寫在下一行），涵蓋全部異票號才放行，並印出宣告。
# exit 0＝乾淨或已宣告；1＝違規；2＝參數／ref 錯誤（fail closed）。
set -uo pipefail

base=; branch=; pr_body=
while [ $# -gt 0 ]; do
  case "$1" in
    --base|--branch|--pr-body)
      if [ -z "${2:-}" ]; then echo "✗ branch-ticket-check：$1 缺值" >&2; exit 2; fi
      case "$1" in --base) base=$2 ;; --branch) branch=$2 ;; --pr-body) pr_body=$2 ;; esac
      shift 2 ;;
    *) echo "✗ branch-ticket-check：未知參數 $1" >&2; exit 2 ;;
  esac
done
[ -n "$base" ] || { echo "✗ branch-ticket-check：缺 --base <ref>" >&2; exit 2; }
[ -n "$branch" ] || branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)

ticket=$(printf '%s' "$branch" | sed -nE 's#^(feature|fix|hotfix)/(LS-[1-9][0-9]*)-[a-z0-9][a-z0-9-]*$#\2#p')
if [ -z "$ticket" ]; then
  echo "✗ branch-ticket-check：「${branch}」不是 (feature|fix|hotfix)/LS-<n>-<slug> 工作分支，沒有本票票號可比。" >&2
  exit 2
fi
if ! git rev-parse -q --verify "${base}^{commit}" >/dev/null; then
  echo "✗ branch-ticket-check：找不到 ${base}（先 git fetch origin）。" >&2
  exit 2
fi
base_sha=$(git merge-base "$base" HEAD) || { echo "✗ branch-ticket-check：${base} 與 HEAD 無共同祖先。" >&2; exit 2; }
if [ -n "$pr_body" ] && [ ! -r "$pr_body" ]; then
  echo "✗ branch-ticket-check：讀不到 --pr-body ${pr_body}。" >&2
  exit 2
fi

exclude=
for r in origin/main origin/development origin/test; do
  git rev-parse -q --verify "refs/remotes/${r}^{commit}" >/dev/null && exclude="${exclude} ${r}"
done
# shellcheck disable=SC2086  # $exclude 是以空白分隔的 ref 名清單，刻意不加引號
commits=$(git rev-list --no-merges --reverse "${base_sha}..HEAD" --not $exclude)

bundles_re='^[[:space:]]*Bundles:[[:space:]]*LS-[1-9][0-9]*(([[:space:]]*,[[:space:]]*|[[:space:]]+)LS-[1-9][0-9]*)*[[:space:]]*$'

n=0; noticket=; foreign_lines=; foreign=
for c in $commits; do
  n=$((n + 1))
  subject=$(git log -1 --format=%s "$c")
  t=$(printf '%s' "$subject" | grep -oE 'LS-[1-9][0-9]*' | head -n1 || true)
  short=$(printf '%s' "$c" | cut -c1-7)
  if [ -z "$t" ]; then
    noticket="${noticket}    ${short} [無票號] ${subject}"$'\n'
  elif [ "$t" != "$ticket" ]; then
    foreign="${foreign}${t}"$'\n'
    foreign_lines="${foreign_lines}    ${short} [${t}] ${subject}"$'\n'
  fi
done
foreign=$(printf '%s' "$foreign" | sort -u)

# shellcheck disable=SC2086
declared=$(git log --no-merges --format=%b "${base_sha}..HEAD" --not $exclude | grep -E "$bundles_re" | grep -oE 'LS-[1-9][0-9]*' | sort -u || true)

undeclared=
for t in $foreign; do
  printf '%s\n' "$declared" | grep -qx "$t" || undeclared="${undeclared}${t}"$'\n'
done

if [ -n "$noticket" ] || [ -n "$undeclared" ]; then
  echo "✗ branch-ticket-check：分支 ${branch}（${ticket}）夾帶了非本票的 commit（一張 ticket＝一條 branch，CLAUDE.md）：" >&2
  [ -n "$noticket" ] && printf '%s' "$noticket" >&2
  for t in $undeclared; do
    printf '%s' "$foreign_lines" | grep -F "[${t}]" >&2
  done
  echo "  非刻意：回各自 worktree、把這些 commit 從本分支拿掉（rebase）。" >&2
  echo "  刻意夾帶：本票 commit body 加獨佔一行 \`Bundles: $(printf '%s' "$undeclared" | paste -s -d, - | sed 's/,/, /g')\`（理由寫下一行），PR body 同步宣告（CI 驗）。" >&2
  exit 1
fi

if [ -z "$foreign" ]; then
  echo "✓ 分支票號乾淨（${ticket}，${n} commits）"
  exit 0
fi

echo "→ 分支 ${branch} 以 commit body 宣告夾帶：Bundles: $(printf '%s\n' "$foreign" | paste -s -d, - | sed 's/,/, /g')（PR body 須同步宣告，CI 驗）"
if [ -n "$pr_body" ]; then
  pr_declared=$(grep -E "$bundles_re" "$pr_body" | grep -oE 'LS-[1-9][0-9]*' | sort -u || true)
  missing=
  for t in $foreign; do
    printf '%s\n' "$pr_declared" | grep -qx "$t" || missing="${missing}${t}"$'\n'
  done
  if [ -n "$missing" ]; then
    echo "✗ branch-ticket-check：commit body 宣告夾帶 $(printf '%s\n' "$missing" | paste -s -d, - | sed 's/,/, /g')，但 PR body 沒有獨佔一行的 \`Bundles: …\` 涵蓋它們——逃生口使用必須在 PR 可見。" >&2
    exit 1
  fi
  echo "✓ PR body 已宣告 Bundles: $(printf '%s\n' "$pr_declared" | paste -s -d, - | sed 's/,/, /g')"
fi
exit 0
