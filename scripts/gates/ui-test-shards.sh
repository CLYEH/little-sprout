#!/bin/bash
# LS-385：CI `ci-ui` job 的 UITests 分片——把 LittleSproutUITests 的測試類別分到 n 片、各片在獨立 runner 上並行跑
# （09-24 單一 `ci` job 串跑單元測試＋整包 UITests 43–51 分、三次撞 timeout-minutes 被 cancelled；UITests 本身
# 約 36–37 分，切三片後每片約 12 分＋建置）。呼叫端：scripts/gates/tap-target-check.sh --shard <i>/<n>。
#
# 輸出的是「略過清單」而非「執行清單」——這是本腳本的安全方向：掃描漏掉的類別（宣告跨行、繼承自共用基底類別而非
# 直接繼承 XCTestCase、寫法跳脫下列規則）不會出現在任何一片的略過清單裡，於是**每一片都會跑它**（重複跑、多花時間、
# 分片耗時失衡會被 CI「印各 test bundle 耗時」步驟與 patrol「ci job 耗時 ≥40 分」看見），不會變成「哪一片都沒跑」
# 的靜默漏測。
#
# 掃描規則（純文字、逐行、不理解語意）：
#   類別：`class <Name>: XCTestCase`（前面可有 `final`／`@MainActor` 等修飾；`//` 開頭的註解行不算）。
#   權重：該類別宣告之後、同檔下一個 XCTestCase 類別宣告之前的 `func test…(` 數（UITests 幾乎一支測試一次 app
#         啟動，啟動是主要耗時，方法數是足夠的代理值；`class func setUp()`、巢狀 helper class 等其他 class 行不切換
#         歸屬）；0 支也記 1，保證每個類別都被分配。
# 分配：權重大到小（同權重依類別名）逐一放進目前總權重最小的分片（同為最小取編號小者）——LPT 貪婪，決定性，
#       同一份原始碼在每個 runner 上算出同一張表（各片獨立計算，不需要彼此溝通）。
#
# 用法：ui-test-shards.sh --shard <i>/<n> [<UI 測試目錄>]   印第 i 片要略過的類別（＝其他片的類別），每行一個
#                                                          `<target>/<Class>`（`<target>`＝目錄 basename），已排序
#       ui-test-shards.sh --plan <n> [<UI 測試目錄>]        印分配表：每片一行「<i>/<n>  權重 <w>  <Class>、<Class>…」
#   目錄預設 LittleSproutUITests（相對 cwd）。
# exit：0＝成功；1＝目錄裡找不到任何 XCTestCase 類別（fail loud：清單空＝每片都跑全部，分片形同虛設）；2＝參數／目錄錯。
# 自測：scripts/gates/ui-test-shards.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

usage() {
  echo "用法：ui-test-shards.sh --shard <i>/<n> [<UI 測試目錄>] | --plan <n> [<UI 測試目錄>]" >&2
  exit 2
}

mode=; spec=
case "${1:-}" in
  --shard|--plan) mode=${1#--}; spec=${2:-}; [ -n "$spec" ] || usage; shift 2 ;;
  *) usage ;;
esac
[ $# -le 1 ] || { echo "✗ ui-test-shards：只接受一個目錄參數（多給了 $2）" >&2; exit 2; }
dir=${1:-LittleSproutUITests}
[ -d "$dir" ] || { echo "✗ ui-test-shards：找不到目錄「${dir}」" >&2; exit 2; }

case "$mode" in
  shard)
    i=${spec%%/*}; n=${spec#*/}
    [ "$i/$n" = "$spec" ] || usage ;;
  plan)
    i=0; n=$spec ;;
esac
case "$i" in ''|*[!0-9]*) usage ;; esac
case "$n" in ''|*[!0-9]*) usage ;; esac
if [ "$n" -lt 1 ] || { [ "$mode" = shard ] && { [ "$i" -lt 1 ] || [ "$i" -gt "$n" ]; }; }; then
  echo "✗ ui-test-shards：分片編號須 1 ≤ i ≤ n（得到「${spec}」）" >&2
  exit 2
fi
target=$(basename "$dir")

files=$(find "$dir" -name '*.swift' | sort)
weights=$(
  [ -n "$files" ] && printf '%s\n' "$files" | while IFS= read -r f; do cat "$f"; printf '\n// __LS385_EOF__\n'; done | awk '
    /^\/\/ __LS385_EOF__$/ { cls = ""; next }
    /^[[:space:]]*\/\// { next }
    /(^|[[:space:]])class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase([^A-Za-z0-9_]|$)/ {
      c = $0
      sub(/.*class[[:space:]]+/, "", c)
      sub(/[^A-Za-z0-9_].*/, "", c)
      cls = c
      if (!(cls in w)) w[cls] = 0
      next
    }
    cls != "" && /func[[:space:]]+test[A-Za-z0-9_]*\(/ { w[cls]++ }
    END { for (k in w) printf "%d\t%s\n", (w[k] > 0 ? w[k] : 1), k }
  '
)
if [ -z "$weights" ]; then
  echo "✗ ui-test-shards：掃過「${dir}」沒找到任何 XCTestCase 類別——分片清單為空，fail loud（不得讓分片形同虛設）" >&2
  exit 1
fi

# LPT：權重大到小、同權重依類別名；每個類別放進目前總權重最小的分片（同為最小取編號小者）。輸出「分片\t權重\t類別」
plan=$(printf '%s\n' "$weights" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | awk -F '\t' -v n="$n" '
  BEGIN { for (s = 1; s <= n; s++) load[s] = 0 }
  {
    best = 1
    for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
    load[best] += $1
    printf "%d\t%d\t%s\n", best, $1, $2
  }
')

if [ "$mode" = plan ]; then
  for s in $(seq 1 "$n"); do
    printf '%s\n' "$plan" | awk -F '\t' -v s="$s" -v n="$n" '
      $1 == s { w += $2; names[++k] = $3 }
      END {
        line = ""
        for (j = 1; j <= k; j++) line = line (j > 1 ? "、" : "") names[j]
        printf "%d/%d  權重 %d  %s\n", s, n, w, (k ? line : "（無）")
      }
    '
  done
  exit 0
fi

printf '%s\n' "$plan" | awk -F '\t' -v s="$i" -v t="$target" '$1 != s { print t "/" $3 }' | sort
exit 0
