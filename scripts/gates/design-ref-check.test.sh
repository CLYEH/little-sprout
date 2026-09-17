#!/bin/bash
# design-ref-check.sh 的自測（LS-316）。CI rules job「Gate 腳本自測」step 跑。
# 合成 git repo＋合成 .pen（頂層節點＝板／reusable component，同一層級不特別過濾）＋合成 PR body，五例＋mutation：
#   ① 名稱相符（`板名（id）`，id 存在、名稱與 .pen 頂層節點一致）→ 綠
#   ② id 缺（body 引用的 id 不在 .pen 頂層節點內）→ 紅，訊息列該 id
#   ③ 名稱不符（id 存在但宣稱的板名與 .pen 實際名稱不同）→ 紅，訊息列宣稱名稱 vs 實際名稱
#   ④ 純 id 寫法（無括號、無宣稱名稱，只驗存在性）→ 綠
#   ⑤ 無 Design: 行 → 綠，exit 0 且訊息交代「交既有非空檢查決定」
#   ⑥（LS-316 基準跑 PR #33 抓到的真實邊界）Design: 欄位留空（模板未填）→ 綠，且不需讀 .pen 快照
#     （不給 --head-sha 對應的 commit，證明真的沒呼叫 git show：若程式碰了 pen 快照這裡就會因 head
#     解析不到而炸，不會安靜綠過）
#   ⑦ mutation（票文「板名改一字」的形狀）：③ 的合成夾具改一字，紅的訊息隨之換成新字——證明紅是
#     逐字比對造成的、不是空跑
# 五例＋mutation 對應票文驗收「design-ref-check.test.sh 夾具：名稱相符／id 缺／名稱不符／純 id 寫法／
# 無 Design 行 五例綠；mutation（#475 body 改一字）紅」——後半句（用真實 PR #475 body／.pen 跑基準與
# mutation）是 LS-316 基準步驟本身（scratchpad/LS-316-baseline/、handoff 附證據)，不進這支合成夾具
# （合成 repo 沒有 PR #475 的歷史 commit 可 git show）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/design-ref-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

source "${root}/scripts/gates/lib/selftest-helpers.sh"

expect() {
  # expect <期望 exit> <名稱> <輸出必含|''> <輸出必不含|''> <body 檔> <pen 路徑…>
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

# pen <頂層節點 JSON 片段…>：組成合成 .pen（version＋children）
pen() {
  local body
  body=$(IFS=,; printf '%s' "$*")
  printf '{"version":"2.17","children":[%s]}\n' "$body" > "$R/design/littlesprout.pen"
}
# board <id> <name>：一塊頂層節點（板或 reusable component 皆同形狀，本 gate 不分）
board() { printf '{"type":"frame","id":"%s","name":"%s","children":[]}' "$1" "$2"; }
commit_pen() { g add design/littlesprout.pen; g commit -qm "$1"; }
body_file() { local f="$work/$1"; shift; printf '%s\n' "$@" > "$f"; printf '%s' "$f"; }

mkdir -p "$R/design"
g init -q -b main
# ⑥ 用：先有一個 design/littlesprout.pen 根本不存在的早期 commit（同 LS-316 基準跑撞到的 PR #33 真實
# 形狀——那個年代還沒有 .pen 檔）；若程式在「沒有條目可核對」時仍去 git show 這個 sha 的 .pen，會像
# PR #33 一樣因「path exists on disk, but not in <sha>」而 exit 2。
echo x > "$R/README.md"; g add README.md; g commit -qm 'init（尚無 .pen）'
early_sha="$(g rev-parse HEAD)"
# 板 Ab12Cd＝「01 板」、reusable component Xk9f2y＝「cmp/Button Import」（同一層級頂層節點，皆可被 Design: 引用）
pen "$(board Ab12Cd '01 板')" "$(board Xk9f2y 'cmp/Button Import')"
commit_pen base

# ① 名稱相符 → 綠
b1=$(body_file body-1.md 'Ticket: LS-1' '' 'Design: 01 板（`Ab12Cd`）')
expect 0 '① 板名（id）與 .pen 頂層節點名稱相符 → 綠' '缺 id 0、名稱不符 0' '' "$b1" design/littlesprout.pen

# ② id 缺：body 引用的 id 不在 .pen 頂層節點內 → 紅
b2=$(body_file body-2.md 'Design: 01 板（`Zz9k1p`）')
expect 1 '② body 引用的 id 不在 .pen 頂層節點內 → 紅，列該 id' 'id Zz9k1p 不在 .pen 頂層節點內' '' "$b2" design/littlesprout.pen

# ③ 名稱不符：id 存在但宣稱的板名與 .pen 實際名稱不同 → 紅，列宣稱 vs 實際
b3=$(body_file body-3.md 'Design: 99 錯板（`Ab12Cd`）')
expect 1 '③ id 存在但宣稱板名與 .pen 實際名稱不符 → 紅，列宣稱名稱與實際名稱' 'body 寫板名「99 錯板」，.pen 頂層節點 Ab12Cd 實際名稱「01 板」' '' "$b3" design/littlesprout.pen

# ④ 純 id 寫法：無括號、無宣稱名稱，只驗存在性 → 綠
b4=$(body_file body-4.md 'Design: Ab12Cd、Xk9f2y')
expect 0 '④ 純 id 寫法（無宣稱名稱，逗號／頓號分隔皆存在）→ 綠' '條目 2 筆、缺 id 0' '✗ Design 行' "$b4" design/littlesprout.pen

# ⑤ 無 Design: 行 → 綠
b5=$(body_file body-5.md 'Ticket: LS-1' '' '變更：foo')
expect 0 '⑤ body 無 Design: 行 → 綠，訊息交代交既有非空檢查決定' '無 Design: 行，交既有非空檢查決定' '' "$b5" design/littlesprout.pen

# ⑥（LS-316 基準跑 PR #33 抓到的真實邊界）Design: 欄位留空（模板未填）→ 綠，且不讀 .pen 快照：指向
#     「.pen 根本不存在」的早期 commit（early_sha），若程式在沒有條目可核對時仍去 git show 那個 sha 的
#     .pen，會像 PR #33 一樣炸成 exit 2（「path exists on disk, but not in <sha>」），而不是安靜綠過
b6=$(body_file body-6.md 'Design:')
expect 0 '⑥ Design: 欄位留空（模板未填）→ 綠，且不讀 .pen 快照（指向 .pen 尚不存在的早期 commit 仍綠，證明沒呼叫 git show）' '條目 0 筆——無條目可核對' '' "$b6" design/littlesprout.pen --head-sha "$early_sha"

# ⑦ mutation：③ 的合成夾具板名多打一個字，紅的訊息隨之換字——證明紅是逐字比對造成的、不是空跑
b7=$(body_file body-7.md 'Design: 99 錯板改（`Ab12Cd`）')
expect 1 '⑦ mutation：③ 板名改一字，紅訊息的宣稱名稱隨之換成新字' 'body 寫板名「99 錯板改」，.pen 頂層節點 Ab12Cd 實際名稱「01 板」' '99 錯板」' "$b7" design/littlesprout.pen

if [ "$fail" -eq 0 ]; then
  echo "design-ref-check.test.sh：全數通過"
else
  echo "design-ref-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
