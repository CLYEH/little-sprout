#!/bin/bash
# UI 測試觸發判定（LS-137）：決定 CI `ci` job 的「點擊目標 gate」步驟（`-only-testing:LittleSproutUITests`，
# 這是 CI 唯一跑 UI 測試的地方）在 pull_request 事件下要不要跑。
#
# 來源：LS-136 merge-review R2 n1（LS-96 池項 93a9dee8）——先前 ci.yml 內嵌的判定只認 diff 含 `Features/`
# 或 `DesignSystem/`；LS-136（PR #235）十個檔全在 `LittleSprout/Navigation/`、`LittleSprout/Services/Timeline/`、
# 根層 `TapTargetGate*`、`LittleSproutUITests/`，CI 印「略過」→ 該票驗收「四 tab ≥44pt（gate 綠）」在 CI 是
# 跳過＝綠，靠 reviewer 本機實跑抵銷。任何在那兩個目錄之外新增的 SwiftUI View（含改 UI 測試本身）都能繞過
# 44pt gate 與全部 UI 測試。
#
# 規則（路徑層級，不理解語意）：變更清單任一路徑符合下列其一即要跑——
#   LittleSprout/**/*.swift   app target 任何 Swift 檔（前綴含斜線：不匹配同名前綴的 `LittleSproutTests/`／
#                             `LittleSproutUITests/`；非 Swift 檔如 Assets.xcassets／Info.plist 不算）
#   LittleSproutUITests/**    UI 測試本身，任何檔
# 否則略過（純 `supabase/`／`docs/`／`scripts/` PR 保留 LS-95 R1 m3 的省時語意）。這是「該不該跑」的判定、
# 不是正確性把關：寧可多跑（約 5 分鐘），不可該跑卻跳——呼叫端對非 0／3 的 exit（參數／ref 錯）應視為
# 「無法證明可略過」照跑（見 ci.yml）。
#
# 用法：ui-test-trigger.sh --base <ref>       對 `<ref>...HEAD`（三點：merge-base 到 HEAD，base 側自己的變更不算）
#                                             做 git diff --name-only --no-renames 取變更清單（搬移兩邊路徑都算；
#                                             core.quotePath=false，非 ASCII 路徑不加引號）
#       ui-test-trigger.sh --files <file>|-   變更清單一行一路徑（repo 相對路徑；`-` 讀 stdin），供自測與本機驗證
# exit：0＝要跑（印命中的第一個路徑）；3＝略過（印實際判定用的路徑集合＋變更清單）；2＝參數／ref 錯誤。
# 自測：ui-test-trigger.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

usage() {
  echo "用法：ui-test-trigger.sh --base <ref> | --files <file>|-" >&2
}

mode=; arg=
while [ $# -gt 0 ]; do
  case "$1" in
    --base|--files)
      if [ -n "$mode" ]; then echo "✗ ui-test-trigger：--base 與 --files 只能擇一" >&2; exit 2; fi
      if [ -z "${2:-}" ]; then echo "✗ ui-test-trigger：$1 缺值" >&2; exit 2; fi
      mode=${1#--}; arg=$2; shift 2 ;;
    *) echo "✗ ui-test-trigger：未知參數 $1" >&2; usage; exit 2 ;;
  esac
done
if [ -z "$mode" ]; then usage; exit 2; fi

case "$mode" in
  base)
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ ui-test-trigger：不在 git repo 內" >&2; exit 2; }
    git rev-parse -q --verify "${arg}^{commit}" >/dev/null 2>&1 \
      || { echo "✗ ui-test-trigger：找不到 base ref「${arg}」" >&2; exit 2; }
    # merge-review R1 F1／F2／F3：`--no-renames` 讓搬移拆成「舊路徑刪除＋新路徑新增」兩邊都進清單——Swift 檔搬出
    # app target（`git mv LittleSprout/Features/A.swift docs/A.swift`）也要跑，且判定不再依賴 rename 偵測（內容相同
    # 的兩個檔會被配成 R100、`--name-only` 只印目的路徑）；`core.quotePath=false` 讓非 ASCII 路徑不被加引號跳脫
    # （否則 `LittleSprout/Features/測試View.swift` 印成 "LittleSprout/Features/\346\270\254…"，`^LittleSprout/` 不匹配）。
    # 行尾 UI-TEST-TRIGGER-DIFF 標記給自測建 mutant 用，改這行請保留。
    changed=$(git -c core.quotePath=false diff --name-only --no-renames "${arg}...HEAD") || { echo "✗ ui-test-trigger：git diff ${arg}...HEAD 失敗" >&2; exit 2; }   # UI-TEST-TRIGGER-DIFF
    ;;
  files)
    if [ "$arg" = - ]; then
      changed=$(cat)
    else
      # merge-review R1 F4：讀不到（含給到目錄）一律 exit 2，不落成「空清單→略過」的 fail-open
      changed=$(cat "$arg" 2>/dev/null) || { echo "✗ ui-test-trigger：讀不到 ${arg}" >&2; exit 2; }
    fi
    ;;
esac

# 判定路徑集合。行尾的 UI-TEST-TRIGGER-RULE 標記給自測建 mutant 用（同 linear-issue-check.sh 的 RULE-X 標記慣例），
# 改這行請保留標記。
pattern='^(LittleSprout/.*\.swift$|LittleSproutUITests/)'   # UI-TEST-TRIGGER-RULE
rule_set='LittleSprout/**/*.swift、LittleSproutUITests/**'

hit=$(printf '%s\n' "$changed" | grep -E -m 1 "$pattern" || true)
if [ -n "$hit" ]; then
  echo "→ ui-test-trigger：要跑——變更含 ${hit}（判定路徑集合：${rule_set}）"
  exit 0
fi

n=$(printf '%s\n' "$changed" | grep -c '[^[:space:]]' || true)
echo "→ ui-test-trigger：略過——變更 ${n} 個檔皆不在判定路徑集合（${rule_set}）內；純 supabase/／docs/／scripts/ 等 PR 不跑 LittleSproutUITests（成本見 ci.yml 註解）"
if [ "$n" -gt 0 ]; then
  printf '%s\n' "$changed" | grep '[^[:space:]]' | head -n 10 | sed 's/^/    /'
  if [ "$n" -gt 10 ]; then echo "    …（其餘 $((n - 10)) 個略）"; fi
fi
exit 3
