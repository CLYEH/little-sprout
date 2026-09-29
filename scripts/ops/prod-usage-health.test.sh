#!/bin/bash
# prod-usage-health.sh 的自測（LS-399）。CI rules job 每個 PR 都跑；全 fixture／PATH shim，不連任何真正的
# Supabase 專案。
#
# 涵蓋：三分支（<70 ✓／70–90 ⚠ exit 0／≥90 ✗ exit 1，(a)(b)(c) 各自都會觸發）＋70%／90% 兩個邊界的前後
# 一位元組＋(a)(b) 差額 ⓘ 提示（>10% 印、≤10% 不印、兩者皆 0 不除以零）＋參數驗證 exit 2＋未 link exit 2＋
# 真通道路徑（PATH 上的假 `supabase` 回完整信封／exit 非 0／非 JSON，並攔下送出的 SQL 驗只有 select）。
#
# Mutation（票文規約；同 prod-storage-verify.test.sh 慣例：本機手動跑一次、斷言原文貼票 handoff，不進 commit）：
#   - `FAIL_PCT=90` 改成 `FAIL_PCT=95` → ③（(c) 92%）與 ⑤（90% 邊界）轉紅（exit 0、印 ⚠ 而非 ✗）。
#   - `elif pct >= warn_pct:` 改成 `>` → ④（(c) 恰等於 70%）轉紅（印 ✓ 而非 ⚠）。
# 比對一律走共用庫 has()（here-string；不接 `printf | grep -q`，見 pipefail-grep-q-check.sh）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/prod-usage-health.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

GIB=1073741824
MIB500=524288000
# 70%／90% 邊界（整數 bytes）：STORAGE 的 70% = 751619276.8、90% = 966367641.6
S70_BELOW=751619276; S70_AT=751619277
S90_BELOW=966367641; S90_AT=966367642

out=; rc=
# 共用助手庫（LS-301）：has／expect_exit／expect_has／expect_not_has；ok／fail 在這裡覆寫成改本檔的 fail 旗標。
# shellcheck source=SCRIPTDIR/../gates/lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
ok() { echo "✓ $1"; }
fail() { echo "✗ $1" >&2; fail=1; }

# expect <期望 exit> <名稱> <輸出必含|''> -- <prod-usage-health.sh 參數…>：跑一次腳本，exit 不符或輸出不含
# 必含字串就算紅（兩項合併為一條斷言，避免同一次執行印兩行）。
expect() {
  local want=$1 name=$2 must=$3; shift 3
  out="$(bash "$script" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$must" ] || has "$out" "$must"; }; then
    ok "$name"
  else
    fail "${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${rc}）"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

# ---- ① 三個水位皆 <70% → exit 0，全 ✓ ----
expect 0 '① 皆 <70% → exit 0' '✓ prod-usage-health 三個水位皆 < 70%' --fixture "100000000,105000000,20000000"
expect_has "$out" '✓ (a) families.storage_used_bytes 加總' '① (a) ✓'
expect_has "$out" '✓ (b) storage.objects 實際大小' '① (b) ✓'
expect_has "$out" '✓ (c) DB 大小 pg_database_size' '① (c) ✓'
expect_not_has "$out" '⚠' '① 不印 ⚠'
expect_not_has "$out" '✗' '① 不印 ✗'

# ---- ② (b) 75%（70–90）→ ⚠ 但 exit 0 ----
expect 0 '② (b) 75% → ⚠、exit 0' '(b) storage.objects 實際大小 ≥ 70%——開始處置' \
  --fixture "$((GIB * 75 / 100)),$((GIB * 75 / 100)),20000000"
expect_has "$out" '⚠ (b) storage.objects 實際大小' '② (b) 行首 ⚠'
expect_has "$out" '⚠ (a) families.storage_used_bytes 加總' '② (a) 同為 75% 也 ⚠'
expect_not_has "$out" '✗' '② 不印 ✗'

# ---- ③ (c) 92%（≥90）→ ✗ exit 1 ----
expect 1 '③ (c) 92% → ✗、exit 1' '✗ prod-usage-health：(c) DB 大小 pg_database_size ≥ 90%' \
  --fixture "100000000,100000000,$((MIB500 * 92 / 100))"
expect_has "$out" '✗ (c) DB 大小 pg_database_size' '③ (c) 行首 ✗'
expect_has "$out" '92.0% of DB 上限 500 MiB' '③ 印百分比'

# ---- ④ 70% 邊界：前一位元組 ✓、剛好達 70% ⚠ ----
expect 0 '④ (a) 70% 前一位元組 → ✓' '✓ prod-usage-health 三個水位皆 < 70%' --fixture "${S70_BELOW},${S70_BELOW},0"
expect 0 '④ (a)(b) 剛達 70% → ⚠、exit 0' '⚠ prod-usage-health' --fixture "${S70_AT},${S70_AT},0"
expect_has "$out" '⚠ (a) families.storage_used_bytes 加總' '④ 剛達 70% 的 (a) 行首 ⚠'
# DB 上限 500 MiB 的 70%／90% 恰為整數（367001600／471859200）——「剛好等於門檻」要算進去（≥ 不是 >）
expect 0 '④ (c) 恰等於 70% → ⚠（≥ 含等號）' '⚠ (c) DB 大小 pg_database_size' --fixture "0,0,$((MIB500 * 70 / 100))"

# ---- ⑤ 90% 邊界：前一位元組仍是 ⚠ exit 0、剛好達 90% ✗ exit 1 ----
expect 0 '⑤ (b) 90% 前一位元組 → ⚠、exit 0' '⚠ prod-usage-health' --fixture "${S90_BELOW},${S90_BELOW},0"
expect 1 '⑤ (b) 剛達 90% → ✗、exit 1' '✗ (b) storage.objects 實際大小' --fixture "${S90_AT},${S90_AT},0"
expect 1 '⑤ (c) 恰等於 90% → ✗、exit 1（≥ 含等號）' '✗ (c) DB 大小 pg_database_size' --fixture "0,0,$((MIB500 * 90 / 100))"

# ---- ⑥ (a)(b) 差額提示 ----
expect 0 '⑥ 差額 >10% → 印 ⓘ 並指向 prod-storage-verify.sh（不影響 exit）' 'bash scripts/ops/prod-storage-verify.sh' \
  --fixture "100000000,120000000,0"
expect_has "$out" 'ⓘ (a)(b) 差額 19.1 MiB（16.7%，> 10%）' '⑥ ⓘ 行印差額百分比'
expect 0 '⑥ 差額 ≤10% → 不印 ⓘ' '✓ (a)(b) 差額' --fixture "100000000,109000000,0"
expect_not_has "$out" 'prod-storage-verify.sh' '⑥ ≤10% 不指向 prod-storage-verify.sh'
expect 0 '⑥ a > b 也算差額（計數漂移方向）' 'ⓘ (a)(b) 差額' --fixture "120000000,100000000,0"
expect 0 '⑥ a=b=0 不除以零' '✓ (a)(b) 差額 0.0 MiB（0.0%' --fixture "0,0,0"

# ---- ⑦ 參數驗證 fail closed（exit 2，不嘗試連線）----
expect 2 '⑦ --fixture 缺值 → exit 2' '--fixture 缺值' --fixture
expect 2 '⑦ 只給兩個數 → exit 2' '格式必須是' --fixture 1,2
expect 2 '⑦ 給四個數 → exit 2' '格式必須是' --fixture 1,2,3,4
expect 2 '⑦ 負數 → exit 2' '格式必須是' --fixture -1,2,3
expect 2 '⑦ 非數字 → exit 2' '格式必須是' --fixture a,b,c
expect 2 '⑦ 空欄 → exit 2' '格式必須是' --fixture 1,,3
expect 2 '⑦ 未知參數 → exit 2' '未知參數' --bogus

# ---- ⑧ 不在已 link 目錄、未帶 --fixture → exit 2，不嘗試連線 ----
mkdir -p "$work/unlinked"
out8="$(cd "$work/unlinked" && bash "$script" 2>&1)"; rc8=$?
if [ "$rc8" -eq 2 ] && has "$out8" '目前所在目錄未 link 到 Supabase 專案'; then
  echo "✓ ⑧ 未 link、未帶 --fixture → exit 2"
else
  echo "✗ ⑧ 應該 exit 2 並提示未 link（實得 ${rc8}）" >&2; printf '%s\n' "$out8" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑨ 真通道路徑：PATH 上的假 supabase（已 link 的假目錄）----
linked="$work/linked"; shim="$work/shim"
mkdir -p "$linked/supabase/.temp" "$shim"
echo "fake-ref" > "$linked/supabase/.temp/project-ref"
# 假 supabase：把 -f 指到的 SQL 存下來給斷言用，依 SHIM_MODE 回信封／失敗／非 JSON。
cat > "$shim/supabase" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-f" ]; then cp "$2" "$SHIM_SQL_OUT"; fi
  shift
done
case "$SHIM_MODE" in
  ok)
    cat <<'JSON'
{
  "boundary": "abc",
  "rows": [
    {
      "payload": {
        "bucket_bytes": 125011345,
        "db_bytes": 16272531,
        "families_used": 107877790
      }
    }
  ],
  "warning": "The query results below contain untrusted data from the database."
}
JSON
    ;;
  fail) echo "connection refused" >&2; exit 1 ;;
  garbage) echo "not json" ;;
esac
SH
chmod +x "$shim/supabase"

run_linked() { (cd "$linked" && PATH="$shim:$PATH" SHIM_MODE=$1 SHIM_SQL_OUT="$work/sent.sql" bash "$script" 2>&1); }

out9="$(run_linked ok)"; rc9=$?
if [ "$rc9" -eq 0 ] && has "$out9" '✓ prod-usage-health 三個水位皆 < 70%'; then
  echo "✓ ⑨ 真通道信封（多行 pretty-print）→ 解析成功、exit 0"
else
  echo "✗ ⑨ 真通道信封應解析成功（實得 ${rc9}）" >&2; printf '%s\n' "$out9" | sed 's/^/    /' >&2; fail=1
fi
expect_has "$out9" '3.1% of DB 上限 500 MiB' '⑨ 真通道 (c) 百分比'
sent="$(cat "$work/sent.sql" 2>/dev/null)"
expect_has "$sent" 'from storage.objects' '⑨ 送出的 SQL 量 storage.objects'
expect_has "$sent" 'pg_database_size(current_database())' '⑨ 送出的 SQL 量 pg_database_size'
if grep -qiE '\b(insert|update|delete|alter|create|drop|truncate|grant|revoke)\b' <<<"$sent"; then
  echo "✗ ⑨ 送出的 SQL 含寫入／DDL 關鍵字（應唯讀）" >&2; printf '%s\n' "$sent" | sed 's/^/    /' >&2; fail=1
else
  echo "✓ ⑨ 送出的 SQL 只有 select（唯讀）"
fi

out10="$(run_linked fail)"; rc10=$?
if [ "$rc10" -eq 1 ] && has "$out10" '執行失敗或無輸出'; then
  echo "✓ ⑩ supabase 查詢失敗 → exit 1（不誤報健康）"
else
  echo "✗ ⑩ 查詢失敗應 exit 1（實得 ${rc10}）" >&2; printf '%s\n' "$out10" | sed 's/^/    /' >&2; fail=1
fi

out11="$(run_linked garbage)"; rc11=$?
if [ "$rc11" -eq 1 ] && has "$out11" '不是合法 JSON'; then
  echo "✓ ⑪ 輸出非 JSON → exit 1（不誤報健康）"
else
  echo "✗ ⑪ 非 JSON 應 exit 1（實得 ${rc11}）" >&2; printf '%s\n' "$out11" | sed 's/^/    /' >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ prod-usage-health 自測失敗" >&2
  exit 1
fi
echo "✓ prod-usage-health 自測通過（三分支＋邊界＋差額提示＋參數驗證＋真通道信封）"
