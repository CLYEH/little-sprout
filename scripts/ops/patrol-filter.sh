#!/bin/bash
# 巡檢輸出過濾（LS-267 R2 M1；LS-239 R3）——**過濾式的唯一定義處**。
#
# orchestrator 每 26 分的巡檢是自己直接跑 `patrol.sh 40 --linear`（不派 subagent，§4-b），只把
# 旗標／停滯／動作清單／lane 表／cycle 行留進 context。這支就是那道過濾：
#
#   bash scripts/ops/patrol.sh 40 --linear 2>&1 | bash scripts/ops/patrol-filter.sh
#
# 為什麼要獨立一支：R1 的版本把樣式字面同時抄在 `docs/COLLABORATION.md` §4-b、`patrol.sh` 的註解與
# 兩支自測裡，merge-review R1 立刻抓到其中一份漏了 `⏳`（m1）。樣式只定義在這裡，文件引用這支腳本、
# 自測也呼叫這支腳本，抄寫漂移就沒有發生的餘地。
#
# 判準（兩道）：
#   1. 留下含 `⚠`／`✗`（異常）、`⏳`（停滯：PR 久無動作／dirty／尚未開工／已 push 無 PR）、`→`（可執行動作）、
#      `lane:`（lane 狀態表）、`current cycle`（cycle 一行）、`無異常`（全正常時的唯一結論）的行。
#   2. 丟掉段落標題 `== …`——標題文字本身就含 ⚠／✗ 字樣（如 `== Pencil 連線（…✗ 先請使用者…）`），留著只是雜訊。
#
# **配套前提（M1）**：patrol.sh／patrol-linear.sh／patrol_linear.py 的每一條「異常／略過／讀不到／對帳不符」
# 結論行都必須帶 ⚠（或動作行帶 →）——沒帶標記的結論行會被這道過濾靜默吞掉，等於那一段沒巡到。
# 這個前提由 `scripts/ops/patrol-filter.test.sh`（夾具逐分支）＋`patrol.test.sh` ㉛／`patrol-linear.test.sh` ⑪ 守住。
#
# 用法：
#   <patrol 輸出> | bash patrol-filter.sh      過濾（過濾後空無一行會印 ⚠ 提醒，不靜默）
#   bash patrol-filter.sh --pattern            只印樣式本身（給自測／文件引用）
#   bash patrol-filter.sh --markers            只印「帶標記」的子集合 ⚠｜✗｜⏳｜→（給自測當輸入選擇器用）
#
# **exit code 的語意（R3 i2，merge-review R2）**：本腳本是管線的**下游**，看不到 `patrol.sh` 的 exit code，
# 也不打算猜——它只回報「過濾這件事本身」：0＝過濾完成（有沒有留下行都算完成，留 0 行另印 ⚠ 提醒）、
# 2＝參數錯。上游的成敗改由**模板自己顯化**：§4-b 的 cron 一行開頭帶 `set -o pipefail`，`patrol.sh` 的
# exit 2（參數／環境錯）才不會被管線末端的 0 蓋掉。另外 `patrol.sh` 失敗時印的訊息本身帶 ✗／⚠，
# 會通過這道過濾進到 context——不是靜默失敗。
set -uo pipefail

# MARKERS＝「這一行自己帶了異常／停滯／動作標記」的集合；PATTERN 再併上三種結構行與全正常時的結論行。
# 分兩層是為了讓自測拿得到「哪些行算帶標記」這個子集合（`patrol.test.sh` ㉛a 的輸入選擇器，R3 i3：
# 原本手寫 `⚠|✗|⏳|✅`，與樣式沒有機械關聯——樣式加了新標記它不會跟上，全稱斷言的涵蓋面會悄悄少一塊）。
MARKERS='⚠|✗|⏳|→'
PATTERN="${MARKERS}|lane:|current cycle|無異常"

case "${1:-}" in
  --pattern) printf '%s\n' "$PATTERN"; exit 0 ;;
  --markers) printf '%s\n' "$MARKERS"; exit 0 ;;
  '') ;;
  *) echo "✗ patrol-filter：未知參數「$1」。用法：<patrol 輸出> | patrol-filter.sh ｜ patrol-filter.sh --pattern" >&2; exit 2 ;;
esac

out=$(grep -E "$PATTERN" | grep -v '^== ')
if [ -z "$out" ]; then
  # fail loud：一行都沒留下，多半是 patrol 根本沒跑起來（或整段被上游吃掉），不是「一切正常」
  echo "⚠ patrol-filter：過濾後沒有任何行——patrol.sh 是不是沒跑起來？（全正常時至少會有「巡檢：無異常」）" >&2
  exit 0
fi
printf '%s\n' "$out"
