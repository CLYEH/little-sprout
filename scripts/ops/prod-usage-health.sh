#!/bin/bash
# LS-399 —— 正式站 Supabase 用量水位巡檢（docs/PLAN.md §10-A 第二道防線「設定接近方案上限時通知，
# 別靠月結帳單才發現」的腳本側；Dashboard 端的 email 告警設定步驟見 docs/API.md §11）。連線骨架沿用
# `prod-purge-health.sh`／`prod-storage-verify.sh`：**必須在已 `supabase link` 的目錄執行**（通常是
# 主 checkout，不是票 worktree），未 link 開頭就 exit 2。
#
# 三個水位（單一 `supabase db query --linked`，SQL 把結果包成 `jsonb_build_object(...) as payload`，
# 解析 `{ boundary, rows: [ { payload } ], warning }` 信封，同 prod-purge-health.sh 檔頭「M1」）：
#   (a) families_used  `sum(public.families.storage_used_bytes)`——app 自己記帳的額度用量（未軟刪 media 的
#                      byte_size 加總，不含縮圖物件、不含軟刪待清的原檔，見 docs/API.md §3 byte_size 段）。
#   (b) bucket_bytes   `sum(storage.objects.metadata->>'size')`——Storage 全部 bucket 的實際物件大小，
#                      Supabase 對 File storage 計量的口徑。
#   (c) db_bytes       `pg_database_size(current_database())`——Supabase 對 Database size 計量的口徑。
# (a)(b) 對 Storage 上限、(c) 對 DB 上限各算百分比：≥ WARN_PCT 印 ⚠、≥ FAIL_PCT 印 ✗；任一 ✗ exit 1，
# 只有 ⚠ 仍 exit 0（⚠ 是「開始處置」的訊號，見 API.md §11 的 70% 處置順序）。
# 另印 (a)(b) 差額：|b−a| / max(a,b) > DRIFT_PCT 印 ⓘ 提示改跑 `prod-storage-verify.sh` 查孤兒物件／計數
# 漂移（不影響 exit code——縮圖與軟刪待清的物件本來就讓 b > a，差額是線索不是判決）。
#
# **唯讀**：只有 select，不寫入任何資料；不讀任何 `.env`、不印任何憑證（走 CLI 既有的專案連結）。
# 本腳本只報告，不改額度、不關註冊、不升級方案（票文「不做」）。
#
# 用法：
#   bash scripts/ops/prod-usage-health.sh [--fixture <a>,<b>,<c>]
#
# --fixture a,b,c  跳過真正連線，三個水位直接給 bytes（非負整數），腳本自己包成與真通道同形的信封
#                  再走同一條解析路徑——供自測（prod-usage-health.test.sh）與手動除錯用。
# Exit：0＝全 ✓（或只有 ⚠）；1＝任一 ✗，或連線／解析失敗（fail loud，不誤報健康）；2＝用法錯誤或未 link。
set -uo pipefail

# ---- 方案上限（Supabase 定價頁 2026-09-29 查：Free plan File storage 1 GB、Database size 500 MB；
#      以 1 GiB／500 MiB 計）。換方案時改這兩行，並同步 docs/API.md §11「Supabase 用量水位」段。----
STORAGE_LIMIT_BYTES=1073741824   # 1 GiB
DB_LIMIT_BYTES=524288000         # 500 MiB
WARN_PCT=70
FAIL_PCT=90
DRIFT_PCT=10

FIXTURE=""

while [ $# -gt 0 ]; do
  case "$1" in
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

if [ -n "$FIXTURE" ]; then
  case "$FIXTURE" in
    *[!0-9,]*|,*|*,|*,,*)
      echo "✗ --fixture 格式必須是 <a>,<b>,<c>（三個非負整數 bytes），收到：$FIXTURE" >&2
      exit 2
      ;;
  esac
  IFS=, read -r fx_a fx_b fx_c fx_extra <<<"$FIXTURE"
  if [ -z "${fx_a:-}" ] || [ -z "${fx_b:-}" ] || [ -z "${fx_c:-}" ] || [ -n "${fx_extra:-}" ]; then
    echo "✗ --fixture 格式必須是 <a>,<b>,<c>（三個非負整數 bytes），收到：$FIXTURE" >&2
    exit 2
  fi
fi

if [ -z "$FIXTURE" ] && [ ! -f "supabase/.temp/project-ref" ]; then
  echo "✗ prod-usage-health：目前所在目錄未 link 到 Supabase 專案" \
    "（找不到 supabase/.temp/project-ref，目前目錄：$(pwd)）——請在已 link" \
    "的目錄執行本腳本（通常是主 checkout，不是票 worktree），或加 --fixture" \
    "走自測路徑。" >&2
  exit 2
fi

build_query() {
  cat <<'SQL'
select jsonb_build_object(
  'families_used', (select coalesce(sum(storage_used_bytes), 0) from public.families),
  'bucket_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects),
  'db_bytes', pg_database_size(current_database())
) as payload;
SQL
}

if [ -n "$FIXTURE" ]; then
  raw=$(printf '{\n  "boundary": "fixture",\n  "rows": [\n    { "payload": { "families_used": %s, "bucket_bytes": %s, "db_bytes": %s } }\n  ],\n  "warning": null\n}\n' \
    "$fx_a" "$fx_b" "$fx_c")
else
  sql_file=$(mktemp "${TMPDIR:-/tmp}/LS-399-usage-health.XXXXXX")
  build_query > "$sql_file"
  raw=$(supabase db query --linked --output-format json -f "$sql_file" 2>/dev/null)
  rc=$?
  rm -f "$sql_file"
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    echo "✗ supabase db query --linked 執行失敗或無輸出（exit ${rc}）——未量到任何水位，不代表健康" >&2
    exit 1
  fi
fi

LS399_RAW="$raw" \
LS399_STORAGE_LIMIT="$STORAGE_LIMIT_BYTES" \
LS399_DB_LIMIT="$DB_LIMIT_BYTES" \
LS399_WARN_PCT="$WARN_PCT" \
LS399_FAIL_PCT="$FAIL_PCT" \
LS399_DRIFT_PCT="$DRIFT_PCT" \
python3 <<'PY'
import json
import os
import sys

try:
    envelope = json.loads(os.environ["LS399_RAW"])
except json.JSONDecodeError as exc:
    print(f"✗ 查詢輸出不是合法 JSON：{exc}", file=sys.stderr)
    sys.exit(1)
rows = envelope.get("rows") if isinstance(envelope, dict) else None
if not rows or not isinstance(rows[0].get("payload"), dict):
    print(f"✗ 查詢輸出不是預期的信封格式（缺 rows[0].payload）：{envelope!r}", file=sys.stderr)
    sys.exit(1)
payload = rows[0]["payload"]

values = {}
for key in ("families_used", "bucket_bytes", "db_bytes"):
    v = payload.get(key)
    if not isinstance(v, int) or v < 0:
        print(f"✗ payload.{key} 不是非負整數：{v!r}", file=sys.stderr)
        sys.exit(1)
    values[key] = v

storage_limit = int(os.environ["LS399_STORAGE_LIMIT"])
db_limit = int(os.environ["LS399_DB_LIMIT"])
warn_pct = int(os.environ["LS399_WARN_PCT"])
fail_pct = int(os.environ["LS399_FAIL_PCT"])
drift_pct = int(os.environ["LS399_DRIFT_PCT"])


def mib(n):
    return f"{n / 1048576:.1f} MiB"


failed = []
warned = []


def level(label, used, limit, limit_label):
    pct = used * 100 / limit
    if pct >= fail_pct:
        mark = "✗"
        failed.append(label)
    elif pct >= warn_pct:
        mark = "⚠"
        warned.append(label)
    else:
        mark = "✓"
    print(f"{mark} {label}：{mib(used)}（{used} bytes），{pct:.1f}% of {limit_label}")


level("(a) families.storage_used_bytes 加總", values["families_used"], storage_limit, "Storage 上限 1 GiB")
level("(b) storage.objects 實際大小", values["bucket_bytes"], storage_limit, "Storage 上限 1 GiB")
level("(c) DB 大小 pg_database_size", values["db_bytes"], db_limit, "DB 上限 500 MiB")

a, b = values["families_used"], values["bucket_bytes"]
denom = max(a, b)
drift = abs(b - a) * 100 / denom if denom else 0.0
if drift > drift_pct:
    print(
        f"ⓘ (a)(b) 差額 {mib(abs(b - a))}（{drift:.1f}%，> {drift_pct}%）：可能是孤兒物件或計數漂移"
        "（縮圖／軟刪待清的原檔本來就讓 b > a）——跑 bash scripts/ops/prod-storage-verify.sh 查"
    )
else:
    print(f"✓ (a)(b) 差額 {mib(abs(b - a))}（{drift:.1f}%，≤ {drift_pct}%）")

sys.stdout.flush()
if failed:
    print(f"✗ prod-usage-health：{'、'.join(failed)} ≥ {fail_pct}%——見 docs/API.md §11 處置順序", file=sys.stderr)
    sys.exit(1)
if warned:
    print(f"⚠ prod-usage-health：{'、'.join(warned)} ≥ {warn_pct}%——開始處置，見 docs/API.md §11")
    sys.exit(0)
print(f"✓ prod-usage-health 三個水位皆 < {warn_pct}%")
sys.exit(0)
PY
