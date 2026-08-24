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
#     migrations 是 append-only 的歷史紀錄：若日後有碼被後續 migration 退役，這裡會紅、
#     逼著顯式處理（屆時再補退役清單機制），不靜默；已知限制同 LS-34：`/* */` 塊註解不剝。
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
mig_not_doc="$(comm -13 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$mig_codes"))"

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
