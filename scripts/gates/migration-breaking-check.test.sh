#!/bin/bash
# migration-breaking-check.sh 的自測（LS-53）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：分級規則若退化（退回逐行 grep 看不到多行敘述、註解誤判、
# REVOKE 不分角色、DROP 又變回白名單、換個寫法就漏），這裡會紅。樣本編號對應檔頭規則表 D1–D4／B1–B6。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/migration-breaking-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'public.existing_fn\nprivate.helper\n' > "$work/known"
K=(--known-functions "$work/known")

# expect <期望級別集合> <樣本名稱> <SQL（stdin）> [額外參數…]
#   期望級別集合＝輸出第一欄去重、排序、以 + 連接：NONE／BREAKING／DESTRUCTIVE／BREAKING+DESTRUCTIVE
expect() {
  local want=$1 name=$2 sql=$3 out rc got
  shift 3
  out="$(printf '%s' "$sql" | bash "$check" "$@")"
  rc=$?
  got="$(printf '%s\n' "$out" | cut -f1 | grep -v '^$' | sort -u | paste -s -d '+' -)"
  [ -z "$got" ] && got=NONE
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    echo "✓ $name"
  else
    echo "✗ ${name}（期望 ${want}，實得 ${got}，exit ${rc}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ── DESTRUCTIVE ────────────────────────────────────────────────────────────────
expect DESTRUCTIVE 'D1 DROP TABLE' 'drop table public.foo;' "${K[@]}"
expect DESTRUCTIVE 'D1 DROP COLUMN' 'alter table public.foo drop column bar;' "${K[@]}"
expect DESTRUCTIVE 'D1 DROP POLICY IF EXISTS' 'drop policy if exists p on public.foo;' "${K[@]}"
expect DESTRUCTIVE 'D1 DROP FUNCTION' 'drop function public.f(uuid);' "${K[@]}"
expect DESTRUCTIVE 'D1 DROP VIEW（舊白名單漏的物件型別，任何 DROP 都算）' 'drop view public.v;' "${K[@]}"
expect DESTRUCTIVE 'D1 DROP NOT NULL' 'alter table public.foo alter column bar drop not null;' "${K[@]}"
expect DESTRUCTIVE 'D1 大小寫混寫' 'Drop Table public.foo;' "${K[@]}"
expect DESTRUCTIVE 'D1 換寫法：DO 區塊動態 SQL' $'do $$ begin execute \'drop policy p on public.foo\'; end $$;' "${K[@]}"
expect DESTRUCTIVE 'D2 TRUNCATE' 'truncate public.foo;' "${K[@]}"
expect DESTRUCTIVE 'D3 DISABLE ROW LEVEL SECURITY' 'alter table public.foo disable row level security;' "${K[@]}"
expect DESTRUCTIVE 'D4 ALTER COLUMN TYPE' 'alter table public.foo alter column bar type varchar(10);' "${K[@]}"
expect DESTRUCTIVE 'D4 多行 SET DATA TYPE' $'alter table public.foo\n  alter column bar\n  set data type text;' "${K[@]}"
expect NONE 'D4 反例：欄名叫 type 不算' 'alter table public.foo add column type text;' "${K[@]}"
expect NONE 'D2 反例：date_trunc 不算 TRUNCATE' "select date_trunc('day', now());" "${K[@]}"

# ── 註解不得誤判 ───────────────────────────────────────────────────────────────
expect NONE '註解：整行 -- drop policy' $'-- drop policy p on public.foo;\ncreate table public.t (id int);' "${K[@]}"
expect NONE '註解：行尾 -- 提及 DROP TABLE' $'create index i on public.t (id); -- 舊版這裡 DROP TABLE，已改\n' "${K[@]}"
expect NONE '註解：/* */ 單行' $'/* truncate public.t; */ create table public.t (id int);' "${K[@]}"
expect NONE '註解：/* */ 跨行含 revoke authenticated' $'/*\n  revoke insert on public.t from authenticated;\n  alter policy p on public.t using (false);\n*/\ngrant select on public.t to authenticated;' "${K[@]}"
expect NONE '註解：中文說明提到關鍵字' $'-- 這裡刻意不用 DROP POLICY，改用 ALTER POLICY … WITH CHECK (false)\ncreate table public.t (id int);' "${K[@]}"

# ── BREAKING ───────────────────────────────────────────────────────────────────
expect BREAKING 'B1 ALTER POLICY WITH CHECK (false)' 'alter policy p on public.t with check (false);' "${K[@]}"
expect BREAKING 'B1 ALTER POLICY USING (false) WITH CHECK (false)' 'alter policy p on public.t using (false) with check (false);' "${K[@]}"
expect BREAKING 'B1 ALTER POLICY USING (true)（放寬也算）' 'alter policy p on public.t using (true);' "${K[@]}"
expect BREAKING 'B1 ALTER POLICY 多行改條件（LS-52 形狀）' $'alter policy albums_update on public.albums\n  using (\n    created_by = (select auth.uid())\n  )\n  with check (\n    created_by = (select auth.uid())\n  );' "${K[@]}"
expect BREAKING 'B1 大寫 ALTER POLICY RENAME' 'ALTER POLICY P ON PUBLIC.T RENAME TO Q;' "${K[@]}"
expect BREAKING 'B2 CREATE POLICY AS RESTRICTIVE（收緊的換寫法）' 'create policy deny_all on public.t as restrictive using (false);' "${K[@]}"
expect NONE 'B2 反例：一般 CREATE POLICY 是新增' 'create policy p on public.t for select using (family_id in (select private.family_ids()));' "${K[@]}"
expect BREAKING 'B3 REVOKE … FROM authenticated（LS-48 形狀）' 'REVOKE INSERT, UPDATE ON public.diaries FROM authenticated;' "${K[@]}"
expect BREAKING 'B3 REVOKE … FROM public, anon, authenticated' 'revoke execute on function public.f() from public, anon, authenticated;' "${K[@]}"
expect BREAKING 'B3 REVOKE … FROM service_role' 'revoke select on public.t from service_role;' "${K[@]}"
expect BREAKING 'B3 REVOKE 無 FROM 子句（fail closed）' 'revoke all on public.t;' "${K[@]}"
expect BREAKING 'B3 換寫法：DO 區塊動態 REVOKE' $'do $$ begin execute \'revoke insert on public.t from authenticated\'; end $$;' "${K[@]}"
expect NONE 'B3 反例：只從 public／anon 收回＝新函式上鎖慣例' 'revoke execute on function public.f(uuid) from public, anon;' "${K[@]}"
expect NONE 'B3 反例：多行 REVOKE，角色在下一行（LS-48 get_family_timeline 形狀）' $'revoke execute on function\n  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)\n  from public, anon;' "${K[@]}"
expect NONE 'B3 反例：ALTER DEFAULT PRIVILEGES 只影響未來物件' 'alter default privileges in schema public revoke all on tables from anon, authenticated;' "${K[@]}"
expect BREAKING 'B4 CREATE OR REPLACE 既有函式' 'create or replace function public.existing_fn() returns void language sql as $$ select 1 $$;' "${K[@]}"
expect BREAKING 'B4 CREATE OR REPLACE 既有函式（省略 schema 視為 public）' 'create or replace function existing_fn() returns void language sql as $$ select 1 $$;' "${K[@]}"
expect BREAKING 'B4 CREATE FUNCTION 既有名稱加 overload（改簽章）' 'create function public.existing_fn(p uuid) returns void language sql as $$ select 1 $$;' "${K[@]}"
expect BREAKING 'B4 未給 --known-functions 一律視為既有（fail closed）' 'create or replace function public.whatever() returns void language sql as $$ select 1 $$;'
expect NONE 'B4 反例：新函式' 'create or replace function public.new_fn() returns void language sql as $$ select 1 $$;' "${K[@]}"
expect BREAKING 'B5 ALTER TABLE RENAME COLUMN' 'alter table public.t rename column a to b;' "${K[@]}"
expect BREAKING 'B5 ALTER FUNCTION RENAME' 'alter function public.f(uuid) rename to g;' "${K[@]}"
expect NONE 'B5 反例：欄名 renamed_at' 'alter table public.t add column renamed_at timestamptz;' "${K[@]}"
expect BREAKING 'B6 ALTER FUNCTION SET SCHEMA' 'alter function public.f(uuid) set schema private;' "${K[@]}"

# ── 聯集與典型檔 ───────────────────────────────────────────────────────────────
expect BREAKING+DESTRUCTIVE '兩級並存（LS-37 invites 形狀：DROP POLICY＋REVOKE authenticated）' $'drop policy invites_insert on public.invites;\nrevoke insert, update on public.invites from authenticated;' "${K[@]}"
expect NONE '典型新增 RPC migration 全部不誤判' $'create table public.t (id uuid primary key);\nalter table public.t enable row level security;\ncreate policy p on public.t for select to authenticated using (true);\ngrant select on public.t to authenticated;\ncreate or replace function public.new_rpc() returns void language sql security definer set search_path = \'\' as $$ select 1 $$;\nrevoke execute on function public.new_rpc() from public, anon;\ngrant execute on function public.new_rpc() to authenticated;\ncreate index concurrently if not exists i on public.t (id);' "${K[@]}"
expect NONE '空輸入' '' "${K[@]}"

# ── 檔案清單模式 ───────────────────────────────────────────────────────────────
printf 'drop table public.a;\n' > "$work/a.sql"
printf 'alter policy p on public.b using (false);\n' > "$work/b.sql"
expect BREAKING+DESTRUCTIVE '檔案清單模式：兩檔合併分級' '' "${K[@]}" "$work/a.sql" "$work/b.sql"
if bash "$check" "${K[@]}" "$work/nope.sql" >/dev/null 2>&1; then
  echo "✗ 檔案不存在應 exit 1" >&2; fail=1
else
  echo "✓ 檔案不存在 → exit 1（不靜默放行）"
fi

# ── --base 模式（CI／push-gate 的實際用法）：既有函式清單自 base 的 migrations 取，分級 base...HEAD 新增行 ──
repo="$work/repo"
git init -q "$repo"
gitc() { git -C "$repo" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
mkdir -p "$repo/supabase/migrations"
printf 'create function public.existing_fn() returns void language sql as $$ select 1 $$;\n' > "$repo/supabase/migrations/001.sql"
gitc add -A && gitc commit -qm base && gitc tag base
printf -- '-- 只改本體＋多行 revoke public/anon（不算）\ncreate or replace function public.existing_fn() returns void language sql as $$ select 2 $$;\nrevoke execute on function\n  public.existing_fn()\n  from public, anon;\n' > "$repo/supabase/migrations/002.sql"
gitc add -A && gitc commit -qm head1
printf 'create function public.brand_new() returns void language sql as $$ select 3 $$;\nrevoke execute on function public.brand_new() from public, anon;\n' > "$repo/supabase/migrations/003.sql"
gitc add -A && gitc commit -qm head2
cd "$repo"
expect BREAKING '--base：既有函式被 OR REPLACE（清單自 base 取）' '' --base base
expect NONE '--base：只有新函式的 commit' '' --base HEAD~1
cd "$root"
if (cd "$repo" && bash "$check" --base no-such-rev >/dev/null 2>&1); then
  echo "✗ --base 壞 rev 應 exit 1" >&2; fail=1
else
  echo "✓ --base 壞 rev → exit 1（不靜默放行）"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ migration-breaking-check 自測通過（51 組樣本）"
fi
exit "$fail"
