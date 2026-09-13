#!/bin/bash
# LS-244 —— 正式站 Storage 部署驗證腳本（見 docs/PLAN.md §5「Storage 的雲端部署驗證清單」，本機測不到、
# `db push` 綠燈不能取代的三件事；連線骨架沿用 `prod-purge-health.sh`，LS-235）。
#
# 三條檢查（判準照 docs/PLAN.md §5 原文，約 L119–L125，這裡不重述判準只註記如何機械化）：
#   1. `storage.prefixes`：`to_regclass('storage.prefixes')` 非 NULL 才需要再查 `relrowsecurity` 與
#      `pg_policy`——表不存在（本機開發映像通常沒有這張表）視為 ⓘ 略過；**啟用了 RLS 又沒有任何 policy**
#      才是 PLAN 指名「上傳會在雲端被擋的形狀」的 ⚠（本腳本不做「真實上傳」那一步最終判準，只做這裡
#      機械查得到的前置訊號）。三個子查詢一律用 `to_regclass()` 取 oid（而非 `'…'::regclass` 顯式轉型）
#      ——表不存在時 `to_regclass()` 回 NULL、`oid = NULL`／`polrelid = NULL` 只是查無資料，不會像
#      `::regclass` 轉型那樣直接對不存在的關聯拋錯，三個子查詢可以放在同一個信封裡一次問完。
#   2. `storage.objects where bucket_id = 'media'`：抽樣最近 N 筆（預設 20，`--limit N`，依 `created_at`
#      取最新）`owner`／`owner_id` 至少一欄非 NULL——這裡是整批抽樣的聚合判斷（任一欄在抽樣中有填值即
#      算過），不是要求每一列都填值；抽樣 0 筆（bucket 目前無物件）視為 ⓘ 略過；兩欄在整批抽樣裡都完全
#      是 NULL 才是 ⚠（PLAN 原文：不是安全問題，只是「上傳者自刪孤兒物件」在雲端不會生效）。
#   3. `storage.buckets`：`pg_policy` 數應為 0，非 0 即 ⚠（PLAN 原文：表示有人從 dashboard 加了東西）。
#
# 任一 ⚠ exit 1；全部 ✓／ⓘ exit 0。**唯讀**：三條查詢全部是 select，不寫入任何資料；不讀取任何 `.env`
# 值、不印出任何憑證（`supabase db query --linked` 走 CLI 既有的專案連結，不需要在這裡處理任何連線字串
# 或金鑰）。本腳本只報告，不修任何發現的問題——真的抓到 ⚠ 另開票處理（見票文「不做」）。
#
# 三條檢查各自獨立一次 `supabase db query --linked`（對應 PLAN 原文描述的三個獨立查詢，也讓
# `--fixture <dir>` 自測能各自替換單一情境而不牽動另外兩條）。`--fixture <dir>` 指到一個目錄，內含
# `prefixes.json`／`objects.json`／`buckets.json` 三個檔案，格式同 `supabase db query --linked
# --output-format json` 的完整信封 `{ boundary, rows: [ { payload: {...} } ], warning }`（見
# prod-purge-health.sh 檔頭「M1」說明）——供自測（prod-storage-verify.test.sh）與手動除錯用。
#
# 用法：
#   bash scripts/ops/prod-storage-verify.sh [--limit N] [--fixture <dir>]
#
# --limit N       抽樣 storage.objects（bucket=media）的筆數（預設 20）。
# --fixture <dir> 跳過真正連線，改讀這個目錄裡的三個信封檔案（見上）。
set -uo pipefail

LIMIT=20
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

if [ -n "$FIXTURE" ] && [ ! -d "$FIXTURE" ]; then
  echo "⚠ --fixture 指定的目錄不存在：$FIXTURE" >&2
  exit 1
fi

# 腳本開頭就檢查是否已 link（同 prod-purge-health.sh 的 i3）；--fixture 模式完全不連線，不需要這個前提。
if [ -z "$FIXTURE" ] && [ ! -f "supabase/.temp/project-ref" ]; then
  echo "✗ prod-storage-verify：目前所在目錄未 link 到 Supabase 專案" \
    "（找不到 supabase/.temp/project-ref，目前目錄：$(pwd)）——請在已 link" \
    "的目錄執行本腳本（通常是主 checkout，不是票 worktree），或加 --fixture" \
    "走自測路徑。" >&2
  exit 2
fi

sql_prefixes() {
  cat <<'SQL'
select jsonb_build_object(
  'exists', (to_regclass('storage.prefixes') is not null),
  'relrowsecurity', (select relrowsecurity from pg_class where oid = to_regclass('storage.prefixes')),
  'policies', (
    select coalesce(jsonb_agg(polname order by polname), '[]'::jsonb)
    from pg_policy where polrelid = to_regclass('storage.prefixes')
  )
) as payload;
SQL
}

sql_objects() {
  cat <<SQL
select jsonb_build_object(
  'sample_size', count(*),
  'owner_filled', count(*) filter (where owner is not null),
  'owner_id_filled', count(*) filter (where owner_id is not null)
) as payload
from (
  select owner, owner_id
  from storage.objects
  where bucket_id = 'media'
  order by created_at desc
  limit ${LIMIT}
) s;
SQL
}

sql_buckets() {
  cat <<'SQL'
select jsonb_build_object(
  'policy_count', (select count(*) from pg_policy where polrelid = 'storage.buckets'::regclass)
) as payload;
SQL
}

# fetch_raw <name> <sql> —— name 對應 --fixture 目錄裡的 <name>.json；否則真的打
# `supabase db query --linked`。任何一步失敗都印訊息到 stderr 並回傳空字串——呼叫端看到空字串會
# fail loud（exit 1），不會誤報健康。
fetch_raw() {
  local name=$1 sql=$2
  if [ -n "$FIXTURE" ]; then
    local f="${FIXTURE}/${name}.json"
    if [ ! -f "$f" ]; then
      echo "⚠ --fixture 目錄缺少 ${name}.json：$FIXTURE" >&2
      return
    fi
    cat "$f"
    return
  fi

  local sql_file raw rc
  sql_file=$(mktemp "${TMPDIR:-/tmp}/LS-244-storage-verify-${name}.XXXXXX")
  printf '%s' "$sql" > "$sql_file"

  raw=$(supabase db query --linked --output-format json -f "$sql_file" 2>/dev/null)
  rc=$?
  rm -f "$sql_file"
  if [ $rc -ne 0 ]; then
    echo "⚠ supabase db query --linked（${name}）執行失敗（exit ${rc}）" >&2
    return
  fi

  printf '%s' "$raw"
}

raw_prefixes=$(fetch_raw prefixes "$(sql_prefixes)")
raw_objects=$(fetch_raw objects "$(sql_objects)")
raw_buckets=$(fetch_raw buckets "$(sql_buckets)")

if [ -z "$raw_prefixes" ] || [ -z "$raw_objects" ] || [ -z "$raw_buckets" ]; then
  echo "⚠ 查無資料（連線失敗或查詢無輸出，見上方訊息）" >&2
  exit 1
fi

LS244_LIMIT="$LIMIT" \
LS244_PREFIXES_JSON="$raw_prefixes" \
LS244_OBJECTS_JSON="$raw_objects" \
LS244_BUCKETS_JSON="$raw_buckets" \
python3 <<'PY'
import json
import os
import sys


def extract_payload(raw, label):
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"⚠ {label} 查詢輸出不是合法 JSON：{exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(envelope, dict) or "rows" not in envelope:
        print(
            f"⚠ {label} 查詢輸出不是預期的信封格式（缺 rows 欄位）：{envelope!r}",
            file=sys.stderr,
        )
        sys.exit(1)
    rows = envelope.get("rows") or []
    if not rows:
        print(f"⚠ {label} 查詢沒有回傳任何列（rows 為空）", file=sys.stderr)
        sys.exit(1)
    payload = rows[0].get("payload")
    if not isinstance(payload, dict):
        print(f"⚠ {label} 查詢結果缺少 payload 欄位：{rows[0]!r}", file=sys.stderr)
        sys.exit(1)
    return payload


limit = os.environ["LS244_LIMIT"]
prefixes = extract_payload(os.environ["LS244_PREFIXES_JSON"], "storage.prefixes")
objects = extract_payload(os.environ["LS244_OBJECTS_JSON"], "storage.objects")
buckets = extract_payload(os.environ["LS244_BUCKETS_JSON"], "storage.buckets")

problems = []

# ---- 1. storage.prefixes（PLAN §5-1） ----
if not prefixes.get("exists"):
    line1 = "ⓘ storage.prefixes：表不存在，略過（本機開發映像通常沒有這張表，PLAN §5-1）"
else:
    rls = prefixes.get("relrowsecurity")
    policies = prefixes.get("policies") or []
    if rls and not policies:
        line1 = "⚠ storage.prefixes：RLS 已啟用但沒有任何 policy（PLAN §5-1：上傳會在雲端被擋的形狀）"
        problems.append("storage.prefixes 啟用 RLS 但無 policy")
    else:
        policy_note = ", ".join(policies) if policies else "無"
        line1 = f"✓ storage.prefixes：relrowsecurity={rls}，policies={policy_note}"

# ---- 2. storage.objects（bucket=media，PLAN §5-2） ----
sample_size = objects.get("sample_size") or 0
owner_filled = objects.get("owner_filled") or 0
owner_id_filled = objects.get("owner_id_filled") or 0
if sample_size == 0:
    line2 = "ⓘ storage.objects（bucket=media）：抽樣 0 筆，略過（bucket 目前無物件）"
elif owner_filled == 0 and owner_id_filled == 0:
    line2 = (
        f"⚠ storage.objects：抽樣 {sample_size} 筆，owner／owner_id 皆為 NULL"
        "（上傳者自刪孤兒物件在雲端不會生效，PLAN §5-2）"
    )
    problems.append("storage.objects 抽樣 owner／owner_id 皆為 NULL")
else:
    line2 = (
        f"✓ storage.objects：抽樣 {sample_size} 筆（limit={limit}），"
        f"owner 已填 {owner_filled} 筆／owner_id 已填 {owner_id_filled} 筆"
    )

# ---- 3. storage.buckets（PLAN §5-3） ----
policy_count = buckets.get("policy_count")
if policy_count == 0:
    line3 = "✓ storage.buckets：policy 數＝0（PLAN §5-3 預期狀態）"
else:
    line3 = f"⚠ storage.buckets：policy 數＝{policy_count}（PLAN §5-3：預期為 0，有人從 dashboard 加了東西）"
    problems.append(f"storage.buckets 有 {policy_count} 個 policy（預期 0）")

print(line1)
print(line2)
print(line3)

if problems:
    print("⚠ prod-storage-verify 發現異常：", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

print("✓ prod-storage-verify 三條檢查皆通過")
sys.exit(0)
PY
