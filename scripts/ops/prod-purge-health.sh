#!/bin/bash
# LS-235 —— 正式站 purge-storage 排程健康度巡檢（每週人工執行，見
# docs/COLLABORATION.md §4-b）。
#
# 背景：`cron.job_run_details` 記的是 pg_cron 呼叫 pg_net.http_post() 這個動作
# 本身有沒有成功排進非同步佇列，不是 purge-storage Edge Function 實際回應的
# HTTP 狀態——pg_net 是非同步呼叫，job_run_details 幾乎永遠回報 succeeded，即使
# 那次呼叫最終收到 500（09-11 一次 Gateway Timeout 就是這樣被漏掉，見 LS-96 池項
# fa8c91fc／LS-235 票文）。真正的 HTTP 狀態只在 `net._http_response`
# （status_code／error_msg／created）。
#
# 唯讀：只執行 SELECT，不寫入任何資料；不讀取任何 `.env` 值、不印出任何憑證
# （`supabase db query --linked` 走 CLI 既有的專案連結，不需要在這裡處理任何
# 連線字串或金鑰）。
#
# 對帳邏輯：取最近 N 筆 `private.purge_runs`（`purge_expired()` 每次執行留一列，
# 見 20260903110908_purge_expired.sql），對每一筆用執行日期（UTC）比對
# `cron.job_run_details`（jobname='ls153-purge-storage-daily'，見 docs/API.md §6
# 「pg_cron＋pg_net 呼叫範本」）當天最早一次呼叫的 start_time，再用該時間點之後
# 10 分鐘內最早一筆 `net._http_response` 當作那次呼叫的實際回應（pg_net
# timeout_milliseconds=60000，10 分鐘窗口留了充裕的餘裕）。找不到對應的
# cron 呼叫或回應、或 status_code 不是 2xx，都算異常。
#
# **已知假設（下次實際對正式站跑時可能要調整，見票 handoff「風險」）**：
# `supabase db query --linked` 這個版本的 `--output-format json` 是否真的會把
# 查詢結果列印成可直接解析的 JSON，只能在正式站實跑時驗證——如果格式跟這裡的
# 假設不同，`fetch_rows_json` 會因為抓不到 `[...]` 陣列而回傳空字串，本腳本會
# fail loud（exit 1 並印 ⚠），不會把「解析失敗」誤報成「健康」。
#
# 用法：
#   bash scripts/ops/prod-purge-health.sh [--limit N] [--fixture <file>]
#
# --limit N     檢查最近 N 筆 purge_runs（預設 7）。
# --fixture <file>
#               跳過真正的 `supabase db query --linked` 連線，改讀這個檔案當作
#               查詢已經整理好的 JSON 陣列結果——供自測
#               （prod-purge-health.test.sh）使用，格式見下方 fetch_rows_json()
#               的說明與 SQL 註解。
set -uo pipefail

LIMIT=7
FIXTURE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --limit)
      [ $# -ge 2 ] || { echo "✗ --limit 缺值" >&2; exit 2; }
      LIMIT=$2
      shift 2
      ;;
    --fixture)
      [ $# -ge 2 ] || { echo "✗ --fixture 缺值" >&2; exit 2; }
      FIXTURE=$2
      shift 2
      ;;
    *)
      echo "✗ 未知參數：$1" >&2
      exit 2
      ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*)
    echo "✗ --limit 必須是正整數，收到：$LIMIT" >&2
    exit 2
    ;;
esac
if [ "$LIMIT" -lt 1 ]; then
  echo "✗ --limit 必須是正整數，收到：$LIMIT" >&2
  exit 2
fi

# 每一列輸出的欄位：run_date（UTC 日期）、purge_run_id、http_status_code
# （null＝這一天找不到對應的 purge-storage HTTP 回應）、http_error_msg、
# http_created。SQL 面：對每筆 purge_runs（依 run_at 取最近 LIMIT 筆），
# lateral join 找同一天 ls153-purge-storage-daily 的第一次 cron 呼叫，再 lateral
# join 找那次呼叫之後 10 分鐘內最早一筆 net._http_response。
build_query() {
  cat <<SQL
with recent_runs as (
  select id as purge_run_id, run_at, run_at::date as run_date
  from private.purge_runs
  order by run_at desc
  limit ${LIMIT}
),
matched as (
  select
    rr.run_date,
    rr.purge_run_id,
    resp.status_code as http_status_code,
    resp.error_msg as http_error_msg,
    resp.created as http_created
  from recent_runs rr
  left join lateral (
    select jrd.start_time
    from cron.job_run_details jrd
    join cron.job j on j.jobid = jrd.jobid
    where j.jobname = 'ls153-purge-storage-daily'
      and jrd.start_time::date = rr.run_date
    order by jrd.start_time asc
    limit 1
  ) call on true
  left join lateral (
    select h.status_code, h.error_msg, h.created
    from net._http_response h
    where call.start_time is not null
      and h.created >= call.start_time
      and h.created < call.start_time + interval '10 minutes'
    order by h.created asc
    limit 1
  ) resp on true
)
select coalesce(jsonb_agg(matched.* order by matched.run_date desc), '[]'::jsonb)
from matched;
SQL
}

# 印出 JSON 陣列字串（供下面的 python3 解析）；`--fixture` 直接讀檔，否則真的
# 打 `supabase db query --linked`。任何一步失敗都印 ⚠ 到 stderr 並回傳空字串
# ——呼叫端看到空字串會 fail loud（exit 1），不會誤報健康。
fetch_rows_json() {
  if [ -n "$FIXTURE" ]; then
    if [ ! -f "$FIXTURE" ]; then
      echo "⚠ --fixture 指定的檔案不存在：$FIXTURE" >&2
      return
    fi
    cat "$FIXTURE"
    return
  fi

  local sql_file raw
  sql_file=$(mktemp "${TMPDIR:-/tmp}/LS-235-purge-health-query.XXXXXX")
  build_query > "$sql_file"

  raw=$(supabase db query --linked --output-format json -f "$sql_file" 2>/dev/null)
  local rc=$?
  rm -f "$sql_file"
  if [ $rc -ne 0 ]; then
    echo "⚠ supabase db query --linked 執行失敗（exit ${rc}）" >&2
    return
  fi

  printf '%s\n' "$raw" | grep -oE '\[.*\]' | tail -n1
}

json=$(fetch_rows_json)

if [ -z "$json" ]; then
  echo "⚠ 查無資料（purge_runs 為空、或查詢/解析失敗，見上方訊息）" >&2
  exit 1
fi

LS235_PURGE_HEALTH_JSON="$json" python3 <<'PY'
import json
import os
import sys

raw = os.environ["LS235_PURGE_HEALTH_JSON"]
try:
    rows = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"⚠ 查詢結果不是合法 JSON：{exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(rows, list) or len(rows) == 0:
    print("⚠ 沒有任何 purge_runs 紀錄可供比對", file=sys.stderr)
    sys.exit(1)

problems = []
for row in rows:
    run_date = row.get("run_date")
    status = row.get("http_status_code")
    error_msg = row.get("http_error_msg")
    if status is None:
        problems.append(f"{run_date}：缺少對應的 purge-storage HTTP 回應")
    elif not (200 <= int(status) < 300):
        problems.append(f"{run_date}：HTTP {status}（{error_msg or '無錯誤訊息'}）")

if problems:
    print("⚠ purge-storage 健康度異常：", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

latest = rows[0]
print(
    f"✓ purge-storage 最近 {len(rows)} 次呼叫皆為 2xx"
    f"（最新：{latest.get('run_date')} HTTP {latest.get('http_status_code')}）"
)
PY
