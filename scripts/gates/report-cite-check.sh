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
#   - 標題（`#`+空白）整行是「待使用者（裁決）」「待裁決」「建議」（可帶括號附註）的段落整段豁免（問句、orchestrator 補的判斷）；
#     整行是「風險與查無」「查無」的段落只豁免「句首」為固定缺席句型（無在飛票／無新 comment／無完成票／查無／收集員失敗：無）且無 id
#     的列，帶 id 的列照查照抽（R2 m2／R3 M1：豁免不能靠 Haiku 寫的標題「含」或「開頭含」關鍵字；R3 I3：缺席句不是「含」）。
#   - 空行、標題、引文（`>`）、程式碼區塊（``` 內）、`|---` 分隔列、表頭不檢查。
#   - `--sample N`：通過時另印「抽驗樣本」N 行——**由本腳本從已查事實列隨機抽**（R1 M1：不能讓受驗的 Haiku 自己挑樣本），
#     orchestrator 對這 N 行反查 id。排序鍵由 bash RANDOM 產生（R2 m1：mawk 不理 srand），種子預設 $RANDOM，自測用 CITE_SAMPLE_SEED 釘死。
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
# 豁免只認「標題開頭」是版型固定字（R2 m2：Haiku 寫的標題不能靠「含關鍵字」就整段放行）：
#   整段豁免：標題以 待使用者／待裁決／建議 開頭；缺席句豁免：標題以 風險與查無／查無 開頭，段內只豁免固定的缺席句型，帶 id 的列照查照抽。
# R3 M1：整行比對（可帶括號附註），「建議與在飛」這種以關鍵字開頭的標題不再整段豁免
# 註：多位元組字元不能放進 `[…]` 括號式（C locale 的 grep -E 會逐位元組比對、ubuntu runner 下失配），一律用 `(a|b)` 交替
EXEMPT_FULL_RE='^(待使用者裁決|待使用者|待裁決|建議)((（|\().*)?$'
EXEMPT_ABSENT_RE='^(風險與查無|查無)((（|\().*)?$'
# 缺席句型要在（去掉清單記號與 `lane:x：`／`[lane:x]` 前綴後）整句開頭命中，不是「含」（R3 I3）
ABSENT_LINE_RE='^(- |\* |\+ |[0-9]+\. )?(\[?lane:[a-z]+\]?(：|:)? *)?(本 lane )?(無在飛票|無新 comment|無完成票|查無|收集員失敗：無|失敗：無)'

has_id() {  # ≥7 位 hex 且含字母（排除純數字日期／run id），或 #<PR>
  printf '%s' "$1" | grep -Eo '[0-9a-f]{7,}' | grep -q '[a-f]' && return 0
  printf '%s' "$1" | grep -Eq '#[0-9]{2,}'
}

# 先把整檔讀進陣列（bash 3.2 無 mapfile），表頭判定要看下一行
lines=(); total=0
while IFS= read -r line || [ -n "$line" ]; do lines[total]=$line; total=$((total + 1)); done < "$f"

checked_file="$(mktemp)"; trap 'rm -f "$checked_file" "${checked_file}.keyed"' EXIT
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
      # 標題＝`#`+ 後接空白（R2 m2：`#598 …` 開頭的事實列不是標題）；去掉 # 與空白後看開頭字
      hashes="${stripped%%[^#]*}"; rest="${stripped#"$hashes"}"
      is_heading=0
      case "$rest" in ' '*|'	'*) [ "${#hashes}" -le 6 ] && is_heading=1 ;; esac   # MUT:heading-space
      if [ "$is_heading" -eq 1 ]; then
        title="${rest#"${rest%%[![:space:]]*}"}"
        if printf '%s' "$title" | grep -Eq "$EXEMPT_FULL_RE"; then in_exempt=1
        elif printf '%s' "$title" | grep -Eq "$EXEMPT_ABSENT_RE"; then in_exempt=2
        else in_exempt=0; fi
        continue
      fi
      ;;  # `#598` 這類不是標題，落到下面當事實列
    '>'*) continue ;;
    '|'*)
      case "$stripped" in '|'*'---'*) continue ;; esac
      next=""; [ "$i" -lt "$total" ] && next="${lines[i]}"
      nstripped="${next#"${next%%[![:space:]]*}"}"
      case "$nstripped" in '|'*'---'*) continue ;; esac  # 下一行是分隔列 → 本列是表頭
      ;;
  esac
  if [ "$in_exempt" -eq 1 ]; then exempt=$((exempt + 1)); continue; fi
  if [ "$in_exempt" -eq 2 ] && printf '%s' "$stripped" | grep -Eq "$ABSENT_LINE_RE" && ! has_id "$stripped"; then exempt=$((exempt + 1)); continue; fi
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
  # R2 m1：mawk 不理 srand(seed)、同種子不可重現——排序鍵改由 bash 自己的 RANDOM（RANDOM=seed 可重現）產生
  RANDOM=$seed
  keyed="${checked_file}.keyed"
  : > "$keyed"
  while IFS= read -r l; do printf '%05d\t%s\n' "$RANDOM" "$l" >> "$keyed"; done < "$checked_file"   # 不進管線：子 shell 會重新播種 RANDOM
  sort "$keyed" | head -n "$sample" | cut -f2- | sed 's/^/  /'
  rm -f "$keyed"
fi
exit 0
