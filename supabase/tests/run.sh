#!/usr/bin/env bash
# LS-6 — 本地 DB 測試 runner（RLS 隔離／owner 不變量／trigger／RLS plan 效能）
#
# 用法：
#   supabase start
#   supabase db reset          # 套用 supabase/migrations
#   bash supabase/tests/run.sh
#
# fail loud：任何一個測試檔非 0 結束就立刻中止並回傳非 0，不會有「跳過等於通過」。
# 測試檔本身用 DO 區塊斷言，失敗時 RAISE EXCEPTION，psql 帶 ON_ERROR_STOP 直接非 0 結束。
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evidence_dir="$here/evidence"

# 連線參數拆開放，不組成含帳密的連線字串：一來 repo 裡不出現任何形似金鑰的字串，
# 二來本機預設值（supabase start 的 shadow DB）本來就不該被當成可攜的設定。
db_host="${SUPABASE_DB_HOST:-127.0.0.1}"
db_port="${SUPABASE_DB_PORT:-54322}"
db_user="${SUPABASE_DB_USER:-postgres}"
db_name="${SUPABASE_DB_NAME:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
container="${SUPABASE_DB_CONTAINER:-supabase_db_little-sprout}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$evidence_dir"

# psql 不一定裝在 host 上；沒有的話就借用 supabase 的 DB container 裡那一份。
if command -v psql >/dev/null 2>&1; then
  channel="host psql → ${db_host}:${db_port}/${db_name}"
  run_sql() {
    psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
      -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
elif docker exec "$container" true >/dev/null 2>&1; then
  channel="docker exec $container psql"
  run_sql() {
    docker exec -i "$container" \
      psql -U "$db_user" -d "$db_name" -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"
  }
else
  echo "✗ 找不到 psql，也連不到 DB container（$container）。請先執行 supabase start。" >&2
  exit 1
fi

echo "→ 連線方式：$channel"

# 前置檢查：schema 真的套用了嗎？沒套用就跑測試，會得到一堆看不懂的錯誤
preflight="$tmp/preflight.sql"
cat > "$preflight" <<'SQL'
do $$
begin
  if to_regprocedure('private.family_ids()') is null then
    raise exception '找不到 private.family_ids()：migration 尚未套用，請先執行 supabase db reset';
  end if;
  if not exists (
    select 1 from pg_class c
     where c.relname = 'media' and c.relnamespace = 'public'::regnamespace and c.relrowsecurity
  ) then
    raise exception 'public.media 沒有啟用 RLS：schema 不完整';
  end if;
end;
$$;
SQL
if ! run_sql "$preflight" > "$tmp/preflight.out" 2>&1; then
  cat "$tmp/preflight.out" >&2
  exit 1
fi

for f in "$here"/[0-9][0-9]_*.sql; do
  name="$(basename "$f")"
  out="$tmp/$name.out"
  echo "→ $name"
  if run_sql "$f" > "$out" 2>&1; then
    sed 's/^/    /' "$out"
    echo "  ✓ $name"
  else
    echo "  ✗ $name 失敗：" >&2
    sed 's/^/    /' "$out" >&2
    exit 1
  fi
done

# EXPLAIN 證據存檔（驗收條件 c 要求留存）
perf_out="$tmp/50_rls_plan_no_percall_subquery.sql.out"
if [ -f "$perf_out" ]; then
  {
    echo "# LS-6 RLS plan 證據 —— 由 supabase/tests/run.sh 產生"
    echo "# 產生時間：$(date -u '+%Y-%m-%dT%H:%M:%SZ')（UTC）"
    # 連線通道與 server 版本一起記下來：證據要能自己說明它是在哪裡跑出來的
    echo "# 連線：$channel"
    echo "# Server：$(printf 'select version();' > "$tmp/ver.sql"; run_sql "$tmp/ver.sql" 2>/dev/null | sed -n '3p' | sed 's/^ *//')"
    echo "# 資料量：public.media 5 萬列（家庭 fc000000-0000-4000-8000-000000000001）"
    echo "# 判準：plan 不得出現 (SubPlan N) 形式的 qual 引用，且所有節點 loops=1"
    echo
    cat "$perf_out"
  } > "$evidence_dir/explain_rls_plan.txt"
  echo "→ EXPLAIN 證據：$evidence_dir/explain_rls_plan.txt"
fi

echo "✓ 全部 DB 測試通過"
