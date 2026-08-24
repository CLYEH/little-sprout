#!/bin/bash
# breaking-section-check.sh 的負向測試（LS-53）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：偵測規則若退化回子字串比對，這裡會紅。
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
check=scripts/gates/breaking-section-check.sh
fail=0

# expect <期望 exit code> <樣本名稱> <PR body>
expect() {
  local want=$1 name=$2 body=$3 got
  printf '%s' "$body" | bash "$check"
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "✓ $name"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2
    fail=1
  fi
}

# 應放行：行首標頭＋同行摘要
expect 0 '① 行首＋同行摘要' $'## 影響\nBREAKING: albums_update 不再放行 owner 改他人相簿；iOS ≥1.2 改走 set_album_deleted\n- 細節列點\n'
expect 0 '① 前導空白＋尾隨空白＋CRLF（web UI 貼上）' $'## 影響\r\n  BREAKING: revoke authenticated 的 diaries 直寫，改走 create_diary_entry  \r\n'
expect 0 '① 標記在末行、無結尾換行（CI printf %s 的實際形狀）' $'## 影響\nBREAKING: 說明'

# 不得放行：散文提及（子字串比對會被這些滿足）
expect 1 '② 散文：句中提及' $'本 PR 沒有 migration，不需要 BREAKING: 段落\n'
expect 1 '② 散文：〈〉括起' $'請補〈BREAKING:〉段落\n'

# 不得放行：形式不對
expect 1 '③ 只有標頭，內容在下一行' $'BREAKING:\n- albums_update 收緊\n'
expect 1 '③ 標頭後只有空白' $'BREAKING:   \n'
expect 1 '③ Markdown 粗體包起（標記須裸寫）' $'**BREAKING:** 說明\n'
expect 1 '③ 列點前綴' $'- BREAKING: 說明\n'
expect 1 '③ 引用前綴' $'> BREAKING: 說明\n'
expect 1 '③ 小寫' $'breaking: 說明\n'
expect 1 '③ 無冒號' $'BREAKING 說明\n'

expect 1 '空 body' ''

if [ "$fail" -eq 0 ]; then
  echo "✓ breaking-section-check 自測通過（13 組樣本）"
fi
exit "$fail"
