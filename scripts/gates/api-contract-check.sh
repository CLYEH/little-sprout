#!/bin/bash
# API 契約對帳 gate（LS-41；PR #58 review 主修：CI 改用活資料庫 catalog 為權威）。
# 規約見 docs/COLLABORATION.md §7、docs/API.md §9。實際解析／比對邏輯在
# scripts/gates/api_contract_check.py（本檔只負責模式分派與 catalog 模式的 psql 查詢）。
#
# 兩種模式：
#   （預設，本機 push-gate 用）純文字解析 supabase/migrations/*.sql，best-effort，
#     不需要跑起 DB；已知限制見 api_contract_check.py 檔頭。
#   --catalog（CI db job 用，權威）：db job 在 `supabase db reset` 套用完全部
#     migrations 後已經有一個活資料庫，直接用 psql 查 pg_catalog 取得 RPC 簽章與
#     表清單，不重新剖析 SQL 原始碼，不受文字解析限制影響。需要 SUPABASE_DB_URL。
#
# 兩種模式都對照 docs/API.md §9 的 API-CONTRACT:RPC / API-CONTRACT:TABLES 區塊，
# doc 缺項或 schema 缺項（含幽靈項）皆 FAIL 並印出差異。
#
# 用法：
#   api-contract-check.sh [path-to-API.md] [path-to-migrations-dir]      文字模式
#   api-contract-check.sh --catalog [path-to-API.md]                    catalog 模式
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
checker="${root}/scripts/gates/api_contract_check.py"

if [ ! -f "${checker}" ]; then
  echo "✗ api-contract gate：找不到 ${checker}" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ api-contract gate：需要 python3（macOS 與 ubuntu-latest 皆內建；PATH 異常請修復）" >&2
  exit 1
fi

if [ "${1:-}" = "--catalog" ]; then
  api_md="${2:-${root}/docs/API.md}"
  if [ ! -f "${api_md}" ]; then
    echo "✗ api-contract gate：找不到 ${api_md}" >&2
    exit 1
  fi
  if [ -z "${SUPABASE_DB_URL:-}" ]; then
    echo "✗ api-contract gate（catalog 模式）：需要 SUPABASE_DB_URL——CI 的 db job 在 supabase db reset 之後會匯出；本機可用 supabase status -o env 取得後 export" >&2
    exit 1
  fi
  if ! command -v psql >/dev/null 2>&1; then
    echo "✗ api-contract gate（catalog 模式）：需要 psql" >&2
    exit 1
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # pg_get_function_identity_arguments：只回傳「識別一支函式所需」的參數（IN/INOUT/
  # VARIADIC，不含 OUT——這正好對齊我們要的『呼叫端要傳什麼』，也正好排除
  # RETURNS TABLE(...) 隱含的 OUT 欄位，不必額外處理）、不含預設值。實測澄清：
  # 會保留參數名（例如 "p_family_id uuid"），不是純型別列表——解析邏輯見
  # api_contract_check.py 的 extract_schema_from_catalog。
  psql "${SUPABASE_DB_URL}" -v ON_ERROR_STOP=1 --no-psqlrc -qtA -c "
    select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
     order by 1;
  " > "${tmp}/rpcs.txt"

  # relkind 'r'=一般表、'p'=分區母表；不含 view/sequence/index，比 information_schema
  # 更直接（同一顆 pg_catalog，跟上面 RPC 查詢一致的查法）。
  psql "${SUPABASE_DB_URL}" -v ON_ERROR_STOP=1 --no-psqlrc -qtA -c "
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p')
     order by 1;
  " > "${tmp}/tables.txt"

  PYTHONIOENCODING=utf-8 python3 "${checker}" --catalog "${api_md}" "${tmp}/rpcs.txt" "${tmp}/tables.txt"
else
  api_md="${1:-${root}/docs/API.md}"
  migrations_dir="${2:-${root}/supabase/migrations}"
  if [ ! -f "${api_md}" ]; then
    echo "✗ api-contract gate：找不到 ${api_md}" >&2
    exit 1
  fi
  if [ ! -d "${migrations_dir}" ]; then
    echo "✗ api-contract gate：找不到 ${migrations_dir}" >&2
    exit 1
  fi
  PYTHONIOENCODING=utf-8 python3 "${checker}" --text "${api_md}" "${migrations_dir}"
fi
