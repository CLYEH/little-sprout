#!/bin/bash
# api-contract-check.sh 的自測（LS-41；PR #58 review F3）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：文字解析器（本機 push-gate 用的 best-effort
# 模式）若退化或漏判，這裡會紅。
#
# 範圍：只測 --text（文字解析）模式。--catalog 模式（CI db job 用的權威來源）需要
# 一個已套用 migrations 的活資料庫，不適合塞進這個快速、不起 DB 的 rules job 自測；
# 它的正確性由 CI db job 自己每次真的執行來回歸驗證（本票開發時也已用本機
# `supabase db reset` + 真實 psql 手動驗證過一輪，見 handoff）。
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
    echo "✗ $name（期望 exit $want，實得 $got）" >&2
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

if [ "$fail" -eq 0 ]; then
  echo "✓ api-contract-check 自測通過（10 組樣本；--catalog 模式靠 CI db job 本身回歸）"
fi
exit "$fail"
