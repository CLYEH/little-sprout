#!/bin/bash
# 合併衝突預檢（LS-50，來源 LS-55 PR #77 事件）：push 前以 `git merge-tree --write-tree <target> HEAD` 模擬與目標分支
# 的合併，有衝突即擋。GitHub 對「不可合併」的 PR 不觸發 pull_request workflow——CI 零紀錄、`gh pr checks --watch`
# 立刻退出、required checks 無從擋，沒有任何機械訊號（靠 orchestrator 讀 mergeStateStatus 才發現）；所以這一關只能在
# 本機 push 前做，CI 無法兜底。掛 push-gate；自測 merge-conflict-check.test.sh。
#
# 用法：merge-conflict-check.sh --target <remote>/<branch>（push-gate 依方向矩陣傳 origin/development／origin/main）
#   1) 本機 refs/remotes/<target> 不存在 → exit 2（先 git fetch origin），不靜默跳過。
#   2) git ls-remote 對遠端當前 sha，本機追蹤 ref 不同即 exit 2——拿過期的 origin/development 比是假綠
#      （PR #77 的分支正是落後 27 commit）；push 本來就要網路，這一趟 ls-remote 不多要什麼。
#   3) git merge-tree --write-tree --name-only：exit 1＝有衝突（第 2 行到空行之間是檔名）→ exit 1；
#      exit ≥2＝git 本身錯誤（<2.38 沒有 --write-tree）→ exit 2，fail closed。
# exit 0＝可乾淨合併；1＝衝突；2＝參數／ref／遠端／git 錯誤。
set -uo pipefail

target=
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      if [ -z "${2:-}" ]; then echo "✗ merge-conflict-check：--target 缺值" >&2; exit 2; fi
      target=$2; shift 2 ;;
    *) echo "✗ merge-conflict-check：未知參數 $1" >&2; exit 2 ;;
  esac
done
remote=${target%%/*}
rbranch=${target#*/}
if [ -z "$target" ] || [ "$remote" = "$target" ] || [ -z "$remote" ] || [ -z "$rbranch" ]; then
  echo "✗ merge-conflict-check：--target 須為 <remote>/<branch>（得到「${target}」）。" >&2
  exit 2
fi

local_sha=$(git rev-parse -q --verify "refs/remotes/${target}^{commit}") || {
  echo "✗ merge-conflict-check：找不到 ${target}（先 git fetch origin），無法預檢合併衝突。" >&2
  exit 2
}
remote_sha=$(git ls-remote --exit-code "$remote" "refs/heads/${rbranch}" 2>/dev/null | cut -f1) || {
  echo "✗ merge-conflict-check：遠端 ${remote} 沒有分支 ${rbranch}，或連不到遠端。" >&2
  exit 2
}
if [ "$remote_sha" != "$local_sha" ]; then
  echo "✗ merge-conflict-check：本機 ${target}（${local_sha:0:7}）與遠端（${remote_sha:0:7}）不同——先 git fetch origin 再 push；拿過期的目標分支比對是假綠。" >&2
  exit 2
fi

out=$(git merge-tree --write-tree --name-only "$local_sha" HEAD 2>&1)
rc=$?
case "$rc" in
  0)
    echo "✓ 與 ${target}（${local_sha:0:7}）可乾淨合併"
    exit 0 ;;
  1)
    echo "✗ push gate：本分支與 ${target} 有合併衝突——GitHub 對不可合併的 PR 不跑 CI，開出去不會有任何檢查：" >&2
    printf '%s\n' "$out" | sed -n '2,/^$/p' | sed '/^$/d; s/^/    /' >&2
    echo "  請先 git merge ${target}（解衝突、commit）再 push。" >&2
    exit 1 ;;
  *)
    if printf '%s' "$out" | grep -qi 'unrelated histories'; then
      echo "✗ merge-conflict-check：git merge-tree 失敗（exit ${rc}；${target} 與本分支沒有共同祖先，refusing to merge unrelated histories——分支起點可能切錯了）：" >&2
    else
      echo "✗ merge-conflict-check：git merge-tree 失敗（exit ${rc}；--write-tree 需 git ≥ 2.38，或其他 git 本身的錯誤，詳見下方輸出）：" >&2
    fi
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    exit 2 ;;
esac
