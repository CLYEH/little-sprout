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
#      都有對應 `// QA-GATE-HANDLED: <View>` 標記；1＝有缺漏；2＝參數／環境錯誤（fail closed）。
# 判定規則細節（含備援掃描 ⚠ 的角色）見 qa_driver_gate_check.py 檔頭。
# 自測：qa-driver-gate-check.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

case "${1:-}" in
  --help|-h)
    cat <<'EOF'
用法：qa-driver-gate-check.sh [--repo <dir>]
RootView*.swift 的 `// QA-GATE: <View>` 標記（登入後全屏 gate 清單）對帳 QADriver*.swift 的
`// QA-GATE-HANDLED: <View>` 標記（已處理清單），差集非空即紅。另外對 `.fullScreenCover`／
`.sheet` modifier 做純文字備援掃描，找到沒有 `// QA-GATE` 標記的疑似 gate 會印 ⚠（不影響 exit code）。
exit：0＝全過；1＝有缺漏；2＝參數／環境錯誤。
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
