#!/bin/bash
# 衝突標記 gate（LS-157；來源 LS-96 池項 53e7b0fd／LS-154 收尾實測：back-merge 解衝突後標記留在檔案裡，靠 push 前
# 自查才抓回，commit gate 沒擋）：staged diff 的**新增行**若以 git 衝突標記開頭即擋——
#   `<<<<<<< `（七個 < 加空白）、`=======`（整行恰好七個 =，無其他字元）、`>>>>>>> `（七個 > 加空白）。
# 只看 `git diff --cached` 的 `+` 行：HEAD 既有內容、未 staged 的工作區變更不算；`--no-renames` 讓改名＋修改的檔以
# D＋A 呈現，新增行不會因 rename 偵測（預設 --diff-filter 不含 R）被漏掉；`-U0` 讓 hunk 標頭的新檔行號可直接對應。
# 掛 scripts/gates/commit-gate.sh（pre-commit）。CI 不另掛本腳本（PR merge ref 沒有「staged」可言；PR 能否合併由
# merge-conflict-check／GitHub 管），這一關擋的是「解衝突解一半就 commit」，只有 commit 當下擋得到；自測
# conflict-marker-check.test.sh 掛 CI rules job。
#
# 2026-09-04 全 repo grep（`git grep -nE '^(<<<<<<< |=======$|>>>>>>> )'`，全部 tracked 檔）零命中：repo 內沒有把衝突
# 標記當示範內容的文件，故不做 fenced-block／路徑排除。已知誤擋面：Markdown setext 標題底線恰好七個 `=`（本 repo
# 文件一律用 `#` 標題，無此寫法；真要用就換成六個或八個）；行中出現 `=======`、表格分隔線 `|---|`、`====`、
# `=======x`、行首帶空白的 ` =======` 皆不命中（只比對行首整行）。
# exit 0＝無標記；1＝有（列 檔案:行號: 內容）；2＝不在 git repo／git diff 失敗（fail closed）。
set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ conflict-marker-check：不在 git repo 內（fail closed）" >&2; exit 2; }

diff=$(git -c core.quotePath=false diff --cached --no-renames --no-color --no-ext-diff --diff-filter=ACM --unified=0) || {
  echo "✗ conflict-marker-check：git diff --cached 失敗（fail closed）" >&2
  exit 2
}

# 檔名取自 `--- a/…`／`--- /dev/null` 之後緊接的 `+++ b/…` 標頭（成對才算，內容行 `++ b/x` 被 + 前綴成 `+++ b/x` 不會誤認）；
# 行號取自 hunk 標頭 `@@ -a,b +c,d @@` 的 c，之後每個 `+` 行遞增。
hits=$(printf '%s\n' "$diff" | awk '
  /^--- (a\/|\/dev\/null)/ { hdr = 1; next }
  /^\+\+\+ b\// && hdr { f = substr($0, 7); hdr = 0; next }
  { hdr = 0 }
  /^@@ / { split($0, a, " "); sub(/^\+/, "", a[3]); split(a[3], b, ","); ln = b[1] + 0; next }
  /^\+/ { line = substr($0, 2); if (line ~ /^(<<<<<<< |>>>>>>> )/ || line == "=======") print f ":" ln ": " line; ln++ }
')

if [ -n "$hits" ]; then
  echo "✗ commit gate：staged 新增行含 git 衝突標記（解衝突解一半就 commit？）：" >&2
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
  echo "  清掉 <<<<<<<／=======／>>>>>>> 行、確認保留的內容正確後再 git add。" >&2
  exit 1
fi
echo "✓ conflict-marker gate：staged 新增行無衝突標記"
