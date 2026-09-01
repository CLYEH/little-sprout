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
# 只看 index／--base 給的 diff（--diff-filter=d：新增／修改／rename 目的地，不含刪除——清掉歷史誤入版控的取證要放行），
# 不看工作區：未追蹤的取證目錄不在此 gate（§7 盲區，靠 agent 存放指示）。白名單外新增資產路徑時要改這裡。
# 路徑用 -z（NUL 分隔）讀：--name-only 對含 "／\／換行的檔名會加引號輸出，*.png 比對就對不上而靜默放行（PR #94 R1 I1）。
# NUL 進不了 bash 變數，所以先落暫存檔再讀；git diff 失敗（不是 repo、index 壞掉）exit 2 fail closed（R1 I2）。
#
# --base <ref>（LS-69，R1 I10）：CI `rules` job 對 PR merge ref 跑的模式——比對 `<ref>...HEAD`（三點語法，
# 對 merge-base 以來新增／改名的路徑）套用同一套規則，`--no-verify` 繞過本機 pre-commit 時這裡是伺服器端兜底。
# 不帶 --base 時維持原本行為：看 `--cached`（staged，pre-commit 用）。
#
# 用法：evidence-path-check.sh [--base <ref>] [repo 路徑]（repo 路徑只給自測餵臨時 repo 用；hook／CI 不帶）
set -euo pipefail
shopt -s nocasematch

base=""
if [ "${1:-}" = "--base" ]; then
  if [ -z "${2:-}" ]; then
    echo "✗ evidence-path gate：--base 需要接一個 ref 參數（fail closed）" >&2
    exit 2
  fi
  base="$2"
  shift 2
fi

repo="${1:-$(git rev-parse --show-toplevel)}"
if ! cd "$repo" 2>/dev/null; then
  echo "✗ evidence-path gate：找不到目錄「${repo}」（fail closed）" >&2
  exit 2
fi

# N1（LS-69，R1 N1）：非 git 目錄時，若讓下面的 git diff 直接吃到非 repo 路徑，`--cached`／三點語法對 git 而言是
# 合法選項組合，git 會誤判成「把路徑當 --no-index <path> <path>」執行，噴出完整 ~100 行 usage 把真正錯誤淹沒。
# 這裡先用 --git-dir 探測；錯誤訊息完整保留（不可 2>/dev/null 吞——fail loud，git 自己的診斷要看得到）只精簡包成一行。
if ! git_dir_err=$(git rev-parse --git-dir 2>&1 >/dev/null); then
  echo "✗ evidence-path gate：「${repo}」不是 git 目錄（fail closed）：${git_dir_err}" >&2
  exit 2
fi

mode_desc="staged"
diff_cmd=(git diff --cached --name-only -z --diff-filter=d)
if [ -n "$base" ]; then
  mode_desc="${base}...HEAD"
  diff_cmd=(git diff "${base}...HEAD" --name-only -z --diff-filter=d)
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! "${diff_cmd[@]}" > "$list"; then
  echo "✗ evidence-path gate：「${repo}」git diff（${mode_desc}）失敗（fail closed）" >&2
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
  echo "✗ evidence-path gate（${mode_desc}）：下列路徑是審查取證的形狀（截圖／匯出／掃描輸出不入版控）：" >&2
  printf '%s' "$hits" >&2
  if [ -n "$base" ]; then
    echo "  解法：取證一律放 .claude/evidence/<票號>/<輪次>/（已 ignore）；本機 --no-verify 繞過了 pre-commit，改分支上把該檔從 tracked 移除（git rm --cached -- <檔> 後補一個 commit）。確為資產者：png 只准放 design/／LittleSprout/Assets.xcassets/／LittleSprout/Preview Content/／docs/img/，其他新資產路徑要改 scripts/gates/evidence-path-check.sh 的白名單。" >&2
  else
    echo "  解法：取證一律放 .claude/evidence/<票號>/<輪次>/（已 ignore）；git rm --cached -- <檔> 從 index 移除（工作區檔案保留）。確為資產者：png 只准放 design/／LittleSprout/Assets.xcassets/／LittleSprout/Preview Content/／docs/img/，其他新資產路徑要改 scripts/gates/evidence-path-check.sh 的白名單。" >&2
  fi
  exit 1
fi
echo "✓ evidence-path gate（${mode_desc}）：無審查取證形狀"
