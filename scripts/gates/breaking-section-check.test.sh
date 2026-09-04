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

# ── ④ LS-181：--findings 消費端逐一處置（B7 enum 加值） ─────────────────────────────────
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# 假的 migration-breaking-check 輸出：三個路徑，其中 handler.ts 被兩個 enum 都列到（只需交代一次）
printf "BREAKING\talter type public.notification_kind add value 'x'\nENUM\tpublic.notification_kind\tx\t既有值 3 個：a,b,c\t消費端 3 處\nCONSUMER\tpublic.notification_kind\tsupabase/functions/push/handler.ts\t名稱＋既有值 3 種，行 1,2\nCONSUMER\tpublic.notification_kind\tLittleSprout/Models.swift\t名稱，行 1\nCONSUMER\tpublic.notification_kind\tdocs/API.md\t值表／矩陣候選，行 3,7\nBREAKING\talter type public.content_target_type add value 'y'\nENUM\tpublic.content_target_type\ty\t既有值 2 個：d,e\t消費端 1 處\nCONSUMER\tpublic.content_target_type\tsupabase/functions/push/handler.ts\t名稱＋既有值 2 種，行 9\n" > "$work/findings"
# 只有 B1–B6 的 BREAKING、沒有 CONSUMER 行
printf "BREAKING\talter policy p on public.t using (false)\n" > "$work/findings-noconsumer"

# expect_f <期望 exit code> <樣本名稱> <PR body> <findings 檔> [期望 stderr 含的字串]
expect_f() {
  local want=$1 name=$2 body=$3 findings=$4 needle=${5:-} got err
  err="$(printf '%s' "$body" | bash "$check" --findings "$findings" 2>&1 >/dev/null)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$needle" ] || printf '%s' "$err" | grep -qF -- "$needle"; }; then
    echo "✓ $name"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}${needle:+；期望 stderr 含「$needle」}）" >&2
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    fail=1
  fi
}
ok_body=$'## Ticket\nLS-175\n\n## 影響\nBREAKING: notification_kind 加 x、content_target_type 加 y\n- `supabase/functions/push/handler.ts` 已更新 `77830be`\n- `LittleSprout/Models.swift` 已更新 7065e3f0dbf037d6cd0d5201111029c6c075a\n- docs/API.md 不需更新：文案矩陣本票不動，由 LS-23 一併補\n\n## 其他\n'
expect_f 0 '④ 全列綠：已更新（反引號 SHA／裸 40 位 SHA）＋不需更新：理由；同一路徑兩個 enum 只交代一次' "$ok_body" "$work/findings"
expect_f 0 '④ 不需更新（理由）括號寫法' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 不需更新（守衛已窮舉）\n- LittleSprout/Models.swift 已更新 abcdef1\n- docs/API.md 不需更新——本票不動\n' "$work/findings"
expect_f 0 '④ CRLF body（web UI 貼上）' $'## 影響\r\nBREAKING: 摘要\r\n- supabase/functions/push/handler.ts 已更新 abcdef1\r\n- LittleSprout/Models.swift 已更新 abcdef1\r\n- docs/API.md 不需更新：理由\r\n' "$work/findings"
expect_f 1 '④ 少列一項紅（缺 docs/API.md，stderr 點名）' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 已更新 abcdef1\n' "$work/findings" 'docs/API.md'
expect_f 1 '④ 路徑有列但沒寫處置' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 已更新 abcdef1\n- docs/API.md 看過了\n' "$work/findings" 'docs/API.md'
expect_f 1 '④ 已更新 沒有 SHA' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新\n- LittleSprout/Models.swift 已更新 abcdef1\n- docs/API.md 不需更新：理由\n' "$work/findings" 'handler.ts'
expect_f 1 '④ 已更新 SHA 只有 6 位' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef\n- LittleSprout/Models.swift 已更新 abcdef1\n- docs/API.md 不需更新：理由\n' "$work/findings" 'handler.ts'
expect_f 1 '④ 不需更新 後面沒理由' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 不需更新\n- docs/API.md 不需更新：理由\n' "$work/findings" 'Models.swift'
expect_f 1 '④ 不需更新： 後只有標點' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 不需更新：（）\n- docs/API.md 不需更新：理由\n' "$work/findings" 'Models.swift'
expect_f 1 '④ 處置寫在段外（下一個標題之後）' $'BREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 已更新 abcdef1\n\n## 其他\n- docs/API.md 不需更新：理由\n' "$work/findings" 'docs/API.md'
expect_f 1 '④ 處置寫在段外（BREAKING: 行之前）' $'- docs/API.md 不需更新：理由\n\nBREAKING: 摘要\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 已更新 abcdef1\n' "$work/findings" 'docs/API.md'
expect_f 1 '④ 全列但沒有 BREAKING: 行（既有規則仍在前）' $'## 影響\n- supabase/functions/push/handler.ts 已更新 abcdef1\n- LittleSprout/Models.swift 已更新 abcdef1\n- docs/API.md 不需更新：理由\n' "$work/findings"
expect_f 0 '④ findings 無 CONSUMER 行（B1–B6）→ 只驗既有規則：有 BREAKING: 即綠' $'BREAKING: albums_update 收緊\n' "$work/findings-noconsumer"
expect_f 1 '④ findings 無 CONSUMER 行、body 無 BREAKING: → 紅' $'本 PR 不需要 BREAKING: 段落\n' "$work/findings-noconsumer"
expect_f 2 '④ --findings 讀不到 → exit 2（fail closed）' $'BREAKING: 摘要\n' "$work/nope"
if printf 'BREAKING: x\n' | bash "$check" --bogus >/dev/null 2>&1; then
  echo "✗ ④ 未知參數應 exit 2" >&2; fail=1
else
  echo "✓ ④ 未知參數 → 非 0（fail closed）"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ breaking-section-check 自測通過（29 組樣本）"
fi
exit "$fail"
