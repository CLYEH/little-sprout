#!/bin/bash
# 自測接線對帳（LS-267，來源 LS-96 池項 `c0d883e1`；根因來自 LS-264 merge-review R1 M1 `ece3dc5b`）：
# repo 內的 `scripts/**/*.test.sh`／`scripts/design/*.test.js` 與 `.github/workflows/ci.yml` 實際會執行的
# 自測清單取差集，非空即 exit 1 並點名。
#
# 背景：`qa-e2e.test.sh`（自 LS-158）與 `stale-xcodebuild-check.test.sh`（自 LS-236）躺在 repo 裡好幾個月
# 從未在 CI 執行過，`docs/COLLABORATION.md` §7 卻白紙黑字標 ✅——要靠 reviewer 手動 `comm` 才發現。這正
# 違反 CLAUDE.md「新增重要規則＝同時新增它的 gate」：自測是 gate 的 gate，沒被執行就等於不存在，而且
# 文件還會宣稱它在跑（比沒 gate 更危險）。這支腳本把那次人工 `comm` 機械化。
#
# 判準：
#   repo 側＝`find scripts -name '*.test.sh' -o -name '*.test.js'`（相對 repo root 的路徑）。
#   ci.yml 側＝**實際的呼叫行**：行首空白後以 `bash`／`node` 起手（`run: |` 區塊內的縮排行），或單行
#     `run: bash scripts/x.test.sh`／`- run: bash scripts/x.test.sh`（R2 m3，merge-review R1：本 PR 自己新增的
#     兩個 gate step 就是單行 `run:` 形式，只是被呼叫的不是 `*.test.sh` 才沒撞上——照那個樣式寫的自測會被
#     誤判成「沒掛」而假紅）。**註解裡的提及不算**——註解常引用自測
#     檔名（例如 ci.yml:216 那段 LS-264 的說明），整檔 grep 會把「被提到」誤判成「有在跑」，那正是本
#     gate 要防的假綠。
#   差集兩個方向都擋：repo 有 ci.yml 沒有（新增自測忘了掛）、ci.yml 有 repo 沒有（改名／刪檔忘了同步，
#     CI 會在那一步 `bash: No such file` 紅——但那是事後才知道）。
#   刻意不掛的走具名 allowlist：`scripts/gates/selftest-wiring-allowlist.txt`（一行一個相對路徑，`#` 註解
#     寫理由；檔案不存在＝空 allowlist）。只對「repo 有、ci.yml 沒有」這個方向生效。
#
# 用法：bash selftest-wiring-check.sh [--repo-root <dir>] [--ci <ci.yml 路徑>]
#   兩個參數只給自測塞夾具用（同 `LS_LOCK_SH` 的 seam 精神）；正式呼叫不帶參數。
# 自測：scripts/gates/selftest-wiring-check.test.sh（夾具正負樣本＋對真 ci.yml 的 mutation）。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
ci=

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) root=${2:-}; shift 2 || true ;;
    --ci) ci=${2:-}; shift 2 || true ;;
    *) echo "✗ selftest-wiring-check：未知參數「$1」。用法：selftest-wiring-check.sh [--repo-root <dir>] [--ci <file>]" >&2; exit 2 ;;
  esac
done

[ -n "$root" ] && [ -d "$root" ] || { echo "✗ selftest-wiring-check：--repo-root 不是目錄（${root}）" >&2; exit 2; }
ci=${ci:-${root}/.github/workflows/ci.yml}
[ -f "$ci" ] || { echo "✗ selftest-wiring-check：找不到 ci.yml（${ci}）" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

( cd "$root" && find scripts \( -name '*.test.sh' -o -name '*.test.js' \) -type f 2>/dev/null ) | sort -u > "${work}/repo.txt"
grep -hE '^[[:space:]]*(-[[:space:]]+)?(run:[[:space:]]*)?(bash|node)[[:space:]]+scripts/[^[:space:]]+\.test\.(sh|js)' "$ci" \
  | grep -oE 'scripts/[^[:space:]]+\.test\.(sh|js)' | sort -u > "${work}/ci.txt"

allow="${root}/scripts/gates/selftest-wiring-allowlist.txt"
if [ -f "$allow" ]; then
  sed 's/#.*//' "$allow" | tr -d '[:blank:]' | grep -v '^$' | sort -u > "${work}/allow.txt"
else
  : > "${work}/allow.txt"
fi

missing=$(comm -23 "${work}/repo.txt" "${work}/ci.txt" | comm -23 - "${work}/allow.txt")
extra=$(comm -13 "${work}/repo.txt" "${work}/ci.txt")

rc=0
if [ -n "$missing" ]; then
  echo "✗ selftest-wiring-check：以下自測存在於 repo，但 ci.yml 沒有任何一行會執行它（新增自測必須同時掛進 rules job 的自測 step）：" >&2
  printf '%s\n' "$missing" | sed 's/^/    /' >&2
  echo "    刻意不掛請在 scripts/gates/selftest-wiring-allowlist.txt 具名列出並寫理由。" >&2
  rc=1
fi
if [ -n "$extra" ]; then
  echo "✗ selftest-wiring-check：ci.yml 會執行以下自測，但 repo 裡沒有這個檔（改名／刪檔忘了同步；CI 會在那一步炸）：" >&2
  printf '%s\n' "$extra" | sed 's/^/    /' >&2
  rc=1
fi
[ "$rc" -eq 0 ] || exit 1

echo "✓ selftest-wiring-check：$(wc -l < "${work}/repo.txt" | tr -d ' ') 支自測全部掛在 ci.yml（allowlist $(wc -l < "${work}/allow.txt" | tr -d ' ') 支）"
