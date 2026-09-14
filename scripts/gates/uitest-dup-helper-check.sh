#!/bin/bash
# UITest 重複 helper 偵測（LS-267，來源 LS-96 池項 `c8215a9e`／LS-263 收尾 lesson review）：
# `LittleSproutUITests/**/*.swift` 裡的 `private func …{…}` 區塊正規化後比對，同一份本體出現 ≥2 次就印 ⚠。
#
# 背景：LS-263 之前，5 個 UITest 檔累積了 8 份 byte-identical 的 `private func waitForHittable`／
# `waitForNonExistence` 複本，直到有人用肉眼抓到才發現——「跨測試檔重複 private func 本體」沒有任何機械偵測。
#
# **informational：一律 exit 0、不擋**。重複有時是刻意的（測試檔之間本來就該可獨立閱讀），要不要抽共用
# helper 是人的判斷；這支只負責讓它在 CI log 裡看得見，不製造「為了讓 gate 綠而硬抽共用工具」的壓力。
#
# 判準：
#   - 起點＝含 `private func` 的行（含 `private static func`）；以該行之後第一個 `{` 起算大括號配對，配平即為區塊結束。
#   - 正規化＝去掉 `//` 行尾註解與**全部空白**後的整段文字（含宣告行）——同名同本體才算同一份複本，
#     只是本體湊巧相同、名字不同的兩支不算（那通常是不同意圖）。
#   - 大括號配對是純文字計數：字串字面或註解裡的 `{`／`}` 會被算進去（去註解用的 `sub(/\/\/.*$/,…)` 同樣
#     會切掉字串裡的 `//`，例如 URL）。**失準的後果侷限在該檔案**——每換一個檔案就重置抽取狀態
#     （`FNR == 1`，R2 m2；在那之前狀態跨檔延續，一個配不平的檔會讓其後所有檔案的偵測全部失效），
#     該檔可能少報／多報一條 informational，不值得為此引進 Swift 解析器（同 repo 內其他 grep 型 gate 的取捨）。
#
# 用法：bash uitest-dup-helper-check.sh [<掃描根目錄>]（預設 repo 的 LittleSproutUITests/）
# 自測：scripts/gates/uitest-dup-helper-check.test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
scan_dir="${1:-${root}/LittleSproutUITests}"

if [ ! -d "$scan_dir" ]; then
  echo "→ uitest-dup-helper-check：找不到 ${scan_dir}，略過" >&2
  exit 0
fi

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$scan_dir" -name '*.swift' -type f | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "→ uitest-dup-helper-check：${scan_dir} 下沒有 .swift，略過"
  exit 0
fi

# awk：逐檔抽 private func 區塊 → key=正規化後全文，值累積「檔名:行號」；收工列出出現 ≥2 次的 key。
dups=$(awk '
function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
# LS-267 R2 m2（merge-review R1 m2）：每換一個檔案就重置抽取狀態。`in_func`／`depth` 原本跨檔延續，
# 只要有一個檔的大括號因字串字面／註解裡的 `{` 配不平，`in_func` 會一直是 1，**其後所有檔案**都被
# 當成同一個區塊的 body 累加，整個掃描的剩餘部分失效（reviewer 以兩檔夾具實測重現漏報）。
FNR == 1 { in_func = 0; opened = 0; depth = 0; body = "" }
{
  line = $0
  sub(/\/\/.*$/, "", line)                      # 去行尾註解
  if (!in_func) {
    if (line !~ /(^|[[:space:]])private[[:space:]]+(static[[:space:]]+)?func[[:space:]]/) next
    in_func = 1; opened = 0; depth = 0; body = ""
    start_file = FILENAME; start_line = FNR
    sig = line; sub(/.*(^|[[:space:]])private[[:space:]]/, "private ", sig); sub(/\{.*$/, "", sig)
    sig = trim(sig)
  }
  n_open = gsub(/\{/, "{", line)
  n_close = gsub(/\}/, "}", line)
  if (n_open > 0) opened = 1
  depth += n_open - n_close
  stripped = line; gsub(/[[:space:]]/, "", stripped)
  body = body stripped
  if (opened && depth <= 0) {
    count[body]++
    where[body] = where[body] (where[body] == "" ? "" : "、") start_file ":" start_line
    if (!(body in signature)) signature[body] = sig
    in_func = 0
  }
}
END {
  for (b in count) {
    if (count[b] >= 2) printf "⚠ 重複 helper：%s ×%d（%s）\n", signature[b], count[b], where[b]
  }
}
' "${files[@]}" | sed "s#${root}/##g" | sort)

if [ -n "$dups" ]; then
  printf '%s\n' "$dups"
  echo "→ uitest-dup-helper-check：以上 private func 本體在多處重複（informational，不擋）——考慮抽到 LittleSproutUITests/Support/ 的共用 helper（LS-263 先例）。"
else
  echo "✓ uitest-dup-helper-check：無重複的 private func 本體"
fi
exit 0
