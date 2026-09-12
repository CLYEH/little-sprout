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
# R3（merge-review R2 delta comment 32829a28，m1 minor）：「排程觸發」原本只看
# `cron.job_run_details` 有沒有那一天的列，不分 `status`——pg_cron 命令本身失敗
# （例如 vault secret 讀不到、`select net.http_post(...)` 直接 raise）那天根本
# 沒有發出 HTTP 請求，卻照樣算「已觸發」。改成只有 `status = 'succeeded'` 才計入
# `job_triggered_days`；有觸發但非 succeeded 的日期另外列出（`failed_job_trigger_dates`），
# 印出對應的 `status` 值方便判讀是排程本身的問題還是別的。
#
# R3（i1 informational，記錄前提）：輔訊號讀的 `net._http_response` 是整個
# 專案共用的 pg_net 回應表，不是 purge-storage 專屬——**這裡的歸因前提是「目前
# 本專案只有 `cron.job`（jobid 2，`ls153-purge-storage-daily`）這一個 pg_net
# 呼叫者，也沒有任何 DB webhook／trigger 會呼叫 pg_net」**（唯讀查過
# `pg_trigger` 為 0 筆）。之後若新增任何其他 pg_net 呼叫來源（例如
# push-dispatch 的排程真的接上、或新增 DB webhook），這一行會靜默換成別人的
# 回應而不會有任何警示——加人務必同時檢查這個假設是否還成立，必要時把輔訊號
# 改成過濾特定呼叫來源（目前 `net._http_response` 本身不記錄來源 URL，見
# `queue_retry.ts` 檔頭「已知限制」同型說明）。
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
# R3（merge-review R2 delta comment 32829a28，M3 major）：R2 版本輔訊號只用
# `latest_http_status_code is None` 判斷「保留期外查不到」，把兩種完全不同的
# 事實併成一種——(a) `net._http_response` 全表沒有任何列（保留期已過，確實
# 無法核對）、(b) **有列**但那次呼叫根本沒拿到 HTTP 狀態（逾時／連線失敗，
# pg_net 對這種情況寫 `status_code=null`＋`error_msg`＋`timed_out=true`，
# `created` 仍是 NOT NULL）。(b) 正是這張表明擺著支援的形狀（唯讀查過
# `information_schema` 確認），也正是本票起因的那類故障（09-11 那次 Gateway
# Timeout）——R2 版本會把它誤判成「保留期外」而放行，是本票要消滅的盲區原樣
# 放回來。改成三分流：`latest_http_created is None`（全表無列）→ 保留期外，
# 不算異常；`created` 非 null 但 `status_code` 為 null → 異常，印
# `error_msg`／`timed_out`；`status_code` 有值 → 沿用既有 2xx／非 2xx 判定。
#
# R3（i2 informational）：三行摘要原本沒有標明「最新一筆是不是今天的」——如果
# 最新一筆比預期舊（例如視窗末日之前就沒有更新的呼叫），使用者可能誤以為那是
# 最新狀態。SQL 面另外算一個 `query_date`（伺服器端 `current_date`，避免用本機
# 時區猜「今天」），有 `latest_http_created` 時在第三行標明「今日」／「非今日」。
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
#   query_date                  伺服器端 current_date（R3 i2：判斷「最新一筆是
#                                不是今天」不依賴本機時區）
#   job_triggered_days          視窗內 ls153-purge-storage-daily 有 succeeded
#                                觸發過的天數（R3 m1：不算非 succeeded 的觸發）
#   missing_job_trigger_dates   視窗內沒有 succeeded 觸發的日期陣列（含完全沒
#                                觸發、與有觸發但失敗兩種）
#   failed_job_trigger_dates    視窗內「有觸發但非 succeeded」的 {day,status}
#                                陣列（R3 m1 新增，是 missing_job_trigger_dates
#                                的子集，供印出具體 status 值）
#   purge_run_days              視窗內 purge_runs 有列的天數
#   missing_purge_run_dates     視窗內 purge_runs 缺列的日期陣列
#   latest_http_status_code／latest_http_error_msg／latest_http_timed_out／
#   latest_http_created          net._http_response 全表最新一筆——`created` 為
#                                null＝全表無列（保留期外，不算異常）；`created`
#                                非 null 但 `status_code` 為 null＝有列但沒拿到
#                                HTTP 狀態（逾時／連線失敗，R3 M3 新增的異常
#                                分流）；`status_code` 有值＝沿用既有 2xx 判定。
build_query() {
  cat <<SQL
with days as (
  select generate_series(
    current_date - ${LIMIT},
    current_date - 1,
    interval '1 day'
  )::date as day
),
job_run_attempts as (
  select jrd.start_time::date as day, jrd.status
  from cron.job_run_details jrd
  join cron.job j on j.jobid = jrd.jobid
  where j.jobname = 'ls153-purge-storage-daily'
    and jrd.start_time::date >= current_date - ${LIMIT}
    and jrd.start_time::date <= current_date - 1
),
job_run_days as (
  select distinct day from job_run_attempts where status = 'succeeded'
),
job_run_failed as (
  select day, string_agg(distinct status, ',' order by status) as status
  from job_run_attempts
  where status <> 'succeeded'
  group by day
),
purge_run_days as (
  select distinct run_at::date as day
  from private.purge_runs
  where run_at::date >= current_date - ${LIMIT}
    and run_at::date <= current_date - 1
),
latest_response as (
  select status_code, error_msg, timed_out, created
  from net._http_response
  order by created desc
  limit 1
)
select jsonb_build_object(
  'window_days', ${LIMIT},
  'query_date', current_date,
  'job_triggered_days', (select count(*) from job_run_days),
  'missing_job_trigger_dates', (
    select coalesce(jsonb_agg(d.day order by d.day), '[]'::jsonb)
    from days d where d.day not in (select day from job_run_days)
  ),
  'failed_job_trigger_dates', (
    select coalesce(
      jsonb_agg(jsonb_build_object('day', day, 'status', status) order by day),
      '[]'::jsonb
    )
    from job_run_failed
  ),
  'purge_run_days', (select count(*) from purge_run_days),
  'missing_purge_run_dates', (
    select coalesce(jsonb_agg(d.day order by d.day), '[]'::jsonb)
    from days d where d.day not in (select day from purge_run_days)
  ),
  'latest_http_status_code', (select status_code from latest_response),
  'latest_http_error_msg', (select error_msg from latest_response),
  'latest_http_timed_out', (select timed_out from latest_response),
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
query_date = payload.get("query_date")
job_triggered_days = payload.get("job_triggered_days")
missing_job_trigger_dates = payload.get("missing_job_trigger_dates") or []
failed_job_trigger_dates = payload.get("failed_job_trigger_dates") or []
purge_run_days = payload.get("purge_run_days")
missing_purge_run_dates = payload.get("missing_purge_run_dates") or []
latest_status = payload.get("latest_http_status_code")
latest_error = payload.get("latest_http_error_msg")
latest_timed_out = payload.get("latest_http_timed_out")
latest_created = payload.get("latest_http_created")

problems = []

# R3（m1）：job_triggered_days 只算 succeeded；有觸發但非 succeeded 的日期
# 另外印出具體 status（是 missing_job_trigger_dates 的子集，不重複計數）。
line1 = f"排程觸發：{job_triggered_days}/{window_days}（ls153-purge-storage-daily）"
if missing_job_trigger_dates:
    line1 += f"，缺：{', '.join(missing_job_trigger_dates)}"
    problems.append(
        f"排程有 {len(missing_job_trigger_dates)} 天未成功觸發："
        f"{', '.join(missing_job_trigger_dates)}"
    )
for item in failed_job_trigger_dates:
    problems.append(f"排程 {item.get('day')} status={item.get('status')}")

line2 = f"purge_runs：{purge_run_days}/{window_days}"
if missing_purge_run_dates:
    line2 += f"，缺：{', '.join(missing_purge_run_dates)}"
    problems.append(
        f"purge_runs 有 {len(missing_purge_run_dates)} 天缺列："
        f"{', '.join(missing_purge_run_dates)}"
    )


def date_note(created, today):
    """R3（i2）：標明這筆回應是不是今天的，避免誤把一筆舊回應當成最新狀態。"""
    if not created or not today:
        return ""
    return "，今日" if created[:10] == today else "，非今日"


# R3（M3，merge-review R2 delta comment 32829a28）：三分流，不再只用
# `latest_status is None` 判斷「保留期外」——那個條件對「有列但沒拿到 HTTP
# 狀態（逾時／連線失敗）」一樣成立，R2 版本會把這種真正的異常誤判成「保留期外
# 查不到」而放行，正好是本票要接住的那類故障（09-11 那次事故就是這樣）。
if latest_created is None:
    # 全表沒有任何列——保留期已過（net._http_response 僅保留約 6 小時），
    # 不算異常。
    line3 = "最新 HTTP 回應：保留期外，無法核對（net._http_response 僅保留約 6 小時）"
elif latest_status is None:
    # 有列，但那次呼叫沒拿到 HTTP 狀態（逾時／連線失敗）——真正的異常。
    detail = latest_error or ("逾時" if latest_timed_out else "無錯誤訊息")
    line3 = (
        f"最新 HTTP 回應：未取得 HTTP 狀態（{detail}，{latest_created}"
        f"{date_note(latest_created, query_date)}）"
    )
    problems.append(f"最新呼叫未取得 HTTP 狀態：{detail}（{latest_created}）")
else:
    line3 = (
        f"最新 HTTP 回應：{latest_status}"
        f"（{latest_created}{date_note(latest_created, query_date)}）"
    )
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
