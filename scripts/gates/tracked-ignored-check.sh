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
# 用法：tracked-ignored-check.sh [repo 路徑]（參數只給自測餵臨時 repo 用；hook 與 CI 不帶參數）
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo"

# ls-files 只列 cwd 以下，故必須站在 repo 根；quotePath=false 讓非 ASCII 檔名可讀
hits=$(git -c core.quotePath=false ls-files --cached --ignored --exclude-per-directory=.gitignore)
if [ -n "$hits" ]; then
  echo "✗ tracked-ignored gate：下列已追蹤檔命中 .gitignore（規則落地前就進了版控，或被 git add -f 硬加）：" >&2
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
  echo "  解法：git rm --cached -- <檔>（工作區檔案保留，只從 index 移除）；確實該入版控者改 .gitignore。" >&2
  exit 1
fi
echo "✓ tracked-ignored gate：index 內無已追蹤檔命中 .gitignore"
