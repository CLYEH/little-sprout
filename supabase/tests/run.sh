#!/usr/bin/env bash
# LS-6 — 本地 DB 測試 runner（RLS 隔離／owner 不變量／trigger／RLS plan 效能）
#
# 用法：
#   supabase start（或只要 DB：supabase db start）
#   supabase db reset          # 套用 supabase/migrations
#   bash supabase/tests/run.sh
#
# LS-11：CI（.github/workflows/ci.yml 的 db job）額外帶 SUPABASE_DB_URL＝
# `supabase status -o env` 印出的 DB_URL，走 host psql 那條路；本機／QA 備援沿用
# 既有離散參數（SUPABASE_DB_HOST/PORT/USER/NAME）或 SUPABASE_DB_CONTAINER。
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

# LS-11：CI（supabase CLI local stack）用這條——直接吃 `supabase status -o env` 印出的
# DB_URL，不用假設 host/port 剛好對得上 config.toml，換 port 也不必回頭改這個腳本或 CI。
# 沒帶就留空、走下面離散參數那條路：兩者預設值等價，都是 supabase CLI local stack 的
# 標準連線（postgres:postgres@127.0.0.1:54322/postgres），只是給法不同。
db_url="${SUPABASE_DB_URL:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$evidence_dir"

# psql 不一定裝在 host 上；沒有的話就借用 supabase 的 DB container 裡那一份。
if command -v psql >/dev/null 2>&1 && [ -n "$db_url" ]; then
  channel="host psql → SUPABASE_DB_URL"
  run_sql() {
    psql "$db_url" -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
elif command -v psql >/dev/null 2>&1; then
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

# ---------------------------------------------------------------------------
# 併發測試：owner 不變量在 READ COMMITTED 下的序列化
#
# 為什麼不能寫成上面那種單檔 SQL：要重現的時序需要「兩個交易同時開著」，
# 一個 session 內做不到。這裡開兩個真的並行的 psql，用時間差對齊時序：
#   S1  BEGIN → 降級/移除 owner1 →（壓住 3 秒不 commit）→ COMMIT
#   S2  等 1.2 秒 → 降級/移除 owner2 → 必須被阻塞、解除阻塞後必須噴 LS001
# 斷言寫在 S2 與 verify 的 SQL 裡（等待秒數、LS001、最終 owner 數 ≥1）。
# ---------------------------------------------------------------------------
cc_dir="$here/concurrency"

run_sql_bg() {  # $1=sql 檔 $2=輸出檔；結束碼寫到 $2.rc
  # set +e：失敗的結束碼是這裡的觀測目標，不能讓 errexit 把 subshell 直接帶走
  ( set +e; run_sql "$1" > "$2" 2>&1; echo "$?" > "$2.rc" ) &
}

owner_guard_case() {  # $1=場景名 $2=S1 檔名 $3=S2 檔名
  local label="$1" s1="$cc_dir/$2" s2="$cc_dir/$3"
  local s1_out="$tmp/$2.out" s2_out="$tmp/$3.out" setup_out="$tmp/owner_guard_setup.out"
  echo "→ 併發：$label"

  if ! run_sql "$cc_dir/owner_guard_setup.sql" > "$setup_out" 2>&1; then
    echo "  ✗ 併發場景資料建立失敗：" >&2; sed 's/^/    /' "$setup_out" >&2; exit 1
  fi

  run_sql_bg "$s1" "$s1_out"
  run_sql_bg "$s2" "$s2_out"
  wait

  local rc1 rc2 failed=0
  rc1="$(cat "$s1_out.rc")"; rc2="$(cat "$s2_out.rc")"
  sed 's/^/    S1 /' "$s1_out"
  sed 's/^/    S2 /' "$s2_out"
  [ "$rc1" = 0 ] || { echo "  ✗ S1 非 0 結束（rc=$rc1）" >&2; failed=1; }
  [ "$rc2" = 0 ] || { echo "  ✗ S2 非 0 結束（rc=$rc2）" >&2; failed=1; }

  if ! run_sql "$cc_dir/owner_guard_verify.sql" > "$tmp/owner_guard_verify.out" 2>&1; then
    sed 's/^/    /' "$tmp/owner_guard_verify.out" >&2; failed=1
  else
    sed 's/^/    /' "$tmp/owner_guard_verify.out"
  fi

  [ "$failed" = 0 ] || { echo "  ✗ 併發：$label 失敗" >&2; exit 1; }
  echo "  ✓ 併發：$label"
}

owner_guard_case "同時降級兩位 owner" owner_guard_s1_demote.sql owner_guard_s2_demote.sql
owner_guard_case "同時移除兩位 owner" owner_guard_s1_delete.sql owner_guard_s2_delete.sql

cleanup="$tmp/cc_cleanup.sql"
cat > "$cleanup" <<'SQL'
delete from public.families where id = 'fd000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'd0000000-0000-4000-8000-000000000001',
  'd0000000-0000-4000-8000-000000000002'
);
SQL
run_sql "$cleanup" > /dev/null

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
