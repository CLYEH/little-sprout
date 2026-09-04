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

# ── PR #78 merge-reviewer R1 補樣本（B1／B2／M1／M2／I1：自測盲區曾與實作盲區重疊——R1 I10） ──
expect DESTRUCTIVE 'R1-B1 末句無分號、檔尾有換行（reviewer 原樣本）' $'create index i on public.t (id);\ndrop table public.families\n' "${K[@]}"
expect DESTRUCTIVE 'R1-B1 末句無分號、無結尾換行' $'create index i on public.t (id);\ndrop table public.families' "${K[@]}"
expect BREAKING+DESTRUCTIVE 'R1-B2 -- 行註解內的 /* 不開啟塊註解（Postgres 詞法）' $'-- a /*\ndrop table public.families;\nrevoke insert on public.diaries from authenticated;\n-- b */' "${K[@]}"
expect DESTRUCTIVE 'R1-B2 反向：/* */ 內的 -- 不吃掉 */' $'/* -- */ drop table public.families;' "${K[@]}"
expect BREAKING+DESTRUCTIVE 'R1-M1 DROP FUNCTION 既有名稱＝同一句兩級' 'drop function public.existing_fn(uuid);' "${K[@]}"
expect BREAKING+DESTRUCTIVE 'R1-M1 DROP FUNCTION IF EXISTS 既有名稱' 'drop function if exists public.existing_fn(uuid);' "${K[@]}"
expect DESTRUCTIVE 'R1-M1 DROP FUNCTION 新名稱只 DESTRUCTIVE' 'drop function public.new_fn(uuid);' "${K[@]}"
expect BREAKING 'R1-I1 點號旁空白 public . existing_fn' 'create or replace function public . existing_fn () returns void language sql as $$ select 1 $$;' "${K[@]}"
expect NONE 'R1-I1 點號旁空白、新函式' 'create or replace function public . new_fn () returns void language sql as $$ select 1 $$;' "${K[@]}"
if printf 'create or replace function public.x() returns void language sql as $$ select 1 $$;' | bash "$check" --known-functions "$work/nope.known" >/dev/null 2>&1; then
  echo "✗ R1-M2 --known-functions 讀不到應 exit 1" >&2; fail=1
else
  echo "✓ R1-M2 --known-functions 讀不到 → exit 1（fail closed，不當新函式放行）"
fi

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
printf 'drop function public.existing_fn()' > "$repo/supabase/migrations/004.sql"   # 無分號、無結尾換行（R1 B1 的 CI 實際路徑）
gitc add -A && gitc commit -qm head3
cd "$repo"
expect BREAKING+DESTRUCTIVE '--base(R1)：末句無分號的 DROP FUNCTION 既有＝兩級' '' --base HEAD~1
cd "$root"
# 檔案邊界：005 末句 revoke authenticated 無分號、006 第一句 revoke public/anon——黏成一句時 REVOKE 只看最後的
# from 子句而漏報；邊界補 ; 後必須 BREAKING
printf 'revoke insert on public.t from authenticated' > "$repo/supabase/migrations/005.sql"
printf 'revoke execute on function public.brand_new() from public, anon;\n' > "$repo/supabase/migrations/006.sql"
gitc add -A && gitc commit -qm head4
cd "$repo"
expect BREAKING '--base(R1)：跨檔黏句——前檔末句無分號的 REVOKE authenticated 不被後檔蓋掉' '' --base HEAD~1
cd "$root"
expect BREAKING '檔案清單模式：跨檔黏句同上' '' "${K[@]}" "$repo/supabase/migrations/005.sql" "$repo/supabase/migrations/006.sql"

# ── PR #78 merge-reviewer R2 補樣本（F1／F2／F3） ──
# F1：字面值內以 ++ 開頭的行在 diff 呈現為 +++ x，舊寫法把它當檔頭切句 → D4 的 ALTER COLUMN TYPE 漏報
printf "alter table public.t\n  alter column body set default '\n++ x\n', alter column body type text;\n" > "$repo/supabase/migrations/007.sql"
gitc add -A && gitc commit -qm head5
cd "$repo"
expect DESTRUCTIVE '--base(R2-F1)：字面值內 ++ 開頭行不當檔案邊界' '' --base HEAD~1
cd "$root"
# F2：a 的字面值含 /*（無 */）、b 的 DROP 後面才有 */——合併 normalize 會把 a 的 /* 到 b 的 */ 整段剝掉
printf "comment on table public.t is 'see /* details';\n" > "$repo/supabase/migrations/008a.sql"
printf "drop table public.users;\n/* cleanup */\n" > "$repo/supabase/migrations/008b.sql"
gitc add -A && gitc commit -qm head6
cd "$repo"
expect DESTRUCTIVE '--base(R2-F2)：前檔字面值 /* 不跨檔吃掉後檔 DROP' '' --base HEAD~1
cd "$root"
expect DESTRUCTIVE '檔案清單模式(R2-F2)：同上，逐檔 normalize' '' "${K[@]}" "$repo/supabase/migrations/008a.sql" "$repo/supabase/migrations/008b.sql"
# R3 G1：非 ASCII 檔名——core.quotePath 預設會讓 --name-only 輸出加引號 C-escape，餵回 pathspec 對不上、整檔靜默跳過
printf 'drop table public.t;\n' > "$repo/supabase/migrations/009_日記.sql"
gitc add -A && gitc commit -qm head7
cd "$repo"
expect DESTRUCTIVE '--base(R3-G1)：非 ASCII 檔名的 migration 不被 quotePath 跳過' '' --base HEAD~1
cd "$root"
# F3：--known-functions 指向目錄（如 /tmp）→ exit 1
if printf 'create or replace function public.x() returns void language sql as $$ select 1 $$;' | bash "$check" --known-functions "$work" >/dev/null 2>&1; then
  echo "✗ R2-F3 --known-functions 指向目錄應 exit 1" >&2; fail=1
else
  echo "✓ R2-F3 --known-functions 指向目錄 → exit 1（[ -f ] && [ -r ]）"
fi
if (cd "$repo" && bash "$check" --base no-such-rev >/dev/null 2>&1); then
  echo "✗ --base 壞 rev 應 exit 1" >&2; fail=1
else
  echo "✓ --base 壞 rev → exit 1（不靜默放行）"
fi

# ── B7：enum 加值＋消費端清單（LS-181；來源 LS-175 merge-review R1 i1） ──────────────────────
# 夾具：假 EF／Swift／API.md 消費端樹（--consumer-root），既有值集合以 --known-enums 給。
cons="$work/consumer"
mkdir -p "$cons/supabase/functions/push" "$cons/supabase/functions/other" "$cons/supabase/functions/dev" "$cons/LittleSprout/Services" "$cons/docs"
# 多行 union（一行一值）＋型別守衛＋型別名——per-line 規則抓不到 union，靠檔級聚合
printf 'export type NotificationKind =\n  | "comment"\n  | "reaction"\n  | "diary";\nexport function isNotificationKind(v: unknown): v is NotificationKind {\n  return v === "comment" || v === "reaction" || v === "diary";\n}\n' > "$cons/supabase/functions/push/handler.ts"
# 只出現 1 個既有值、沒寫 enum 名 → 不算消費端
printf 'const x = "comment";\nexport default x;\n' > "$cons/supabase/functions/other/index.ts"
# 既有值只有 1 個的 enum（solo：ios）→ 門檻降為 1
printf 'const platform = "ios";\nexport default platform;\n' > "$cons/supabase/functions/dev/index.ts"
# Swift：同名 enum 宣告＋case 宣告行
printf 'enum NotificationKind: String, Decodable {\n    case comment, reaction, diary\n}\n' > "$cons/LittleSprout/Services/Models.swift"
# Swift：只有 switch 的 `case .x` pattern（編譯器窮舉會擋）→ 不算
printf 'func f(_ k: Int) {\n    switch k {\n    case .comment: break\n    case .reaction: break\n    case .diary: break\n    }\n}\n' > "$cons/LittleSprout/Other.swift"
printf 'struct Unrelated {}\n' > "$cons/LittleSprout/Unrelated.swift"
# API.md：一行 ≥2 個既有值反引號（值列表）＋表格首欄涵蓋 ≥2 值（文案矩陣形狀）；不寫 enum 名（測名稱規則的反面）
printf '# 通知\n\n- 欄位：`kind`（`comment`/`reaction`/`diary`）\n- 其他：`media` 只出現一次\n\n| kind | 文案 |\n|---|---|\n| `comment` | a |\n| `reaction` | b |\n\n尾段。\n' > "$cons/docs/API.md"
printf 'public.notification_kind\tcomment\npublic.notification_kind\treaction\npublic.notification_kind\tdiary\npublic.solo\tios\n' > "$work/enums"
E=(--known-enums "$work/enums" --consumer-root "$cons")

# expect_b7 <樣本名稱> <期望 CONSUMER 路徑集合（排序、逗號連接；NONE＝無且 ENUM 行印「消費端：無」）> <SQL> [額外參數…]
#   斷言：exit 0、有 BREAKING 行、有 ENUM 行、CONSUMER 路徑集合（去重）恰等於期望
expect_b7() {
  local name=$1 want=$2 sql=$3 out rc got levels
  shift 3
  out="$(printf '%s' "$sql" | bash "$check" "$@")"
  rc=$?
  levels="$(printf '%s\n' "$out" | cut -f1 | grep -v '^$' | LC_ALL=C sort -u | paste -s -d '+' -)"
  got="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "CONSUMER" {print $3}' | LC_ALL=C sort -u | paste -s -d ',' -)"
  [ -z "$got" ] && got=NONE
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^BREAKING' && printf '%s\n' "$out" | grep -q '^ENUM' \
     && [ "$got" = "$want" ] && { [ "$want" != NONE ] || printf '%s\n' "$out" | grep -q '消費端：無（請人工確認'; }; then
    echo "✓ $name"
  else
    echo "✗ ${name}（期望消費端 ${want}，實得 ${got}，級別 ${levels}，exit ${rc}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
ALL3='LittleSprout/Services/Models.swift,docs/API.md,supabase/functions/push/handler.ts'
expect_b7 'B7 ADD VALUE（假 EF／Swift／API.md 夾具：union 多行、守衛、Swift enum、值列表、矩陣）' "$ALL3" "alter type public.notification_kind add value 'x';" "${K[@]}" "${E[@]}"
expect_b7 'B7 跨行寫法' "$ALL3" $'alter type public.notification_kind\n  add value\n  \'x\';' "${K[@]}" "${E[@]}"
expect_b7 'B7 IF NOT EXISTS' "$ALL3" "alter type public.notification_kind add value if not exists 'x';" "${K[@]}" "${E[@]}"
expect_b7 'B7 大寫＋BEFORE 子句' "$ALL3" "ALTER TYPE public.notification_kind ADD VALUE 'X' BEFORE 'diary';" "${K[@]}" "${E[@]}"
expect_b7 'B7 省略 schema 視為 public' "$ALL3" "alter type notification_kind add value 'x';" "${K[@]}" "${E[@]}"
expect_b7 'B7 換寫法：DO 區塊動態 SQL（雙重引號的新值抽不出來、ENUM 行印 ?；既有值集合仍在、消費端照列）' "$ALL3" $'do $$ begin execute \'alter type public.notification_kind add value \'\'x\'\'\'; end $$;' "${K[@]}" "${E[@]}"
expect_b7 'B7 無消費端 → ENUM 行印「消費端：無（請人工確認）」' NONE "alter type public.nobody_uses add value 'x';" "${K[@]}" "${E[@]}"
expect_b7 'B7 未給 --known-enums → 只靠名稱命中（API.md 夾具沒寫名 → 不列）' 'LittleSprout/Services/Models.swift,supabase/functions/push/handler.ts' "alter type public.notification_kind add value 'x';" "${K[@]}" --consumer-root "$cons"
expect_b7 'B7 既有值只有 1 個 → 門檻降為 1' 'supabase/functions/dev/index.ts' "alter type public.solo add value 'android';" "${K[@]}" "${E[@]}"
# 非 enum 加值的 ALTER TYPE 不誤判 B7（RENAME VALUE 走 B5，只有 BREAKING、無 ENUM／CONSUMER 行）
expect NONE 'B7 反例：ALTER TYPE … ADD ATTRIBUTE（composite）' 'alter type public.addr add attribute zip text;' "${K[@]}" "${E[@]}"
expect NONE 'B7 反例：ALTER TYPE … OWNER TO' 'alter type public.notification_kind owner to postgres;' "${K[@]}" "${E[@]}"
expect BREAKING 'B7 反例：ALTER TYPE … RENAME VALUE 是 B5、不印 ENUM 行' "alter type public.notification_kind rename value 'x' to 'y';" "${K[@]}" "${E[@]}"
# 同一輸入內：create type 與第一次加值累加進集合，第二次加值的消費端掃描看得到（k/index.ts 有 "a"、"c"：第一次只算 1 種、第二次 2 種）。
# enum 名不能取單字母（`k` 會整字命中 Other.swift 的參數 `k`——名稱規則本來就這麼寬）
mkdir -p "$cons/supabase/functions/k"
printf 'const s = ["a", "c"];\nexport default s;\n' > "$cons/supabase/functions/k/index.ts"
expect_b7 'B7 同一輸入累加：create type＋兩次 add value，第二次才命中 k/index.ts' 'supabase/functions/k/index.ts' "create type public.batch_kind as enum ('a', 'b'); alter type public.batch_kind add value 'c'; alter type public.batch_kind add value 'd';" "${K[@]}" --consumer-root "$cons"
n_enum=$(printf "create type public.batch_kind as enum ('a', 'b'); alter type public.batch_kind add value 'c'; alter type public.batch_kind add value 'd';" | bash "$check" "${K[@]}" --consumer-root "$cons" | grep -c '^ENUM')
if [ "$n_enum" -eq 2 ]; then echo "✓ B7 同一輸入兩次加值 → 2 行 ENUM"; else echo "✗ B7 同一輸入兩次加值應印 2 行 ENUM，實得 ${n_enum}" >&2; fail=1; fi
# --base 模式：既有值集合自 base 的 migrations 取、掃描根＝repo 根
printf "create type public.k2 as enum ('p', 'q');\n" > "$repo/supabase/migrations/010.sql"
gitc add -A && gitc commit -qm head8
printf "alter type public.k2 add value 'r';\n" > "$repo/supabase/migrations/011.sql"
mkdir -p "$repo/supabase/functions/k2"
printf 'const ok = v === "p" || v === "q";\n' > "$repo/supabase/functions/k2/index.ts"
gitc add -A && gitc commit -qm head9
cd "$repo"
expect_b7 '--base(B7)：既有值自 base 取、消費端在 repo 根找到' 'supabase/functions/k2/index.ts' '' --base HEAD~1
cd "$root"
# 參數／環境錯誤 fail closed
if printf "alter type public.k add value 'x';" | bash "$check" "${K[@]}" --known-enums "$work/nope.enums" --consumer-root "$cons" >/dev/null 2>&1; then
  echo "✗ B7 --known-enums 讀不到應 exit 1" >&2; fail=1
else
  echo "✓ B7 --known-enums 讀不到 → exit 1（fail closed）"
fi
if printf "alter type public.k add value 'x';" | bash "$check" "${K[@]}" --consumer-root "$work/nope.dir" >/dev/null 2>&1; then
  echo "✗ B7 --consumer-root 不是目錄應 exit 1" >&2; fail=1
else
  echo "✓ B7 --consumer-root 不是目錄 → exit 1（fail closed）"
fi
if (cd "$work" && printf "alter type public.k add value 'x';" | bash "$check" "${K[@]}" >/dev/null 2>&1); then
  echo "✗ B7 不在 git repo 內且未給 --consumer-root 應 exit 1" >&2; fail=1
else
  echo "✓ B7 不在 git repo 內且未給 --consumer-root → exit 1（不靜默印「無消費端」）"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ migration-breaking-check 自測通過（87 組樣本）"
fi
exit "$fail"
