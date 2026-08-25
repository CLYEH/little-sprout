#!/bin/bash
# 審查取證不得進版控（LS-61）。
#
# visual-reviewer／ui-designer／qa 的截圖、匯出、掃描輸出固定落在 .claude/evidence/<票號>/<輪次>/
# （根 .gitignore 已 ignore；git add -f 硬加的由 tracked-ignored-check 擋）。這裡擋的是「沒照規矩放、
# 又 git add 進來」的形狀——歷史上取證散落在 worktree 根（ls46r7-review/、ls46r8/…），.gitignore
# 沒有規則可 ignore。staged 路徑任一目錄層以 review 開頭或含 -review（review*／*-review*；不是 *review*——
# 那會誤擋 Xcode 預設的 Preview Content/）、或以 ls<數字> 開頭，或檔名 *.png 不在白名單
# （design/、LittleSprout/Assets.xcassets/、LittleSprout/Preview Content/——Xcode 模板的 Preview Assets.xcassets、
# docs/img/）即紅並列出檔案。目錄名規則不看白名單（docs/img/ 底下也不准有 *-review/）。
# 所有比對大小寫不敏感（nocasematch：LS46r9/、Review-shots/、.PNG 都擋；白名單亦然——macOS 檔案系統本就不分）。
#
# 只看 index（--diff-filter=d：新增／修改／rename 目的地，不含刪除——清掉歷史誤入版控的取證要放行），
# 不看工作區：未追蹤的取證目錄不在此 gate（§7 盲區，靠 agent 存放指示）。白名單外新增資產路徑時要改這裡。
# 路徑用 -z（NUL 分隔）讀：--name-only 對含 "／\／換行的檔名會加引號輸出，*.png 比對就對不上而靜默放行（PR #94 R1 I1）。
# NUL 進不了 bash 變數，所以先落暫存檔再讀；git diff 失敗（不是 repo、index 壞掉）exit 2 fail closed（R1 I2）。
#
# 用法：evidence-path-check.sh [repo 路徑]（參數只給自測餵臨時 repo 用；hook 不帶參數）
set -euo pipefail
shopt -s nocasematch

repo="${1:-$(git rev-parse --show-toplevel)}"
if ! cd "$repo" 2>/dev/null; then
  echo "✗ evidence-path gate：找不到目錄「${repo}」（fail closed）" >&2
  exit 2
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! git diff --cached --name-only -z --diff-filter=d > "$list"; then
  echo "✗ evidence-path gate：「${repo}」git diff --cached 失敗——不是 git repo？（fail closed）" >&2
  exit 2
fi

hits=""
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue
  why=""
  # 目錄層：pattern 裡的 * 可跨 /，*-review*/* 等價於「任一目錄層含 -review」、*/review*/* 等價於
  # 「任一非首層目錄以 review 開頭」（首層另列；ls[0-9] 同法）；檔名層不算（visual-reviewer.md、ls46-notes.md 放行）
  case "$p" in
    review*/*|*/review*/*|*-review*/*) why='目錄層命中 review*/ 或 *-review*/' ;;
    ls[0-9]*/*|*/ls[0-9]*/*) why='目錄層命中 ls[0-9]*/' ;;
  esac
  if [ -z "$why" ]; then
    case "$p" in
      *.png)
        case "$p" in
          design/*|LittleSprout/Assets.xcassets/*|'LittleSprout/Preview Content/'*|docs/img/*) ;;
          *) why='png 不在白名單 design/／LittleSprout/Assets.xcassets/／LittleSprout/Preview Content/／docs/img/' ;;
        esac ;;
    esac
  fi
  if [ -n "$why" ]; then
    hits+="    ${p}（${why}）"$'\n'
  fi
done < "$list"

if [ -n "$hits" ]; then
  echo "✗ evidence-path gate：下列 staged 路徑是審查取證的形狀（截圖／匯出／掃描輸出不入版控）：" >&2
  printf '%s' "$hits" >&2
  echo "  解法：取證一律放 .claude/evidence/<票號>/<輪次>/（已 ignore）；git rm --cached -- <檔> 從 index 移除（工作區檔案保留）。確為資產者：png 只准放 design/／LittleSprout/Assets.xcassets/／LittleSprout/Preview Content/／docs/img/，其他新資產路徑要改 scripts/gates/evidence-path-check.sh 的白名單。" >&2
  exit 1
fi
echo "✓ evidence-path gate：staged 路徑無審查取證形狀"
