#!/bin/bash
# 審查輪次報表（LS-352 範圍 5）：量 merge-review rubric 前移到 ios-dev 自檢（docs/REVIEW-RUBRIC.md）之後，
# 審查退件輪次有沒有真的下降。從 `git log <ref> --since=<n>.days --format=%s` 統計：
#   fix commit 總數＝subject 以 `fix(`／`fix:`／`fix!` 起頭的 commit；
#   R2+／R3+＝這些 fix commit 裡 subject 帶審查輪次標記 `R<n>`（前一字元不是英數字，如 ` R2 `、`（R3`；
#            `PR2` 不算）且 n ≥2／≥3 的支數（同一 subject 多個標記取最大值）。
# 印一行摘要（比例＝占 fix commit 總數）；fix commit 為 0 時比例印「—」。
# 基線（LS-352 票文，08-22 起全 main）：fix 721 支、R3+ 約 40%；驗收目標：上線後兩個 cycle 內 R3+ < 20%
# （未達標回頭檢討 rubric，不是加 gate）。巡檢週報用 `patrol.sh --weekly` 印這一行。
#
# 用法：review-rounds-report.sh [--days <n>] [--ref <ref>] [--repo <path>]
#   --days  回看天數（預設 7＝一個 cycle）
#   --ref   統計的分支（預設 main）
#   --repo  repo 路徑（預設當前 git repo）
# exit：0＝已印摘要；2＝參數錯誤／不是 git repo／ref 不存在（fail closed）。
# 自測：scripts/ops/patrol.test.sh 的 ㉛ 段（合成 repo 夾具＋mutation）。
set -uo pipefail

DAYS=7; REF=main; REPO=
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
    -h|--help)
      echo "用法：review-rounds-report.sh [--days <n>] [--ref <ref>] [--repo <path>]（說明見檔頭註解）"; exit 0 ;;
    *) echo "✗ review-rounds-report：未知參數 $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ review-rounds-report：不在 git repo 內且未給 --repo" >&2; exit 2; }
fi
git -C "$REPO" rev-parse --verify -q "${REF}^{commit}" >/dev/null 2>&1 || { echo "✗ review-rounds-report：${REPO} 找不到 ref「${REF}」" >&2; exit 2; }

subjects=$(git -C "$REPO" log "$REF" --since="${DAYS}.days" --format=%s) || { echo "✗ review-rounds-report：git log 失敗" >&2; exit 2; }

printf '%s\n' "$subjects" | awk -v days="$DAYS" -v ref="$REF" '
  function pct(a, b) { return b == 0 ? "—" : sprintf("%.1f%%", a * 100 / b) }
  /^fix[(:!]/ {
    total++
    s = " " $0; max = 0
    while (match(s, /[^A-Za-z0-9]R[0-9]+/)) {  # REVIEW-ROUNDS-MARKER
      n = substr(s, RSTART + 2, RLENGTH - 2) + 0
      if (n > max) max = n
      s = substr(s, RSTART + RLENGTH)
    }
    if (max >= 2) r2++
    if (max >= 3) r3++
  }
  END {
    printf "review-rounds（近 %d 天，%s）：fix commit %d｜R2+ %d（%s）｜R3+ %d（%s）｜目標 R3+ < 20%%（LS-352）\n", days, ref, total, r2, pct(r2, total), r3, pct(r3, total)
  }
'
