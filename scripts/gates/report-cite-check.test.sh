#!/bin/bash
# report-cite-check.sh 的自測（LS-429）。CI rules job 每個 PR 都跑。
# 若 gate 退化——清單列沒 id 仍綠、`LS-<n>` 單獨提到就算引據、純數字（日期／run id）被當 hex id、表格資料列不檢查、
# 豁免段落擴到下一段、程式碼區塊／引文被當事實、缺檔靜默放行——這裡會紅。
# mutation：把 `# MUT:state-word` 那行換成無條件放行 → ③ 負樣本（LS-<n> 無狀態詞）變綠，證明紅是那條規則造成。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/report-cite-check.sh"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect() {  # expect <期望 rc> <名稱> <輸出必含|''> <md 內容>
  local want=$1 name=$2 must=$3 body=$4 out got
  printf '%s\n' "$body" > "$work/r.md"
  out="$(bash "$check" "$work/r.md" 2>&1)"; got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}；應含「${must}」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
  fi
}

GOOD='# 晨報 2026-10-09

## 狀態表

| 項目 | 值 |
|---|---|
| main | a4cdce8 v0.27.29 |
| open PR | #596 → development |

## 今日 Done
- LS-416 Done（QA R2 PASS 665bfd3f）
- LS-411 Done，設計 PR #589 併 dev

## 在飛
- LS-425 In Progress，VR R1 ITERATE（dff84df8）

## 待使用者
- LS-148 名稱沿用或改名？
- LS-417 第 2 條 a／b／c

```
- 這行在程式碼區塊，沒 id 也不算
```
> - 引文行也不算'
expect 0 '① 合法：表格列、清單列皆有 id；待使用者段與 code／引文豁免' '✓ report-cite-check：5 條事實列皆有引據（豁免 2 條）' "$GOOD"

expect 1 '② 清單列沒任何 id → exit 1 並點出行號' '✗ 第 2 行缺引據' '# 在飛
- LS-425 的設計進行中
- 設計者今天畫了六態'

expect 1 '③ LS-<n> 單獨提到（無狀態詞）不算引據' '✗ 第 2 行缺引據' '# 在飛
- LS-425 設計者今天畫了六態'
expect 0 '③ LS-<n>＋狀態詞算引據' '✓' '# 在飛
- LS-425 In Progress，設計者今天畫了六態'

expect 1 '④ 純數字 token（日期 20261009／run id）不算 hex id' '✗ 第 2 行缺引據' '# 在飛
- 20261009 跑了 run 37874656901，全綠'

expect 1 '⑤ 表格資料列沒 id → 紅；表頭與分隔列不算' '✗ 第 5 行缺引據' '# 狀態表
| 項目 | 值 |
|---|---|
| main | a4cdce8 |
| test | 跟 main 一樣 |'

expect 1 '⑥ 豁免只限標題含待使用者／待裁決／建議的段落，下一段恢復檢查' '✗ 第 4 行缺引據' '## 待使用者
- 要不要改名？
## 風險
- 分類器擋 docker pause，QA 第 2 條沒驗
- 另一條有 id 1a2b3c4d'

out7="$(bash "$check" "$work/none.md" 2>&1)"; got7=$?
if [ "$got7" -eq 2 ]; then echo "✓ ⑦ 檔案不存在 → exit 2"; else echo "✗ ⑦ 檔案不存在應 exit 2（實得 ${got7}）" >&2; fail=1; fi
out8="$(bash "$check" 2>&1)"; got8=$?
if [ "$got8" -eq 2 ]; then echo "✓ ⑧ 無參數 → exit 2"; else echo "✗ ⑧ 無參數應 exit 2（實得 ${got8}）" >&2; fail=1; fi

# mutation：`# MUT:state-word` 那行改成無條件 continue → ③ 負樣本必須變綠
mut="$work/mut.sh"
sed '/# MUT:state-word/s/.*/    continue/' "$check" > "$mut"
if ! grep -q 'MUT:state-word' "$mut" && grep -q 'MUT:state-word' "$check"; then
  echo "✓ mutant 已拿掉狀態詞條件"
  printf '%s\n' '# 在飛
- LS-425 設計者今天畫了六態' > "$work/r.md"
  outm="$(bash "$mut" "$work/r.md" 2>&1)"; gotm=$?
  if [ "$gotm" -eq 0 ]; then echo "✓ mutant：③ 負樣本變綠（狀態詞規則確實是原因）"; else echo "✗ mutant 應 exit 0（實得 ${gotm}）" >&2; printf '%s\n' "$outm" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ mutant 的 sed 未命中（負控本身無效）" >&2; fail=1
fi

[ "$fail" -eq 0 ] && echo "✓ report-cite-check 自測通過"
exit "$fail"
