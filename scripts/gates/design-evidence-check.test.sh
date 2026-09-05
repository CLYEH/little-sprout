#!/bin/bash
# design-evidence-check.sh 的自測（LS-68 規則 4）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成收據缺失也放行、head_sha 不比對、total_nodes 不比對、
# 或漏掉兩支掃描（兄弟交集／橫列溢出）任一支沒輸出也放行，這裡會紅——每條斷言都至少有一個 mutant 能證明它會紅
# （LS-65 教訓：gate 不能只驗過正向樣本）。
#
# head_sha 驗的是「這個 sha 是不是本 PR 自己對這份 .pen 的其中一次 commit」（不是等於 PR 最終 head sha——
# 一個 commit 不可能把自己最終的 sha 寫進自己的內容裡，見 design-evidence-check.sh 檔頭說明）。正向樣本
# 因此用兩支分開的 commit：先落地 .pen（commit A）、記下它的 sha，再另開一支 commit 加收據引用 sha A。
#
# LS-122：四支掃描 schema——①～⑩ 的兩支收據是「既有收據」（.pen commit 早於 LEGACY_CUTOFF 2026-09-02T04:00Z），
# 靠 GIT_COMMITTER_DATE 釘在 cutoff 之前才綠；⑪～⑳ 驗四支：缺任一支紅、corner_anchor.mismatch>0 紅、計數缺失紅、
# 跨 parent 碰撞缺分類紅、四支齊全且 mismatch=0 綠、**cutoff 之後的 round 1 兩支收據紅**（新票不得沿用舊 schema）、
# **cutoff 之前的 round 6 兩支收據綠**（既有收據不看輪次，merge-review R1 MJ-1）、boards 漏列本 PR 觸碰的頂層節點紅、
# boards 含不存在的 id 紅、unresolved 缺分類紅。
#
# LS-127：㉑～㉕ 驗 CI merge ref（refs/pull/N/merge）與 base 前進——合成 base 分出後改了 .pen 另一頂層節點，再以 commit-tree
# 造雙親合併 commit 模擬 actions/checkout 的 HEAD：不給 --head-sha 仍紅（合併 commit 被當最後一次 .pen commit；形狀確認）、
# 給 --head-sha <PR head> 綠、PR 自己漏列觸碰板仍紅（負控，只點名自己的板）、PR 把 base 併進來後歷史收據仍綠（每份收據以自己的
# 共同祖先為 touched 基準）、--head-sha 解析不到／缺值 exit 2。修前（舊 gate）實跑：㉑ 負控／㉒／㉓／㉔／㉕ 六條紅，證明有鑑別力。
#
# LS-168：㉖～㉛-b 驗 tree_hash／第五支／舊收據放行（LS-171：㉖ 的合成 .pen 含帶 geometry 的 path，㉖-b 以 geometry 省略成 "..." 的雜湊紅）；㉜～㉝（merge-review R1 N1）驗「輪次最高的收據另看 PR head tree」——.pen 最後一次
# 落地時 tree 尚無第五支、之後分支才併入新腳本（不碰 .pen）→ 最新收據缺兩欄位紅（㉜；修前印「舊收據放行」綠）、同 head_sha 用新腳本
# 重跑補齊即綠（㉜-b）、舊輪次 r5 不受 PR head 影響仍放行（㉝）。
#
# LS-185：㉞～㊶ 驗第六支 board_clip＋scan_scope——六支齊全＋scan_scope=document 綠（㉞）／scan_scope=boards 綠（㉞-b）／缺 board_clip 紅
# （㉟）／scan_scope 非法紅（㊱）／board_clip.flagged 非空紅、帶 classification intentional_bleed 也紅（㊲）／缺 scan_scope 紅（㊳）／舊收據
# （head_sha tree 只有第五支）缺兩欄位綠＋放行行（㊴）、同形但 scan_scope 非法仍紅（㊴-b）／最新收據 head_sha tree 無第六支但 PR head 已有
# 紅（㊵）、同 head_sha 補齊綠（㊵-b）／每支 scope 非法紅（㊶）。cutoff 同 LS-168 用腳本標記（scanBoardClip）不用時間，見 gate 檔頭。
#
# LS-202：㊷～㊹-b 驗六支各帶 scope／document_count——齊全綠（㊷）／某支缺 document_count 紅（㊷-b）／某支缺 scope 紅（㊷-c，LS-185 時可省）／
# document_count 負數／布林紅（㊷-d／e）／head_sha tree 無標記、缺欄位綠＋放行行（㊸）／PR head 已含標記而最新收據缺紅、補齊綠（㊹／㊹-b）。
# cutoff＝腳本含 `document_count` 字面（同 LS-168／LS-185 用腳本標記不用時間）。R2 minor-1：㊺ scan_scope=document 且
# corner_anchor.document_containers=0 紅（第四支停擺）／㊺-b boards 限縮全零綠／㊺-c in-scope containers=0 而 document 216 綠（LS-133 形狀）／
# ㊺-d R3 省略 document_containers 鍵紅（cutoff 下必填；㉞～㊶ 的 write_receipt6 收據在 cutoff 前、沒有此鍵仍綠）。
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
# LS-122：①～⑩ 是兩支 schema 的既有收據樣本，commit 時間釘在 LEGACY_CUTOFF（2026-09-02T04:00Z）之前；⑪ 起改釘之後
export GIT_COMMITTER_DATE='2026-09-01T00:00:00Z'

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

# ⑨ merge-review R1 F1 重現（假陽性）：一個 PR 累積 r1／r2 兩份收據（設計票 ≥3 輪迭代的常態，
# CLAUDE.md／§1）——r1 記錄第 1 輪那個時點的 .pen（3 節點），r2 記錄第 2 輪之後（4 節點）。
# R1 版本會把 r1 也拿去比對「工作區當下」那份 .pen（此刻是 4 節點）→ r1 誤判紅。
# R2 修正：每份收據對帳自己 head_sha 那個時點的快照——r1 對 3 節點的快照、r2 對 4 節點的快照，
# 兩份都應該綠（若退回 R1 的做法，r1 會被誤判紅，這裡就會抓到）。
g checkout -q -b pr-r1r2 "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": []}, {"id": "b", "children": []}, {"id": "c", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地（3 節點）'
r1_sha="$(g rev-parse HEAD)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$r1_sha" 3 1 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據'

cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": []}, {"id": "b", "children": []}, {"id": "c", "children": []}, {"id": "e", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r2 落地（4 節點）'
r2_sha="$(g rev-parse HEAD)"
write_receipt "$R/design/evidence/LS-67-r2-overflow.json" "$r2_sha" 4 1 1 1
g add design/evidence/LS-67-r2-overflow.json
g commit -qm 'design(evidence): LS-67 r2 收據'
expect 0 '⑨ F1 重現：同一 PR 累積 r1(3節點)/r2(4節點) 收據，各對各的時點 → 兩份皆綠' '' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑩ merge-review R1 F2 重現（假陰性）：commit A 落地 .pen（a、b 重疊）→ commit B 交收據引用 A →
# commit C 修正版面（搬動／改寬高，**節點數不變**——這是溢出修正的標準動作，不是巧合）但沒有補
# 新收據。R1 版本只驗 head_sha 屬於本 PR（A 確實是本 PR 的 commit）→ 誤判綠，C 這次真正的修正完
# 全沒有收據把關。R2 修正：輪次最高（這裡只有 r1，所以就是它）的收據 head_sha 必須等於本 PR 對
# 這份 .pen 最後一次的 commit（C），不是 A → 應該紅。
g checkout -q -b pr-f2 "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "note": "overlap-with-b", "children": []}, {"id": "b", "children": []}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r1 落地（a 與 b 重疊）'
commit_a="$(g rev-parse HEAD)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$commit_a" 4 1 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（引用 commit A）'
# commit C：修正版面（把 a 的 note 換成「已搬開」），節點數仍是 4，且不補新收據
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "note": "moved-away-from-b", "children": []}, {"id": "b", "children": []}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): 修正版面（a 移開，未補收據）'
commit_c="$(g rev-parse HEAD)"
if [ "$commit_a" = "$commit_c" ]; then
  echo "✗ ⑩ 前置條件：commit_c 應與 commit_a 不同（自測環境異常）" >&2
  fail=1
fi
expect 1 '⑩ F2 重現：最新收據引用較早的 commit A，最後一次 .pen commit 是 C（節點數不變）→ 紅' \
  '規則 4 F2' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ───── LS-122：四支掃描 schema ─────
# 之後的 commit 釘在 LEGACY_CUTOFF 之後（不用真實現在時間——測試不得依賴 wall clock）：只有 round ≤ 5 且 commit 早於
# cutoff 才准兩支。
export GIT_COMMITTER_DATE='2026-09-03T00:00:00Z'

write_receipt4() {
  # write_receipt4 <path> <head_sha> <total_nodes> <mismatch> <mode: full|nocounts|noclass|noboard|badboard|unres>
  #   land4 的 .pen 相對 base 只有頂層 d 是新增／變更（a、c 不變）→ boards 至少要列 d
  local path=$1 sha=$2 n=$3 mismatch=$4 mode=$5 corner cross boards='["d"]' unres='[]' flagged='[]'
  case "$mode" in
    noboard)  boards='["a"]' ;;
    badboard) boards='["d","zzz"]' ;;
    unres)    unres='[{"container":"a","reason":"找不到吻合的紙面"}]' ;;
  esac
  if [ "$mismatch" != 0 ]; then
    flagged='[{"container":"a","corner":"b","axis":"y","expected":157,"actual":149}]'
  fi
  case "$mode" in
    nocounts) corner='"corner_anchor":{"boards":'"$boards"',"containers":1,"mismatch":0,"document_mismatch":0,"flagged":[],"unresolved":[]}' ;;
    *) corner='"corner_anchor":{"boards":'"$boards"',"containers":1,"points":8,"mismatch":'"$mismatch"',"document_mismatch":'"$mismatch"',"flagged":'"$flagged"',"unresolved":'"$unres"'}' ;;
  esac
  if [ "$mode" = noclass ]; then
    cross='"cross_parent_collision":{"flagged":[{"node_a":"a","node_b":"c"}]}'
  else
    cross='"cross_parent_collision":{"flagged":[{"node_a":"a","node_b":"c","classification":"corner-out whitelist"}]}'
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{"ticket":"LS-67","round":6,"head_sha":"${sha}","total_nodes":${n},
 "scans":{"sibling_intersection":{"flagged":[]},"row_overflow":{"flagged":[]},${cross},${corner}}}
EOF
}

land4() {
  # land4 <branch>：切分支、落地 4 節點 .pen、回傳落地 commit sha
  g checkout -q -b "$1" "$base_ref"
  cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "children": []}]}
EOF
  g add design/littlesprout.pen
  g commit -qm 'design(pen): LS-67 落地'
  g rev-parse HEAD
}

# ⑪ round 6 只交兩支（舊 schema）→ 紅，訊息點名四支
sha11="$(land4 pr-r6-twoscans)"
write_receipt "$R/design/evidence/LS-67-r6-overflow.json" "$sha11" 4 1 1 1
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（只有兩支）'
expect 1 '⑪ round 6 只交兩支掃描 → 紅' 'scans.cross_parent_collision 缺失' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑫ round 6 四支齊全但 corner_anchor.mismatch=2 → 紅（角托錯位不接受白名單）
sha12="$(land4 pr-r6-mismatch)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha12" 4 2 full
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（mismatch=2）'
expect 1 '⑫ round 6 四支齊全但 corner_anchor.mismatch=2 → 紅' 'mismatch 必須為 0' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑬ round 6 四支齊全、mismatch=0 → 綠
sha13="$(land4 pr-r6-ok)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha13" 4 0 full
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（四支齊全）'
expect 0 '⑬ round 6 四支齊全、mismatch=0 → 綠' '四支掃描皆有輸出' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑭ corner_anchor 缺 points 計數 → 紅
sha14="$(land4 pr-r6-nocounts)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha14" 4 0 nocounts
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（corner_anchor 缺 points）'
expect 1 '⑭ corner_anchor 缺 points 計數 → 紅' 'corner_anchor.points 必須是非負整數' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑮ cross_parent_collision 有一筆缺分類 → 紅
sha15="$(land4 pr-r6-noclass)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha15" 4 0 noclass
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（跨 parent 缺分類）'
expect 1 '⑮ cross_parent_collision 有一筆缺分類 → 紅' 'scans.cross_parent_collision.flagged[0] 缺分類' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑯ round 1 兩支收據、但 .pen commit 在 LEGACY_CUTOFF 之後（＝gate 落地後的新票第 1 輪）→ 紅
#    （與 ① 同一份收據內容，差別只在 commit 時間——證明「round ≤ 5」不是新票前五輪的永久漏洞）
sha16="$(land4 pr-r1-after-cutoff)"
write_receipt "$R/design/evidence/LS-67-r1-overflow.json" "$sha16" 4 1 1 1
g add design/evidence/LS-67-r1-overflow.json
g commit -qm 'design(evidence): LS-67 r1 收據（cutoff 之後的兩支收據）'
expect 1 '⑯ cutoff 之後的 round 1 兩支收據 → 紅（不得沿用舊 schema）' '四支掃描' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑰ merge-review R1 MJ-1 重現：cutoff **之前**的 round 6 兩支收據（＝LS-119 r6 的情境）→ 綠——「既有收據」只看落地時間，不看輪次
#    （R1 版的 round ≤ 5 conjunct 沒有任何負控覆蓋，唯一效果是把 LS-119 r6 踢紅；這一格就是漏掉的那格）
export GIT_COMMITTER_DATE='2026-09-01T00:00:00Z'
sha17="$(land4 pr-r6-before-cutoff)"
write_receipt "$R/design/evidence/LS-67-r6-overflow.json" "$sha17" 4 1 1 1
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（cutoff 之前，兩支）'
expect 0 '⑰ cutoff 之前的 round 6 兩支收據 → 綠（既有收據不看輪次，MJ-1）' '舊 schema' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
export GIT_COMMITTER_DATE='2026-09-03T00:00:00Z'

# ⑱ boards 漏列本 PR 觸碰的頂層節點 d（只列沒動的 a）→ 紅（不得靠縮小 boards 把自己的錯位推進 document_mismatch）
sha18="$(land4 pr-r6-noboard)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha18" 4 0 noboard
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（boards 漏列 d）'
expect 1 '⑱ boards 漏列本 PR 觸碰的頂層節點 → 紅' '漏列本 PR 對 .pen 有變更的頂層節點：d' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑲ boards 含 head_sha 快照頂層不存在的 id → 紅
sha19="$(land4 pr-r6-badboard)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha19" 4 0 badboard
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（boards 含不存在的 id）'
expect 1 '⑲ boards 含不存在於頂層的 id → 紅' "不存在於 head_sha 快照頂層的 id：['zzz']" \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ⑳ unresolved 有一筆缺分類 → 紅（找不到紙面的角托容器要說明原因，不能默默略過）
sha20="$(land4 pr-r6-unres)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha20" 4 0 unres
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（unresolved 缺分類）'
expect 1 '⑳ corner_anchor.unresolved 有一筆缺分類 → 紅' 'unresolved[0] 缺分類' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ───── LS-127：CI merge ref（refs/pull/N/merge）上 base 側 .pen 變更不算本 PR ─────
# PR #223 的形狀：分支自 base_ref 切出後，base 自己又動了 .pen 的另一頂層節點 c（LS-114 動 PXPcH）；GitHub 的
# actions/checkout 把 HEAD 放在「PR head＋base tip」的雙親合併 commit 上。舊接線（gate 以 HEAD 為終點）用
# merge-base(base, HEAD)＝base tip 當起點：① base 側對 c 的變更被算成本 PR 觸碰的板（boards 漏列 c 假紅）、② 合併
# commit 兩側 .pen 都不同、被 rev-list 當成「本 PR 對 .pen 最後一次的 commit」（最新收據 head_sha 假紅）。修法：CI 傳
# --head-sha <PR head>，gate 以 merge-base(base, head-sha)..head-sha 計算；本機模式（不給 --head-sha）行為不變。
g checkout -q -b base-moved "$base_ref"
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "note": "moved-by-base", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-114 他票改 c（base 側，PR 分出之後）'
base_moved="$(g rev-parse HEAD)"

merge_ref() {
  # merge_ref <branch> <receipt mode>：自 base_ref 切 PR 分支落地 d＋收據（引用落地 commit），再模擬 GitHub 的
  # refs/pull/N/merge——以 base_moved 為第一親、PR head 為第二親的合併 commit（tree＝兩側變更都在；親序同 GitHub 實測
  # refs/pull/223/merge cd73c6d：^1=base b516606、^2=PR head——所以從合併 commit --first-parent 走到的是 base 側，不是解法）
  # ——並 checkout 到它；印出 PR head sha（CI 會以 github.event.pull_request.head.sha 傳給 gate 的那個）
  local sha head
  sha="$(land4 "$1")"
  write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha" 4 0 "$2"
  g add design/evidence/LS-67-r6-overflow.json
  g commit -qm 'design(evidence): LS-67 r6 收據'
  head="$(g rev-parse HEAD)"
  cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "note": "moved-by-base", "children": []}, {"id": "d", "children": []}]}
EOF
  g add design/littlesprout.pen
  g update-ref "refs/heads/$1-merge" "$(g commit-tree "$(g write-tree)" -p "$base_moved" -p "$head" -m 'Merge PR head into base（模擬 refs/pull/N/merge）')"
  g checkout -q -f "$1-merge"
  printf '%s\n' "$head"
}

# ㉑ 形狀確認：merge ref 上不給 --head-sha（＝舊 CI 接線，HEAD＝合併 commit）→ 仍紅：合併 commit 兩側 .pen 都不同、被當成
#    「本 PR 對 .pen 最後一次的 commit」（PR #223 假紅 ②，只有 --head-sha 能解）——證明合成的 merge ref 真的是 PR #223 的
#    形狀（沒有這一格，㉒ 的綠可能只是合成失真的假綠）；但假紅 ①（boards 漏列 base 側的 c）已由 (a) 解掉：每份收據的
#    touched 基準是 merge-base(base_sha, 該收據 head_sha)、不是 base_sha 本身，merge ref 上也不再點名 c
pr21="$(merge_ref pr-mergeref full)"
if [ "$(g rev-parse HEAD^1)" != "$base_moved" ] || [ "$(g rev-parse HEAD^2)" != "$pr21" ] || [ "$(g merge-base "$base_moved" HEAD)" != "$base_moved" ]; then
  echo "✗ ㉑ 前置條件：HEAD 應是 ^1=base_moved、^2=PR head 的合併 commit，且 merge-base(base_moved, HEAD)＝base_moved（自測環境異常）" >&2
  fail=1
fi
expect 1 '㉑ merge ref 上不給 --head-sha → 紅：合併 commit 被當成最後一次 .pen commit（PR #223 假紅 ②）' \
  '不是本 PR 對這份 .pen 最後一次的 commit' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved"
out21="$(cd "$R" && bash "$check" "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved" 2>&1)"
if printf '%s' "$out21" | grep -qF '漏列本 PR 對 .pen 有變更的頂層節點'; then
  echo "✗ ㉑ merge ref 上不給 --head-sha：base 側動的 c 不該被算成本 PR 觸碰的板（(a) 每份收據以自己的共同祖先為基準）" >&2
  printf '%s\n' "$out21" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ㉑ merge ref 上不給 --head-sha：boards 不再點名 base 側的 c（PR #223 假紅 ① 由 (a) 解掉）"
fi

# ㉒ 同一個 merge ref 上給 --head-sha <PR head> → 綠（boards=["d"] 已覆蓋本 PR 真正觸碰的板；c 是 base 側的、不算）
expect 0 '㉒ merge ref 上 --head-sha <PR head> → 綠（base 側 c 與合併 commit 都不算本 PR）' '四支掃描皆有輸出' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved" --head-sha "$pr21"

# ㉓ 負控：同形狀但 PR 自己的收據真的漏列觸碰板 d（只列沒動的 a）→ --head-sha 下仍紅，且只點名 d、不點名 base 側的 c
#    （若 c 也被算進去，訊息會是「頂層節點：c（）, d（）」、比對不到「頂層節點：d」→ 這一格同時釘住「c 不算」）
pr23="$(merge_ref pr-mergeref-noboard noboard)"
expect 1 '㉓ merge ref 上 --head-sha，但 PR 自己漏列觸碰板 d → 仍紅（負控，只點名 d）' \
  '漏列本 PR 對 .pen 有變更的頂層節點：d' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved" --head-sha "$pr23"

# ㉔ (a) base 前進後歷史收據仍綠（LS-119 merge-review comment 3d5851ac 實測）：PR r6 落地 A＋收據引用 A → base 前進（改 c）→
#    PR 自己把 base 併進來（合併 commit M1，兩側 .pen 都不同）→ r7 再落地 B（改 d）＋收據引用 B。此時 merge-base(base, HEAD)＝
#    base_moved、在 A 之後：舊算法對每份收據都拿 base_moved 快照當基準，r6 的 A 快照沒有 base 對 c 的變更 → c 被算成 r6
#    漏列的板（歷史收據全紅）；新算法每份收據以 merge-base(base_sha, 該收據 head_sha) 為基準（r6→fork、r7→base_moved）→ 綠。
#    最後一次 .pen commit＝B（r7 引用 B）、M1 在中間不是最後一次。本機模式（不給 --head-sha）就能重現，與 merge ref 無關。
sha24="$(land4 pr-base-advanced)"
write_receipt4 "$R/design/evidence/LS-67-r6-overflow.json" "$sha24" 4 0 full
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（引用 A）'
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "note": "moved-by-base", "children": []}, {"id": "d", "children": []}]}
EOF
g add design/littlesprout.pen
g update-ref refs/heads/pr-base-advanced "$(g commit-tree "$(g write-tree)" -p "$(g rev-parse HEAD)" -p "$base_moved" -m 'Merge base into PR branch（PR 自己把 base 併進來）')"
g reset -q --hard
cat > "$R/design/littlesprout.pen" <<'EOF'
{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "note": "moved-by-base", "children": []}, {"id": "d", "note": "r7-moved", "children": []}]}
EOF
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r7 落地（B，改 d）'
sha24b="$(g rev-parse HEAD)"
write_receipt4 "$R/design/evidence/LS-67-r7-overflow.json" "$sha24b" 4 0 full
g add design/evidence/LS-67-r7-overflow.json
g commit -qm 'design(evidence): LS-67 r7 收據（引用 B）'
if [ "$(g merge-base "$base_moved" HEAD)" != "$base_moved" ]; then
  echo "✗ ㉔ 前置條件：merge-base(base_moved, HEAD) 應為 base_moved（base 已併入 PR 分支；自測環境異常）" >&2
  fail=1
fi
expect 0 '㉔ base 前進後 PR 併入 base：歷史收據 r6（快照停在 base 變更前）＋最新 r7 → 兩份皆綠' '四支掃描皆有輸出' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved"

# ㉕ --head-sha 參數 fail closed：解析不到的 commit／缺值 → exit 2
expect 2 '㉕ --head-sha 指向解析不到的 commit → exit 2' '不是可解析的 commit' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved" --head-sha 0000000000000000000000000000000000000000
expect 2 '㉕ --head-sha 缺值 → exit 2' '--head-sha 缺值' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_moved" --head-sha

# ───── LS-168：第五支 text_occlusion＋收據新鮮度 tree_hash ─────
# 新欄位只對「head_sha 快照的 tree 裡 scripts/design/overflow-scan.js 含 scanTextOcclusion」的收據要求；㉖～㉚ 的落地 commit
# 同時放入帶標記的腳本副本，㉛ 不放（＝in-flight 設計分支／既有收據）。tree_hash 由 scripts/gates/design_tree_hash.py 對該
# commit 的 .pen 算（與正典腳本 SUMMARY 同規格，js／py 交叉一致由 overflow-scan.test.js 釘住）。
hash_of() { g show "$1:design/littlesprout.pen" > "$work/hash-in.pen"; python3 "$root/scripts/gates/design_tree_hash.py" "$work/hash-in.pen"; }
# LS-171：把快照裡每個 geometry 改成字面 "..."（＝Pencil Get 不帶 includePathGeometry 的輸出形狀）再算 tree_hash
dots_hash_of() {
  g show "$1:design/littlesprout.pen" > "$work/hash-in.pen"
  PYTHONDONTWRITEBYTECODE=1 python3 - "$work/hash-in.pen" "$root/scripts/gates" <<'PY'
import io, json, sys
sys.path.insert(0, sys.argv[2])
import design_tree_hash
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
def w(x):
    if "geometry" in x:
        x["geometry"] = "..."
    for c in x.get("children") or []:
        w(c)
for c in d["children"]:
    w(c)
print(design_tree_hash.tree_hash(d))
PY
}
# 本 PR 新增的頂層 d 是帶 geometry 的 path（LS-171：cmp/Photo Corner 的 Corner Shape）——節點數仍 4、touched 板仍只有 d
pen4='{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "type": "path", "geometry": "M0 14a14 14 0 0 1 14-14l12 0-26 26z", "children": []}]}'
land5() {
  # land5 <branch> <with-script 1/0>：落地 4 節點 .pen＋（可選）帶第五支標記的正典腳本副本；回傳落地 sha
  g checkout -q -b "$1" "$base_ref"
  printf '%s\n' "$pen4" > "$R/design/littlesprout.pen"
  g add design/littlesprout.pen
  if [ "$2" = 1 ]; then
    mkdir -p "$R/scripts/design"
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\n' > "$R/scripts/design/overflow-scan.js"
    g add scripts/design/overflow-scan.js
  fi
  g commit -qm 'design(pen): LS-67 落地（LS-168 樣本）'
  g rev-parse HEAD
}
write_receipt5() {
  # write_receipt5 <path> <head_sha> <tree_hash|''> <occl: ok|missing|flagged>
  local path=$1 sha=$2 hash=$3 occl=$4 hash_field='' occl_field=''
  [ -n "$hash" ] && hash_field=',"tree_hash":"'"$hash"'"'
  case "$occl" in
    ok)      occl_field=',"text_occlusion":{"flagged":[],"document_flagged":[]}' ;;
    flagged) occl_field=',"text_occlusion":{"flagged":[{"node":"b","overlay":"c","classification":"Value × Tab Bar"}],"document_flagged":[]}' ;;
    missing) occl_field='' ;;
  esac
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '{"ticket":"LS-67","round":6,"head_sha":"'"$sha"'","total_nodes":4'"$hash_field"',' \
    ' "scans":{"sibling_intersection":{"flagged":[]},"row_overflow":{"flagged":[]},' \
    '  "cross_parent_collision":{"flagged":[]},' \
    '  "corner_anchor":{"boards":["d"],"containers":1,"points":8,"mismatch":0,"document_mismatch":0,"flagged":[],"unresolved":[]}'"$occl_field"'}}' > "$path"
}

# ㉖ 五支齊全＋tree_hash＝對 head_sha 快照算出的值 → 綠，訊息含 tree_hash
sha26="$(land5 pr-fifth-ok 1)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha26" "$(hash_of "$sha26")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（五支＋tree_hash）'
expect 0 '㉖ 五支齊全、tree_hash 對應 head_sha 快照、text_occlusion.flagged 空 → 綠' 'tree_hash 對應 head_sha 快照、text_occlusion.flagged 為空' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㉖-b LS-171：收據 tree_hash 是「geometry 被省略成 "..."」那份雜湊（Pencil 端雜湊走訪漏帶 includePathGeometry 的輸出）→ 紅「tree_hash 不符」
#    （LS-152 VR R3 三方比對：py＝js 03e7804b035d8e4b、Pencil 不帶選項 84420d7b6419b40e，8 個 path 節點；gate 對含 path 的稿本來永遠紅）
dots26="$(dots_hash_of "$sha26")"
if [ "$dots26" = "$(hash_of "$sha26")" ]; then echo "✗ ㉖-b 前置條件：geometry 省略成 \"...\" 後 tree_hash 應改變（自測環境異常）" >&2; fail=1; fi
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha26" "$dots26" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（tree_hash 來自 geometry 被省略的走訪）'
expect 1 '㉖-b 收據 tree_hash 來自 geometry 省略成 "..." 的走訪（Pencil 漏帶 includePathGeometry）→ 紅' 'tree_hash 不符' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉗ 拼接／掃完又改稿：commit A 落地 v1 → 掃描（hash 取自 v1）→ commit C 搬一個節點（節點數不變）→ 收據 head_sha=C 但 tree_hash 是 v1 的
#    → 紅「tree_hash 不符」（F2 對「收據引用最後一次 commit、內容卻是舊掃描」這種形狀是綠的；修前舊 gate 實跑：綠）
sha27a="$(land5 pr-stale-hash 1)"
stale_hash="$(hash_of "$sha27a")"
printf '%s\n' '{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "type": "path", "geometry": "M0 14a14 14 0 0 1 14-14l12 0-26 26z", "x": 99, "children": []}]}' > "$R/design/littlesprout.pen"
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 搬 d（節點數不變、boards 仍覆蓋）'
sha27c="$(g rev-parse HEAD)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha27c" "$stale_hash" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（head_sha=C、tree_hash 卻是 A 的掃描）'
if [ "$stale_hash" = "$(hash_of "$sha27c")" ]; then echo "✗ ㉗ 前置條件：搬節點後 tree_hash 應改變（自測環境異常）" >&2; fail=1; fi
expect 1 '㉗ 掃完又改稿再落地／拼接：head_sha 是最後一次 commit、tree_hash 卻是舊掃描 → 紅' 'tree_hash 不符' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉘ 新 schema 缺 text_occlusion → 紅
sha28="$(land5 pr-no-occl 1)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha28" "$(hash_of "$sha28")" missing
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（缺 text_occlusion）'
expect 1 '㉘ 新 schema 缺 scans.text_occlusion → 紅' 'scans.text_occlusion 缺失' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉙ text_occlusion.flagged 非空 → 紅（不接受白名單，即使有 classification）
sha29="$(land5 pr-occl-flagged 1)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha29" "$(hash_of "$sha29")" flagged
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（text_occlusion 有 1 筆）'
expect 1 '㉙ text_occlusion.flagged 非空（帶分類也一樣）→ 紅' 'text_occlusion.flagged 必須為空（收據 1 筆：b×c）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉚ 新 schema 缺 tree_hash → 紅
sha30="$(land5 pr-no-hash 1)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha30" "" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（缺 tree_hash）'
expect 1 '㉚ 新 schema 缺 tree_hash → 紅' 'tree_hash 必須是 16 碼小寫 hex' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉛ 舊收據：head_sha 快照沒有帶第五支的正典腳本（in-flight 設計分支／既有收據），缺兩個新欄位 → 綠＋印一行放行
sha31="$(land5 pr-legacy-fifth 0)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha31" "" missing
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（舊 schema：無 tree_hash／text_occlusion）'
expect 0 '㉛ head_sha 快照無第五支腳本、缺 tree_hash／text_occlusion → 綠並印放行行' 'LS-168 新欄位 tree_hash／text_occlusion 不要求' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㉛-b 同一舊收據形狀但 tree_hash 填了錯值 → 仍紅（欄位若在就驗，不因舊收據放行）
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha31" "0000000000000000" missing
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（舊 schema 但 tree_hash 錯）'
expect 1 '㉛-b 舊收據但 tree_hash 欄位在且錯 → 仍紅（欄位在就驗）' 'tree_hash 不符' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉜ merge-review R1 N1 重現：.pen 最後一次落地（sha32）時 tree 尚無第五支；之後分支才拿到新腳本（併入 commit 不碰 .pen，＝LS-152 R3+
#    把 development 併進來的形狀）→ 最新收據缺 tree_hash／text_occlusion。修前 fifth 只看 head_sha tree → 印「舊收據放行」綠；修後
#    is_latest 且 PR head tree 含第五支 → 紅，訊息指出「PR head 的 tree 已含」與補法
add_script() {
  mkdir -p "$R/scripts/design"
  printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\n' > "$R/scripts/design/overflow-scan.js"
  g add scripts/design/overflow-scan.js
  g commit -qm 'chore: 併入含第五支的正典腳本（不碰 .pen）'
}
sha32="$(land5 pr-late-script 0)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha32" "" missing
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（舊 schema）'
add_script
expect 1 '㉜ 最新收據 head_sha tree 無第五支、但 PR head tree 已有 → 紅（N1：不得靠「之後不再動 .pen」永遠不填）' 'PR head 的 tree 已含' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㉜-b 同一 head_sha（＝last_pen_commit，.pen 內容未變）用新腳本重跑、補齊兩欄位 → 綠
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha32" "$(hash_of "$sha32")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（新腳本重跑補 tree_hash／text_occlusion）'
expect 0 '㉜-b 同一 head_sha 用新腳本重跑補齊 tree_hash／text_occlusion → 綠' 'tree_hash 對應 head_sha 快照' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉝ 只對最新輪次加嚴：r5（舊輪次，head_sha tree 無第五支、缺兩欄位）→ 分支併入新腳本 → r6 落地＋五支齊全收據。r5 產於新腳本
#    存在之前、回填不可能 → 仍放行；r6 最新且齊全 → 綠。兩份皆綠，且 r5 印放行行（釘住「非最新不受 PR head tree 影響」）
sha33a="$(land5 pr-late-script-r5 0)"
write_receipt5 "$R/design/evidence/LS-67-r5-overflow.json" "$sha33a" "" missing
g add design/evidence/LS-67-r5-overflow.json
g commit -qm 'design(evidence): LS-67 r5 收據（舊 schema）'
add_script
printf '%s\n' '{"version": 1, "children": [{"id": "a", "children": [{"id": "b", "children": []}]}, {"id": "c", "children": []}, {"id": "d", "type": "path", "geometry": "M0 14a14 14 0 0 1 14-14l12 0-26 26z", "x": 5, "children": []}]}' > "$R/design/littlesprout.pen"
g add design/littlesprout.pen
g commit -qm 'design(pen): LS-67 r6 落地（搬 d）'
sha33b="$(g rev-parse HEAD)"
write_receipt5 "$R/design/evidence/LS-67-r6-overflow.json" "$sha33b" "$(hash_of "$sha33b")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（五支＋tree_hash）'
expect 0 '㉝ 舊輪次 r5（head_sha tree 無第五支、缺欄位）＋最新 r6 五支齊全 → 兩份皆綠、r5 印放行行' 'LS-67-r5-overflow.json：head_sha=' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ───── LS-185：第六支 board_clip＋scan_scope ─────
# 新欄位只對「head_sha 快照（或最新輪次的 PR head）tree 裡正典腳本含 scanBoardClip」的收據要求；land6 依 <script> 放入只含第五支或
# 五＋六支標記的腳本副本。write_receipt6 以 write_receipt5 的五支＋tree_hash 為底，加 scan_scope／board_clip 變體。
land6() {
  # land6 <branch> <script: fifth|sixth>：落地 4 節點 .pen＋帶對應標記的腳本副本；回傳落地 sha
  g checkout -q -b "$1" "$base_ref"
  printf '%s\n' "$pen4" > "$R/design/littlesprout.pen"
  g add design/littlesprout.pen
  mkdir -p "$R/scripts/design"
  if [ "$2" = sixth ]; then
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n' > "$R/scripts/design/overflow-scan.js"
  else
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\n' > "$R/scripts/design/overflow-scan.js"
  fi
  g add scripts/design/overflow-scan.js
  g commit -qm 'design(pen): LS-67 落地（LS-185 樣本）'
  g rev-parse HEAD
}
add_script6() {
  printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n' > "$R/scripts/design/overflow-scan.js"
  g add scripts/design/overflow-scan.js
  g commit -qm 'chore: 併入含第六支的正典腳本（不碰 .pen）'
}
write_receipt6() {
  # write_receipt6 <path> <head_sha> <tree_hash> <mode: ok|boards|nobc|badscope|bcflag|noscope|legacy5|badscanscope>
  local path=$1 sha=$2 hash=$3 mode=$4 scope_field=',"scan_scope":"document"' bc_field=',"board_clip":{"flagged":[],"document_flagged":[]}' tx_scope=''
  case "$mode" in
    boards)       scope_field=',"scan_scope":"boards"' ;;
    nobc)         bc_field='' ;;
    badscope)     scope_field=',"scan_scope":"board"' ;;
    bcflag)       bc_field=',"board_clip":{"flagged":[{"board":"d","node":"b","side":"bottom","overflow_px":123,"classification":"intentional_bleed"}],"document_flagged":[]}' ;;
    noscope)      scope_field='' ;;
    legacy5)      scope_field=''; bc_field='' ;;
    badscanscope) tx_scope='"scope":"全稿",' ;;
  esac
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '{"ticket":"LS-67","round":6,"head_sha":"'"$sha"'","total_nodes":4,"tree_hash":"'"$hash"'"'"$scope_field"',' \
    ' "scans":{"sibling_intersection":{"flagged":[]},"row_overflow":{"flagged":[]},' \
    '  "cross_parent_collision":{"flagged":[]},' \
    '  "corner_anchor":{"boards":["d"],"containers":1,"points":8,"mismatch":0,"document_mismatch":0,"flagged":[],"unresolved":[]},' \
    '  "text_occlusion":{'"$tx_scope"'"flagged":[],"document_flagged":[]}'"$bc_field"'}}' > "$path"
}

# ㉞ 六支齊全＋scan_scope=document → 綠，訊息含 board_clip／scan_scope
sha34="$(land6 pr-sixth-ok sixth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha34" "$(hash_of "$sha34")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（六支＋scan_scope）'
expect 0 '㉞ 六支齊全、scan_scope=document、board_clip.flagged 空 → 綠' 'board_clip.flagged 為空、scan_scope=document' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㉞-b scan_scope=boards（限縮模式如實標示）→ 綠
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha34" "$(hash_of "$sha34")" boards
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（scan_scope=boards）'
expect 0 '㉞-b scan_scope=boards → 綠（限縮模式合法，只要如實標示）' 'scan_scope=boards' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㉞-c LS-198：綠訊息的支數依收據實際要求的層數算、不寫死（六支收據印「六支」；⑬／㉒／㉔ 的 LS-122 收據仍印「四支」）
expect 0 '㉞-c 六支收據的綠訊息印「六支掃描皆有輸出」（支數指回 overflow-scan.js 檔頭）' '六支掃描皆有輸出（支數以 scripts/design/overflow-scan.js 檔頭為準）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㉟ 新 schema 缺 board_clip → 紅
sha35="$(land6 pr-no-bc sixth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha35" "$(hash_of "$sha35")" nobc
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（缺 board_clip）'
expect 1 '㉟ 新 schema 缺 scans.board_clip → 紅' 'scans.board_clip 缺失' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊱ scan_scope 非法值 → 紅
sha36="$(land6 pr-bad-scope sixth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha36" "$(hash_of "$sha36")" badscope
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（scan_scope 非法）'
expect 1 '㊱ scan_scope 非法值 → 紅' "scan_scope 只接受 boards|document（收據='board'）" \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊲ board_clip.flagged 非空（帶 classification intentional_bleed 也一樣）→ 紅
sha37="$(land6 pr-bc-flagged sixth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha37" "$(hash_of "$sha37")" bcflag
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（board_clip 有 1 筆）'
expect 1 '㊲ board_clip.flagged 非空（classification=intentional_bleed 不放行）→ 紅' 'board_clip.flagged 必須為空（收據 1 筆：b@d:bottom）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊳ 新 schema 缺 scan_scope → 紅
sha38="$(land6 pr-no-scope sixth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha38" "$(hash_of "$sha38")" noscope
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（缺 scan_scope）'
expect 1 '㊳ 新 schema 缺 scan_scope → 紅' '缺 scan_scope' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊴ 舊收據：head_sha tree 的腳本只有第五支（＝in-flight 設計分支／LS-177 r1／r2 形狀），五支＋tree_hash、無 scan_scope／board_clip → 綠＋放行行
sha39="$(land6 pr-legacy-sixth fifth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha39" "$(hash_of "$sha39")" legacy5
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（五支 schema，無第六支欄位）'
expect 0 '㊴ head_sha tree 只有第五支、缺 board_clip／scan_scope → 綠並印放行行（cutoff 前）' 'LS-185 新欄位 board_clip／scan_scope 不要求' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊴-b 同一舊收據但 scan_scope 填了非法值 → 仍紅（欄位若在就驗）
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha39" "$(hash_of "$sha39")" badscope
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（舊 schema 但 scan_scope 非法）'
expect 1 '㊴-b 舊收據但 scan_scope 欄位在且非法 → 仍紅（欄位在就驗）' 'scan_scope 只接受' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊵ N1 同形：.pen 最後一次落地時 tree 只有第五支；之後分支併入含第六支的腳本（不碰 .pen）→ 最新收據缺兩欄位 → 紅
sha40="$(land6 pr-late-sixth fifth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha40" "$(hash_of "$sha40")" legacy5
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（五支 schema）'
add_script6
expect 1 '㊵ 最新收據 head_sha tree 無第六支、但 PR head tree 已有 → 紅' 'PR head 的 tree 已含第六支' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊵-b 同 head_sha 用新腳本重跑補齊 scan_scope／board_clip → 綠
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha40" "$(hash_of "$sha40")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（新腳本重跑補 scan_scope／board_clip）'
expect 0 '㊵-b 同一 head_sha 補齊 scan_scope／board_clip → 綠' 'board_clip.flagged 為空、scan_scope=document' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊶ 每支的 scope 非法 → 紅
sha41="$(land6 pr-bad-scanscope sixth)"
write_receipt6 "$R/design/evidence/LS-67-r6-overflow.json" "$sha41" "$(hash_of "$sha41")" badscanscope
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（text_occlusion.scope 非法）'
expect 1 '㊶ scans.text_occlusion.scope 非法 → 紅' "scans.text_occlusion.scope 只接受 boards|document（收據='全稿'" \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ───── LS-202：六支各帶 scope／document_count ─────
# 新欄位只對「head_sha 快照（或最新輪次的 PR head）tree 裡正典腳本含 document_count」的收據要求；land7 依 <script> 放入五＋六支或
# 五＋六支＋per-scan 標記的腳本副本。write_receipt7 以 write_receipt6 的六支＋scan_scope 為底，六支各帶 scope／document_count 再依 mode 挖掉一格。
land7() {
  # land7 <branch> <script: sixth|perscan>
  g checkout -q -b "$1" "$base_ref"
  printf '%s\n' "$pen4" > "$R/design/littlesprout.pen"
  g add design/littlesprout.pen
  mkdir -p "$R/scripts/design"
  if [ "$2" = perscan ]; then
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n// tag: scope + document_count\n' > "$R/scripts/design/overflow-scan.js"
  else
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n' > "$R/scripts/design/overflow-scan.js"
  fi
  g add scripts/design/overflow-scan.js
  g commit -qm 'design(pen): LS-67 落地（LS-202 樣本）'
  g rev-parse HEAD
}
add_script7() {
  printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n// tag: scope + document_count\n' > "$R/scripts/design/overflow-scan.js"
  g add scripts/design/overflow-scan.js
  g commit -qm 'chore: 併入含 per-scan scope／document_count 的正典腳本（不碰 .pen）'
}
write_receipt7() {
  # write_receipt7 <path> <head_sha> <tree_hash> <mode: ok|nocount|noscope|badcount|boolcount|legacy6|zerodoc|zerodoc_boards|zeroin>
  local path=$1 sha=$2 hash=$3 mode=$4
  local ps='"scope":"document","document_count":0,' ss='"scan_scope":"document"'
  local counts='"containers":1,"points":8,"mismatch":0,"document_containers":1,"document_mismatch":0'
  case "$mode" in
    nodoccont)      counts='"containers":1,"points":8,"mismatch":0,"document_mismatch":0' ;;
    zerodoc)        counts='"containers":0,"points":0,"mismatch":0,"document_containers":0,"document_mismatch":0' ;;
    zerodoc_boards) counts='"containers":0,"points":0,"mismatch":0,"document_containers":0,"document_mismatch":0'; ss='"scan_scope":"boards"'; ps='"scope":"boards","document_count":0,' ;;
    zeroin)         counts='"containers":0,"points":0,"mismatch":0,"document_containers":216,"document_mismatch":0' ;;
  esac
  local si="$ps" ro="$ps" cp="$ps" ca="$ps" tx="$ps" bc="$ps"
  case "$mode" in
    nocount)   ro='"scope":"document",' ;;
    noscope)   cp='"document_count":0,' ;;
    badcount)  tx='"scope":"document","document_count":-1,' ;;
    boolcount) bc='"scope":"document","document_count":true,' ;;
    legacy6)   si=''; ro=''; cp=''; ca=''; tx=''; bc='' ;;
  esac
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '{"ticket":"LS-67","round":6,"head_sha":"'"$sha"'","total_nodes":4,"tree_hash":"'"$hash"'",'"$ss"',' \
    ' "scans":{"sibling_intersection":{'"$si"'"flagged":[]},"row_overflow":{'"$ro"'"flagged":[]},' \
    '  "cross_parent_collision":{'"$cp"'"flagged":[]},' \
    '  "corner_anchor":{'"$ca"'"boards":["d"],'"$counts"',"flagged":[],"unresolved":[]},' \
    '  "text_occlusion":{'"$tx"'"flagged":[],"document_flagged":[]},"board_clip":{'"$bc"'"flagged":[],"document_flagged":[]}}}' > "$path"
}

# ㊷ 六支各帶 scope／document_count → 綠，訊息含新欄位
sha42="$(land7 pr-perscan-ok perscan)"
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha42" "$(hash_of "$sha42")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（六支各帶 scope／document_count）'
expect 0 '㊷ 六支各帶 scope／document_count → 綠' '六支各帶 scope／document_count' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊷-b row_overflow 缺 document_count → 紅
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha42" "$(hash_of "$sha42")" nocount
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（row_overflow 缺 document_count）'
expect 1 '㊷-b 某支缺 document_count → 紅' 'scans.row_overflow.document_count 必須是非負整數（收據=None）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊷-c cross_parent_collision 缺 scope → 紅（LS-185 時 scope 可省略，LS-202 起必填）
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha42" "$(hash_of "$sha42")" noscope
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（cross_parent_collision 缺 scope）'
expect 1 '㊷-c 某支缺 scope → 紅' 'scans.cross_parent_collision 缺 scope' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊷-d document_count 負數／布林 → 紅
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha42" "$(hash_of "$sha42")" badcount
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（document_count=-1）'
expect 1 '㊷-d document_count 負數 → 紅' 'scans.text_occlusion.document_count 必須是非負整數（收據=-1）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha42" "$(hash_of "$sha42")" boolcount
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（document_count=true）'
expect 1 '㊷-e document_count 布林 → 紅' 'scans.board_clip.document_count 必須是非負整數（收據=True）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊸ 舊收據：head_sha tree 的腳本只有五＋六支（＝LS-194 r2 等既有收據形狀）、六支都沒帶 scope／document_count → 綠＋放行行
sha43="$(land7 pr-legacy-perscan sixth)"
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha43" "$(hash_of "$sha43")" legacy6
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（六支 schema，無 per-scan 欄位）'
expect 0 '㊸ head_sha tree 無 per-scan 標記、六支缺 scope／document_count → 綠並印放行行（cutoff 前）' 'LS-202 新欄位不要求——舊收據放行' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊹ N1 同形：.pen 最後一次落地時 tree 無 per-scan 標記；之後分支併入新腳本（不碰 .pen）→ 最新收據缺欄位 → 紅；同 head_sha 補齊 → 綠
sha44="$(land7 pr-late-perscan sixth)"
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha44" "$(hash_of "$sha44")" legacy6
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（六支 schema）'
add_script7
expect 1 '㊹ 最新收據 head_sha tree 無 per-scan 標記、但 PR head tree 已有 → 紅' 'PR head 的 tree 已含（新腳本已併入本分支）——最新輪次的 .pen 內容＝工作區，用現行 scripts/design/overflow-scan.js 對它重跑一次，把每支的 scope 與 document_count 補進' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha44" "$(hash_of "$sha44")" ok
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（新腳本重跑補 scope／document_count）'
expect 0 '㊹-b 同一 head_sha 補齊六支 scope／document_count → 綠' '六支各帶 scope／document_count' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ㊺ R2 minor-1：scan_scope=document 且 corner_anchor.document_containers=0（第四支靜默停擺的收據長相）→ 紅
sha45="$(land7 pr-zero-doc perscan)"
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha45" "$(hash_of "$sha45")" zerodoc
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（document_containers=0）'
expect 1 '㊺ scan_scope=document、corner_anchor.document_containers=0 → 紅（第四支停擺不是「沒有錯位」）' 'scans.corner_anchor.document_containers 為 0 而 scan_scope=document' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊺-b 同樣全零但 scan_scope=boards（限縮快照可能真的沒有印品）→ 綠
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha45" "$(hash_of "$sha45")" zerodoc_boards
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（boards 限縮、document_containers=0）'
expect 0 '㊺-b scan_scope=boards 且 document_containers=0 → 綠（限縮快照可無印品）' 'scan_scope=boards' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊺-c in-scope containers=0 但 document_containers=216（LS-133 r1–r3／LS-177 r1：boards 本來沒有印品）→ 綠
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha45" "$(hash_of "$sha45")" zeroin
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（containers=0、document_containers=216）'
expect 0 '㊺-c in-scope containers=0 而 document_containers=216 → 綠（boards 沒有印品是正常收據，LS-133 形狀）' '六支各帶 scope／document_count' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊺-d R3 minor-1：省略 document_containers 鍵（merge-review R2 探針 LS-202-probe-missingfield 的形狀）→ 紅，不得繞過歸零判定
write_receipt7 "$R/design/evidence/LS-67-r6-overflow.json" "$sha45" "$(hash_of "$sha45")" nodoccont
g add design/evidence/LS-67-r6-overflow.json
g commit -qm 'design(evidence): LS-67 r6 收據（省略 document_containers）'
expect 1 '㊺-d 省略 corner_anchor.document_containers → 紅（cutoff 下必填，省略鍵不得繞過）' 'scans.corner_anchor.document_containers 必填且須為非負整數（收據=None）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

# ───── LS-207：corner_anchor.ref_hits（ref 判準本身的哨兵，跟 document_containers 分開判）─────
# cutoff＝head_sha tree 的正典腳本含 REF_HITS_MARKER（"ref_hits" 字面）才要求；舊收據（腳本尚無此標記）缺欄位放行，
# 手法同 LS-202 perscan（land8／write_receipt8 仿 land7／write_receipt7）。
land8() {
  # land8 <branch> <script: refhits|perscan>（perscan＝有 document_count 標記但還沒有 ref_hits，模擬 cutoff 前）
  g checkout -q -b "$1" "$base_ref"
  printf '%s\n' "$pen4" > "$R/design/littlesprout.pen"
  g add design/littlesprout.pen
  mkdir -p "$R/scripts/design"
  if [ "$2" = refhits ]; then
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n// tag: scope + document_count\nref_hits\n' > "$R/scripts/design/overflow-scan.js"
  else
    printf '// synthetic canonical script\nfunction scanTextOcclusion() {}\nfunction scanBoardClip() {}\n// tag: scope + document_count\n' > "$R/scripts/design/overflow-scan.js"
  fi
  g add scripts/design/overflow-scan.js
  g commit -qm 'design(pen): LS-67 落地（LS-207 樣本）'
  g rev-parse HEAD
}
write_receipt8() {
  # write_receipt8 <path> <head_sha> <tree_hash> <mode: ok|missing|zero|zero_boards|zero_nameonly|neg|bool>
  local path=$1 sha=$2 hash=$3 mode=$4
  local ss='"scan_scope":"document"' rh=',"ref_hits":32'
  local counts='"containers":1,"points":8,"mismatch":0,"document_containers":1,"document_mismatch":0'
  case "$mode" in
    missing)      rh='' ;;
    zero)         rh=',"ref_hits":0' ;;
    zero_boards)  rh=',"ref_hits":0'; ss='"scan_scope":"boards"' ;;
    zero_nameonly) rh=',"ref_hits":0' ;;  # document_containers 仍是 1（預設 counts）：名稱備援撐住，但 ref 判準本身沒接上
    neg)          rh=',"ref_hits":-1' ;;
    bool)         rh=',"ref_hits":true' ;;
  esac
  local ps='"scope":"document","document_count":0,'
  [ "$ss" = '"scan_scope":"boards"' ] && ps='"scope":"boards","document_count":0,'
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '{"ticket":"LS-67","round":8,"head_sha":"'"$sha"'","total_nodes":4,"tree_hash":"'"$hash"'",'"$ss"',' \
    ' "scans":{"sibling_intersection":{'"$ps"'"flagged":[]},"row_overflow":{'"$ps"'"flagged":[]},' \
    '  "cross_parent_collision":{'"$ps"'"flagged":[]},' \
    '  "corner_anchor":{'"$ps"'"boards":["d"],'"$counts""$rh"',"flagged":[],"unresolved":[]},' \
    '  "text_occlusion":{'"$ps"'"flagged":[],"document_flagged":[]},"board_clip":{'"$ps"'"flagged":[],"document_flagged":[]}}}' > "$path"
}

# ㊻ ref_hits 非零、scan_scope=document → 綠
sha50="$(land8 pr-refhits-ok refhits)"
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" ok
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（ref_hits 非零）'
expect 0 '㊻ ref_hits 非零、scan_scope=document → 綠' '六支各帶 scope／document_count' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-b 省略 ref_hits 鍵（cutoff 已到）→ 紅
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" missing
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（省略 ref_hits）'
expect 1 '㊻-b 省略 corner_anchor.ref_hits → 紅（cutoff 下必填）' 'scans.corner_anchor.ref_hits 必填且須為非負整數（收據=None）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-c ref_hits 負數 → 紅
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" neg
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（ref_hits=-1）'
expect 1 '㊻-c ref_hits 負數 → 紅' 'scans.corner_anchor.ref_hits 必填且須為非負整數（收據=-1）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-d ref_hits 布林 → 紅
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" bool
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（ref_hits=true）'
expect 1 '㊻-d ref_hits 布林 → 紅' 'scans.corner_anchor.ref_hits 必填且須為非負整數（收據=True）' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-e ref_hits=0 且 scan_scope=document → 紅（ref 判準本身沒接上）
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" zero
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（ref_hits=0）'
expect 1 '㊻-e ref_hits=0、scan_scope=document → 紅（ref 判準沒接上）' 'scans.corner_anchor.ref_hits 為 0 而 scan_scope=document' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-f ref_hits=0 但 scan_scope=boards（限縮快照可能真的沒有 ref 命中）→ 綠
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" zero_boards
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（ref_hits=0，boards 限縮）'
expect 0 '㊻-f ref_hits=0、scan_scope=boards → 綠（限縮快照不判）' 'scan_scope=boards' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-g ref_hits=0 但 document_containers=1（名稱備援撐住）→ 仍紅：ref 判準本身是壞的，不因 document_containers 非零而放行
write_receipt8 "$R/design/evidence/LS-67-r8-overflow.json" "$sha50" "$(hash_of "$sha50")" zero_nameonly
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（ref_hits=0，document_containers 仍非零）'
expect 1 '㊻-g ref_hits=0 即使 document_containers 非零仍紅（兩個哨兵分開判）' 'scans.corner_anchor.ref_hits 為 0 而 scan_scope=document' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"
# ㊻-h cutoff 前（head_sha tree 的腳本尚無 ref_hits 標記）：省略 ref_hits 鍵仍綠、放行
sha51="$(land8 pr-legacy-refhits perscan)"
write_receipt7 "$R/design/evidence/LS-67-r8-overflow.json" "$sha51" "$(hash_of "$sha51")" ok
g add design/evidence/LS-67-r8-overflow.json
g commit -qm 'design(evidence): LS-67 r8 收據（cutoff 前，無 ref_hits 標記）'
expect 0 '㊻-h cutoff 前：省略 ref_hits → 綠（舊收據放行）' '六支各帶 scope／document_count' \
  "$R/design/littlesprout.pen" --ticket LS-67 --base "$base_ref"

if [ "$fail" -eq 0 ]; then
  echo "design-evidence-check.test.sh：全數通過"
else
  echo "design-evidence-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
