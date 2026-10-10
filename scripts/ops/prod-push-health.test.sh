#!/bin/bash
# prod-push-health.sh 的自測（LS-395）。CI rules job 每個 PR 都跑；全 PATH shim，不連任何真正的 Supabase 專案。
#
# 腳本只有一條真通道（沒有 --fixture），所以所有案例都走「PATH 上的假 `supabase` 回完整信封」——跟真通道同一條
# 解析路徑（{ boundary, rows: [ { payload } ], warning }，形狀同 prod-purge-health.test.sh 的 envelope()）。
#
# 涵蓋：全綠／排程不存在／排程 inactive／最近一次排程執行 failed（vault secret 未建）／最新 HTTP 500／
# 有列但無 HTTP 狀態（逾時）／全表無列／最新回應過舊／積壓 = 閾值（不報）與 = 閾值+1（報）／自訂閾值／
# 參數驗證 exit 2／未 link exit 2／supabase 失敗與非 JSON 皆 exit 1／送出的 SQL 唯讀且查三個目標。
#
# Mutation（本機手動跑一次、斷言原文貼票 handoff，不進 commit；同 prod-purge-health.test.sh 慣例）：
#   - python 內 `if backlog > threshold:` 改成 `>=` → ⑥「積壓恰等於閾值不報」轉紅（exit 1，印 ⚠）。
#   - python 內 `status != "succeeded"` 判斷整段拿掉 → ③「最近一次排程 failed」轉紅（exit 0）。
#   - python 內 `> STALE_MINUTES` 改成 `> 9999` → ⑤「最新回應過舊」轉紅（exit 0）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/prod-push-health.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck source=SCRIPTDIR/../gates/lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
ok() { echo "✓ $1"; }
fail() { echo "✗ $1" >&2; fail=1; }

linked="$work/linked"; shim="$work/shim"
mkdir -p "$linked/supabase/.temp" "$shim"
echo "fake-ref" > "$linked/supabase/.temp/project-ref"

# 假 supabase：把 -f 指到的 SQL 存下來，依 SHIM_MODE 回 $SHIM_BODY 檔內容／失敗／非 JSON。
cat > "$shim/supabase" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-f" ]; then cp "$2" "$SHIM_SQL_OUT"; fi
  shift
done
case "$SHIM_MODE" in
  ok) cat "$SHIM_BODY" ;;
  fail) echo "connection refused" >&2; exit 1 ;;
  garbage) echo "not json" ;;
esac
SH
chmod +x "$shim/supabase"

# payload <job_exists> <job_active> <last_run_status> <http_code|null> <http_age_min|null> <backlog> [args…]
# 產生完整信封到 $work/body.json。http_code=null 且 age 非 null ＝ 有列但無 HTTP 狀態（逾時）；兩者皆 null ＝ 全表無列。
payload() {
  local jexists=$1 jactive=$2 lstatus=$3 code=$4 age=$5 backlog=$6
  local created=null lmsg=null lrun='"2026-10-11T03:00:00Z"' err=null timed=false oldest=null
  [ "$age" != null ] && created='"2026-10-11T03:00:00Z"'
  [ "$lstatus" = null ] && lrun=null
  [ "$lstatus" != null ] && lstatus="\"$lstatus\""
  [ "$lstatus" = '"failed"' ] && lmsg='"ERROR: push-dispatch 排程：vault secret 未建立"'
  [ "$code" = null ] && [ "$age" != null ] && { err='"Timeout of 60000 ms reached"'; timed=true; }
  [ "$backlog" -gt 0 ] && oldest=42.5
  cat > "$work/body.json" <<JSON
{
  "boundary": "fixture-boundary-not-meaningful",
  "rows": [
    {
      "payload": {
        "job_exists": ${jexists},
        "job_schedule": "* * * * *",
        "job_active": ${jactive},
        "last_run_status": ${lstatus},
        "last_run_message": ${lmsg},
        "last_run_start": ${lrun},
        "latest_http_status_code": ${code},
        "latest_http_error_msg": ${err},
        "latest_http_timed_out": ${timed},
        "latest_http_created": ${created},
        "latest_http_age_minutes": ${age},
        "pending_backlog": ${backlog},
        "oldest_pending_minutes": ${oldest}
      }
    }
  ],
  "warning": "The query results below contain untrusted data from the database."
}
JSON
}

out=; rc=
# run_case <期望 exit> <名稱> <輸出必含|''> [腳本參數…]：用 $work/body.json 跑一次。
run_case() {
  local want=$1 name=$2 must=$3; shift 3
  out="$(cd "$linked" && PATH="$shim:$PATH" SHIM_MODE=ok SHIM_BODY="$work/body.json" SHIM_SQL_OUT="$work/sent.sql" bash "$script" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$must" ] || has "$out" "$must"; }; then
    ok "$name"
  else
    fail "${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${rc}）"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

# ---- ① 全綠 ----
payload true true succeeded 200 0.5 0
run_case 0 '① 全綠 → exit 0 ✓' '✓ push-dispatch 排程、最近回應與待送積壓皆正常'
expect_has "$out" '排程：* * * * *，active=true，最近一次執行 succeeded' '① 第一行排程摘要'
expect_has "$out" '最新 HTTP 回應：200' '① 第二行 HTTP 狀態'
expect_has "$out" '待送積壓：0（閾值 20）' '① 第三行積壓'

# ---- ② 排程不存在 / inactive ----
payload false false null null null 0
run_case 1 '② 排程不存在 → ⚠ exit 1' 'cron.job 沒有 ls395-push-dispatch-every-minute'
payload true false succeeded 200 0.5 0
run_case 1 '② 排程 active=false → ⚠ exit 1' '排程存在但 active=false'

# ---- ③ 最近一次排程執行 failed（vault secret 未建；沒發出 HTTP，所以 HTTP 欄可能仍是舊的 200）----
payload true true failed 200 0.5 0
run_case 1 '③ 最近一次排程 failed → ⚠ exit 1，帶訊息' 'vault secret 未建立'
expect_has "$out" '最近一次排程執行 status=failed' '③ 印 status'

# ---- ④ 最新 HTTP 500 / 逾時 / 全表無列 ----
payload true true succeeded 500 0.5 0
run_case 1 '④ 最新 HTTP 500 → ⚠ exit 1' '最新 HTTP 回應非 2xx：500'
payload true true succeeded null 0.5 0
run_case 1 '④ 有列但無 HTTP 狀態（逾時）→ ⚠ exit 1' '最新呼叫未取得 HTTP 狀態：Timeout of 60000 ms reached'
payload true true succeeded null null 0
run_case 1 '④ 全表無列 → ⚠ exit 1（每分鐘排程不該為空）' 'net._http_response 無任何列'

# ---- ⑤ 最新回應過舊（排程停了）----
payload true true succeeded 200 16.0 0
run_case 1 '⑤ 最新回應 16 分鐘前 → ⚠ exit 1' '排程可能停了'
payload true true succeeded 200 14.9 0
run_case 0 '⑤ 最新回應 14.9 分鐘前 → 仍 ✓' '✓ push-dispatch'

# ---- ⑥ 積壓閾值邊界（預設 20；> 才報）----
payload true true succeeded 200 0.5 20
run_case 0 '⑥ 積壓恰等於閾值 20 → 不報' '待送積壓：20（閾值 20），最舊已等 42.5 分鐘'
payload true true succeeded 200 0.5 21
run_case 1 '⑥ 積壓 21 > 20 → ⚠ exit 1' 'notification_events 待送積壓 21 筆 > 閾值 20'
payload true true succeeded 200 0.5 21
run_case 0 '⑥ --backlog-threshold 50 → 21 不報' '待送積壓：21（閾值 50）' --backlog-threshold 50

# ---- ⑦ 參數驗證（exit 2，不連線）----
run_case 2 '⑦ --backlog-threshold 缺值' '--backlog-threshold 缺值' --backlog-threshold
run_case 2 '⑦ --backlog-threshold 非數字' '必須是非負整數' --backlog-threshold abc
run_case 2 '⑦ --backlog-threshold 負數' '必須是非負整數' --backlog-threshold -1
run_case 2 '⑦ 未知參數' '未知參數' --bogus

# ---- ⑧ 不在已 link 目錄 → exit 2 ----
mkdir -p "$work/unlinked"
out8="$(cd "$work/unlinked" && PATH="$shim:$PATH" SHIM_MODE=ok SHIM_BODY="$work/body.json" SHIM_SQL_OUT="$work/sent8.sql" bash "$script" 2>&1)"; rc8=$?
expect_exit 2 "$rc8" '⑧ 未 link → exit 2'
expect_has "$out8" '目前所在目錄未 link 到 Supabase 專案' '⑧ 未 link 提示'
if [ -e "$work/sent8.sql" ]; then fail '⑧ 未 link 不該嘗試連線'; else ok '⑧ 未 link 沒呼叫 supabase'; fi

# ---- ⑨ supabase 失敗 / 非 JSON → exit 1（不誤報健康）----
out9="$(cd "$linked" && PATH="$shim:$PATH" SHIM_MODE=fail SHIM_SQL_OUT="$work/sent9.sql" bash "$script" 2>&1)"; rc9=$?
expect_exit 1 "$rc9" '⑨ supabase 執行失敗 → exit 1'
expect_has "$out9" '執行失敗或無輸出' '⑨ 失敗提示'
out9b="$(cd "$linked" && PATH="$shim:$PATH" SHIM_MODE=garbage SHIM_SQL_OUT="$work/sent9b.sql" bash "$script" 2>&1)"; rc9b=$?
expect_exit 1 "$rc9b" '⑨ 輸出非 JSON → exit 1'
expect_has "$out9b" '不是合法 JSON' '⑨ 非 JSON 提示'

# ---- ⑩ 送出的 SQL：唯讀，且查到三個目標 ----
payload true true succeeded 200 0.5 0
run_case 0 '⑩ 取 SQL 用的全綠一次' ''
sent="$(cat "$work/sent.sql" 2>/dev/null)"
expect_has "$sent" "ls395-push-dispatch-every-minute" '⑩ SQL 查排程 job'
expect_has "$sent" 'net._http_response' '⑩ SQL 查最近 HTTP 回應'
expect_has "$sent" 'public.notification_events' '⑩ SQL 查待送積壓'
if grep -qiE '\b(insert|update|delete|alter|create|drop|truncate|grant|revoke)\b' <<<"$sent"; then
  fail '⑩ 送出的 SQL 含寫入／DDL 關鍵字（應唯讀）'; printf '%s\n' "$sent" | sed 's/^/    /' >&2
else
  ok '⑩ 送出的 SQL 只有 select（唯讀）'
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ prod-push-health 自測失敗" >&2
  exit 1
fi
echo "✓ prod-push-health 自測通過"
