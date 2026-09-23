#!/bin/bash
# 審查輪次報表（LS-352 範圍 5）：量 merge-review rubric 前移到 ios-dev 自檢（docs/REVIEW-RUBRIC.md）之後，
# 審查退件輪次有沒有真的下降。從 `git log <ref> --since=<n>.days --format=%s` 統計：
#   fix commit 總數＝subject 以 `fix(`／`fix:`／`fix!` 起頭的 commit；
#   R2+／R3+＝這些 fix commit 裡 subject 帶審查輪次標記 `R<n>` 且 n ≥2／≥3 的支數（同一 subject 多個標記取最大值）。
#            輪次標記＝前一字元是空白、後一字元不是數字也不是 `.`：` R2 `、` R3-m1`、` R2c`、` R3——` 算；`PR2`（前面是英數）
#            與 rubric 條目編號 `R2.1`（後面接 `.`，LS-352 R2：本票引入的 docs/REVIEW-RUBRIC.md 編號會出現在 subject 裡，
#            不排除就從第一天污染本指標）不算。**R2 取捨**：派工字面是「空白包圍」，但 08-22 起 main 有 7 支 fix 用
#            ` R3-m1`／` R2c`／` R3——` 形狀，嚴格要求後接空白會把 R2+ 從 402 誤降到 395，所以只排除「後接數字或 `.`」。
# 印一行摘要（比例＝占 fix commit 總數）；fix commit 為 0 時比例印「—」。R2+ 後附驗收目標（`--target-r2`，預設 30）。
# 基線與驗收目標的出處是 LS-352 票文（09-24 訂正：驗收看 R2+，不看 R3+），這裡不寫死基線數字；未達標回頭檢討
# rubric，不是加 gate。巡檢週報用 `patrol.sh --weekly` 印這一行。
#
# 用法：review-rounds-report.sh [--days <n>] [--ref <ref>] [--repo <path>] [--target-r2 <pct>]
#   --days  回看天數（預設 7＝一個 cycle）
#   --target-r2  R2+ 比例的驗收目標（百分比數字，整數或小數；預設 30，出處 LS-352 票文）
#   --ref   統計的分支（預設 main）
#   --repo  repo 路徑（預設當前 git repo）
# exit：0＝已印摘要；2＝參數錯誤／不是 git repo／ref 不存在（fail closed）。
# 自測：scripts/ops/patrol.test.sh 的 ㉝ 段（合成 repo 夾具＋mutation）。
set -uo pipefail

DAYS=7; REF=main; REPO=; TARGET_R2=30
while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      case "${2:-}" in ''|*[!0-9]*) echo "✗ review-rounds-report：--days 須為正整數（得到「${2:-}」）" >&2; exit 2 ;; esac
      DAYS=$2; shift ;;
    --ref)
      [ -n "${2:-}" ] || { echo "✗ review-rounds-report：--ref 缺值" >&2; exit 2; }
      REF=$2; shift ;;
    --repo)
      [ -n "${2:-}" ] || { echo "✗ review-rounds-report：--repo 缺值" >&2; exit 2; }
      REPO=$2; shift ;;
    --target-r2)
      [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "✗ review-rounds-report：--target-r2 須為數字（得到「${2:-}」）" >&2; exit 2; }
      TARGET_R2=$2; shift ;;
    -h|--help)
      echo "用法：review-rounds-report.sh [--days <n>] [--ref <ref>] [--repo <path>] [--target-r2 <pct>]（說明見檔頭註解）"; exit 0 ;;
    *) echo "✗ review-rounds-report：未知參數 $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ review-rounds-report：不在 git repo 內且未給 --repo" >&2; exit 2; }
fi
git -C "$REPO" rev-parse --verify -q "${REF}^{commit}" >/dev/null 2>&1 || { echo "✗ review-rounds-report：${REPO} 找不到 ref「${REF}」" >&2; exit 2; }

subjects=$(git -C "$REPO" log "$REF" --since="${DAYS}.days" --format=%s) || { echo "✗ review-rounds-report：git log 失敗" >&2; exit 2; }

# LC_ALL=C：byte 模式——BSD awk 在 UTF-8 locale 下對 `match` 命中多位元組字元後再 `substr` 切片會
# towc 轉換失敗（R2 實測 `R3——` 形狀），byte 模式下 match／substr 口徑一致。
printf '%s\n' "$subjects" | LC_ALL=C awk -v days="$DAYS" -v ref="$REF" -v target="$TARGET_R2" '
  function pct(a, b) { return b == 0 ? "—" : sprintf("%.1f%%", a * 100 / b) }
  /^fix[(:!]/ {
    total++
    s = " " $0 " "; max = 0
    while (match(s, / R[0-9]+[^0-9.]/)) {  # REVIEW-ROUNDS-MARKER
      t = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); n = t + 0
      if (n > max) max = n
      s = substr(s, RSTART + RLENGTH - 1)
    }
    if (max >= 2) r2++
    if (max >= 3) r3++
  }
  END {
    printf "review-rounds（近 %d 天，%s）：fix commit %d｜R2+ %d（%s，目標 < %s%%）｜R3+ %d（%s）\n", days, ref, total, r2, pct(r2, total), target, r3, pct(r3, total)
  }
'
