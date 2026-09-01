#!/bin/bash
# design-evidence-check.sh 的自測（LS-68 規則 4）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成收據缺失也放行、head_sha 不比對、total_nodes 不比對、
# 或漏掉兩支掃描（兄弟交集／橫列溢出）任一支沒輸出也放行，這裡會紅——每條斷言都至少有一個 mutant 能證明它會紅
# （LS-65 教訓：gate 不能只驗過正向樣本）。
#
# head_sha 驗的是「這個 sha 是不是本 PR 自己對這份 .pen 的其中一次 commit」（不是等於 PR 最終 head sha——
# 一個 commit 不可能把自己最終的 sha 寫進自己的內容裡，見 design-evidence-check.sh 檔頭說明）。正向樣本
# 因此用兩支分開的 commit：先落地 .pen（commit A）、記下它的 sha，再另開一支 commit 加收據引用 sha A。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/design-evidence-check.sh"
landing="${root}/scripts/gates/design-landing-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <checker 參數…>
expect() {
  local want=$1 name=$2 must=$3 out got
  shift 3
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

mkdir -p "$R/design"
g init -q -b main
# 3 個節點的合成 .pen（design-landing-check.sh --print-nodes 應算出 3）
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm base
base_ref="$(g rev-parse HEAD)"

nodes="$(bash "$landing" "$R/design/littlesprout.pen" --print-nodes)"
if [ "$nodes" != "3" ]; then
  echo "✗ 前置條件：design-landing-check --print-nodes 應回 3，實得 ${nodes}（自測環境異常）" >&2
  exit 1
fi

write_receipt() {
  # write_receipt <path> <head_sha> <total_nodes> <sibling_classified 0/1> <row_classified 0/1> <include_row 0/1>
  local path=$1 sha=$2 n=$3 sib_ok=$4 row_ok=$5 include_row=$6
  local sib_item row_scan
  if [ "$sib_ok" = 1 ]; then
    sib_item='{"node_a":"a","node_b":"b","classification":"acceptable-overlap"}'
  else
    sib_item='{"node_a":"a","node_b":"b"}'
  fi
  if [ "$include_row" = 1 ]; then
    if [ "$row_ok" = 1 ]; then
      row_scan='"row_overflow":{"flagged":[{"node":"c","classification":"content-fits"}]},'
    else
      row_scan='"row_overflow":{"flagged":[{"node":"c"}]},'
    fi
  else
    row_scan=''
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{"ticket":"LS-67","round":1,"head_sha":"${sha}","total_nodes":${n},
 "scans":{${row_scan}"sibling_intersection":{"flagged":[${sib_item}]}}}
EOF
}

# ① 正向樣本：兩支分開的 commit——先落地 .pen（commit A，記下 sha），再另開一支 commit 加收據引用 sha A
g checkout -q -b pr-ok "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地'
land_sha="$(g rev-parse HEAD)"
land_nodes="$(bash "$landing" "$R/design/littlesprout.pen" --print-nodes)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$land_sha" "$land_nodes" 1 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據'
expect 0 '① 兩支分開 commit：收據 head_sha＝落地那支 commit、節點數相符、兩支掃描皆有分類 → 綠' '' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ② 完全沒有收據 → 紅，訊息提示規則 4
g checkout -q -b pr-missing "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": []}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地但沒補收據'
expect 1 '② 完全沒有收據 → 紅' '找不到' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ③ head_sha 不是本 PR 對這份 .pen 的 commit（用 base_ref 本身——真實存在的 commit，但在 base..HEAD 範圍外）→ 紅
g checkout -q -b pr-badsha "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地'
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$base_ref" 4 1 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（sha 指向 base，不是本 PR 的 commit）'
expect 1 '③ head_sha 指向 base（範圍外的 commit）→ 紅' '不是本 PR 對這份 .pen 的其中一次 commit' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ④ total_nodes 不符 → 紅
g checkout -q -b pr-badnodes "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地'
land_sha4="$(g rev-parse HEAD)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$land_sha4" 99 1 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（節點數不符）'
expect 1 '④ total_nodes 不符 → 紅' 'total_nodes 不符' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑤ FLAGGED 有一筆缺分類 → 紅
g checkout -q -b pr-noclass "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地'
land_sha5="$(g rev-parse HEAD)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$land_sha5" 4 0 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（缺分類）'
expect 1 '⑤ 兄弟交集有一筆缺分類 → 紅' '缺分類' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑥ 只交一支掃描（缺 row_overflow）→ 紅，LS-67 R1 的兩支掃描規則
g checkout -q -b pr-onescanner "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地'
land_sha6="$(g rev-parse HEAD)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$land_sha6" 4 1 1 0
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（只有一支掃描）'
expect 1 '⑥ 只交 sibling_intersection、缺 row_overflow → 紅' 'scans.row_overflow 缺失' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑦ 收據 JSON 壞掉 → 紅（不是假綠、也不是腳本自己炸掉噴一堆 traceback）
g checkout -q -b pr-badjson "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地'
mkdir -p "$R/design/evidence"
printf '{not json' > "$R/design/evidence/LS-67-r1-overflow.json"
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（壞 JSON）'
expect 1 '⑦ 收據 JSON 壞掉 → 紅' '讀取／解析失敗' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑧ 參數錯誤 fail closed：缺 --ticket／--base／票號格式錯／找不到 .pen
g checkout -q "$base_ref"
expect 2 '⑧ 缺 --ticket → exit 2' '缺 --ticket' \
  "$R/design/littlesprout.pen" --base "$base_ref"
expect 2 '⑧ 缺 --base → exit 2' '缺 --base' \
  "$R/design/littlesprout.pen" --ticket LS-67
expect 2 '⑧ --ticket 格式錯 → exit 2' '不是 LS-<n> 格式' \
  "$R/design/littlesprout.pen" --ticket bogus --base "$base_ref"
expect 2 '⑧ 找不到 .pen 檔 → exit 2' '找不到' \
  "$R/design/does-not-exist.pen" --ticket LS-67 --base "$base_ref"

if [ "$fail" -eq 0 ]; then
  echo "design-evidence-check.test.sh：全數通過"
else
  echo "design-evidence-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
