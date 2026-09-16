#!/bin/bash
# design-identity-header-check.sh 的自測（LS-309 C）。CI rules job「Gate 腳本自測」step 跑。
# 合成 git repo＋合成 .pen（板本身的 text 節點，不透過 cmp/Card Album／cmp/Card Diary 元件——這正是本 gate
# 要補的缺口：既有 design-notes-check.sh 的署名 NBSP 檢查只掃那兩個元件，板自己的節點掃不到）：
#   ① 正：觸碰板的「N 歲 N 個月」與「N 個月」兩種樣式皆用正確 codepoint（三個 U+00A0＋一個 U+2060）→ 綠
#   ② 負：觸碰板的年齡字串分隔退化成一般空白 U+0020（LS-252 R3 實測踩過的錯法之一）→ 紅，列板／節點／片段／分隔
#   ③ 負：觸碰板的年齡字串分隔整個缺失（LS-252 R3 實測另一種錯法：「歲」與下一個數字之間直接相接）→ 紅
#   ④ 未觸碰板上的既有違規（他票舊債）→ 不擋（這支只驗本 PR 觸碰的板，不像 design-notes-check.sh 的署名 NBSP
#     檢查那樣印「（舊債）」警告——範圍本身就限定觸碰板，未觸碰板完全不進 identity_header_hits()）
#   ⑤ ref 實例 descendants content 覆寫也掃得到（不是只有直接 text 節點）
#   ⑥ 參數 fail closed：缺 --base／找不到 .pen／非 git 目錄 → exit 2
#   ⑦ --head-sha 指定 PR head（同 design-notes-check.sh 的 LS-127 案例）
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/design-identity-header-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

source "${root}/scripts/gates/lib/selftest-helpers.sh"

expect() {
  # expect <期望 exit> <名稱> <輸出必含|''> <輸出必不含|''> <參數…>
  local want=$1 name=$2 must=$3 mustnot=$4 out got
  shift 4
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || has "$out" "$must"; } && { [ -z "$mustnot" ] || ! has "$out" "$mustnot"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}${mustnot:+、輸出不含「${mustnot}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# NBSP／WJ 用實際字元（不是跳脫序列，避免正／負樣本自己也寫錯）
NBSP=$' '
WJ=$'⁠'
GOOD_FULL="2${NBSP}歲${NBSP}3${NBSP}個${WJ}月"       # 「2 歲 3 個⁠月」，與 zk1yE 逐 codepoint 相同
GOOD_MONTHS="8${NBSP}個${WJ}月"                        # 「8 個⁠月」不足一歲的樣式
BAD_SPACE_FULL="2 歲 3 個${WJ}月"                       # 分隔退化成一般空白 U+0020（LS-252 R3 錯法之一）
BAD_MISSING_FULL="2歲3個${WJ}月"                        # 分隔整個不見（LS-252 R3 另一種錯法）

# pen <頂層節點 JSON 片段…>：組成合成 .pen
pen() {
  local body
  body=$(IFS=,; printf '%s' "$*")
  printf '{"version":"2.17","children":[%s]}\n' "$body" > "$R/design/littlesprout.pen"
}
# board <id> <name> <子節點 JSON 片段>
board() { printf '{"type":"frame","id":"%s","name":"%s","children":[%s]}' "$1" "$2" "$3"; }
# text <id> <content>
text() { printf '{"type":"text","id":"%s","name":"Age","content":%s}' "$1" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")"; }
# ref_with_override <refId> <ref元件id> <descId> <content>：帶 descendants 覆寫的 ref 實例
ref_with_override() { printf '{"type":"ref","id":"%s","ref":"%s","name":"Instance","descendants":{"%s":{"content":%s}}}' "$1" "$2" "$3" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$4")"; }
commit_pen() { g add design/littlesprout.pen; g commit -qm "$1"; }

mkdir -p "$R/design"
g init -q -b main
# base：一塊無關的板，Identity 板尚不存在
pen "$(board Other '其他板' '')"
commit_pen base
base_ref="$(g rev-parse HEAD)"

# ① 正：新增 Identity 板，兩個 text 節點各一種樣式，皆正確 codepoint → 綠
g checkout -q -b pr-good "$base_ref"
pen "$(board Other '其他板' '')" "$(board Identity01 'Growth / 01 最新值卡' "$(text T1 "$GOOD_FULL")","$(text T2 "$GOOD_MONTHS")")"
commit_pen 'design(pen): LS-309 r1 good'
expect 0 '① 觸碰板年齡字串皆正確 codepoint（N歲N個月＋N個月兩種樣式）→ 綠' '違規 0' '' design/littlesprout.pen --base "$base_ref"

# ② 負：分隔退化成一般空白 U+0020 → 紅，列板／節點／片段
g checkout -q -b pr-space "$base_ref"
pen "$(board Other '其他板' '')" "$(board Identity01 'Growth / 01 最新值卡' "$(text T1 "$BAD_SPACE_FULL")")"
commit_pen 'design(pen): LS-309 r1 bad-space'
expect 1 '② 分隔退化成一般空白 U+0020 → 紅，列板／節點／片段／分隔' '板 Identity01（Growth / 01 最新值卡）／節點 T1' '' design/littlesprout.pen --base "$base_ref"
expect 1 '② 訊息含命中片段與分隔說明（U+0020）' 'U+0020' '' design/littlesprout.pen --base "$base_ref"

# ③ 負：分隔整個缺失 → 紅
g checkout -q -b pr-missing "$base_ref"
pen "$(board Other '其他板' '')" "$(board Identity01 'Growth / 01 最新值卡' "$(text T1 "$BAD_MISSING_FULL")")"
commit_pen 'design(pen): LS-309 r1 bad-missing'
expect 1 '③ 分隔整個缺失（歲與數字直接相接）→ 紅' '(缺)' '' design/littlesprout.pen --base "$base_ref"

# ④ 未觸碰板上的既有違規（他票舊債）→ 不擋——PR 只新增 Other2，不動 Identity01（本輪維持 base 的錯誤版本）
g checkout -q -b pr-old-debt "$base_ref"
pen "$(board Other '其他板' '')" "$(board Identity01 'Growth / 01 最新值卡' "$(text T1 "$BAD_SPACE_FULL")")"
commit_pen 'design(pen): base 上先有錯誤版本（模擬已存在的舊債）'
old_debt_base="$(g rev-parse HEAD)"
pen "$(board Other '其他板' '')" "$(board Identity01 'Growth / 01 最新值卡' "$(text T1 "$BAD_SPACE_FULL")")" "$(board Other2 '不相干的新板' '')"
commit_pen 'design(pen): 本 PR 只新增 Other2，沒有動 Identity01'
expect 0 '④ 未觸碰板（Identity01）上的既有違規是他票舊債 → 不擋（這支範圍限定觸碰板，非「（舊債）」警告，直接不進命中清單）' '違規 0' 'Identity01' design/littlesprout.pen --base "$old_debt_base"

# ⑤ ref 實例 descendants content 覆寫也掃得到
g checkout -q -b pr-ref-override "$base_ref"
pen "$(board Other '其他板' '')" "$(board Identity01 'Growth / 01 最新值卡' "$(ref_with_override RInst CompId DescT "$BAD_SPACE_FULL")")"
commit_pen 'design(pen): LS-309 r1 ref override bad'
expect 1 '⑤ ref 實例 descendants content 覆寫（不是直接 text 節點）也掃得到 → 紅' '實例 RInst override DescT' '' design/littlesprout.pen --base "$base_ref"

# ⑤b Notes 板（實作註記，`NOTES_NAME_RE` 命中）內提到年齡的散文（一般空白，正確的中文標點寫法）→ 不算違規
#     （LS-252 實測：h5BNyi「今天年齡＝1 歲 4 個月＝16 個月大」這類句子若不排除 Notes 板會被誤判——那是
#     文件散文，不是 UI 節點，逐 codepoint 比對散文不合理）
g checkout -q -b pr-notes-prose "$base_ref"
pen "$(board Other '其他板' '')" "$(board NotesBoard 'Growth / 實作註記 · Handoff Notes (ios-dev)' "$(text NT1 '今天年齡＝1 歲 4 個月＝16 個月大')")"
commit_pen 'design(pen): LS-309 r1 notes prose 年齡散文（一般空白，正確中文寫法）'
expect 0 '⑤b Notes 板（實作註記）內的年齡散文（一般空白）不算違規——那是文件散文不是 UI 節點' '違規 0' 'NT1' design/littlesprout.pen --base "$base_ref"

# ⑥ 參數 fail closed
out="$(cd "$R" && bash "$check" design/littlesprout.pen 2>&1)"; got=$?
if [ "$got" -eq 2 ]; then echo '✓ ⑥a 缺 --base → exit 2'; else echo "✗ ⑥a 應 exit 2（實得 ${got}）" >&2; fail=1; fi
out="$(cd "$R" && bash "$check" design/nope.pen --base "$base_ref" 2>&1)"; got=$?
if [ "$got" -eq 2 ]; then echo '✓ ⑥b 找不到 .pen → exit 2'; else echo "✗ ⑥b 應 exit 2（實得 ${got}）" >&2; fail=1; fi
out="$(cd "$work" && bash "$check" "$R/design/littlesprout.pen" --base "$base_ref" 2>&1)"; got=$?
if [ "$got" -eq 2 ]; then echo '✓ ⑥c 非 git 目錄 → exit 2'; else echo "✗ ⑥c 應 exit 2（實得 ${got}）" >&2; fail=1; fi

# ⑦ --head-sha 指定 PR head（LS-127 情境）
head_sha_for_good="$(g rev-parse pr-good)"
expect 0 '⑦ --head-sha 指定 PR head → 依該 head 判定，綠' '違規 0' '' design/littlesprout.pen --base "$base_ref" --head-sha "$head_sha_for_good"

if [ "$fail" -ne 0 ]; then
  echo "✗ design-identity-header-check 自測失敗" >&2
  exit 1
fi
echo "✓ design-identity-header-check 自測通過"
