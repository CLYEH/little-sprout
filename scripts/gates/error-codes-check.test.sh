#!/bin/bash
# error-codes-check.sh 的自測（LS-54 N4′；LS-56 補硬化的正負對照組）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：抽取規則若退化（例如抽到空集合卻綠、只查單向、
# 把散文裡的碼也抽進來、把註解掉的 case 當存在、把首欄帶註記的列靜默略過、
# 說明欄提到的碼抓成幽靈碼、migrations 那一腳被拿掉），這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/error-codes-check.sh"
fail=0
count=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

is_code() { printf '%s' "$1" | grep -qE '^LS[0-9]{3}$'; }

api_doc() {  # $1=輸出路徑 $2...=§5 表格內容：LSnnn → 標準列；其他字串 → 原樣寫成一行（餵自訂列）
  local out=$1; shift
  {
    echo '## 4. RPC 逐支文件'
    echo '§4 散文提到 `LS777` 不算數。'
    echo '## 5. 錯誤碼全表'
    echo '§5 散文提到 `LS888` 也不算數，只認表格列。'
    echo '| 碼 | 意義 | 觸發 |'
    echo '|---|---|---|'
    local c
    for c in "$@"; do
      if is_code "$c"; then echo "| \`$c\` | 意義 | 路徑 |"; else echo "$c"; fi
    done
    echo '## 6. 下一節'
    echo '| `LS999` | 在 §6 的表格列，不算數 |'
  } > "$out"
}

swift_enum() {  # $1=輸出路徑 $2...=enum 內容：LSnnn → 標準 case 行；其他字串 → 原樣寫成一行
  local out=$1; shift
  {
    echo 'enum LSErrorCode: String, CaseIterable {'
    local i=0 c
    for c in "$@"; do
      if is_code "$c"; then echo "    case code$i = \"$c\""; i=$((i + 1)); else echo "    $c"; fi
    done
    echo '}'
  } > "$out"
}

migrations() {  # $1=輸出目錄 $2...=migration 內容：LSnnn → 標準 raise；其他字串 → 原樣寫成一行
  local dir=$1; shift
  mkdir -p "$dir"
  {
    echo "-- 行註解裡的 errcode = 'LS666' 不算數"
    local c
    for c in "$@"; do
      if is_code "$c"; then echo "  raise exception 'x' using errcode = '$c';"; else echo "$c"; fi
    done
  } > "$dir/0001_synthetic.sql"
}

# expect <期望 exit code> <樣本名稱> <API.md> <swift> <migrations 目錄> [<輸出必須包含的字串>]
# 第 6 個參數用來釘「紅的理由對不對」：修前修後可能同樣是紅，但必須是新規則抓到的那個紅。
expect() {
  local want=$1 name=$2 doc=$3 swift=$4 mig=$5 must=${6:-} out got
  count=$((count + 1))
  out="$(bash "$checker" "$doc" "$swift" "$mig" 2>&1)"
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ $name（期望 exit $want，實得 $got）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  elif [ -n "$must" ] && ! printf '%s\n' "$out" | grep -qF -- "$must"; then
    echo "✗ $name（exit 對了，但輸出缺少「$must」——紅的理由不對）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  else
    echo "✓ $name"
  fi
}

# ① 三方一致 → 綠（同時證明 §4／§5 散文的 LS777／LS888、§6 表格的 LS999、
#    migration 行註解的 LS666 都沒被抽進來，否則這組會紅）
api_doc "$work/ok.md" LS001 LS010 LS020
swift_enum "$work/ok.swift" LS001 LS010 LS020
migrations "$work/ok_mig" LS001 LS010 LS020
expect 0 '① 三方一致（散文、他節表格、migration 行註解的碼不計入）' "$work/ok.md" "$work/ok.swift" "$work/ok_mig"

# ② API.md 有、Swift 沒有 → 紅（PR #60 併入後 LS020-022 的真實形狀）
swift_enum "$work/doc_more.swift" LS001 LS010
expect 1 '② API.md 有、LSErrorCode 沒有' "$work/ok.md" "$work/doc_more.swift" "$work/ok_mig" \
  'LSErrorCode 沒有（會在 AppError.map 落到 .server）：LS020'

# ③ Swift 有、API.md 沒有 → 紅（幽靈碼）
swift_enum "$work/swift_more.swift" LS001 LS010 LS020 LS099
expect 1 '③ LSErrorCode 有、API.md 沒有（幽靈碼）' "$work/ok.md" "$work/swift_more.swift" "$work/ok_mig" \
  'API.md 沒有（幽靈碼）：LS099'

# ④ 任一側抽到空集合 → 紅，不得「都空＝一致」
api_doc "$work/empty_doc.md"
expect 1 '④ API.md §5 抽不到任何表格列' "$work/empty_doc.md" "$work/ok.swift" "$work/ok_mig" '抽不到任何首欄'
swift_enum "$work/empty_swift.swift"
expect 1 '④ Swift 抽不到任何 rawValue' "$work/ok.md" "$work/empty_swift.swift" "$work/ok_mig" '抽不到任何 case'
migrations "$work/empty_mig"
expect 1 '④ migrations 抽不到任何 errcode（只剩行註解）' "$work/ok.md" "$work/ok.swift" "$work/empty_mig" "抽不到任何 errcode"

# ⑤ 檔案／目錄不存在 → 紅（搬家不得靜默變成跳過）
expect 1 '⑤ API.md 不存在' "$work/nope.md" "$work/ok.swift" "$work/ok_mig" '找不到'
expect 1 '⑤ migrations 目錄不存在' "$work/ok.md" "$work/ok.swift" "$work/nope_mig" '找不到 migrations 目錄'

# ⑥ LS-56 F1（Swift 側行首錨定）：註解掉的 case 不算存在 → 紅（修前實測 gate 綠、enum 實缺）
swift_enum "$work/f1_red.swift" LS001 LS010 '// case timelineCursorIncomplete = "LS020"'
expect 1 '⑥ 註解掉的 case 必須紅' "$work/ok.md" "$work/f1_red.swift" "$work/ok_mig" \
  'LSErrorCode 沒有（會在 AppError.map 落到 .server）：LS020'
#    正向對照：註解裡提到的 "LSnnn" 不會被抓成幽靈碼（修前假紅）
swift_enum "$work/f1_green.swift" LS001 LS010 LS020 \
  '// 舊寫法 code = "LS023" 已移除' \
  '/* case retired = "LS024" */'
expect 0 '⑥ 註解裡的 "LSnnn" 不算幽靈碼（正向對照）' "$work/ok.md" "$work/f1_green.swift" "$work/ok_mig"

# ⑦ LS-56 F2（首欄錨定）：首欄帶括號註記的列必須被捕捉（修前整列 grep 靜默略過——危險方向）
api_doc "$work/f2.md" LS001 '| `LS023`（diary_body_too_long） | 相簿不存在 | `set_album_deleted` |'
swift_enum "$work/f2_ok.swift" LS001 LS023
migrations "$work/f2_mig" LS001 LS023
expect 0 '⑦ 首欄帶括號註記的列被捕捉（正向）' "$work/f2.md" "$work/f2_ok.swift" "$work/f2_mig"
swift_enum "$work/f2_miss.swift" LS001
expect 1 '⑦ 首欄帶括號註記的列被捕捉（反向：Swift 缺它必須紅）' "$work/f2.md" "$work/f2_miss.swift" "$work/f2_mig" \
  'LSErrorCode 沒有（會在 AppError.map 落到 .server）：LS023'
#    說明欄引用已有列的碼不計入集合、不誤紅（LS-55 把 LS016 列說明欄寫成「跟 LS010/LS011/LS012 不同」的形狀）
api_doc "$work/f2_desc.md" LS010 LS011 \
  '| `LS016` | 撞碼 | `create_invite`（歸 `retryableSystem`，跟 LS010/LS011 的 `validationRetryable` 不同） |'
swift_enum "$work/f2_desc.swift" LS010 LS011 LS016
migrations "$work/f2_desc_mig" LS010 LS011 LS016
expect 0 '⑦ 說明欄引用已有列的碼不計入集合' "$work/f2_desc.md" "$work/f2_desc.swift" "$work/f2_desc_mig"

# ⑧ LS-56 F2 fail loud：表內出現沒有首欄列的碼，不得靜默略過、也不得誤報成幽靈碼
api_doc "$work/f2_ghost.md" LS001 '| `LS010` | 意義 | 路徑（類似 `LS099`） |'
swift_enum "$work/f2_ghost.swift" LS001 LS010
migrations "$work/f2_ghost_mig" LS001 LS010
expect 1 '⑧ 說明欄提到沒有首欄列的碼 → fail loud' "$work/f2_ghost.md" "$work/f2_ghost.swift" "$work/f2_ghost_mig" '沒有對應首欄列'
api_doc "$work/f2_bad.md" LS001 '| LS010 | 首欄少了反引號 | 路徑 |'
expect 1 '⑧ 首欄格式寫壞（少反引號）→ fail loud' "$work/f2_bad.md" "$work/f2_ghost.swift" "$work/f2_ghost_mig" '沒有對應首欄列'
api_doc "$work/f2_two.md" LS001 '| `LS010`／`LS011` | 一格塞兩個碼 | 路徑 |'
swift_enum "$work/f2_two.swift" LS001 LS010 LS011
migrations "$work/f2_two_mig" LS001 LS010 LS011
expect 1 '⑧ 首欄一格塞兩個碼 → fail loud' "$work/f2_two.md" "$work/f2_two.swift" "$work/f2_two_mig" '沒有對應首欄列'

# ⑨ LS-56 migrations 腳（LS-54 retro 工具缺口）：後端實際 raise 的碼 ↔ §5 表雙向
api_doc "$work/m.md" LS001 LS010
swift_enum "$work/m.swift" LS001 LS010
migrations "$work/m_more" LS001 LS010 LS020
expect 1 '⑨ migrations 有、API.md 沒有（後端會丟但文件沒寫）' "$work/m.md" "$work/m.swift" "$work/m_more" \
  'migrations 有、API.md 沒有（後端會丟但文件沒寫，client 落 .server）：LS020'
migrations "$work/m_less" LS001
expect 1 '⑨ API.md 有、migrations 沒有（後端從不丟）' "$work/m.md" "$work/m.swift" "$work/m_less" \
  'API.md 有、migrations 沒有（後端從不丟的幽靈碼）：LS010'
#    正向對照：errcode 大小寫不拘、空白不拘
migrations "$work/m_case" "  RAISE EXCEPTION 'x' USING ERRCODE='LS001';" "  raise exception 'y' using errcode   =   'LS010';"
expect 0 '⑨ ERRCODE 大小寫／空白不拘（正向對照）' "$work/m.md" "$work/m.swift" "$work/m_case"

if [ "$fail" -eq 0 ]; then
  echo "✓ error-codes-check 自測通過（${count} 組樣本）"
fi
exit "$fail"
