#!/bin/bash
# LS-211 I-b（來源 LS-96 池項 edbc460c）：CI runner image 常同時裝有多個 iOS runtime，`xcrun simctl
# list devices available` 依 runtime 安裝順序（通常是舊到新）逐一列出各自的可用機型清單——`ci-ipad`
# job 找不到釘住版（`.ios-runtime`）時的舊 fallback `find_ipad_udid ""` 直接抓「第一個找到的」，實務
# 上等於永遠退回最舊的 runtime（`.ios-runtime` 若釘 26.2、runner 只有 17.0／18.0／26.0，退回會選到
# 17.0，比選任何一個更新版本都離釘住版更遠）。
#
# 改為兩段式：優先選「≥ 釘住版」裡最接近（最小）的一個；沒有任何 ≥ 釘住版的候選才退回「所有可用
# 版本裡最新」的一個（仍是同一機型，只是版本比釘住版舊，總比選到最舊的更合理）。釘住版本身若存在
# 於候選中，「≥ 釘住版裡最小」自然就是它自己——與舊行為（先試釘住版、找不到才 fallback）等價，只
# 是 fallback 分支的選法變了。
#
# 用法：pick-ipad-runtime.sh <pinned 版本，可空字串> [<裝置型號 pattern，預設 iPad Air 11-inch \(M3\)>]
#   讀 stdin（`xcrun simctl list devices available` 的輸出）——不自己呼叫 xcrun，方便自測餵假輸出、
#   也讓呼叫端（ci.yml／push-gate.sh）決定要不要先過濾其他條件。
# 輸出：找到 → 一行 "<udid>\t<os>"；找不到（該機型完全不存在於任何 runtime） → 空輸出。
# exit：恆 0（純函式，呼叫端以空輸出判斷「找不到」；用法錯誤才印錯誤字串到 stderr 並 exit 2）。
# 自測：pick-ipad-runtime.test.sh。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

case "${1:-}" in
  --help|-h)
    cat <<'EOF'
用法：pick-ipad-runtime.sh <pinned 版本，可空字串> [<裝置型號 pattern>]
讀 stdin（xcrun simctl list devices available 的輸出），選出裝置型號（預設 iPad Air 11-inch (M3)）
在所有可用 runtime 裡最適合的一台：優先選 >= pinned 版本裡最接近的一個，找不到才退回所有可用版本
裡最新的一個。輸出一行 "<udid>\t<os>"；找不到裝置型號則空輸出。exit 恆 0。
EOF
    exit 0
    ;;
esac

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "✗ pick-ipad-runtime：用法 pick-ipad-runtime.sh <pinned 版本，可空字串> [<裝置型號 pattern>]" >&2
  exit 2
fi

pin=$1
if [ $# -ge 2 ]; then
  pattern=$2
else
  # awk `-v` 賦值會對值再做一次跳脫序列解讀（`\(` 會被吃成 `(`，丟失跳脫），所以這裡要多一層反斜線
  # （`\\(`）才能讓 awk 收到的字串真的是 `\(`（regex 逐字括號）——純 `\(` 傳進去會被拆成失去跳脫的
  # `(`，變成 regex 分組符號而非逐字括號，導致完全比對不到含真實括號的裝置名稱字面（自測 ①f 抓到）。
  pattern='iPad Air 11-inch \\(M3\\)'
fi

awk -v pin="$pin" -v pattern="$pattern" '
  function verkey(v,    n, a, i, key, part) {
    n = split(v, a, ".")
    key = ""
    for (i = 1; i <= 4; i++) {
      part = (i <= n) ? a[i] + 0 : 0
      key = key sprintf("%06d.", part)
    }
    return key
  }
  /^-- iOS / { os=$0; sub(/^-- iOS /,"",os); sub(/ --$/,"",os); next }
  $0 ~ pattern {
    line=$0
    if (match(line, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)) {
      udid = substr(line, RSTART, RLENGTH)
      k = verkey(os)
      cands[k] = udid "\t" os
      n_cand++
    }
  }
  END {
    if (n_cand == 0) { exit 0 }
    pk = (pin != "") ? verkey(pin) : ""
    best_any_k = ""; best_any = ""
    best_ge_k = ""; best_ge = ""
    for (k in cands) {
      if (best_any_k == "" || k > best_any_k) { best_any_k = k; best_any = cands[k] }
      if (pk != "" && k >= pk) {
        if (best_ge_k == "" || k < best_ge_k) { best_ge_k = k; best_ge = cands[k] }
      }
    }
    if (pk != "" && best_ge != "") { print best_ge; exit 0 }
    print best_any
  }
'
