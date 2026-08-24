#!/bin/bash
# destructive-approval-check.sh 的負向測試（LS-45）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：偵測規則若退化回子字串比對，這裡會紅。
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
check=scripts/gates/destructive-approval-check.sh
fail=0

# expect <期望 exit code> <樣本名稱> <PR body>
expect() {
  local want=$1 name=$2 body=$3 got
  printf '%s' "$body" | bash "$check"
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "✓ $name"
  else
    echo "✗ $name（期望 exit $want，實得 $got）" >&2
    fail=1
  fi
}

# 應放行：標記獨佔一行
expect 0 '① 獨立成行' $'## 風險\nDESTRUCTIVE-APPROVED\n'
expect 0 '① 獨立成行＋前後空白＋CRLF（web UI 貼上）' $'## 風險\r\n  DESTRUCTIVE-APPROVED  \r\n'

# 不得放行：散文提及（PR #55 run 32626369903 實際被誤放行的寫法）
expect 1 '② 散文：〈〉括起' $'等待使用者蓋〈DESTRUCTIVE-APPROVED〉後再合併\n'
expect 1 '② 散文：前綴文字' $'等待使用者蓋 DESTRUCTIVE-APPROVED\n'

# 不得放行：行內尾隨其他字
expect 1 '③ 行內尾隨文字' $'DESTRUCTIVE-APPROVED by orchestrator\n'
expect 1 '③ Markdown 粗體包起（已知限制：標記須裸寫）' $'**DESTRUCTIVE-APPROVED**\n'

expect 1 '空 body' ''

if [ "$fail" -eq 0 ]; then
  echo "✓ destructive-approval-check 自測通過"
fi
exit "$fail"
