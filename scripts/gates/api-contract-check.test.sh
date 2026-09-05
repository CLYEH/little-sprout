#!/bin/bash
# api-contract-check.sh 的自測（LS-41；PR #58 review F3）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：文字解析器（本機 push-gate 用的 best-effort
# 模式）若退化或漏判，這裡會紅。
#
# 範圍：①-⑬ 走 --text（文字解析）模式；⑭-⑯ 用合成的 catalog 輸入檔直接餵
# api_contract_check.py --catalog（LS-54 N3），驗的是解析與大小寫 fail-loud——psql 對
# 活資料庫的查詢本身仍不在這裡（需要已套用 migrations 的活 DB，不適合塞進這個快速、
# 不起 DB 的 rules job），由 CI db job 自己每次真的執行來回歸驗證（LS-41 開發時也已用
# 本機 `supabase db reset` + 真實 psql 手動驗證過一輪，見該票 handoff）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/api-contract-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

new_case() {  # $1=樣本名 -> echo 出這個樣本專用的目錄路徑（各自獨立，互不干擾）
  local dir="$work/$1"
  mkdir -p "$dir/migrations"
  echo "$dir"
}

contract_doc() {  # $1=輸出路徑 $2=RPC 區塊內容（可空） $3=TABLES 區塊內容（可空）
  cat > "$1" <<EOF
<!-- API-CONTRACT:RPC
$2
-->

<!-- API-CONTRACT:TABLES
$3
-->
EOF
}

# expect <期望 exit code> <樣本名稱> <migrations 目錄> <API.md 路徑>
expect() {
  local want=$1 name=$2 mig=$3 doc=$4 out got
  out="$(bash "$checker" "$doc" "$mig" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "✓ $name"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ① schema 有、doc 無（RPC／表皆漏寫）
d=$(new_case case1_missing_in_doc)
cat > "$d/migrations/001.sql" <<'SQL'
create table public.widgets (id uuid primary key);
create function public.foo(a text) returns void language sql as $$ select 1 $$;
SQL
contract_doc "$d/API.md" "" ""
expect 1 '① schema 有、doc 無（漏寫）' "$d/migrations" "$d/API.md"

# ② doc 有、schema 無（幽靈 RPC／幽靈表）
d=$(new_case case2_ghost_in_doc)
cat > "$d/migrations/001.sql" <<'SQL'
create table public.widgets (id uuid primary key);
SQL
contract_doc "$d/API.md" "ghost_rpc(uuid)" $'widgets\nghost_table'
expect 1 '② doc 有、schema 無（幽靈項）' "$d/migrations" "$d/API.md"

# ③ 缺 API-CONTRACT 區塊
d=$(new_case case3_missing_block)
cat > "$d/migrations/001.sql" <<'SQL'
create table public.widgets (id uuid primary key);
SQL
echo '# 沒有任何 API-CONTRACT 區塊' > "$d/API.md"
expect 1 '③ 文件缺少 API-CONTRACT 區塊' "$d/migrations" "$d/API.md"

# ④ create table if not exists 也抓得到（F1）
d=$(new_case case4_if_not_exists)
cat > "$d/migrations/001.sql" <<'SQL'
create table if not exists public.widgets (id uuid primary key);
SQL
contract_doc "$d/API.md" "" "widgets"
expect 0 '④ create table if not exists 也抓得到（F1）' "$d/migrations" "$d/API.md"

# ⑤ 無參數列 drop function：移除該名稱全部 overload（F2）
d=$(new_case case5_drop_no_parens)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.foo(a text) returns void language sql as $$ select 1 $$;
drop function public.foo;
SQL
contract_doc "$d/API.md" "" ""
expect 0 '⑤ 無括號 drop function 移除該名稱全部 overload（F2）' "$d/migrations" "$d/API.md"

# ⑥ 型別別名：create 用短別名、drop 用展開後的 SQL 標準寫法，必須視為同一支（F2）
d=$(new_case case6_type_alias)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.foo(a timestamptz) returns void language sql as $$ select 1 $$;
drop function public.foo(timestamp with time zone);
SQL
contract_doc "$d/API.md" "" ""
expect 0 '⑥ 型別別名（timestamptz／timestamp with time zone）drop 正確抵銷（F2）' "$d/migrations" "$d/API.md"

# ⑦ overload：同名不同參數列是兩支不同的 RPC，各自獨立追蹤，doc 漏列一支要紅
d=$(new_case case7_overload)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.foo(a text) returns void language sql as $$ select 1 $$;
create function public.foo(a text, b integer) returns void language sql as $$ select 1 $$;
SQL
contract_doc "$d/API.md" "foo(text)" ""
expect 1 '⑦ overload 各自獨立追蹤（doc 漏列第二支）' "$d/migrations" "$d/API.md"

# ⑧ 大寫識別子：Postgres 對未加引號的識別字折成小寫，doc 用小寫寫法必須對得上（F6）
d=$(new_case case8_uppercase)
cat > "$d/migrations/001.sql" <<'SQL'
CREATE FUNCTION Public.Foo(P_X text) RETURNS void LANGUAGE sql AS $$ select 1 $$;
SQL
contract_doc "$d/API.md" "foo(text)" ""
expect 0 '⑧ 大寫識別子折成小寫後與 doc 對上（F6）' "$d/migrations" "$d/API.md"

# ⑨ 沒有 schema 前綴的宣告直接紅，不得靜默漏掉（F1）
d=$(new_case case9_unqualified)
cat > "$d/migrations/001.sql" <<'SQL'
create function foo(a text) returns void language sql as $$ select 1 $$;
SQL
contract_doc "$d/API.md" "" ""
expect 1 '⑨ 沒有 schema 前綴的 create function 直接紅（F1）' "$d/migrations" "$d/API.md"

# ⑩ 簽章括號區間內混進行內註解時 fail loud，不得悄悄解析錯（F5）
d=$(new_case case10_inline_comment_in_sig)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.foo(
  a text -- 這是行內註解，混在參數列裡
) returns void language sql as $$ select 1 $$;
SQL
contract_doc "$d/API.md" "foo(text)" ""
expect 1 '⑩ 簽章括號內混進行內註解時 fail loud（F5）' "$d/migrations" "$d/API.md"

# ⑪ 參數模式前綴（LS-54 N1）：OUT 參數不是呼叫端要傳的、也不在 Postgres 識別簽章裡，
#    文字模式必須跟 catalog 模式一樣排除；IN 只剝關鍵字。doc 寫 foo(text) 才能綠——
#    若解析成 foo(text, uuid) 會同時出現漏寫＋幽靈項而紅。
d=$(new_case case11_in_out_params)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.foo(in a text, out b uuid) returns uuid language sql as $$ select gen_random_uuid() $$;
SQL
contract_doc "$d/API.md" "foo(text)" ""
expect 0 '⑪ in 剝關鍵字、out 參數排除（對齊 catalog，LS-54 N1）' "$d/migrations" "$d/API.md"

# ⑫ INOUT／VARIADIC 是識別簽章的一部分，只剝關鍵字、保留型別（LS-54 N1）
d=$(new_case case12_inout_variadic)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.bar(inout a text, variadic b integer[]) returns text language sql as $$ select a $$;
SQL
contract_doc "$d/API.md" "bar(text, integer[])" ""
expect 0 '⑫ inout／variadic 保留型別（LS-54 N1）' "$d/migrations" "$d/API.md"

# ⑬ 同一支（或稍後一支）migration 內 DROP 舊簽名、CREATE 回完全相同的簽名，只是
#    改了回傳型別（`CREATE OR REPLACE FUNCTION` 不允許改變回傳型別，例如
#    `RETURNS TABLE(...)` 的欄位改名／改型別，只能先 DROP 再重建）——「先蒐集全部
#    CREATE、再套用全部 DROP」的兩批次模式會把這種合法寫法誤判成「這支 RPC 已經
#    不存在」（LS-121 實測踩到：get_family_timeline 的 DROP＋CREATE 用了完全相同的
#    參數簽章，只改了 RETURNS TABLE 的欄位）；改成依文字出現順序單一序列重播後，
#    DROP 之後又出現的同簽名 CREATE 要正確地重新加回去
d=$(new_case case13_drop_then_recreate_same_sig)
cat > "$d/migrations/001.sql" <<'SQL'
create function public.foo(a uuid) returns table(x uuid) language sql as $$ select a $$;
SQL
cat > "$d/migrations/002.sql" <<'SQL'
drop function public.foo(uuid);
create function public.foo(a uuid) returns table(x uuid[]) language sql as $$ select array[a] $$;
SQL
contract_doc "$d/API.md" "foo(uuid)" ""
expect 0 '⑬ 同簽名 drop 之後又 create 回來（只改回傳型別）要視為仍存在（LS-121）' "$d/migrations" "$d/API.md"

# --catalog 模式的合成輸入（LS-54 N3）：不起 DB，直接餵 api_contract_check.py 兩個
# 「psql 查出來的樣子」的檔案，驗的是解析與大小寫 fail-loud，不是 psql 查詢本身
# （那部分仍靠 CI db job 實跑）。
py_checker="${root}/scripts/gates/api_contract_check.py"
expect_catalog() {  # <期望 exit code> <樣本名稱> <API.md> <rpc_file> <table_file>
  local want=$1 name=$2 doc=$3 rpcs=$4 tables=$5 out got
  out="$(PYTHONIOENCODING=utf-8 python3 "$py_checker" --catalog "$doc" "$rpcs" "$tables" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "✓ $name"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ⑭ catalog 正向：pg_get_function_identity_arguments 的真實形狀（保留參數名、INOUT／
#    VARIADIC 大寫前綴、零參數是空括號）都解析得對，與 doc 一致要綠
d=$(new_case case14_catalog_ok)
printf '%s\n' 'foo(p_a text, p_b uuid)' 'bar(INOUT a text, VARIADIC b integer[])' 'baz()' > "$d/rpcs.txt"
printf '%s\n' 'widgets' > "$d/tables.txt"
contract_doc "$d/API.md" $'foo(text, uuid)\nbar(text, integer[])\nbaz()' "widgets"
expect_catalog 0 '⑭ catalog 合成輸入正向（含 INOUT／VARIADIC／零參數）' "$d/API.md" "$d/rpcs.txt" "$d/tables.txt"

# ⑮ catalog 含大寫表名（只可能來自 "Widgets" 引號識別字）必須紅，不得 .lower() 後靜默對上（LS-54 N3）
d=$(new_case case15_catalog_uppercase_table)
printf '%s\n' 'foo(p_a text)' > "$d/rpcs.txt"
printf '%s\n' 'Widgets' > "$d/tables.txt"
contract_doc "$d/API.md" "foo(text)" "widgets"
expect_catalog 1 '⑮ catalog 大寫表名 fail loud（LS-54 N3）' "$d/API.md" "$d/rpcs.txt" "$d/tables.txt"

# ⑯ 同上，RPC 名稱含大寫
d=$(new_case case16_catalog_uppercase_rpc)
printf '%s\n' 'Foo(p_a text)' > "$d/rpcs.txt"
printf '%s\n' 'widgets' > "$d/tables.txt"
contract_doc "$d/API.md" "foo(text)" "widgets"
expect_catalog 1 '⑯ catalog 大寫 RPC 名 fail loud（LS-54 N3）' "$d/API.md" "$d/rpcs.txt" "$d/tables.txt"


# ⑰-⑳（LS-205，LS-96 池項 ca99c6ae i1）：--text 模式納入 view（第一支是 album_summaries，
# `scripts/gates/api_contract_check.py` 的 create_view／drop_view 事件）。

# ⑰ create view（名稱後接 `with (...)` 子句、無括號參數列，album_summaries 的實際形狀）也抓得到、
#    進 TABLES 對帳；doc 有列 → 綠
d=$(new_case case17_view)
cat > "$d/migrations/001.sql" <<'SQL'
create view public.album_summaries
  with (security_invoker = true)
as
select 1 as id;
SQL
contract_doc "$d/API.md" "" "album_summaries"
expect 0 '⑰ create view（帶 with (...) 子句、無括號參數列）抓得到並進 TABLES 對帳（LS-205）' "$d/migrations" "$d/API.md"

# ⑱ view 若漏寫進 docs TABLES 區塊，跟表一樣要紅（證明真的有追蹤，不是被忽略而巧合放行）
d=$(new_case case18_view_missing_in_doc)
cat > "$d/migrations/001.sql" <<'SQL'
create view public.foo_view as select 1;
SQL
contract_doc "$d/API.md" "" ""
expect 1 '⑱ view 漏寫進 doc TABLES 區塊要紅（LS-205）' "$d/migrations" "$d/API.md"

# ⑲ drop view 移除追蹤，doc 不需要（也不該）列出已刪除的 view
d=$(new_case case19_view_dropped)
cat > "$d/migrations/001.sql" <<'SQL'
create view public.temp_view as select 1;
drop view public.temp_view;
SQL
contract_doc "$d/API.md" "" ""
expect 0 '⑲ drop view 移除追蹤（LS-205）' "$d/migrations" "$d/API.md"

# ⑳ create or replace view 也抓得到
d=$(new_case case20_or_replace_view)
cat > "$d/migrations/001.sql" <<'SQL'
create or replace view public.bar_view as select 1;
SQL
contract_doc "$d/API.md" "" "bar_view"
expect 0 '⑳ create or replace view 也抓得到（LS-205）' "$d/migrations" "$d/API.md"

# ㉑（LS-205）：catalog 模式（CI db job 用、權威）的 SQL 查詢必須把 relkind 'v'（view）納入對帳範圍，
#    不能只留 'r'／'p'——這段 SQL 文字本身要連上活資料庫才能真的驗證行為，本檔案（rules job，不起 DB）
#    無法直接跑一次 psql；改用靜態文字斷言釘住查詢字面（同 detect-simulator.test.sh ⑨／
#    push-gate.test.sh ④ 的既有模式：跳過注釋、只認真正的程式碼字面）。mutation（把 'v' 從 relkind
#    清單拿掉，只留 'r', 'p'）會讓這裡紅——CI 的 db job 本身會用真正的 supabase db reset＋psql 對
#    album_summaries 這支真實 view 再驗一次功能是否正確（權威來源見 docs/API.md §9）。
if grep -qE "relkind in \('r', 'p', 'v'\)" "$checker"; then
  echo "✓ ㉑ catalog 模式 SQL 查詢的 relkind 清單含 'v'（view 納入對帳範圍，LS-205）"
else
  echo "✗ ㉑ catalog 模式 SQL 查詢未把 relkind 'v' 納入——view 會落在對帳網外（LS-205 池項 ca99c6ae i1 退化）" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ api-contract-check 自測通過（21 組樣本：①-⑬／⑰-⑳ --text、⑭-⑯ --catalog 合成輸入、㉑ catalog SQL 靜態斷言；psql 查活 DB 靠 CI db job 本身回歸）"
fi
exit "$fail"
