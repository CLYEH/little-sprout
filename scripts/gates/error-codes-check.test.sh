#!/bin/bash
# error-codes-check.sh 的自測（LS-54 N4′）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：抽取規則若退化（例如抽到空集合卻綠、只查單向、
# 把散文裡的碼也抽進來），這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/error-codes-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

api_doc() {  # $1=輸出路徑 $2...=要放進 §5 表格的碼（可零個）
  local out=$1; shift
  {
    echo '## 4. RPC 逐支文件'
    echo '§4 散文提到 `LS777` 不算數。'
    echo '## 5. 錯誤碼全表'
    echo '§5 散文提到 `LS888` 也不算數，只認表格列。'
    echo '| 碼 | 意義 | 觸發 |'
    echo '|---|---|---|'
    for c in "$@"; do echo "| \`$c\` | 意義 | 路徑 |"; done
    echo '## 6. 下一節'
    echo '| `LS999` | 在 §6 的表格列，不算數 |'
  } > "$out"
}

swift_enum() {  # $1=輸出路徑 $2...=rawValue（可零個）
  local out=$1; shift
  {
    echo 'enum LSErrorCode: String, CaseIterable {'
    local i=0
    for c in "$@"; do echo "    case code$i = \"$c\""; i=$((i + 1)); done
    echo '}'
  } > "$out"
}

# expect <期望 exit code> <樣本名稱> <API.md> <swift>
expect() {
  local want=$1 name=$2 doc=$3 swift=$4 out got
  out="$(bash "$checker" "$doc" "$swift" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "✓ $name"
  else
    echo "✗ $name（期望 exit $want，實得 $got）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ① 一致 → 綠（同時證明 §4／§5 散文的 LS777／LS888 與 §6 表格的 LS999 都沒被抽進來，否則這組會紅）
api_doc "$work/ok.md" LS001 LS010 LS020
swift_enum "$work/ok.swift" LS001 LS010 LS020
expect 0 '① 兩邊一致（散文與他節表格的碼不計入）' "$work/ok.md" "$work/ok.swift"

# ② API.md 有、Swift 沒有 → 紅（PR #60 併入後 LS020-022 的真實形狀）
api_doc "$work/doc_more.md" LS001 LS010 LS020
swift_enum "$work/doc_more.swift" LS001 LS010
expect 1 '② API.md 有、LSErrorCode 沒有' "$work/doc_more.md" "$work/doc_more.swift"

# ③ Swift 有、API.md 沒有 → 紅（幽靈碼）
api_doc "$work/swift_more.md" LS001 LS010
swift_enum "$work/swift_more.swift" LS001 LS010 LS099
expect 1 '③ LSErrorCode 有、API.md 沒有（幽靈碼）' "$work/swift_more.md" "$work/swift_more.swift"

# ④ 任一側抽到空集合 → 紅，不得「兩邊都空＝一致」
api_doc "$work/empty_doc.md"
swift_enum "$work/empty_doc.swift" LS001
expect 1 '④ API.md §5 抽不到任何表格列' "$work/empty_doc.md" "$work/empty_doc.swift"
api_doc "$work/empty_swift.md" LS001
swift_enum "$work/empty_swift.swift"
expect 1 '④ Swift 抽不到任何 rawValue' "$work/empty_swift.md" "$work/empty_swift.swift"

# ⑤ 檔案不存在 → 紅（搬家不得靜默變成跳過）
expect 1 '⑤ 檔案不存在' "$work/nope.md" "$work/ok.swift"

if [ "$fail" -eq 0 ]; then
  echo "✓ error-codes-check 自測通過（6 組樣本）"
fi
exit "$fail"
