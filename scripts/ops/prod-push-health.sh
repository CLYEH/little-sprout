#!/bin/bash
# LS-395 —— 正式站 push-dispatch 排程健康度巡檢（人工執行，見 docs/COLLABORATION.md §4-b）。
# 連線骨架沿用 `prod-purge-health.sh`：**必須在已 `supabase link` 的目錄執行**（通常是主
# checkout，不是票 worktree）；未 link 在開頭就 exit 2。唯讀，只執行 SELECT，不印任何憑證。
#
# 三條檢查（單一 `supabase db query --linked`，CLI 回 `{ boundary, rows: [ { payload } ], warning }`
# 信封，解析同 prod-purge-health.sh「M1」說明）：
#   1. 排程：`cron.job` 有 `ls395-push-dispatch-every-minute` 且 active；該 job 最近一次
#      `cron.job_run_details` 必須 succeeded。cron 指令在 vault secret 缺時會 raise
#      （private.invoke_push_dispatch，migration 檔頭第 2 點），那分鐘記 failed、不會有 HTTP 請求——
#      這是「排程在跑但沒打出去」的唯一訊號，所以最近一次 status 要看。
#   2. 最近一次 EF 回應：`net._http_response` 全表最新一筆。pg_net 是非同步，job_run_details 恆為
#      succeeded（見 prod-purge-health.sh 檔頭），真正的 HTTP 狀態只在這張表。與 purge 不同：本排程
#      每分鐘一次，表只保留約 6 小時，所以「全表無列」或「最新一筆超過 15 分鐘」都是異常，不是
#      「保留期外」。無列、`status_code` 為 null（逾時／連線失敗）、非 2xx、過舊皆 ⚠。
#      歸因前提：該表是整個專案共用（無來源欄位），purge-storage 每日一次也寫進來；本排程每分鐘
#      寫一筆，最新一筆實務上必為本排程。
#   3. 待送積壓：`notification_events` 中 `sent_at is null` 且 `occurred_at` 早於 10 分鐘前的列數
#      （claim 條件是 5 分鐘視窗穩定後取件，再留 5 分鐘餘裕）；超過閾值（預設 20，`--backlog-threshold`）⚠。
#      同時印最舊一筆已等多久。
# 輸出三行摘要，再視情況 ✓／⚠（⚠ 走 stderr 並 exit 1）。
#
# 用法：bash scripts/ops/prod-push-health.sh [--backlog-threshold N]
# 自測：scripts/ops/prod-push-health.test.sh（PATH 上的假 `supabase`，全 fixture）。
set -uo pipefail

THRESHOLD=20

while [ $# -gt 0 ]; do
  case "$1" in
    --backlog-threshold)
      [ $# -ge 2 ] || { echo "✗ --backlog-threshold 缺值" >&2; exit 2; }
      THRESHOLD=$2
      shift 2
      ;;
    *)
      echo "✗ 未知參數：$1" >&2
      exit 2
      ;;
  esac
done

case "$THRESHOLD" in
  ''|*[!0-9]*)
    echo "✗ --backlog-threshold 必須是非負整數，收到：$THRESHOLD" >&2
    exit 2
    ;;
esac

if [ ! -f "supabase/.temp/project-ref" ]; then
  echo "✗ prod-push-health：目前所在目錄未 link 到 Supabase 專案" \
    "（找不到 supabase/.temp/project-ref，目前目錄：$(pwd)）——請在已 link" \
    "的目錄執行本腳本（通常是主 checkout，不是票 worktree）。" >&2
  exit 2
fi

build_query() {
  cat <<'SQL'
with job as (
  select jobid, schedule, active from cron.job
  where jobname = 'ls395-push-dispatch-every-minute'
),
last_run as (
  select jrd.status, jrd.return_message, jrd.start_time
  from cron.job_run_details jrd join job on job.jobid = jrd.jobid
  order by jrd.start_time desc
  limit 1
),
latest_response as (
  select status_code, error_msg, timed_out, created
  from net._http_response
  order by created desc
  limit 1
)
select jsonb_build_object(
  'job_exists', exists (select 1 from job),
  'job_schedule', (select schedule from job),
  'job_active', (select active from job),
  'last_run_status', (select status from last_run),
  'last_run_message', (select return_message from last_run),
  'last_run_start', (select start_time from last_run),
  'latest_http_status_code', (select status_code from latest_response),
  'latest_http_error_msg', (select error_msg from latest_response),
  'latest_http_timed_out', (select timed_out from latest_response),
  'latest_http_created', (select created from latest_response),
  'latest_http_age_minutes', (
    select round((extract(epoch from now() - created) / 60)::numeric, 1)
    from latest_response
  ),
  'pending_backlog', (
    select count(*) from public.notification_events
    where sent_at is null and occurred_at < now() - interval '10 minutes'
  ),
  'oldest_pending_minutes', (
    select round((extract(epoch from now() - min(occurred_at)) / 60)::numeric, 1)
    from public.notification_events
    where sent_at is null and occurred_at < now() - interval '10 minutes'
  )
) as payload;
SQL
}

sql_file=$(mktemp "${TMPDIR:-/tmp}/LS-395-push-health-query.XXXXXX")
build_query > "$sql_file"
raw=$(supabase db query --linked --output-format json -f "$sql_file" 2>/dev/null)
rc=$?
rm -f "$sql_file"
if [ $rc -ne 0 ] || [ -z "$raw" ]; then
  echo "⚠ supabase db query --linked 執行失敗或無輸出（exit ${rc}）——未量到任何訊號，不代表健康" >&2
  exit 1
fi

LS395_PUSH_HEALTH_JSON="$raw" LS395_THRESHOLD="$THRESHOLD" python3 <<'PY'
import json
import os
import sys

STALE_MINUTES = 15  # 排程每分鐘一次；最新回應超過這個年紀代表排程停了或打不出去

try:
    envelope = json.loads(os.environ["LS395_PUSH_HEALTH_JSON"])
except json.JSONDecodeError as exc:
    print(f"⚠ 查詢輸出不是合法 JSON：{exc}", file=sys.stderr)
    sys.exit(1)

rows = envelope.get("rows") if isinstance(envelope, dict) else None
if not rows or not isinstance(rows[0].get("payload"), dict):
    print(f"⚠ 查詢輸出不是預期的信封格式（缺 rows[0].payload）：{envelope!r}", file=sys.stderr)
    sys.exit(1)
p = rows[0]["payload"]
threshold = int(os.environ["LS395_THRESHOLD"])

problems = []

# 1. 排程
if not p.get("job_exists"):
    line1 = "排程：不存在（ls395-push-dispatch-every-minute）"
    problems.append("cron.job 沒有 ls395-push-dispatch-every-minute——migration 尚未 db push")
else:
    active = p.get("job_active")
    status = p.get("last_run_status")
    line1 = (
        f"排程：{p.get('job_schedule')}，active={str(active).lower()}，"
        f"最近一次執行 {status or '尚無紀錄'}（{p.get('last_run_start') or '-'}）"
    )
    if not active:
        problems.append("排程存在但 active=false")
    if status is not None and status != "succeeded":
        problems.append(
            f"最近一次排程執行 status={status}：{p.get('last_run_message') or '無訊息'}"
            "（vault secret 未建立時會是這個）"
        )

# 2. 最近一次 EF 回應
created = p.get("latest_http_created")
code = p.get("latest_http_status_code")
age = p.get("latest_http_age_minutes")
if created is None:
    line2 = "最新 HTTP 回應：net._http_response 全表無列"
    problems.append("net._http_response 無任何列（保留約 6 小時，每分鐘排程不該為空）")
elif code is None:
    detail = p.get("latest_http_error_msg") or ("逾時" if p.get("latest_http_timed_out") else "無錯誤訊息")
    line2 = f"最新 HTTP 回應：未取得 HTTP 狀態（{detail}，{created}，{age} 分鐘前）"
    problems.append(f"最新呼叫未取得 HTTP 狀態：{detail}")
else:
    line2 = f"最新 HTTP 回應：{code}（{created}，{age} 分鐘前）"
    if not (200 <= int(code) < 300):
        problems.append(f"最新 HTTP 回應非 2xx：{code}（{p.get('latest_http_error_msg') or '無錯誤訊息'}）")
if created is not None and age is not None and float(age) > STALE_MINUTES:
    problems.append(f"最新 HTTP 回應已是 {age} 分鐘前（> {STALE_MINUTES}），排程可能停了")

# 3. 待送積壓
backlog = int(p.get("pending_backlog") or 0)
oldest = p.get("oldest_pending_minutes")
line3 = f"待送積壓：{backlog}（閾值 {threshold}）" + (f"，最舊已等 {oldest} 分鐘" if backlog else "")
if backlog > threshold:
    problems.append(f"notification_events 待送積壓 {backlog} 筆 > 閾值 {threshold}")

print(line1)
print(line2)
print(line3)

if problems:
    print("⚠ push-dispatch 健康度異常：", file=sys.stderr)
    for item in problems:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

print("✓ push-dispatch 排程、最近回應與待送積壓皆正常")
PY
