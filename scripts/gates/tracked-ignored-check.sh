#!/bin/bash
# 已追蹤檔不得命中 .gitignore（LS-51）。
#
# .gitignore 只擋「還沒進 index」的檔：規則落地前就 commit 進去的、或 git add -f 硬加的，
# 之後每次 `git add .` 都照樣更新，ignore 規則形同虛設。設計畫布（design-canvas*/）的執行
# 產物正是這個形狀——三軌的 _shotcheck.html 在 ignore 規則落地前就已被追蹤。
# 所以這裡拿 index 對 repo 內的 .gitignore（根＋各目錄）比對，命中即紅並印出解法。
#
# 只認 repo 內的 .gitignore（--exclude-per-directory），不吃 core.excludesFile／.git/info/exclude：
# 本機專屬 excludes 因人而異，吃進來會變成「我機器紅、CI 綠」（或反過來）的不可重現結果。
#
# 第二檢查（PR #79 R1 F1）：根規則寫 design-canvas*/_shotcheck.html，子目錄 .gitignore 一行
# `!_shotcheck.html` 就能讓它失效——而且檔案從此「不再 ignored」，第一檢查看不見。所以 index 內
# 所有 design-canvas*/.gitignore 一律不准有 `!` 開頭的行（允許前導空白，寧可多擋）：各軌只准
# 收窄（多 ignore），放寬只准改根 .gitignore（diff 可見、merge-reviewer 看得到）。
# 讀 index 版本（git show :path）而非工作樹：hook 與 CI 判的是要進版控的內容。
#
# 用法：tracked-ignored-check.sh [repo 路徑]（參數只給自測餵臨時 repo 用；hook 與 CI 不帶參數）
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo"
fail=0

# ① ls-files 只列 cwd 以下，故必須站在 repo 根；quotePath=false 讓非 ASCII 檔名可讀
hits=$(git -c core.quotePath=false ls-files --cached --ignored --exclude-per-directory=.gitignore)
if [ -n "$hits" ]; then
  echo "✗ tracked-ignored gate：下列已追蹤檔命中 .gitignore（規則落地前就進了版控，或被 git add -f 硬加）：" >&2
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
  echo "  解法：git rm --cached -- <檔>（工作區檔案保留，只從 index 移除）；確實該入版控者：只准收窄根 .gitignore 規則；子目錄否定規則會被本 gate 擋。" >&2
  fail=1
fi

# ② 子目錄 .gitignore 的否定行（pathspec 未加 :(glob)，* 跨 /：軌內更深層的 .gitignore 一併掃）
neg=""
while IFS= read -r gi; do
  [ -n "$gi" ] || continue
  lines=$(git show ":$gi" | grep -nE '^[[:space:]]*!' || true)
  [ -n "$lines" ] || continue
  neg+=$(printf '%s\n' "$lines" | sed "s|^\([0-9]*\):.*|    ${gi}:\1: 子目錄否定規則會讓根規則失效，只准收窄根 .gitignore|")$'\n'
done < <(git -c core.quotePath=false ls-files --cached -- 'design-canvas*/.gitignore')
if [ -n "$neg" ]; then
  echo "✗ tracked-ignored gate：design-canvas*/.gitignore 內有否定行（!）：" >&2
  printf '%s' "$neg" >&2
  echo "  解法：刪掉該行；確實該入版控者改根 .gitignore（收窄 design-canvas*/ 規則）。" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "✓ tracked-ignored gate：index 內無已追蹤檔命中 .gitignore，design-canvas*/.gitignore 無否定行"
