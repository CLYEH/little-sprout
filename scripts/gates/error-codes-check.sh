#!/bin/bash
# 錯誤碼對帳 gate（LS-54 N4′）：docs/API.md §5 錯誤碼全表的自訂碼集合 ↔
# LittleSprout/Errors/AppError.swift 裡 LSErrorCode 的 rawValue 集合，必須完全相等。
#
# 為什麼要雙向：LS-49 收尾結論是「逐碼列舉」——API.md 有、Swift 沒有的碼會在
# AppError.map 落到 .server（PR #60 併入後 LS020-022 就是這個狀態，CI 全綠沒人發現）；
# Swift 有、API.md 沒有的碼則是幽靈碼（後端根本不會丟）。兩個方向都不允許。
#
# 抽取規則（刻意窄）：
#   - API.md 側只認 §5（`## 5.` 到下一個 `## `）裡以 `| \`LSnnn\` |` 開頭的表格列，
#     散文提到的碼（例如本節末「已涵蓋 LS020–LS022」）不算，免得文件敘述被當成契約。
#   - Swift 側只認 `= "LSnnn"` 這種 rawValue 指派（AppError.swift 裡只有 LSErrorCode 這麼寫）。
#   - 任一側抽到空集合直接紅（檔案搬走／節名改了／格式改了都不該靜默變成「兩邊都空＝一致」）。
#
# 用法：error-codes-check.sh [path-to-API.md] [path-to-AppError.swift]
# （參數只給自測餵合成檔用；push-gate 與 CI 一律不帶參數走 repo 預設路徑）
set -euo pipefail
export LC_ALL=C  # sort 與 comm 必須同一套 collation

root="$(git rev-parse --show-toplevel)"
api_md="${1:-${root}/docs/API.md}"
swift_file="${2:-${root}/LittleSprout/Errors/AppError.swift}"

for f in "$api_md" "$swift_file"; do
  if [ ! -f "$f" ]; then
    echo "✗ error-codes gate：找不到 ${f}" >&2
    exit 1
  fi
done

doc_codes="$(awk '/^## 5\. /{f=1; next} /^## /{f=0} f' "$api_md" \
  | grep -E '^\|[[:space:]]*`LS[0-9]{3}`[[:space:]]*\|' \
  | grep -oE 'LS[0-9]{3}' | sort -u || true)"
swift_codes="$(grep -oE '=[[:space:]]*"LS[0-9]{3}"' "$swift_file" \
  | grep -oE 'LS[0-9]{3}' | sort -u || true)"

if [ -z "$doc_codes" ]; then
  echo "✗ error-codes gate：${api_md} 的 §5 表格裡抽不到任何 \`LSnnn\` 列——節名或表格格式改了？" >&2
  exit 1
fi
if [ -z "$swift_codes" ]; then
  echo "✗ error-codes gate：${swift_file} 裡抽不到任何 = \"LSnnn\" rawValue——LSErrorCode 搬家或改寫法了？" >&2
  exit 1
fi

only_doc="$(comm -23 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$swift_codes"))"
only_swift="$(comm -13 <(printf '%s\n' "$doc_codes") <(printf '%s\n' "$swift_codes"))"

if [ -n "$only_doc" ] || [ -n "$only_swift" ]; then
  echo "✗ error-codes gate：docs/API.md §5 錯誤碼表與 LSErrorCode 不一致" >&2
  for c in $only_doc; do
    echo "  - API.md 有、LSErrorCode 沒有（會在 AppError.map 落到 .server）：$c" >&2
  done
  for c in $only_swift; do
    echo "  - LSErrorCode 有、API.md 沒有（幽靈碼）：$c" >&2
  done
  exit 1
fi

echo "✓ error-codes gate 通過：docs/API.md §5 與 LSErrorCode 皆為 $(printf '%s\n' "$doc_codes" | wc -l | tr -d ' ') 個自訂碼且一致"
