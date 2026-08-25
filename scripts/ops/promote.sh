#!/bin/bash
# 晉升（LS-85）：development→test、test→main 一律 fast-forward push——不開 PR、不留 merge commit、不再 back-merge。
# 帳：LS-57 一張票花了 4 個 PR（dev→test、test→main、兩支 back-merge）、4 輪 CI、零人審，全為了讓分支保護放行；
# back-merge 純粹是 --merge 在 main 留 merge commit 造成。三條分支從不直接 commit → 永遠是祖先鏈 → 晉升就是 FF。
# merge-reviewer 不動（本來就只審 feature／fix／hotfix PR）；gate 不減、換位置：
#   server-side：test／main 的 required status checks 對推上去的 SHA 生效（沒有綠 check 的 SHA 推不上去，GH006；
#               scripts/ops/protection-apply.sh）
#   client-side：本腳本驗 FF＋四個 check；push-gate（scripts/gates/push-ref-check.sh）擋繞過本腳本的 test／main 推送；
#               漂移由 scripts/ops/patrol.sh 偵測。
#
# 用法：promote.sh <from> <to>       只接受 development test ／ test main；在 repo 內任一目錄執行
# 步驟：(a) git fetch origin
#       (b) 方向
#       (c) FF：origin/<to> 須為 origin/<from> 的祖先，否則拒絕並指示先 back-merge
#       (d) origin/<from> 的 SHA 在 GitHub 的 check-runs：只認 GitHub Actions（app id 15368，與分支保護 required checks 限 app
#           一致——別的 app 貼同名 check 不算，PR #141 R1 F5）的 ci／db／lint／rules，各取最新一筆（id 最大；同一 SHA 推到 test
#           後會再跑一輪，與 GitHub 分支保護「看最新一筆」一致），status completed 且 conclusion success 才放行；缺／skipped／
#           failure／in_progress 皆拒絕並印出是哪一個
#       (e) PROMOTE_VIA_SCRIPT=1 git push origin <驗過的 sha>:refs/heads/<to>——推 (c)(d) 驗過的那個 SHA、不推 origin/<from> ref：
#           巡檢 cron 每 26 分鐘 fetch 會移動 remote-tracking ref，ref 與驗過的 SHA 之間有空窗（PR #141 R1 F1）；push-gate 憑此
#           變數＋FF 放行並早退
#       (f) 印 from／to／sha／check 摘要；test→main 提醒打 tag
# exit 0＝已晉升（或 origin/<to> 已等於 origin/<from>，無需動作）；1＝拒絕（非 FF／check 未全綠／遠端拒收）；
#      2＝參數或環境錯誤（方向不合法、不在 git repo、fetch／gh 失敗——fail closed，不猜）
# 自測：scripts/ops/promote.test.sh（合成 repo＋stub gh，掛 CI rules job）。規約：docs/COLLABORATION.md §2、§7。
set -uo pipefail

REQUIRED_CHECKS="ci db lint rules"
CHECKS_APP_ID=15368   # GitHub Actions；分支保護的 required checks 也限這個 app（scripts/ops/protection-apply.sh）

usage() { echo "用法：promote.sh <from> <to>（development test ／ test main）" >&2; exit 2; }
[ $# -eq 2 ] || usage
from=$1; to=$2
case "${from}→${to}" in
  "development→test"|"test→main") ;;
  *) echo "✗ promote：方向 ${from}→${to} 不合法，只允許 development→test、test→main（hotfix 走 PR 進 main、feature 走 PR 進 development）。" >&2; exit 2 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ promote：目前目錄不在 git repo 內。" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "✗ promote：需要 gh（brew install gh）。" >&2; exit 2; }

# (a)
git fetch -q origin || { echo "✗ promote：git fetch origin 失敗。" >&2; exit 2; }
for b in "$from" "$to"; do
  git rev-parse -q --verify "refs/remotes/origin/${b}" >/dev/null || { echo "✗ promote：本機沒有 origin/${b}。" >&2; exit 2; }
done
from_sha=$(git rev-parse "refs/remotes/origin/${from}")
to_sha=$(git rev-parse "refs/remotes/origin/${to}")

echo "== promote ${from} → ${to}"
echo "  origin/${from}  $(git log -1 --format='%h %s' "$from_sha")"
echo "  origin/${to}    $(git log -1 --format='%h %s' "$to_sha")"

if [ "$from_sha" = "$to_sha" ]; then
  echo "✓ origin/${to} 已等於 origin/${from}，無需晉升。"
  exit 0
fi

# (c)
if ! git merge-base --is-ancestor "$to_sha" "$from_sha"; then
  extra=$(git rev-list --count "${from_sha}..${to_sha}")
  echo "✗ promote：非 fast-forward——origin/${to} 有 ${extra} commit 不在 origin/${from}：" >&2
  git log --format='    %h %s' "${from_sha}..${to_sha}" | head -10 >&2
  case "$to" in
    test) echo "  先把 origin/test 併回 development（hotfix/LS-<n>-backmerge-development 分支 merge origin/test → PR 進 development），再晉升（docs/COLLABORATION.md §2）。" >&2 ;;
    main) echo "  先 back-merge main→development（gh pr create --head main --base development）→ promote.sh development test → 再晉升 test→main（docs/COLLABORATION.md §2）。" >&2 ;;
  esac
  exit 1
fi
ahead=$(git rev-list --count "${to_sha}..${from_sha}")
echo "  FF  origin/${to} 是 origin/${from} 的祖先（晉升 ${ahead} commit）"

# (d)
runs=$(gh api "repos/{owner}/{repo}/commits/${from_sha}/check-runs?per_page=100" \
  --jq '.check_runs | map(select(.app.id == '"${CHECKS_APP_ID}"')) | sort_by(.id) | .[] | [.name, .status, (.conclusion // "-"), (.html_url // "-")] | @tsv') || {
  echo "✗ promote：gh api check-runs 失敗（未登入？離線？）——不猜，拒絕晉升。" >&2; exit 2; }
bad=0
for name in $REQUIRED_CHECKS; do
  line=$(printf '%s\n' "$runs" | awk -F'\t' -v n="$name" '$1 == n' | tail -1)
  if [ -z "$line" ]; then
    echo "  check ${name}: 缺（該 SHA 沒有 GitHub Actions（app ${CHECKS_APP_ID}）的這個 check-run——CI 還沒對 push 跑？.github/workflows/ci.yml 的 ${name} job 在 push 事件下要跑）"
    bad=1; continue
  fi
  st=$(printf '%s' "$line" | cut -f2); cc=$(printf '%s' "$line" | cut -f3); url=$(printf '%s' "$line" | cut -f4)
  if [ "$st" = completed ] && [ "$cc" = success ]; then
    echo "  check ${name}: ✓ success"
  else
    echo "  check ${name}: ✗ ${st}/${cc}  ${url}"; bad=1
  fi
done
if [ "$bad" -ne 0 ]; then
  echo "✗ promote：origin/${from} ${from_sha} 的 check 未全綠（上列），拒絕晉升。未完成的等 CI 跑完再試；failure 先修；skipped＝CI 在 push 事件下跳過了該 job。" >&2
  exit 1
fi

# (e)
echo "→ PROMOTE_VIA_SCRIPT=1 git push origin ${from_sha}:refs/heads/${to}"
if ! PROMOTE_VIA_SCRIPT=1 git push origin "${from_sha}:refs/heads/${to}"; then
  echo "✗ promote：push 被拒（遠端在 fetch 之後又前進？分支保護的 required checks 對該 SHA 未滿足？）——重跑一次；仍紅看上方 remote 訊息。" >&2
  exit 1
fi

# (f)
echo "✓ 已晉升 ${to} → ${from_sha}（${ahead} commit；check ci／db／lint／rules 全綠）"
if [ "$to" = main ]; then echo "  → release：打 tag vX.Y.Z（docs/COLLABORATION.md §6）"; fi
exit 0
