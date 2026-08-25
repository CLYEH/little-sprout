#!/bin/bash
# push-ref-check（LS-85 G4／LS-87 G4）：pre-push stdin 逐條 ref 分類，決定 push-gate 要不要跑、能不能推。
#   stdin 每行 <local ref> <local sha> <remote ref> <remote sha>（git pre-push 格式；push-gate.sh 把自己的 stdin 交給本腳本）
#   ・remote ref 不是 refs/heads/*（tag）或 local sha 全 0（刪除分支）→ 不需 gate（2026-08-25 29 條分支刪除與 2 個 tag 推送各跑了
#     整套 lint＋unit tests——刪除／tag 沒有「要驗的內容」）
#   ・remote ref 是 refs/heads/test 或 refs/heads/main → 只准 scripts/ops/promote.sh（PROMOTE_VIA_SCRIPT=1）且 fast-forward
#     （remote sha 是 local sha 的祖先；remote sha 本機沒有＝沒 fetch，fail closed）；通過＝晉升，該 SHA 的 check 由
#     promote.sh 與 GitHub required checks 驗，本機 lint／tests 跑的是當前 worktree、與被推的 SHA 無關 → 不需 gate
#   ・其餘 refs/heads/*（feature／fix／hotfix、development）→ 需要完整 push gate
# exit 0＝至少一條 ref 需要完整 gate（或 stdin 沒有任何 ref：手動執行時維持既有行為）；1＝擋；2＝stdin 格式錯（fail closed）；
#      3＝本次 push 沒有任何 ref 需要完整 gate（push-gate 據此早退 exit 0）
# GitHub 沒有「拒絕非 FF 推送」的規則（require linear history 會連 development 自己的 PR merge commit 一起拒），所以 FF 只能在
# 客戶端驗；--no-verify 繞過後靠 required checks（沒有綠 check 的 SHA 推不上去）＋scripts/ops/patrol.sh 漂移偵測。
# 自測：push-ref-check.test.sh（含經 push-gate.sh 的接線）。規約：docs/COLLABORATION.md §2、§4、§7。
set -uo pipefail

ZERO=0000000000000000000000000000000000000000
need_gate=0; blocked=0; seen=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  # shellcheck disable=SC2086
  set -- $line
  if [ $# -ne 4 ]; then echo "✗ push-ref-check：stdin 不是 pre-push 格式（應 4 欄）：${line}" >&2; exit 2; fi
  lsha=$2; rref=$3; rsha=$4
  seen=$((seen + 1))
  case "$rref" in
    refs/heads/*) ;;
    *) echo "  push-ref-check：${rref} 非分支（tag？）→ 不需 gate"; continue ;;
  esac
  if [ "$lsha" = "$ZERO" ]; then echo "  push-ref-check：刪除 ${rref} → 不需 gate"; continue; fi
  branch=${rref#refs/heads/}
  case "$branch" in
    test|main)
      if [ "${PROMOTE_VIA_SCRIPT:-}" != 1 ]; then
        echo "✗ push-ref-check：refs/heads/${branch} 只能由 bash scripts/ops/promote.sh 晉升（fast-forward push；docs/COLLABORATION.md §2），禁止手動 push。hotfix 走 PR 進 main。" >&2
        blocked=1; continue
      fi
      if [ "$rsha" = "$ZERO" ]; then
        echo "✗ push-ref-check：遠端沒有 ${branch}，promote 不建立分支。" >&2; blocked=1; continue
      fi
      if ! git cat-file -e "${rsha}^{commit}" 2>/dev/null; then
        echo "✗ push-ref-check：本機沒有遠端 ${branch} 的 tip ${rsha}（先 git fetch origin），無法驗 fast-forward。" >&2; blocked=1; continue
      fi
      if ! git merge-base --is-ancestor "$rsha" "$lsha"; then
        echo "✗ push-ref-check：推到 ${branch} 的 ${lsha} 不是 fast-forward（遠端 ${branch} 有 commit 不在其中）→ 先 back-merge（docs/COLLABORATION.md §2），不留 merge commit 在 ${branch}。" >&2
        blocked=1; continue
      fi
      echo "  push-ref-check：${branch} ← ${lsha}（promote.sh、fast-forward）→ 不需完整 gate（check 由 promote.sh／GitHub 驗）"
      ;;
    *) need_gate=1 ;;
  esac
done

[ "$blocked" -eq 0 ] || exit 1
[ "$seen" -gt 0 ] || exit 0
[ "$need_gate" -eq 0 ] || exit 0
exit 3
