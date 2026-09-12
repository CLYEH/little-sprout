#!/bin/bash
# QADriver 全屏 gate 對帳（LS-232）。實際解析邏輯在 qa_driver_gate_check.py（同 privacy-manifest-check.sh
# 呼叫 privacy_manifest_check.py 的既有慣例）。
#
# 用法：qa-driver-gate-check.sh [--repo <dir>]
#   --repo <dir>  待掃描的 repo 根目錄（需含 LittleSprout/Navigation/RootView*.swift 與
#                 LittleSproutUITests/QA/QADriver*.swift）；預設當前 git repo
#                 （git rev-parse --show-toplevel）。回歸測試對 `git archive <sha>` 匯出的舊快照
#                 跑時用這個參數指到快照目錄（LS-232 驗收 4）。
# exit：0＝RootView*.swift 的 `// QA-GATE: <View>` 標記（登入後全屏 gate 清單）在 QADriver*.swift
#      都有對應 `// QA-GATE-HANDLED: <View>` 標記、且備援掃描候選（`.fullScreenCover`／`.sheet`
#      綁定但未標記者）扣掉宣告與 `// QA-GATE-EXEMPT: <View>` 豁免後也是空集合；1＝有缺漏或
#      未標記候選；2＝參數／環境錯誤（fail closed）。LS-232 R2（merge-review R1 M1）：備援掃描
#      候選原本只印 ⚠、不影響 exit code，已改成計入紅／綠——不會再對「新增全屏 gate 但忘記寫
#      任何標記」的 commit 誤判成綠。
# 判定規則細節（含備援掃描候選如何計入紅／綠、豁免標記）見 qa_driver_gate_check.py 檔頭。
# 自測：qa-driver-gate-check.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

case "${1:-}" in
  --help|-h)
    cat <<'EOF'
用法：qa-driver-gate-check.sh [--repo <dir>]
RootView*.swift 的 `// QA-GATE: <View>` 標記（登入後全屏 gate 清單）對帳 QADriver*.swift 的
`// QA-GATE-HANDLED: <View>` 標記（已處理清單），差集非空即紅。另外對 `.fullScreenCover`／
`.sheet` modifier 做純文字備援掃描，找到沒有 `// QA-GATE` 標記的疑似 gate 候選——扣掉已宣告
與 `// QA-GATE-EXEMPT: <View>` 豁免清單後非空也算紅（LS-232 R2：不再只印 ⚠、不影響 exit code）。
exit：0＝全過；1＝有缺漏或未標記候選；2＝參數／環境錯誤。
EOF
    exit 0
    ;;
esac

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/qa_driver_gate_check.py"

command -v python3 >/dev/null 2>&1 || { echo "✗ qa-driver-gate-check：需要 python3（macOS 與 ubuntu-latest 皆內建）" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ qa-driver-gate-check：找不到 ${py}" >&2; exit 2; }

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ -n "${2:-}" ] || { echo "✗ qa-driver-gate-check：--repo 缺值" >&2; exit 2; }
      repo="$2"; shift 2 ;;
    -*) echo "✗ qa-driver-gate-check：未知參數 $1" >&2; exit 2 ;;
    *) echo "✗ qa-driver-gate-check：不接受位置參數（$1）" >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ]; then
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "✗ qa-driver-gate-check：不在 git repo 內且未給 --repo（fail closed）" >&2
    exit 2
  }
fi

exec python3 "$py" --repo "$repo"
