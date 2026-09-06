#!/bin/bash
# LS-209：CI `ci-ipad` job 要跑哪些測試——自動從原始碼 grep 產生清單，不手寫死名單（LS-96 池項 00b9c9ef：
# `*IPadTests` 用 `XCTSkipUnless(pad)` 在 iPhone CI 上永遠跳過，iPad 分支死碼回歸沒有機械守門；手寫死名單一樣
# 會漏掉未來新增的 iPad 測試檔）。
#
# 掃描規則（純文字、不理解語意，逐行單一 pass；同檔案內類別邊界以「下一個 class 宣告」為界，見下方盲區）：
#   1. `(final )?class <Name>` 宣告，`<Name>` 以 `IPadTests` 結尾 → 整個類別進清單（`<target>/<Name>`）。
#   2. 目前所在類別內 `func <method>(` 宣告，`<method>` 含子字串 `Regular` → 該方法進清單
#      （`<target>/<CurrentClass>/<method>`）——對應「TapTargetGateTests/testSettingsViewRegular 這類 regular
#      案」（票文 LS-209 範圍 3）：iPad（regular 寬度）互動回歸不只長在 `*IPadTests` 檔案裡，也長在同一個
#      `TapTargetGateHarness` 家族的 `Regular` 具名測試裡（`testSettingsViewRegular` 逼 `.settingsRegular` 強制
#      `horizontalSizeClass = .regular`，本質是 iPad 版面情境，只是沒有另開一個 `*IPadTests` 檔案）。
#
# 用法：list-ipad-tests.sh [<UI 測試目錄>]（預設 LittleSproutUITests；目錄不存在 exit 2）
# 輸出：每行一個 `-only-testing:` 值（`<target>/<Class>` 或 `<target>/<Class>/<method>`，`<target>`＝目錄
#       basename），已排序去重；stdout 只印清單，供呼叫端直接迴圈組 `-only-testing:` 參數。
# Exit：0＝清單非空；1＝掃描完全沒找到任何案例——**fail loud**，不要讓「清單空」被 CI 讀成「這個 job 沒事做」
#       靜默跳過（LS-209 池項 00b9c9ef 要防的正是這種靜默）；2＝參數／目錄錯誤。
# 盲區（誠實聲明）：純正則掃描，抓不到同一類別用 `extension` 分開接續宣告的方法、或類別宣告跨多行（如
#       泛型／多重繼承清單換行）；本 repo 目前的 UI 測試慣例是單檔單類別、宣告單行，不構成風險。
# 自測：scripts/gates/list-ipad-tests.test.sh（掛 CI rules job）。
set -uo pipefail

if [ $# -gt 1 ]; then
  echo "✗ list-ipad-tests：只接受一個目錄參數（多給了 $2）" >&2
  exit 2
fi
dir=${1:-LittleSproutUITests}
[ -d "$dir" ] || { echo "✗ list-ipad-tests：找不到目錄「${dir}」" >&2; exit 2; }
target=$(basename "$dir")

files=$(find "$dir" -name '*.swift' | sort)
if [ -z "$files" ]; then
  echo "✗ list-ipad-tests：「${dir}」底下沒有任何 .swift 檔" >&2
  exit 1
fi

out=$(awk -v target="$target" '
  FNR == 1 { cls = "" }
  {
    line = $0
    if (match(line, /(^|[[:space:]])class[[:space:]]+[A-Za-z0-9_]+/)) {
      c = line
      sub(/.*class[[:space:]]+/, "", c)
      sub(/[^A-Za-z0-9_].*/, "", c)
      cls = c
      if (cls ~ /IPadTests$/) print target "/" cls
      next
    }
    if (cls != "" && match(line, /func[[:space:]]+test[A-Za-z0-9_]*\(/)) {
      m = line
      sub(/.*func[[:space:]]+/, "", m)
      sub(/\(.*/, "", m)
      if (m ~ /Regular/) print target "/" cls "/" m
    }
  }
' $files | sort -u)

if [ -z "$out" ]; then
  echo "✗ list-ipad-tests：掃過「${dir}」的 .swift 檔，沒找到任何 *IPadTests 類別或含 Regular 的測試方法——清單為空，fail loud（不得靜默略過 ci-ipad job）" >&2
  exit 1
fi
printf '%s\n' "$out"
exit 0
