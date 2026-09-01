#!/bin/bash
# 錯誤碼對帳 gate（LS-54 N4′；LS-56 硬化＋補 migrations 腳）：三方集合必須完全相等——
#   (a) docs/API.md §5 錯誤碼全表的自訂碼（表格列首欄）
#   (b) LittleSprout/Errors/AppError.swift 裡 LSErrorCode 的 rawValue
#   (c) supabase/migrations/*.sql 裡 `errcode = 'LSnnn'` 實際會 raise 的碼
#
# 為什麼要雙向：LS-49 收尾結論是「逐碼列舉」——API.md 有、Swift 沒有的碼會在
# AppError.map 落到 .server（PR #60 併入後 LS020-022 就是這個狀態，CI 全綠沒人發現）；
# Swift 有、API.md 沒有的碼則是幽靈碼（後端根本不會丟）。兩個方向都不允許。
# migrations 那一腳（LS-56，LS-54 retro 工具缺口）補的是「文件寫了但後端從不丟」與
# 「後端會丟但文件沒寫（client 一樣落 .server）」兩個方向。
#
# 抽取規則（刻意窄；每條都有正負自測釘住，見 error-codes-check.test.sh）：
#   - API.md 側只認 §5（`## 5.` 到下一個 `## `）裡的表格列（以 `|` 起頭的行），取
#     `awk -F'|'` 的第 2 欄（首欄），錨定開頭 `` `LSnnn` ``；碼後面可以接括號註記
#     （例如 `` `LS023`（diary_body_too_long） ``，PR #69 review F2 指出舊版整列 grep
#     會把這種列靜默略過）。說明欄提到的碼不計入集合；散文提到的碼（例如本節末
#     「已涵蓋 LS020–LS022」）也不算，免得文件敘述被當成契約。
#   - fail loud：§5 表格列裡任何位置出現的 `LSnnn`，若沒有以它為首欄的列，直接紅——
#     首欄格式寫壞（少了反引號、一格塞兩個碼）不會被靜默略過；說明欄引用**已有列**的碼
#     （例如 LS016 列提到 LS010/LS011/LS012）則允許。
#   - Swift 側只認 `case <名稱> = "LSnnn"` 這種行首錨定的 rawValue 指派（PR #69 review F1：
#     舊版 `= "LSnnn"` 不分程式碼與註解——註解掉的 `// case x = "LS022"` 仍算存在、
#     註解裡的 `code = "LS023"` 會被抓成幽靈碼）。已知限制：多行 /* */ 塊註解內
#     縮排寫的 case 行仍會被算進去。
#   - migrations 側：剝掉 `--` 行尾註解後，抓 `errcode = 'LSnnn'`（errcode 大小寫不拘）。
#     migrations 是 append-only 的歷史紀錄，這裡取的是歷史**聯集**——兩個方向都要注意：
#     把某碼從 §5／Swift 拿掉、但舊 migration 裡那句 raise 文字還在時，這裡會紅（fail-loud，
#     逼著顯式處理）；反之，若後續 migration 以 `CREATE OR REPLACE FUNCTION` 拿掉了某個
#     raise、卻沒人同步清掉 §5／Swift，舊 migration 仍含該碼文字，三方聯集仍然綠——
#     假綠方向，只能靠下方退役碼白名單顯式登記才會被攔下（見 `retired_mig_codes`）。
#     已知限制同 LS-34：`/* */` 塊註解不剝。
#   - 退役碼白名單（LS-57 R2-b 補的機制，見下方 `retired_mig_codes`）：某支已經合併進
#     main／test、append-only 不能回頭改的 migration 裡，若有 `errcode = 'LSnnn'` 被
#     後續一支新 migration 用 `CREATE OR REPLACE FUNCTION` 覆寫成別的碼，舊檔案裡那句
#     文字仍會被上面的純文字掃描抓到、但後端已經不會再丟這個碼——顯式登記在這裡才能
#     排除，不能不寫任何清單就靜默放過（那樣任何碼消失都測不出來）。清單本身雙向
#     對帳：登記的碼如果又出現在 API.md 裡（代表其實沒有真的退役）一律紅；如果
#     migrations 裡已經找不到這個碼的 errcode 文字了（殭屍條目）也紅，但**這個方向
#     只在走 repo 預設路徑（未傳自訂 migrations 目錄，即 `$3` 為空）時才驗**——
#     self-test 用隔離的合成 migrations 目錄逐案測試三方對帳邏輯本身，那些目錄天生
#     不含任何已登記的退役碼，若不分路徑一律驗殭屍方向，會讓每一個跟退役無關的
#     合成案例都被誤判成「殭屍條目」而炸開（LS-57 R3 F1 修過這個誠實度落差：早期
#     版本檔頭宣稱雙向、程式碼卻只做了一個方向）。
#   - 白名單是**碼層級**的排除，不是檔案層級的（LS-57 R3 F2）：退役碼若重新出現在
#     一支**新**的 migration 裡、卻沒有同步寫回 API.md，這個 gate **不會**擋下來
#     ——白名單只認 `LSnnn` 這個字串本身，不記得它原本是從哪支檔案退役的。這是白名單
#     機制本身的固有代價，不是漏洞：會被影響的只有清單裡登記的那幾個碼（目前只有
#     `LS040`），且只要同時忘了寫進 Swift，`only_swift`／`only_doc` 兩個既有方向
#     仍然會抓到；真的要根治，需要把條目改成綁定「碼＋檔名」而不是只有碼，目前
#     判斷不值得為這一個碼加這層複雜度。
#   - 任一側抽到空集合直接紅（檔案搬走／節名改了／格式改了都不該靜默變成「都空＝一致」）。
#
# 用法：error-codes-check.sh [path-to-API.md] [path-to-AppError.swift] [migrations-dir]
# （參數只給自測餵合成檔用；push-gate 與 CI 一律不帶參數走 repo 預設路徑）
set -euo pipefail
export LC_ALL=C  # sort 與 comm 必須同一套 collation

root="$(git rev-parse --show-toplevel)"
api_md="${1:-${root}/docs/API.md}"
swift_file="${2:-${root}/LittleSprout/Errors/AppError.swift}"
migrations_dir="${3:-${root}/supabase/migrations}"

# 退役碼白名單：見上方註解。只能登記「後端已經不會再丟」的碼——新增一筆前，先確認
# 真的有一支後續 migration 用 CREATE OR REPLACE 把它覆寫掉了，不是單純想讓 gate
# 閉嘴。每筆各佔一行，行尾可以加 `#` 註解說明理由（不影響比對，比對只取 `#` 前的
# 部分並去除頭尾空白）。
retired_mig_codes_raw='
LS040  # LS-66 children 的 family_id 不可變原本用專屬碼，LS-57 R2／I1 對齊三表慣例
       # 改用裸 42501（20260825040000_deletion_attribution.sql 的 CREATE OR REPLACE
       # FUNCTION private.enforce_children_family_immutable()）——原本定義它的
       # 20260825030000_children_write_path_and_soft_delete.sql 已併入 main（PR
       # #102／#103），append-only 不能回頭改，那個檔案裡的
       # errcode = '"'"'LS040'"'"' 文字因此永久留在 migrations 裡。
'
retired_mig_codes="$(printf '%s\n' "$retired_mig_codes_raw" \
  | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^LS[0-9]{3}$' | sort -u || true)"

for f in "$api_md" "$swift_file"; do
  if [ ! -f "$f" ]; then
    echo "✗ error-codes gate：找不到 ${f}" >&2
    exit 1
  fi
done
if [ ! -d "$migrations_dir" ]; then
  echo "✗ error-codes gate：找不到 migrations 目錄 ${migrations_dir}" >&2
  exit 1
fi

table_rows="$(awk '/^## 5\. /{f=1; next} /^## /{f=0} f' "$api_md" \
  | grep -E '^[[:space:]]*\|' || true)"
# 首欄錨定：第 2 欄去掉前導空白後必須以 `LSnnn` 開頭；後面的括號註記等一概允許
doc_codes="$(printf '%s\n' "$table_rows" | awk -F'|' '{print $2}' \
  | grep -oE '^[[:space:]]*`LS[0-9]{3}`' | grep -oE 'LS[0-9]{3}' | sort -u || true)"
# 表內任何位置出現的碼（含說明欄、格式寫壞的首欄），用來 fail loud
doc_mentions="$(printf '%s\n' "$table_rows" | grep -oE 'LS[0-9]{3}' | sort -u || true)"

swift_codes="$(grep -E '^[[:space:]]*case[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*"LS[0-9]{3}"' "$swift_file" \
  | grep -oE '"LS[0-9]{3}"' | grep -oE 'LS[0-9]{3}' | sort -u || true)"

mig_codes="$(cat "$migrations_dir"/*.sql 2>/dev/null | sed 's/--.*//' \
  | grep -ioE "errcode[[:space:]]*=[[:space:]]*'LS[0-9]{3}'" \
  | grep -oE 'LS[0-9]{3}' | sort -u || true)"

if [ -z "$doc_codes" ]; then
  echo "✗ error-codes gate：${api_md} 的 §5 表格裡抽不到任何首欄 \`LSnnn\` 列——節名或表格格式改了？" >&2
  exit 1
fi
uncaptured="$(comm -23 <(printf '%s\n' "$doc_mentions") <(printf '%s\n' "$doc_codes"))"
if [ -n "$uncaptured" ]; then
  echo "✗ error-codes gate：${api_md} §5 表格裡出現了沒有對應首欄列的碼——首欄格式寫壞（少反引號／一格塞兩碼）或說明欄引用了未定義的碼：" >&2
  for c in $uncaptured; do
    echo "  - $c" >&2
  done
  exit 1
fi
if [ -z "$swift_codes" ]; then
  echo "✗ error-codes gate：${swift_file} 裡抽不到任何 case <名稱> = \"LSnnn\" rawValue——LSErrorCode 搬家或改寫法了？" >&2
  exit 1
fi
if [ -z "$mig_codes" ]; then
  echo "✗ error-codes gate：${migrations_dir} 裡抽不到任何 errcode = 'LSnnn'——migrations 搬家或改寫法了？" >&2
  exit 1
fi

only_doc="$(comm -23 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$swift_codes"))"
only_swift="$(comm -13 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$swift_codes"))"
doc_not_mig="$(comm -23 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$mig_codes"))"
mig_not_doc_raw="$(comm -13 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$mig_codes"))"
# 退役碼白名單只排除 mig_not_doc 這一個方向（migrations 裡還留著舊文字、docs 已經
# 不寫它）——其餘三個方向的比對不受白名單影響。
mig_not_doc="$(comm -23 <(printf '%s\n' "$mig_not_doc_raw") <(printf '%s\n' "$retired_mig_codes"))"

# 白名單雙向對帳（比照 65_fk_reverse_index.sql 的 v_known_gaps 慣例）：
#   方向 1（任何路徑都驗）：登記了退役，卻又出現在 API.md §5 裡——代表這個碼其實
#   又在用，白名單的排除反而會遮住一個真正的三方不一致，必須擋下。
retired_but_doc="$(comm -12 <(printf '%s\n' "$retired_mig_codes") <(printf '%s\n' "$doc_codes"))"
if [ -n "$retired_but_doc" ]; then
  echo "✗ error-codes gate：retired_mig_codes 白名單不成立" >&2
  for c in $retired_but_doc; do
    echo "  - 白名單登記退役，但 API.md §5 又把它列回來了（不是真的退役，請從 retired_mig_codes 移除，讓下面的三方對帳正常比對）：$c" >&2
  done
  exit 1
fi

#   方向 2（只在走 repo 預設路徑時驗，見上方檔頭說明）：登記了退役，但 migrations
#   裡其實已經找不到這個碼的 errcode 文字了——清單過期的殭屍條目，放著不清會讓
#   「這個碼消失了」這件事永遠測不出來，且哪天清單被打錯字（例如登記成 `LS004`）
#   也會被悄悄放過。`$3`（自訂 migrations 目錄）為空時才代表這次呼叫走的是 repo
#   真正的 migrations 目錄，self-test 的合成目錄一律會傳 `$3`，天生跳過這段。
if [ -z "${3:-}" ]; then
  retired_stale="$(comm -23 <(printf '%s\n' "$retired_mig_codes") <(printf '%s\n' "$mig_codes"))"
  if [ -n "$retired_stale" ]; then
    echo "✗ error-codes gate：retired_mig_codes 白名單過期" >&2
    for c in $retired_stale; do
      echo "  - 白名單登記退役，但 migrations 裡已經找不到這個 errcode 了（殭屍條目，請從 retired_mig_codes 移除）：$c" >&2
    done
    exit 1
  fi
fi

if [ -n "$only_doc" ] || [ -n "$only_swift" ] || [ -n "$doc_not_mig" ] || [ -n "$mig_not_doc" ]; then
  echo "✗ error-codes gate：docs/API.md §5 錯誤碼表、LSErrorCode、migrations 三方不一致" >&2
  for c in $only_doc; do
    echo "  - API.md 有、LSErrorCode 沒有（會在 AppError.map 落到 .server）：$c" >&2
  done
  for c in $only_swift; do
    echo "  - LSErrorCode 有、API.md 沒有（幽靈碼）：$c" >&2
  done
  for c in $doc_not_mig; do
    echo "  - API.md 有、migrations 沒有（後端從不丟的幽靈碼）：$c" >&2
  done
  for c in $mig_not_doc; do
    echo "  - migrations 有、API.md 沒有（後端會丟但文件沒寫，client 落 .server）：$c" >&2
  done
  exit 1
fi

echo "✓ error-codes gate 通過：docs/API.md §5、LSErrorCode、migrations 三方皆為 $(printf '%s\n' "$doc_codes" | wc -l | tr -d ' ') 個自訂碼且一致"
