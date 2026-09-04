#!/bin/bash
# Migration 分級偵測（LS-53）：把 SQL 逐句分成 DESTRUCTIVE／BREAKING 兩級，供 CI rules job 與
# push-gate 決定這個 PR 要附什麼證據（docs/COLLABORATION.md §6、§7）。
#
# 用法：
#   migration-breaking-check.sh [--known-functions FILE] [--known-enums FILE] [--consumer-root DIR] [SQL檔...]
#                                   無檔名則讀 stdin
#   migration-breaking-check.sh --base <rev>                            分級 <rev>...HEAD 在
#                                   supabase/migrations/ 的新增行；既有函式清單與既有 enum 值集合自 <rev> 的 migrations 取
# 輸出：每個命中一行 `<級別>\t<正規化後的敘述（截 160 bytes）>`，無命中則無輸出。同一句可同時命中兩級
#   （各印一行；例：DROP FUNCTION <既有 RPC> ＝ DESTRUCTIVE＋BREAKING——PR #78 R1 M1 裁決）。
#   B7（enum 加值）在 BREAKING 行之後再印機器可讀的消費端清單（LS-181）：
#     ENUM\t<schema.name>\t<新值>\t既有值 <k> 個：…\t消費端 <n> 處（或「消費端：無（請人工確認）」）
#     CONSUMER\t<schema.name>\t<repo 根相對路徑>\t<命中說明：既有值幾種／名稱／行號>
#   接線：CI rules job 把整份輸出落檔、以 `breaking-section-check.sh --findings <檔>` 要求 PR body 的 BREAKING: 段逐一
#   列出每個 CONSUMER 路徑的處置；push-gate 只印提醒。CI／push-gate 的 `grep '^BREAKING'`／`'^DESTRUCTIVE'` 不受新行影響。
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
#     B5 RENAME（表／欄／函式／policy 改名；含 ALTER TYPE … RENAME VALUE）
#     B6 SET SCHEMA（物件搬 schema，呼叫端找不到）
#     B7 ALTER TYPE <enum> ADD VALUE [IF NOT EXISTS] '<v>'（enum 加值，LS-181；來源 LS-175 merge-review R1 i1：LS-149 加
#        `report` 後 push-dispatch 的 `isNotificationKind` 守衛沒人更新，含 report 事件的已 claim 批次整批靜默丟失）。
#        加值本身不會讓 SQL 壞掉，壞的是「既有消費端不認得新值」——TS 型別守衛／union、iOS `Codable` enum 解碼、
#        API.md 值表與文案矩陣——所以一律 BREAKING，並自動列出消費端候選（CONSUMER 行）供 PR body 逐一交代：
#          - 既有值集合：`--base` 自 base 的 migrations 取（`create type … as enum (…)`＋先前的 `add value`）；
#            stdin／檔案模式用 `--known-enums FILE`（每行 `schema.name<TAB>value`）；輸入本身出現的 `create type`／
#            較早的 `add value` 也會累加。沒有集合時只靠名稱命中（仍會列出直接寫了 enum 名的檔）。
#          - 命中定義（掃描根：`--base` 為 repo 根；stdin／檔案模式用 `--consumer-root DIR`，未給則 git toplevel）：
#            `supabase/functions/**/*.ts`／`LittleSprout/**/*.swift`：檔內出現 enum 名整字（snake_case 或 PascalCase，
#              如 notification_kind／NotificationKind）即列；否則同一檔出現 ≥2 種既有值的引號字面（`'v'`／`"v"`／`` `v` ``，
#              不分大小寫；Swift 另認 `case v` 宣告行，不認 `case .v` 的 switch pattern——後者由編譯器窮舉擋）才列
#              （既有值只有 1 個時門檻降為 1）。多行 union（一行一值）靠檔級聚合抓到。
#            `docs/API.md`：逐行——含 enum 名整字、或同一行 ≥2 種既有值反引號字面；另認表格區塊（連續 `|` 行）
#              首欄反引號值涵蓋 ≥2 種既有值（文案矩陣形狀）。API.md 太大，不做檔級聚合。
#          - 都沒命中 → ENUM 行印「消費端：無（請人工確認）」，仍是 BREAKING、PR body 仍要 BREAKING: 段。
#        已知限制：值集合相近的 enum 互相多報（feed_kind 的 album／media／diary 與 content_target_type 重疊）；
#        Swift 端 snake_case 值轉 camelCase 的 case 名認不得（漏報方向，靠 merge-reviewer）；normalize 已把值轉小寫，
#        消費端比對因此不分大小寫；`execute 'alter type … add value ''x'''` 動態 SQL 的值抽不出來（仍列 BREAKING，
#        消費端只靠名稱）；新 enum 與加值同一 PR 也判 BREAKING（多報方向）。
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
#   - 逐檔 normalize（--base 逐檔取 diff、檔案清單逐檔、既有清單逐檔）：前檔末句沒分號不黏進後檔，字面值內
#     的 `/*` 也不會跨檔吃掉後續語句（PR #78 R1 B1／R2 F1／F2）。
#   - 後續登記（PR #78 R1 I5／I6／I7）：每句 fork 數次 grep（全 repo 約 6s、--base 實務 1–2s，可接受）；
#     UTF-16 檔案不認得；CRLF 的 \r 殘留在輸出（cosmetic）。
set -uo pipefail
export LC_ALL=C   # 位元組導向：中文註解不會讓 tr／grep 出錯，[:upper:] 只轉 ASCII

known_file=""
known_enums_arg=""
consumer_root=""
base=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --known-functions) known_file=${2:?--known-functions 需要檔名}; shift 2 ;;
    --known-enums) known_enums_arg=${2:?--known-enums 需要檔名}; shift 2 ;;
    --consumer-root) consumer_root=${2:?--consumer-root 需要目錄}; shift 2 ;;
    --base) base=${2:?--base 需要 rev}; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) echo "✗ migration-breaking-check：未知參數 $1" >&2; exit 1 ;;
    *) files+=("$1"); shift ;;
  esac
done

# PR #78 R1 M2：清單檔讀不到就直接紅——grep 讀檔失敗會被當「不是既有函式」放行（fail open）
# R2 F3：[ -r ] 對目錄也為真，要 [ -f ] && [ -r ]
if [ -n "$known_file" ] && { [ ! -f "$known_file" ] || [ ! -r "$known_file" ]; }; then
  echo "✗ migration-breaking-check：--known-functions 不是可讀的一般檔：$known_file（fail closed，不當新函式放行）" >&2
  exit 1
fi
if [ -n "$known_enums_arg" ] && { [ ! -f "$known_enums_arg" ] || [ ! -r "$known_enums_arg" ]; }; then
  echo "✗ migration-breaking-check：--known-enums 不是可讀的一般檔：$known_enums_arg（fail closed）" >&2
  exit 1
fi
if [ -n "$consumer_root" ] && [ ! -d "$consumer_root" ]; then
  echo "✗ migration-breaking-check：--consumer-root 不是目錄：$consumer_root（fail closed）" >&2
  exit 1
fi

# LS-181：暫存目錄集中管理（既有函式清單、enum 值集合都放這裡，一個 trap 收）
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# enum 值集合（每行 `schema.name<TAB>value`）：--known-enums 複製一份進來（不動使用者的檔），classify 途中會累加
known_enums="$tmpdir/known_enums"
if [ -n "$known_enums_arg" ]; then cp "$known_enums_arg" "$known_enums"; else : > "$known_enums"; fi

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

# ── B7：enum 加值（LS-181） ────────────────────────────────────────────────────
# enum 名正規化：去引號；無 schema 補 public.
enum_name() { printf '%s' "$1" | tr -d '"' | sed -E 's/^([^.]+)$/public.\1/'; }

# 從正規化敘述抽 enum 定義：`create type <n> as enum ('a', 'b')` 與 `alter type <n> add value [if not exists] 'v'`
# → 每行 `schema.name<TAB>value`（既有清單自 base 取時用；classify 途中也用它累加輸入內看到的定義）
enum_defs() {
  local stmt name vals
  while IFS= read -r stmt || [ -n "$stmt" ]; do
    case "$stmt" in
      *"create type "*" as enum ("*)
        name=${stmt#*create type }; name=${name%% *}
        vals=${stmt#*as enum (}; vals=${vals%%)*}
        printf '%s\n' "$vals" | tr ',' '\n' | sed -E "s/^ *'//; s/' *$//" \
          | awk -v n="$(enum_name "$name")" 'NF {print n "\t" $0}'
        ;;
      *"alter type "*" add value "*)
        name=${stmt#*alter type }; name=${name%% *}
        vals=${stmt#* add value }; vals=${vals#if not exists }
        vals=${vals#*\'}; vals=${vals%%\'*}
        [ -n "$vals" ] && printf '%s\t%s\n' "$(enum_name "$name")" "$vals"
        ;;
    esac
  done
  return 0
}

# 消費端掃描根：--base 已 cd 到 repo 根；stdin／檔案模式用 --consumer-root，未給則 git toplevel；都沒有就紅（fail closed）
resolve_consumer_root() {
  [ -n "$consumer_root" ] && return 0
  consumer_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$consumer_root" ] && return 0
  echo "✗ migration-breaking-check：B7 需要消費端掃描根——不在 git repo 內請給 --consumer-root DIR（fail closed）" >&2
  return 1
}

# snake_case → PascalCase（notification_kind → NotificationKind）；bash 3.2 無 ${x^}，用 awk
to_pascal() { printf '%s' "$1" | awk -F_ '{ for (i=1;i<=NF;i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2); print "" }'; }

# 程式碼檔（ts／swift）的檔級聚合：輸出 `path<TAB>distinct<TAB>namehit<TAB>行號清單`（只印候選）
AWK_CODE='
BEGIN { n = split(vals, V, " ") }
{
  f = FILENAME; low = tolower($0); hit = 0
  if (match($0, "(^|[^A-Za-z0-9_])" pascal "([^A-Za-z0-9_]|$)") || match(low, "(^|[^a-z0-9_])" snake "([^a-z0-9_]|$)")) { namehit[f] = 1; hit = 1 }
  for (i = 1; i <= n; i++) {
    v = V[i]
    if (index(low, "\"" v "\"") || index(low, "\047" v "\047") || index(low, "`" v "`")) { seen[f, i] = 1; hit = 1 }
    else if (lang == "swift" && low ~ /^[[:space:]]*case[[:space:]]+[a-z_]/ && match(low, "(^|[^a-z0-9_])" v "([^a-z0-9_]|$)")) { seen[f, i] = 1; hit = 1 }
  }
  if (hit) { cnt[f]++; if (cnt[f] <= 8) lines[f] = lines[f] (cnt[f] > 1 ? "," : "") FNR }
}
END {
  for (f in cnt) {
    d = 0; for (i = 1; i <= n; i++) if ((f, i) in seen) d++
    nh = (f in namehit) ? 1 : 0   # 不能寫 namehit[f]：awk 讀取即建立元素，之後 (f in namehit) 會誤為真
    if (nh || d >= thr) printf "%s\t%d\t%d\t%s%s\n", f, d, nh, lines[f], (cnt[f] > 8 ? ",…" : "")
  }
}'
# docs/API.md 的逐行＋表格區塊規則：輸出命中的行號（每行一個）
AWK_DOC='
BEGIN { n = split(vals, V, " "); intable = 0 }
function flush(   i, d) {
  if (!intable) return
  d = 0; for (i = 1; i <= n; i++) if (i in tv) d++
  if (d >= thr) print tstart
  split("", tv); intable = 0
}
{
  low = tolower($0)
  if ($0 ~ /^[[:space:]]*\|/) {
    if (!intable) { intable = 1; tstart = FNR }
    if (match(low, /^[[:space:]]*\|[[:space:]]*`[a-z0-9_]+`/)) {
      cell = substr(low, RSTART, RLENGTH); gsub(/[^a-z0-9_]/, "", cell)
      for (i = 1; i <= n; i++) if (V[i] == cell) tv[i] = 1
    }
  } else flush()
  if (match($0, "(^|[^A-Za-z0-9_])" pascal "([^A-Za-z0-9_]|$)") || match(low, "(^|[^a-z0-9_])" snake "([^a-z0-9_]|$)")) { print FNR; next }
  d = 0; for (i = 1; i <= n; i++) if (index(low, "`" V[i] "`")) d++
  if (d >= 2) print FNR
}
END { flush() }'

# 印一個 enum 的 ENUM＋CONSUMER 行。$1=schema.name $2=新值。既有值自 $known_enums 取（此時尚未含新值）。
enum_consumers() {
  local name=$1 newv=$2 snake pascal vals nvals thr out n=0 f d nh ln lines
  resolve_consumer_root || return 1
  snake=${name#*.}; pascal=$(to_pascal "$snake")
  vals=$(awk -F'\t' -v n="$name" '$1 == n && $2 != "" {print $2}' "$known_enums" | sort -u | tr '\n' ' ' | sed 's/ $//')
  nvals=$(printf '%s\n' "$vals" | awk '{print NF}')
  thr=2; [ "$nvals" -lt 2 ] && thr=1
  out="$tmpdir/consumers"; : > "$out"
  local lang dir
  # 這段跑在 classify 的 while-read 迴圈內：stdin 是敘述串流——awk 都帶檔案參數不碰 stdin；xargs -r 讓空清單不起 awk
  # （GNU xargs 空輸入仍會起一次、awk 就會去讀 stdin；不能改成對 xargs 加 < /dev/null——那會讓 find 吃 SIGPIPE 141）
  for lang in ts swift; do
    case "$lang" in ts) dir="$consumer_root/supabase/functions" ;; swift) dir="$consumer_root/LittleSprout" ;; esac
    [ -d "$dir" ] || continue
    find "$dir" -type f -name "*.$lang" -print0 \
      | xargs -0 -r awk -v vals="$vals" -v snake="$snake" -v pascal="$pascal" -v lang="$lang" -v thr="$thr" "$AWK_CODE" \
      | sort | while IFS=$'\t' read -r f d nh lines; do
          f=${f#"$consumer_root"/}
          printf '%s\t' "$f"
          if [ "$nh" = 1 ] && [ "$d" -gt 0 ]; then printf '名稱＋既有值 %s 種' "$d"
          elif [ "$nh" = 1 ]; then printf '名稱'
          else printf '既有值 %s 種' "$d"; fi
          printf '，行 %s\n' "$lines"
        done >> "$out" || return 1
  done
  if [ -f "$consumer_root/docs/API.md" ]; then
    # 行號最多列 12 個；用 awk 截而不用 head（head 提前關管線會讓 sort 吃 SIGPIPE，pipefail 下誤判失敗）
    ln=$(awk -v vals="$vals" -v snake="$snake" -v pascal="$pascal" -v thr="$thr" "$AWK_DOC" "$consumer_root/docs/API.md" < /dev/null \
      | sort -nu | awk 'NR <= 12 {print} NR == 13 {print "…"}' | paste -s -d ',' -) || return 1
    [ -n "$ln" ] && printf 'docs/API.md\t值表／矩陣／值列表候選，行 %s\n' "$ln" >> "$out"
  fi
  n=$(grep -c . "$out" || true)
  if [ "$n" -eq 0 ]; then
    printf 'ENUM\t%s\t%s\t既有值 %s 個：%s\t消費端：無（請人工確認——名稱 %s／%s 與既有值字面在 supabase/functions／LittleSprout／docs/API.md 皆未命中）\n' \
      "$name" "$newv" "$nvals" "$(printf '%s' "$vals" | tr ' ' ',')" "$snake" "$pascal"
  else
    printf 'ENUM\t%s\t%s\t既有值 %s 個：%s\t消費端 %s 處（PR body BREAKING: 段須逐一列出每個路徑的處置：已更新 <sha>／不需更新＋理由）\n' \
      "$name" "$newv" "$nvals" "$(printf '%s' "$vals" | tr ' ' ',')" "$n"
    awk -F'\t' -v n="$name" '{ printf "CONSUMER\t%s\t%s\t%s\n", n, $1, $2 }' "$out"
  fi
  return 0
}

classify() {
  local stmt breaking ename evalue
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
    # B7：enum 加值——BREAKING（不與上面互斥：RENAME VALUE 走 B5，ADD VALUE 走這裡）＋消費端清單；
    # 先掃消費端（既有值尚未含新值）再把新值累加進集合，同一輸入內第二次加值看得到第一次。
    # 外層 case 不 fork：只有句中真有 `alter type`／`create type` 才起 grep（全 repo 檔案模式數千句，每句多 2 次 fork 就多 10 秒）
    case "$stmt" in
      *"alter type "*|*"create type "*)
        if printf '%s' "$stmt" | grep -qE "(^|[^a-z0-9_])alter type [^ ]+ add value (if not exists )?'"; then
          ename=$(printf '%s' "$stmt" | grep -oE "alter type [^ ]+ add value" | head -1 | awk '{print $3}')
          ename=$(enum_name "$ename")
          evalue=${stmt#*add value }; evalue=${evalue#if not exists }; evalue=${evalue#*\'}; evalue=${evalue%%\'*}
          [ -n "$evalue" ] || evalue='?'   # 動態 SQL 的 ''x'' 抽不出來：ENUM 行印 ?，消費端照掃
          [ "$breaking" -eq 1 ] || printf 'BREAKING\t%s\n' "${stmt:0:160}"
          enum_consumers "$ename" "$evalue" || exit 1
          printf '%s\n' "$stmt" | enum_defs >> "$known_enums"
        elif printf '%s' "$stmt" | grep -qE "(^|[^a-z0-9_])create type [^ ]+ as enum \("; then
          printf '%s\n' "$stmt" | enum_defs >> "$known_enums"
        fi
        ;;
    esac
  done
  return 0
}

pipeline_failed() { echo "✗ migration-breaking-check：分級管線失敗（perl／sed／tr 任一步非 0），不靜默放行" >&2; exit 1; }

# 逐檔 normalize（PR #78 R2 F1／F2）：檔與檔之間不再靠補 `;`——前檔末句沒分號不會黏進後檔，字面值內的 `/*`
# 也不會跨檔吃掉後續語句。每檔 normalize 完補一個換行當句界。
# R2 F1：--base 改「先 --name-only 再逐檔取 diff」，且只取第一個 hunk 標頭 `@@` 之後的 `+` 行——舊寫法把
# `+++ …` 一律當檔頭換成 `;`，內容以 `++` 開頭的新增行（字面值內的 `++ x`）也會被切句而漏報 D4。
# 任一檔讀取／diff／normalize 非 0 即中止（pipefail；在管線 subshell 內 exit 1 → 呼叫端 || pipeline_failed）。
normalize_files() {   # $1=files|base|show；其餘＝路徑
  local mode=$1 f; shift
  for f in "$@"; do
    case "$mode" in
      files) normalize < "$f" ;;
      base)  git diff "$base...HEAD" -- "$f" | sed -n '/^@@/,$p' | sed -n 's/^+//p' | normalize ;;
      show)  git show "$base:$f" | normalize ;;
    esac || { echo "✗ migration-breaking-check：$mode $f 讀取或正規化失敗，不靜默放行" >&2; exit 1; }
    printf '\n'
  done
}

# 把逐行清單讀進陣列（bash 3.2 無 mapfile）
to_array() { paths=(); local f; while IFS= read -r f; do [ -n "$f" ] && paths+=("$f"); done <<< "$1"; }

if [ -n "$base" ]; then
  cd "$(git rev-parse --show-toplevel)" || exit 1
  consumer_root=$(pwd)
  known_file="$tmpdir/known_functions"
  # R3 G1：core.quotePath 預設會把非 ASCII 檔名輸出成加引號的 C-escape，餵回 pathspec 對不上 → 該檔靜默跳過；
  # 兩處「輸出路徑」的 git 指令都關掉（逐檔 diff／show 是「吃路徑」，不受影響）
  base_files=$(git -c core.quotePath=false ls-tree -r --name-only "$base" -- supabase/migrations/) \
    || { echo "✗ migration-breaking-check：git ls-tree $base 失敗" >&2; exit 1; }
  to_array "$base_files"
  if [ "${#paths[@]}" -gt 0 ]; then
    normalize_files show "${paths[@]}" | fn_name "$FN_DEF" | sort -u > "$known_file" || pipeline_failed
    # LS-181：既有 enum 值集合同樣自 base 取（B7 消費端掃描用）
    normalize_files show "${paths[@]}" | enum_defs >> "$known_enums" || pipeline_failed
  else
    : > "$known_file"
  fi
  changed=$(git -c core.quotePath=false diff --name-only "$base...HEAD" -- supabase/migrations/) \
    || { echo "✗ migration-breaking-check：git diff --name-only $base...HEAD 失敗" >&2; exit 1; }
  to_array "$changed"
  if [ "${#paths[@]}" -gt 0 ]; then
    normalize_files base "${paths[@]}" | classify || pipeline_failed
  fi
  exit 0
fi

if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "✗ migration-breaking-check：讀不到 $f" >&2; exit 1; }
  done
  normalize_files files "${files[@]}" | classify || pipeline_failed
else
  normalize | classify || pipeline_failed
fi
exit 0
