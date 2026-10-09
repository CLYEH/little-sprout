#!/bin/bash
# scripts/gates/report-cite-check.sh <report.md> — Haiku 日報／核可頁的引據 gate（LS-429）
#
# 「前饋必有反饋」：Haiku 5.5 在 low／medium effort 會「沒驗證就報完成」（官方 Prompting Claude Haiku 5.5），報告裡的每條事實
# 必須能被 orchestrator 反查。規則：
#   - 事實列＝以 `- `／`* ` 開頭的清單行，或表格資料列（`|` 開頭、非 `|---` 分隔列；標題後第一個表格列視為表頭）。
#   - 每條事實列至少含一個可反查 id：≥7 位且含英文字母的 hex token（Linear comment id 前綴或 git sha；純數字如日期不算）、
#     `#<PR 號>`（≥2 位數），或 `LS-<n>` 且同一行帶狀態詞（Done／In Progress／In Review／QA／Ready／Backlog／Canceled／PASS／
#     FAIL／BLOCKED／APPROVE／ITERATE／REQUEST_CHANGES／merged／open／tag／v<版本>）——單獨提到票號不算引據。
#   - 標題含「待使用者」「待裁決」「建議」的段落整段豁免（那是問句與 orchestrator 補的判斷，不是事實）。
#   - 空行、標題、引文（`>`）、程式碼區塊（``` 內）不檢查。
# exit：0 全部有引據；1 有缺引據的列（逐行印 ✗ 行號＋內容）；2 用法／檔案錯誤。
# 自測：scripts/gates/report-cite-check.test.sh（CI rules job；mutation 拿掉 `# MUT:state-word` 那行的狀態詞條件）。
set -uo pipefail

[ $# -eq 1 ] || { echo "用法：bash scripts/gates/report-cite-check.sh <report.md>" >&2; exit 2; }
f=$1
[ -r "$f" ] || { echo "✗ report-cite-check：讀不到 ${f}" >&2; exit 2; }

STATE_RE='(Done|In Progress|In Review|QA|Ready|Backlog|Canceled|PASS|FAIL|BLOCKED|APPROVE|ITERATE|REQUEST_CHANGES|merged|open|tag|v[0-9]+\.[0-9]+)'
EXEMPT_RE='(待使用者|待裁決|建議)'

has_id() {  # ≥7 位 hex 且含字母（排除純數字日期／run id），或 #<PR>
  printf '%s' "$1" | grep -Eo '[0-9a-f]{7,}' | grep -q '[a-f]' && return 0
  printf '%s' "$1" | grep -Eq '#[0-9]{2,}'
}

bad=0; n=0; checked=0; exempt=0; in_code=0; in_exempt=0; table_header_pending=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  case "$line" in
    '```'*) in_code=$((1 - in_code)); continue ;;
  esac
  [ "$in_code" -eq 1 ] && continue
  case "$line" in
    '#'*)
      if printf '%s' "$line" | grep -Eq "$EXEMPT_RE"; then in_exempt=1; else in_exempt=0; fi
      table_header_pending=1
      continue ;;
    '>'*|'') continue ;;
  esac
  is_fact=0
  case "$line" in
    '- '*|'* '*) is_fact=1 ;;
    '|'*)
      case "$line" in '|'*'---'*) table_header_pending=0; continue ;; esac
      if [ "$table_header_pending" -eq 1 ]; then table_header_pending=0; continue; fi  # 標題後第一個表格列＝表頭
      is_fact=1 ;;
  esac
  [ "$is_fact" -eq 1 ] || continue
  if [ "$in_exempt" -eq 1 ]; then exempt=$((exempt + 1)); continue; fi
  checked=$((checked + 1))
  has_id "$line" && continue
  if printf '%s' "$line" | grep -Eq 'LS-[0-9]+'; then
    if printf '%s' "$line" | grep -Eq "$STATE_RE"; then continue; fi   # MUT:state-word
  fi
  echo "✗ 第 ${n} 行缺引據（需 ≥7 位 hex／#PR／LS-<n>＋狀態詞）：${line}"
  bad=$((bad + 1))
done < "$f"

if [ "$bad" -gt 0 ]; then
  echo "✗ report-cite-check：${bad} 條事實列缺引據（已查 ${checked} 條、豁免 ${exempt} 條）——Haiku 回報只收有 id 的事實，缺的要重跑或改手寫（LS-429）" >&2
  exit 1
fi
echo "✓ report-cite-check：${checked} 條事實列皆有引據（豁免 ${exempt} 條）"
exit 0
