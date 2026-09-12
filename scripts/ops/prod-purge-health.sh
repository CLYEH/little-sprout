#!/bin/bash
# LS-235 —— 正式站 purge-storage 排程健康度巡檢（每週人工執行，見
# docs/COLLABORATION.md §4-b）。**必須在已 `supabase link` 的目錄執行**（通常是
# 主 checkout，不是票 worktree——票 worktree 各自獨立、預設沒有連結任何正式站
# 專案；見下方「腳本開頭檢查」與 i3）。
#
# 背景：`cron.job_run_details` 記的是 pg_cron 呼叫 pg_net.http_post() 這個動作
# 本身有沒有成功排進非同步佇列，不是 purge-storage Edge Function 實際回應的
# HTTP 狀態——pg_net 是非同步呼叫，job_run_details 幾乎永遠回報 succeeded，即使
# 那次呼叫最終收到 500（09-11 一次 Gateway Timeout 就是這樣被漏掉，見 LS-96 池項
# fa8c91fc／LS-235 票文）。真正的 HTTP 狀態只在 `net._http_response`
# （status_code／error_msg／created）。
#
# R2（merge-review R1 comment da96a7d0，M2 major）：`net._http_response` 只保留
# 約 6 小時（正式站唯讀查到 `pg_net.ttl = 6 hours`，全表在 reviewer 查驗當下只
# 剩 1 列）——原本「取最近 N 天每天比對一次 HTTP 回應」的設計，在完全健康的一
# 週裡也會有 N-1 天因為「保留期已過、查不到回應」被誤判成異常，跟真事故長得
# 一模一樣。改成雙訊號設計：
#   **主訊號**（決定 exit code）：`private.purge_runs`（`ls153-purge-expired-daily`
#     每次執行留一列）與 `cron.job_run_details`（`ls153-purge-storage-daily`，
#     jobid 見 `cron.job`）各自獨立算「最近 N 天（不含今天，見下方視窗說明）裡
#     有幾天出現過至少一列／一次觸發」——**不透過 join 互相依賴**（R2 修正
#     i4：R1 版本以 `purge_runs` 當 join driver，若某天 `ls153-purge-expired-daily`
#     沒跑成功，那天 `ls153-purge-storage-daily` 的呼叫完全不會被檢查，是個
#     靜默盲區）。任一邊缺天數就是異常。
#   **輔訊號**（僅供參考，不影響 exit code）：`net._http_response` 只看全表
#     最新一筆——如果還在保留期內查得到，印出 `status_code`（非 2xx 才算異常，
#     計入 exit code）；查不到就印「保留期外，無法核對」，不計入異常。
# 輸出固定三行摘要（排程觸發 N/M、purge_runs N/M、最新 HTTP 狀態），再視情況印
# `✓`／`⚠`。
#
# 視窗定義：最近 `--limit`（預設 7）個**完整**日曆日，UTC，**不含今天**——
# 兩支排程都是每日一次（`ls153-purge-expired-daily` 19:00 UTC、
# `ls153-purge-storage-daily` 19:15 UTC 附近），今天當下這班可能還沒跑，把
# 今天算進視窗會被誤判成「缺天」；從「昨天」往回數 N 天，任何執行本腳本的時間
# 點，那 N 天的排定時間必然都已經過了。
#
# 唯讀：只執行 SELECT，不寫入任何資料；不讀取任何 `.env` 值、不印出任何憑證
# （`supabase db query --linked` 走 CLI 既有的專案連結，不需要在這裡處理任何
# 連線字串或金鑰）。
#
# R2（merge-review R1 comment da96a7d0，M1 major）：`supabase db query --linked
# --output-format json` 在真實通道下回的是**多行 pretty-print 的信封**
# `{ "boundary": ..., "rows": [ { "<欄位別名>": ... } ], "warning": ... }`，
# 不是裸陣列——R1 版本用 `grep -oE '\[.*\]'` 逐行比對，陣列跨多行時抓不到任何
# 東西，永遠落入「查無資料」分支（真通道下這支腳本因此不存在成功路徑）。改法：
# 不再用正則掏字串，直接把整份 stdout 交給 python3 的 `json.loads()`，取
# `envelope["rows"][0]["payload"]`（SQL 面把整包結果 `as payload` 命名，不依賴
# Postgres 對無別名欄位的預設命名，例如 `coalesce`／`jsonb_build_object`）。
# `--fixture` 現在必須注入**同樣的信封格式**（一份去識別化的真實 CLI 輸出），
# 讓自測跟真通道走同一條解析路徑，不會再出現「12 組自測全綠、真通道全滅」的
# 落差（見 prod-purge-health.test.sh 的 fixture 檔）。
#
# R2（merge-review R1 comment da96a7d0，i3 informational）：腳本開頭先檢查目前
# 目錄是不是已經 `supabase link`——不是的話（例如在票 worktree 裡執行）立刻印
# 清楚訊息並 exit 2，不要讓使用者先痛苦等一次 `supabase db query --linked` 逾時
# 或報「執行失敗」才意識到問題出在目錄。
#
# 用法：
#   bash scripts/ops/prod-purge-health.sh [--limit N] [--fixture <file>]
#
# --limit N     檢查最近 N 個完整日曆日（預設 7，不含今天）。
# --fixture <file>
#               跳過真正的 `supabase db query --linked` 連線，改讀這個檔案當作
#               CLI 的完整信封輸出（見上方「M1」說明的信封格式）——供自測
#               （prod-purge-health.test.sh）使用，也可手動除錯用。
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

if [ -n "$FIXTURE" ] && [ ! -f "$FIXTURE" ]; then
  echo "⚠ --fixture 指定的檔案不存在：$FIXTURE" >&2
  exit 1
fi

# R2（i3）：腳本開頭就檢查，不要等 supabase CLI 逾時／報錯才發現目錄不對。
# `--fixture` 模式完全不連線，不需要這個前提。
if [ -z "$FIXTURE" ] && [ ! -f "supabase/.temp/project-ref" ]; then
  echo "✗ prod-purge-health：目前所在目錄未 link 到 Supabase 專案" \
    "（找不到 supabase/.temp/project-ref，目前目錄：$(pwd)）——請在已 link" \
    "的目錄執行本腳本（通常是主 checkout，不是票 worktree），或加 --fixture" \
    "走自測路徑。" >&2
  exit 2
fi

# 輸出（jsonb_build_object，單一物件、單一列，見上方「M1」說明的別名策略——
# SQL 欄位固定叫 payload，解析端不必猜測任何 Postgres 隱含命名規則）：
#   window_days                 這次視窗的天數（＝--limit）
#   job_triggered_days          視窗內 ls153-purge-storage-daily 有觸發過的天數
#   missing_job_trigger_dates   視窗內完全沒觸發過的日期陣列
#   purge_run_days              視窗內 purge_runs 有列的天數
#   missing_purge_run_dates     視窗內 purge_runs 缺列的日期陣列
#   latest_http_status_code／latest_http_error_msg／latest_http_created
#                                net._http_response 全表最新一筆（null＝保留期
#                                外查不到任何資料，不算異常，見上方「輔訊號」）
build_query() {
  cat <<SQL
with days as (
  select generate_series(
    current_date - ${LIMIT},
    current_date - 1,
    interval '1 day'
  )::date as day
),
job_run_days as (
  select distinct jrd.start_time::date as day
  from cron.job_run_details jrd
  join cron.job j on j.jobid = jrd.jobid
  where j.jobname = 'ls153-purge-storage-daily'
    and jrd.start_time::date >= current_date - ${LIMIT}
    and jrd.start_time::date <= current_date - 1
),
purge_run_days as (
  select distinct run_at::date as day
  from private.purge_runs
  where run_at::date >= current_date - ${LIMIT}
    and run_at::date <= current_date - 1
),
latest_response as (
  select status_code, error_msg, created
  from net._http_response
  order by created desc
  limit 1
)
select jsonb_build_object(
  'window_days', ${LIMIT},
  'job_triggered_days', (select count(*) from job_run_days),
  'missing_job_trigger_dates', (
    select coalesce(jsonb_agg(d.day order by d.day), '[]'::jsonb)
    from days d where d.day not in (select day from job_run_days)
  ),
  'purge_run_days', (select count(*) from purge_run_days),
  'missing_purge_run_dates', (
    select coalesce(jsonb_agg(d.day order by d.day), '[]'::jsonb)
    from days d where d.day not in (select day from purge_run_days)
  ),
  'latest_http_status_code', (select status_code from latest_response),
  'latest_http_error_msg', (select error_msg from latest_response),
  'latest_http_created', (select created from latest_response)
) as payload;
SQL
}

# 印出 CLI 的完整信封 stdout（供下面的 python3 解析）；`--fixture` 直接讀檔，
# 否則真的打 `supabase db query --linked`。任何一步失敗都印訊息到 stderr 並
# 回傳空字串——呼叫端看到空字串會 fail loud（exit 1），不會誤報健康。
fetch_raw_output() {
  if [ -n "$FIXTURE" ]; then
    cat "$FIXTURE"
    return
  fi

  local sql_file raw rc
  sql_file=$(mktemp "${TMPDIR:-/tmp}/LS-235-purge-health-query.XXXXXX")
  build_query > "$sql_file"

  raw=$(supabase db query --linked --output-format json -f "$sql_file" 2>/dev/null)
  rc=$?
  rm -f "$sql_file"
  if [ $rc -ne 0 ]; then
    echo "⚠ supabase db query --linked 執行失敗（exit ${rc}）" >&2
    return
  fi

  printf '%s' "$raw"
}

raw=$(fetch_raw_output)

if [ -z "$raw" ]; then
  echo "⚠ 查無資料（連線失敗或查詢無輸出，見上方訊息）" >&2
  exit 1
fi

LS235_PURGE_HEALTH_JSON="$raw" python3 <<'PY'
import json
import os
import sys

raw = os.environ["LS235_PURGE_HEALTH_JSON"]
try:
    envelope = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"⚠ 查詢輸出不是合法 JSON：{exc}", file=sys.stderr)
    sys.exit(1)

# R2（M1）：CLI --output-format json 的信封形狀是
# { boundary, rows: [ { payload: {...} } ], warning }，不是裸陣列／裸物件。
if not isinstance(envelope, dict) or "rows" not in envelope:
    print(
        f"⚠ 查詢輸出不是預期的信封格式（缺 rows 欄位）：{envelope!r}",
        file=sys.stderr,
    )
    sys.exit(1)

rows = envelope.get("rows") or []
if not rows:
    print("⚠ 查詢沒有回傳任何列（rows 為空）", file=sys.stderr)
    sys.exit(1)

payload = rows[0].get("payload")
if not isinstance(payload, dict):
    print(f"⚠ 查詢結果缺少 payload 欄位：{rows[0]!r}", file=sys.stderr)
    sys.exit(1)

window_days = payload.get("window_days")
job_triggered_days = payload.get("job_triggered_days")
missing_job_trigger_dates = payload.get("missing_job_trigger_dates") or []
purge_run_days = payload.get("purge_run_days")
missing_purge_run_dates = payload.get("missing_purge_run_dates") or []
latest_status = payload.get("latest_http_status_code")
latest_error = payload.get("latest_http_error_msg")
latest_created = payload.get("latest_http_created")

problems = []

line1 = f"排程觸發：{job_triggered_days}/{window_days}（ls153-purge-storage-daily）"
if missing_job_trigger_dates:
    line1 += f"，缺：{', '.join(missing_job_trigger_dates)}"
    problems.append(
        f"排程有 {len(missing_job_trigger_dates)} 天未觸發："
        f"{', '.join(missing_job_trigger_dates)}"
    )

line2 = f"purge_runs：{purge_run_days}/{window_days}"
if missing_purge_run_dates:
    line2 += f"，缺：{', '.join(missing_purge_run_dates)}"
    problems.append(
        f"purge_runs 有 {len(missing_purge_run_dates)} 天缺列："
        f"{', '.join(missing_purge_run_dates)}"
    )

# R2（M2 輔訊號）：net._http_response 只保留約 6 小時，查不到不算異常——只有
# 「查得到但不是 2xx」才計入 problems。
if latest_status is None:
    line3 = "最新 HTTP 回應：保留期外，無法核對（net._http_response 僅保留約 6 小時）"
else:
    line3 = f"最新 HTTP 回應：{latest_status}（{latest_created}）"
    if not (200 <= int(latest_status) < 300):
        problems.append(
            f"最新 HTTP 回應非 2xx：{latest_status}"
            f"（{latest_error or '無錯誤訊息'}，{latest_created}）"
        )

print(line1)
print(line2)
print(line3)

if problems:
    print("⚠ purge-storage 健康度異常：", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

print(f"✓ purge-storage 最近 {window_days} 天排程與 purge_runs 皆完整")
sys.exit(0)
PY
