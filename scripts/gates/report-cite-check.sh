#!/bin/bash
# scripts/gates/report-cite-check.sh <report.md> [--sample N] — Haiku 日報／核可頁的引據 gate（LS-429）
#
# 「前饋必有反饋」：Haiku 5.5 在 low／medium effort 會「沒驗證就報完成」（官方 Prompting Claude Haiku 5.5），報告裡的每條事實
# 必須能被 orchestrator 反查。規則：
#   - 事實列＝非豁免段落裡的每一行內容：清單列（`- `／`* `／`+ `／`1. `，含縮排）、表格資料列（`|` 開頭、非 `|---` 分隔列、
#     非表頭——表頭＝下一行是 `|---` 分隔列的那一列，同一段落第二張表的表頭也認得），以及一般段落行（R1 m1：Haiku 會把事實寫成段落）。
#   - 每條事實列至少含一個可反查 id：≥7 位且含英文字母的 hex token（Linear comment id 前綴或 git sha；純數字如日期不算）、
#     `#<PR 號>`（≥2 位數），或 `LS-<n>` 且同一行帶整字狀態詞（Done／In Progress／In Review／QA／Ready／Backlog／Canceled／PASS／
#     FAIL／BLOCKED／APPROVE／ITERATE／REQUEST_CHANGES／merged／open／tag／v<版本>；`tagline`／`reopened` 不算，R1 I1）——單獨提到票號不算引據。
#   - 標題含「待使用者」「待裁決」「建議」的段落整段豁免（那是問句與 orchestrator 補的判斷，不是事實）。
#   - 空行、標題、引文（`>`）、程式碼區塊（``` 內）、`|---` 分隔列、表頭不檢查。
#   - `--sample N`：通過時另印「抽驗樣本」N 行——**由本腳本從已查事實列隨機抽**（R1 M1：不能讓受驗的 Haiku 自己挑樣本），
#     orchestrator 對這 N 行反查 id。亂數種子預設 $RANDOM，自測用 CITE_SAMPLE_SEED 釘死。
# exit：0 全部有引據；1 有缺引據的列（逐行印 ✗ 行號＋內容）；2 用法／檔案錯誤。
# 自測：scripts/gates/report-cite-check.test.sh（CI rules job；mutation 拿掉 `# MUT:state-word` 那行的狀態詞條件）。
set -uo pipefail

usage() { echo "用法：bash scripts/gates/report-cite-check.sh <report.md> [--sample N]" >&2; exit 2; }
f=""; sample=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) [ $# -ge 2 ] || usage; case "$2" in ''|*[!0-9]*) echo "✗ --sample 需要正整數，收到「${2}」" >&2; exit 2 ;; esac; sample=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$f" ] || usage; f=$1; shift ;;
  esac
done
[ -n "$f" ] || usage
[ -r "$f" ] || { echo "✗ report-cite-check：讀不到 ${f}" >&2; exit 2; }

STATE_WORDS='Done|In Progress|In Review|QA|Ready|Backlog|Canceled|PASS|FAIL|BLOCKED|APPROVE|ITERATE|REQUEST_CHANGES|merged|open|tag|v[0-9]+\.[0-9]+'
STATE_RE="(^|[^A-Za-z_])(${STATE_WORDS})([^A-Za-z_]|$)"
EXEMPT_RE='(待使用者|待裁決|建議)'

has_id() {  # ≥7 位 hex 且含字母（排除純數字日期／run id），或 #<PR>
  printf '%s' "$1" | grep -Eo '[0-9a-f]{7,}' | grep -q '[a-f]' && return 0
  printf '%s' "$1" | grep -Eq '#[0-9]{2,}'
}

# 先把整檔讀進陣列（bash 3.2 無 mapfile），表頭判定要看下一行
lines=(); total=0
while IFS= read -r line || [ -n "$line" ]; do lines[total]=$line; total=$((total + 1)); done < "$f"

checked_file="$(mktemp)"; trap 'rm -f "$checked_file"' EXIT
bad=0; checked=0; exempt=0; in_code=0; in_exempt=0
i=0
while [ "$i" -lt "$total" ]; do
  line=${lines[i]}; n=$((i + 1)); i=$((i + 1))
  case "$line" in
    '```'*) in_code=$((1 - in_code)); continue ;;
  esac
  [ "$in_code" -eq 1 ] && continue
  # 去掉前導空白後判形狀（縮排子彈也算清單列）
  stripped="${line#"${line%%[![:space:]]*}"}"
  case "$stripped" in
    '') continue ;;
    '#'*)
      if printf '%s' "$stripped" | grep -Eq "$EXEMPT_RE"; then in_exempt=1; else in_exempt=0; fi
      continue ;;
    '>'*) continue ;;
    '|'*)
      case "$stripped" in '|'*'---'*) continue ;; esac
      next=""; [ "$i" -lt "$total" ] && next="${lines[i]}"
      nstripped="${next#"${next%%[![:space:]]*}"}"
      case "$nstripped" in '|'*'---'*) continue ;; esac  # 下一行是分隔列 → 本列是表頭
      ;;
  esac
  if [ "$in_exempt" -eq 1 ]; then exempt=$((exempt + 1)); continue; fi
  checked=$((checked + 1))
  if has_id "$stripped"; then printf '%s\n' "第 ${n} 行：${stripped}" >> "$checked_file"; continue; fi
  if printf '%s' "$stripped" | grep -Eq 'LS-[0-9]+'; then
    if printf '%s' "$stripped" | grep -Eq "$STATE_RE"; then printf '%s\n' "第 ${n} 行：${stripped}" >> "$checked_file"; continue; fi   # MUT:state-word
  fi
  echo "✗ 第 ${n} 行缺引據（需 ≥7 位 hex／#PR／LS-<n>＋狀態詞）：${stripped}"
  bad=$((bad + 1))
done

if [ "$bad" -gt 0 ]; then
  echo "✗ report-cite-check：${bad} 條事實列缺引據（已查 ${checked} 條、豁免 ${exempt} 條）——Haiku 回報只收有 id 的事實，缺的要重跑或改手寫（LS-429）" >&2
  exit 1
fi
echo "✓ report-cite-check：${checked} 條事實列皆有引據（豁免 ${exempt} 條）"
if [ "$sample" -gt 0 ] && [ "$checked" -gt 0 ]; then
  seed="${CITE_SAMPLE_SEED:-$RANDOM}"
  echo "抽驗樣本（${sample} 條，由本腳本隨機抽、seed ${seed}；orchestrator 對每條反查 id）："
  awk -v seed="$seed" 'BEGIN{srand(seed)} {print rand() "\t" $0}' "$checked_file" | sort | head -n "$sample" | cut -f2- | sed 's/^/  /'
fi
exit 0
