#!/bin/bash
# design-notes-check.sh 的自測（LS-168）。CI rules job「Gate 腳本自測」step 跑。
# 合成 git repo＋合成 .pen（Notes 板＝頂層 frame 名稱含「實作註記」），三案＋mutation：
#   ① 活 id（Notes 引用的節點還在）→ 綠
#   ② 死 id（本 PR 刪了節點、Notes 仍現在式引用）→ 紅，訊息列「板／節點／缺失 id」
#   ③ 沿革標記死 id（同子句有「原」「已刪除」「取代舊」「→」）→ 綠並印（沿革）行
#   ④ mutation：整句有「原」但死 id 在另一個子句（oYEi0 段「（原 X）…新 id 為 Y」的真實形狀）→ 仍紅（子句級，非整句級）
#   ⑤ 形狀像 id 的英文字（height／Layout／false）從未是節點 id → 不誤判（綠）
#   ⑥ 別票早在 merge-base 之前刪掉的 id（不在本 PR 範圍候選集）→ 不擋（綠）
#   ⑦ 本 PR 中間 commit 建了又在後一 commit 刪掉的 id、Notes 仍引用 → 紅（候選集含範圍內每個 .pen commit，不只 merge-base）
#   ⑩ merge-review R1 N3：「→」不再是子句級標記——同子句有數字轉場「1134→1031」但死 id 不緊鄰箭頭 → 仍紅（修前放行）
#   ⑪ 「舊→新」只放行箭頭左側：兩側都死時左側 Xk9f2 印沿革、右側 Zq7Lm 紅（右側是現行 id、必須存在）
#   ⑧ --head-sha 指定 PR head（CI merge ref 情境，同 LS-127）→ 依該 head 判定；解析不到／缺值 → exit 2
#   ⑨ 參數 fail closed：缺 --base／找不到 .pen／非 git 目錄 → exit 2
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/design-notes-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

expect() {
  # expect <期望 exit> <名稱> <輸出必含|''> <輸出必不含|''> <參數…>
  local want=$1 name=$2 must=$3 mustnot=$4 out got
  shift 4
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; } && { [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}${mustnot:+、輸出不含「${mustnot}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# pen <頂層節點 JSON 片段…>：組成合成 .pen（version＋children）
pen() {
  local body
  body=$(IFS=,; printf '%s' "$*")
  printf '{"version":"2.17","children":[%s]}\n' "$body" > "$R/design/littlesprout.pen"
}
# board <id> <name> <子節點 JSON 片段>
board() { printf '{"type":"frame","id":"%s","name":"%s","children":[%s]}' "$1" "$2" "$3"; }
# notes <textId> <content>：一塊 Notes 板（id NOTES）含一個 text 節點
notes() { board NOTES "LS-1 / 實作註記 · Handoff Notes" "{\"type\":\"text\",\"id\":\"$1\",\"name\":\"l\",\"content\":\"$2\"}"; }
commit_pen() { g add design/littlesprout.pen; g commit -qm "$1"; }

mkdir -p "$R/design"
g init -q -b main
# base：板 Ab12C 含子節點 Xk9f2、Zq7Lm；另一塊舊板 OLDID 在 base 之前就被刪（這裡直接不存在）；Notes 引用 Xk9f2
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Xk9f2","name":"Row"},{"type":"frame","id":"Zq7Lm","name":"Row 2"}')" "$(notes T1 '列 Xk9f2 高 44；別票舊 id OLDID 早已不存在')"
commit_pen base
base_ref="$(g rev-parse HEAD)"

# ① 活 id → 綠
g checkout -q -b pr-live "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Xk9f2","name":"Row"},{"type":"frame","id":"Zq7Lm","name":"Row 2"},{"type":"frame","id":"Nw3Pq","name":"Row 3"}')" "$(notes T1 '列 Xk9f2 高 44、新增列 Nw3Pq 高 60（height 沿用 Layout 預設，false）')"
commit_pen 'design(pen): LS-1 r1'
expect 0 '① Notes 引用的 id 都在 head 快照 → 綠' '缺失 0' '' design/littlesprout.pen --base "$base_ref"
expect 0 '⑤ 形狀像 id 的英文字（height／Layout／false）從未是節點 id → 不誤判' '缺失 0' '缺失 id height' design/littlesprout.pen --base "$base_ref"
expect 0 '⑥ 別票早在 merge-base 之前就刪掉的 id（OLDID）不在候選集 → 不擋' '缺失 0' 'OLDID' design/littlesprout.pen --base "$base_ref"

# ② 死 id：本 PR 刪了 Xk9f2、Notes 仍現在式引用 → 紅
g checkout -q -b pr-dead "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Zq7Lm","name":"Row 2"}')" "$(notes T1 '列 Xk9f2 高 44；列 Zq7Lm 高 60')"
commit_pen 'design(pen): LS-1 r2 刪 Row 但 Notes 沒改'
expect 1 '② 本 PR 刪掉的 id 仍被 Notes 現在式引用 → 紅，列板／節點／缺失 id' '板 NOTES（LS-1 / 實作註記 · Handoff Notes）／節點 T1／缺失 id Xk9f2' '' design/littlesprout.pen --base "$base_ref"

# ③ 沿革標記：同子句「原」「已刪除」「取代舊」「→」→ 綠（四種寫法各一個死 id）
g checkout -q -b pr-history "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Zq7Lm","name":"Row 2"}')" "$(notes T1 '原 Xk9f2 已於 R2 刪除重建；Row 現為 Zq7Lm（取代舊 Xk9f2）；Xk9f2→Zq7Lm；當時的 id 為 Xk9f2')"
commit_pen 'design(pen): LS-1 r2 刪 Row，Notes 用沿革標記'
expect 0 '③ 死 id 所在子句含沿革標記（原／取代舊／→／當時）→ 綠並印沿革行' '（沿革）板 NOTES' '缺失 id' design/littlesprout.pen --base "$base_ref"

# ④ mutation：整句含「原」但死 id 在另一個子句（現在式活指標）→ 仍紅
g checkout -q -b pr-clause "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Nw3Pq","name":"Row 3"}')" "$(notes T1 '參考板（原 Xk9f2）在重構後刪除重建，新 id 為 Zq7Lm（iPhone）')"
commit_pen 'design(pen): LS-1 r2 Zq7Lm 也被刪了、Notes 仍以現在式指它'
expect 1 '④ 整句有「原」但死 id Zq7Lm 在無標記的子句「新 id 為 Zq7Lm」→ 仍紅（子句級白名單）' '缺失 id Zq7Lm' '缺失 id Xk9f2' design/littlesprout.pen --base "$base_ref"

# ⑦ 本 PR 中間 commit 建了 Tmp9Z、下一 commit 刪掉，Notes 仍引用 → 紅（候選集含範圍內每個 .pen commit）
g checkout -q -b pr-transient "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Xk9f2","name":"Row"},{"type":"frame","id":"Zq7Lm","name":"Row 2"},{"type":"frame","id":"Tmp9Z","name":"Row 3"}')" "$(notes T1 '列 Tmp9Z 高 60')"
commit_pen 'design(pen): LS-1 r1 加 Row 3'
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Xk9f2","name":"Row"},{"type":"frame","id":"Zq7Lm","name":"Row 2"}')" "$(notes T1 '列 Tmp9Z 高 60')"
commit_pen 'design(pen): LS-1 r2 又刪 Row 3，Notes 沒改'
expect 1 '⑦ 範圍內中間 commit 建又刪的 id（不在 merge-base 也不在 head）→ 仍紅' '缺失 id Tmp9Z' '' design/littlesprout.pen --base "$base_ref"
# 若候選集只看 merge-base（退化），Tmp9Z 抓不到——上面這格就是釘住它的 mutation 負控

# ⑩ R1 N3：子句含「→」但死 id 不緊鄰箭頭（數字轉場）→ 紅。修前 HISTORY_MARKERS 含 → 時整個子句放行（development 60 個此形引用位置）
g checkout -q -b pr-arrow-far "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Zq7Lm","name":"Row 2"}')" "$(notes T1 '板高 Xk9f2：1134→1031，Row 現為 Zq7Lm')"
commit_pen 'design(pen): LS-1 r2 刪 Row，Notes 同子句只有數字轉場箭頭'
expect 1 '⑩ 子句含「→」但死 id 不緊鄰箭頭（數字轉場 1134→1031）→ 紅（→ 不是子句級標記）' '缺失 id Xk9f2' '（沿革）' design/littlesprout.pen --base "$base_ref"

# ⑪ 「舊→新」兩側都死：左側 Xk9f2 緊鄰箭頭 → 沿革放行；右側 Zq7Lm 是「現行 id」→ 紅
g checkout -q -b pr-arrow-right "$base_ref"
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Nw3Pq","name":"Row 3"}')" "$(notes T1 'Row 改版：Xk9f2→Zq7Lm')"
commit_pen 'design(pen): LS-1 r2 兩個 Row 都刪了、Notes 箭頭右側指向死 id'
expect 1 '⑪ 「舊→新」右側的新 id 已死 → 紅，左側舊 id 印沿革（只放行箭頭左側）' '缺失 id Zq7Lm' '缺失 id Xk9f2' design/littlesprout.pen --base "$base_ref"
out="$(cd "$R" && bash "$check" design/littlesprout.pen --base "$base_ref" 2>&1)"
if printf '%s' "$out" | grep -qF '（沿革）板 NOTES（LS-1 / 實作註記 · Handoff Notes）／節點 T1／舊 id Xk9f2'; then echo "✓ ⑪ 左側 Xk9f2 印沿革行"; else echo "✗ ⑪ 左側 Xk9f2 應印沿革行" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ⑧ --head-sha：在 pr-dead 之後再開一個 commit 模擬 merge ref；指定 PR head＝pr-dead 的 commit 仍紅；指向修正後的 commit 綠
dead_head="$(g rev-parse pr-dead)"
g checkout -q pr-dead
pen "$(board Ab12C '01 板' '{"type":"frame","id":"Zq7Lm","name":"Row 2"}')" "$(notes T1 '列 Zq7Lm 高 60（原 Xk9f2 已刪除）')"
commit_pen 'design(pen): LS-1 r3 Notes 改沿革'
fixed_head="$(g rev-parse HEAD)"
expect 1 '⑧ --head-sha 指向仍有死 id 的 commit → 紅（以該 head 判定，不看工作區 HEAD）' '缺失 id Xk9f2' '' design/littlesprout.pen --base "$base_ref" --head-sha "$dead_head"
expect 0 '⑧ --head-sha 指向已改沿革的 commit → 綠' '缺失 0' '' design/littlesprout.pen --base "$base_ref" --head-sha "$fixed_head"
expect 2 '⑧ --head-sha 解析不到 → exit 2' '不是可解析的 commit' '' design/littlesprout.pen --base "$base_ref" --head-sha 0000000000000000000000000000000000000000
expect 2 '⑧ --head-sha 缺值 → exit 2' '--head-sha 缺值' '' design/littlesprout.pen --base "$base_ref" --head-sha

# ⑨ 參數 fail closed
expect 2 '⑨ 缺 --base → exit 2' '缺 --base' '' design/littlesprout.pen
expect 2 '⑨ 找不到 .pen → exit 2' '找不到' '' design/nope.pen --base "$base_ref"
out="$(cd "$work" && bash "$check" "$R/design/littlesprout.pen" --base "$base_ref" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '不在 git 目錄內'; then echo "✓ ⑨ 非 git 目錄 → exit 2"; else echo "✗ ⑨ 非 git 目錄（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "design-notes-check.test.sh：全數通過"
else
  echo "design-notes-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
