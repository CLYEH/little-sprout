#!/bin/bash
# Migration 分級偵測（LS-53）：把 SQL 逐句分成 DESTRUCTIVE／BREAKING 兩級，供 CI rules job 與
# push-gate 決定這個 PR 要附什麼證據（docs/COLLABORATION.md §6、§7）。
#
# 用法：
#   migration-breaking-check.sh [--known-functions FILE] [SQL檔...]   無檔名則讀 stdin
#   migration-breaking-check.sh --base <rev>                            分級 <rev>...HEAD 在
#                                   supabase/migrations/ 的新增行；既有函式清單自 <rev> 的 migrations 取
# 輸出：每個命中的敘述一行 `<級別>\t<正規化後的敘述（截 160 bytes）>`，無命中則無輸出。
# exit 0＝分級完成（不論有無命中；要不要擋是呼叫端的事）；exit 1＝用法／工具／git 錯誤。
#
# 為什麼是 statement 級而不是逐行 grep：ci.yml 舊版對 diff 逐行比對關鍵字，多行敘述
# （`revoke execute on function\n  public.f(...) from public, anon`）看不到角色清單、
# `alter policy …\n  using (false)` 看不到條件；且同一實質變更換個寫法就繞過（PR #60 review F7：
# DROP POLICY 要人核可，ALTER POLICY … (false) 不用）。這裡先剝註解、把 `;` 切成一句一行、
# 壓空白轉小寫，再對每句套規則；分級看的是「這句做了什麼」，不是「用了哪個字」。
#
# 規則（一句只取最高級；一個 PR 的要求＝所有句子的聯集）：
#   DESTRUCTIVE（資料或物件消失／形狀改變 → PR body 須使用者本人蓋核可標記，見
#   destructive-approval-check.sh）：
#     D1 DROP <任何物件>（TABLE／COLUMN／POLICY／FUNCTION／TRIGGER／INDEX／SCHEMA／CONSTRAINT／VIEW／
#        TYPE…，含 IF EXISTS；DROP NOT NULL／DROP DEFAULT 也算——寧可多要一次核可，不留白名單讓人換寫法）
#     D2 TRUNCATE
#     D3 DISABLE ROW LEVEL SECURITY
#     D4 ALTER TABLE … ALTER [COLUMN] x [SET DATA] TYPE …（不分縮窄放寬；舊版 `ALTER TABLE.* TYPE ` 會把
#        `add column type text` 這種欄名也命中，這裡改對準 ALTER COLUMN 子句）
#   BREAKING（既有呼叫端的行為改變 → PR body 須 `BREAKING:` 行錨定段落＋同 PR 動 docs/API.md，
#   見 breaking-section-check.sh）：
#     B1 ALTER POLICY …（收緊 (false)、放寬 (true)、改條件、RENAME 一律；多行也認得）
#     B2 CREATE POLICY … AS RESTRICTIVE（對既有表加限制性 policy＝B1 收緊的換寫法）
#     B3 REVOKE … FROM <roles>，roles 含 public／anon 以外的任何角色（authenticated／service_role／
#        自訂）。只從 public／anon 收回＝新函式上鎖慣例（每支 RPC 都做），不算；
#        ALTER DEFAULT PRIVILEGES … REVOKE 只影響未來物件，不算；找不到 FROM 子句視為 BREAKING（fail closed）
#     B4 CREATE [OR REPLACE] FUNCTION <name>，name 已存在（--known-functions 或 --base 取得；
#        兩者都沒給時一律視為既有，fail closed）。只改本體（OR REPLACE）或加 overload 改簽章都算：
#        本體行為就是契約（§6）
#     B5 RENAME（表／欄／函式／policy 改名）
#     B6 SET SCHEMA（物件搬 schema，呼叫端找不到）
#
# 已知限制（皆倒向多報，不倒向漏報）：
#   - 字串字面值內的關鍵字也算（含 COMMENT ON 的說明文字、函式本體裡的 raise 訊息）——刻意的：
#     `execute 'drop policy …'` 動態 SQL 是最自然的繞法，不能為了說明文字放過它。說明文字請改寫。
#   - `--` 出現在字串字面值內時，其後同行內容會被當註解剝掉（同舊版）。
#   - 函式本體（$$…$$）內的 `;` 一樣切句，本體內語句一樣分級。
set -uo pipefail
export LC_ALL=C   # 位元組導向：中文註解不會讓 tr／grep 出錯，[:upper:] 只轉 ASCII

known_file=""
base=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --known-functions) known_file=${2:?--known-functions 需要檔名}; shift 2 ;;
    --base) base=${2:?--base 需要 rev}; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) echo "✗ migration-breaking-check：未知參數 $1" >&2; exit 1 ;;
    *) files+=("$1"); shift ;;
  esac
done

if ! command -v perl >/dev/null 2>&1; then
  echo "✗ migration-breaking-check：需要 perl 剝 /* */ 註解（macOS／ubuntu 內建），未找到即中止，不靜默放行" >&2
  exit 1
fi

# 正規化：剝 /* */ 與 -- 註解 → 一句一行（以 ; 切）→ 壓空白 → 小寫
normalize() {
  perl -0777 -pe 's{/\*.*?\*/}{ }gs' \
    | sed 's/--.*//' \
    | tr '\n\t' '  ' \
    | tr ';' '\n' \
    | tr -s ' ' \
    | sed 's/^ //; s/ $//' \
    | tr '[:upper:]' '[:lower:]'
}

# 從正規化句子抽函式名（去引號；無 schema 者補 public.）
fn_name() {
  grep -oE 'create (or replace )?function [^ (]+' | awk '{print $NF}' | tr -d '"' \
    | sed -E 's/^([^.]+)$/public.\1/'
}

# 關鍵字整詞比對：前後不得是 [a-z0-9_]（避免 date_trunc／dropped／renamed_at 誤中）
kw() { printf '%s' "$1" | grep -qE "(^|[^a-z0-9_])($2)([^a-z0-9_]|$)"; }

# B3：REVOKE 的角色清單是否含 public／anon 以外的角色
revoke_is_breaking() {
  local stmt=$1 roles r
  case "$stmt" in *"alter default privileges"*) return 1 ;; esac
  roles=${stmt##* from }
  [ "$roles" = "$stmt" ] && return 0            # 沒有 from 子句：fail closed
  roles=$(printf '%s' "$roles" | sed -E 's/ (granted by|cascade|restrict)( .*)?$//' | tr -d "\"')")
  local IFS=','
  for r in $roles; do
    r=${r# }; r=${r% }
    case "$r" in public|anon|'') ;; *) return 0 ;; esac
  done
  return 1
}

classify() {
  local stmt name
  while IFS= read -r stmt; do
    [ -z "$stmt" ] && continue
    if kw "$stmt" 'drop|truncate|disable row level security' \
       || printf '%s' "$stmt" | grep -qE 'alter table .*alter (column )?[^ ]+ (set data )?type '; then
      printf 'DESTRUCTIVE\t%s\n' "${stmt:0:160}"
      continue
    fi
    if kw "$stmt" 'alter policy|rename|set schema' \
       || printf '%s' "$stmt" | grep -qE 'create policy .* as restrictive' \
       || { kw "$stmt" 'revoke' && revoke_is_breaking "$stmt"; }; then
      printf 'BREAKING\t%s\n' "${stmt:0:160}"
      continue
    fi
    if kw "$stmt" 'create (or replace )?function'; then
      name=$(printf '%s' "$stmt" | fn_name)
      if [ -z "$known_file" ] || grep -qxF -- "$name" "$known_file"; then
        printf 'BREAKING\t%s\n' "${stmt:0:160}"
      fi
    fi
  done
}

if [ -n "$base" ]; then
  cd "$(git rev-parse --show-toplevel)" || exit 1
  known_file=$(mktemp)
  trap 'rm -f "$known_file"' EXIT
  base_files=$(git ls-tree -r --name-only "$base" -- supabase/migrations/) \
    || { echo "✗ migration-breaking-check：git ls-tree $base 失敗" >&2; exit 1; }
  if [ -n "$base_files" ]; then
    while IFS= read -r f; do git show "$base:$f" || exit 1; done <<< "$base_files" \
      | normalize | fn_name | sort -u > "$known_file"
  fi
  added=$(git diff "$base...HEAD" -- supabase/migrations/) \
    || { echo "✗ migration-breaking-check：git diff $base...HEAD 失敗" >&2; exit 1; }
  printf '%s\n' "$added" | grep '^+' | grep -v '^+++' | cut -c2- | normalize | classify
  exit 0
fi

if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    [ -r "$f" ] || { echo "✗ migration-breaking-check：讀不到 $f" >&2; exit 1; }
  done
  cat -- "${files[@]}" | normalize | classify
else
  normalize | classify
fi
exit 0
