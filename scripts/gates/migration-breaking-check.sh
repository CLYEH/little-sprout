#!/bin/bash
# Migration 分級偵測（LS-53）：把 SQL 逐句分成 DESTRUCTIVE／BREAKING 兩級，供 CI rules job 與
# push-gate 決定這個 PR 要附什麼證據（docs/COLLABORATION.md §6、§7）。
#
# 用法：
#   migration-breaking-check.sh [--known-functions FILE] [SQL檔...]   無檔名則讀 stdin
#   migration-breaking-check.sh --base <rev>                            分級 <rev>...HEAD 在
#                                   supabase/migrations/ 的新增行；既有函式清單自 <rev> 的 migrations 取
# 輸出：每個命中一行 `<級別>\t<正規化後的敘述（截 160 bytes）>`，無命中則無輸出。同一句可同時命中兩級
#   （各印一行；例：DROP FUNCTION <既有 RPC> ＝ DESTRUCTIVE＋BREAKING——PR #78 R1 M1 裁決）。
# exit 0＝分級完成（不論有無命中；要不要擋是呼叫端的事）；exit 1＝用法／工具／git／管線錯誤（fail closed）。
#
# 為什麼是 statement 級而不是逐行 grep：ci.yml 舊版對 diff 逐行比對關鍵字，多行敘述
# （`revoke execute on function\n  public.f(...) from public, anon`）看不到角色清單、
# `alter policy …\n  using (false)` 看不到條件；且同一實質變更換個寫法就繞過（PR #60 review F7：
# DROP POLICY 要人核可，ALTER POLICY … (false) 不用）。這裡先剝註解、把 `;` 切成一句一行、
# 壓空白轉小寫，再對每句套規則；分級看的是「這句做了什麼」，不是「用了哪個字」。
#
# 規則（一個 PR 的要求＝所有命中的聯集）：
#   DESTRUCTIVE（資料或物件消失／形狀改變 → PR body 須使用者本人蓋核可標記，見
#   destructive-approval-check.sh）：
#     D1 DROP <任何物件>（TABLE／COLUMN／POLICY／FUNCTION／TRIGGER／INDEX／SCHEMA／CONSTRAINT／VIEW／
#        TYPE…，含 IF EXISTS；DROP NOT NULL／DROP DEFAULT 也算——寧可多要一次核可，不留白名單讓人換寫法）。
#        DROP FUNCTION 既有名稱另同時命中 B4。
#     D2 TRUNCATE
#     D3 DISABLE ROW LEVEL SECURITY
#     D4 ALTER TABLE … ALTER [COLUMN] x [SET DATA] TYPE …（不分縮窄放寬；對準 ALTER COLUMN 子句，
#        `add column type text` 這種欄名不命中；但欄名就叫 type 的 ALTER COLUMN——
#        `alter column type set default …`——仍會誤報，已知限制、多報方向，PR #78 R1 I3）
#   BREAKING（既有呼叫端的行為改變 → PR body 須 `BREAKING:` 行錨定段落＋同 PR 動 docs/API.md，
#   見 breaking-section-check.sh）：
#     B1 ALTER POLICY …（收緊 (false)、放寬 (true)、改條件、RENAME 一律；多行也認得）
#     B2 CREATE POLICY … AS RESTRICTIVE（對既有表加限制性 policy＝B1 收緊的換寫法）
#     B3 REVOKE … FROM <roles>，roles 含 public／anon 以外的任何角色（authenticated／service_role／
#        自訂）。只從 public／anon 收回＝新函式上鎖慣例（每支 RPC 都做），不算；
#        ALTER DEFAULT PRIVILEGES … REVOKE 只影響未來物件，不算；找不到 FROM 子句視為 BREAKING（fail closed）
#     B4 CREATE [OR REPLACE] FUNCTION／DROP FUNCTION <name>，name 已存在。既有清單：`--base` 自 base 的
#        migrations 取（base 無 migrations ＝ 清單為空 ＝ 全視為新函式）；stdin／檔案模式用
#        --known-functions，未給時一律視為既有（fail closed）。只改本體（OR REPLACE）、加 overload
#        改簽章、或直接 DROP 都算：本體行為就是契約（§6）
#     B5 RENAME（表／欄／函式／policy 改名）
#     B6 SET SCHEMA（物件搬 schema，呼叫端找不到）
#
# 已知限制（未註明者皆倒向多報，不倒向漏報）：
#   - 字串字面值內的關鍵字也算（含 COMMENT ON 的說明文字、函式本體裡的 raise 訊息）——刻意的：
#     `execute 'drop policy …'` 動態 SQL 是最自然的繞法，不能為了說明文字放過它。說明文字請改寫。
#   - 動態 SQL 只認**單一字面值**內的關鍵字：用 `||` 串接把多字關鍵字拆開（`'alter ' || 'policy …'`）
#     認不得——漏報方向，靠 merge-reviewer（PR #78 R1 I2）。
#   - 註解剝除是單一 pass：`--` 到行尾與 `/* … */` 誰先出現誰生效（與 Postgres 詞法一致，PR #78 R1 B2）。
#     但字串字面值內的 `--`／`/*` 一樣會被當註解起點（其後內容漏掉，漏報方向）；巢狀 `/* /* */ */`
#     只剝到第一個 `*/`，其後到外層 `*/` 之間照常分級（多報方向）。
#   - 函式本體（$$…$$）內的 `;` 一樣切句，本體內語句一樣分級。
#   - 檔案邊界（--base 的 diff 檔頭、檔案清單、既有清單建立）一律補 `;`：上一檔末句沒分號不會黏進下一檔。
#   - 後續登記（PR #78 R1 I5／I6／I7）：每句 fork 數次 grep（全 repo 約 6s、--base 實務 1–2s，可接受）；
#     UTF-16 檔案不認得；CRLF 的 \r 殘留在輸出（cosmetic）。
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

# PR #78 R1 M2：清單檔讀不到就直接紅——grep 讀檔失敗會被當「不是既有函式」放行（fail open）
if [ -n "$known_file" ] && [ ! -r "$known_file" ]; then
  echo "✗ migration-breaking-check：--known-functions 檔讀不到：$known_file（fail closed，不當新函式放行）" >&2
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "✗ migration-breaking-check：需要 perl 剝註解（macOS／ubuntu 內建），未找到即中止，不靜默放行" >&2
  exit 1
fi

# 正規化：單一 pass 剝註解（`--` 到行尾／`/* */` 跨行，位置靠前者先生效——PR #78 R1 B2：先剝塊註解會讓
# `-- x /*` … `-- y */` 之間整段消失）→ 一句一行（以 ; 切）→ 壓空白 → 點號旁空白收斂（R1 I1：`public . fn`）
# → 小寫。末句沒分號時最後一行沒有結尾換行，由 classify 的 read 守衛接住（R1 B1）。
normalize() {
  perl -0777 -pe 's{--[^\n]*|/\*.*?\*/}{ }gs' \
    | tr '\n\t' '  ' \
    | tr ';' '\n' \
    | tr -s ' ' \
    | sed -E 's/^ //; s/ $//; s/ *\. */./g' \
    | tr '[:upper:]' '[:lower:]'
}

# 函式名抽取：$1＝名稱前的關鍵字模式。去引號；無 schema 者補 public.。
# grep 無命中（rc 1）是正常情況，只有 rc≥2 才視為錯誤——pipefail 下不能讓「沒有函式」變成失敗。
FN_DEF='create (or replace )?function'                               # 既有清單只認定義
FN_REF='(create (or replace )?function|drop function( if exists)?)'  # 分級認定義與 DROP
fn_name() {
  local hits
  hits=$(grep -oE "$1 [^ (]+"); [ $? -le 1 ] || return 2
  printf '%s\n' "$hits" | awk 'NF {print $NF}' | tr -d '"' | sed -E 's/^([^.]+)$/public.\1/'
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

# B4：句中出現的函式名有任一在既有清單（或沒有清單＝一律視為既有）
fn_is_known() {
  local stmt=$1 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -z "$known_file" ] || grep -qxF -- "$name" "$known_file"; then return 0; fi
  done <<< "$(printf '%s' "$stmt" | fn_name "$FN_REF")"
  return 1
}

classify() {
  local stmt breaking
  # R1 B1：`read` 對沒有結尾換行的最後一行回傳非 0，`|| [ -n "$stmt" ]` 讓末句（沒分號時）仍被分級
  while IFS= read -r stmt || [ -n "$stmt" ]; do
    [ -z "$stmt" ] && continue
    if kw "$stmt" 'drop|truncate|disable row level security' \
       || printf '%s' "$stmt" | grep -qE 'alter table .*alter (column )?[^ ]+ (set data )?type '; then
      printf 'DESTRUCTIVE\t%s\n' "${stmt:0:160}"
    fi
    # R1 M1：不 continue，同一句可再命中 BREAKING（DROP FUNCTION 既有＝兩級都要）
    breaking=0
    if kw "$stmt" 'alter policy|rename|set schema' \
       || printf '%s' "$stmt" | grep -qE 'create policy .* as restrictive' \
       || { kw "$stmt" 'revoke' && revoke_is_breaking "$stmt"; }; then
      breaking=1
    elif kw "$stmt" "$FN_REF" && fn_is_known "$stmt"; then
      breaking=1
    fi
    if [ "$breaking" -eq 1 ]; then
      printf 'BREAKING\t%s\n' "${stmt:0:160}"
    fi
  done
  return 0
}

pipeline_failed() { echo "✗ migration-breaking-check：分級管線失敗（perl／sed／tr 任一步非 0），不靜默放行" >&2; exit 1; }

if [ -n "$base" ]; then
  cd "$(git rev-parse --show-toplevel)" || exit 1
  known_file=$(mktemp); base_sql=$(mktemp)
  trap 'rm -f "$known_file" "$base_sql"' EXIT
  base_files=$(git ls-tree -r --name-only "$base" -- supabase/migrations/) \
    || { echo "✗ migration-breaking-check：git ls-tree $base 失敗" >&2; exit 1; }
  if [ -n "$base_files" ]; then
    # R1 I4：git show 逐檔檢查 rc（原本放在管線 subshell 裡 exit，外層看不到、清單靜默殘缺）；
    # 檔與檔之間補換行，避免上一檔檔尾 `--` 註解沒換行時把下一檔第一行吃掉
    while IFS= read -r f; do
      git show "$base:$f" >> "$base_sql" \
        || { echo "✗ migration-breaking-check：git show $base:$f 失敗，既有函式清單不完整即中止" >&2; exit 1; }
      printf '\n;\n' >> "$base_sql"
    done <<< "$base_files"
    normalize < "$base_sql" | fn_name "$FN_DEF" | sort -u > "$known_file" || pipeline_failed
  fi
  added=$(git diff "$base...HEAD" -- supabase/migrations/) \
    || { echo "✗ migration-breaking-check：git diff $base...HEAD 失敗" >&2; exit 1; }
  # sed 一次做「+++ 檔頭換成 ; 當檔案邊界、取新增行並剝掉 +」——用 grep 會在沒有新增行時回 1 觸發
  # pipefail；檔案邊界補 ; 是因為上一檔末句沒分號時會與下一檔第一句黏成同一句（R1 B1 同類：REVOKE 只看
  # 最後一個 from 子句，黏句可讓 `from authenticated` 被下一檔的 `from public, anon` 蓋掉）
  printf '%s\n' "$added" | sed -n 's/^+++ .*/;/p; s/^+//p' | normalize | classify || pipeline_failed
  exit 0
fi

if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    [ -r "$f" ] || { echo "✗ migration-breaking-check：讀不到 $f" >&2; exit 1; }
  done
  for f in "${files[@]}"; do cat -- "$f"; printf '\n;\n'; done | normalize | classify || pipeline_failed
else
  normalize | classify || pipeline_failed
fi
exit 0
