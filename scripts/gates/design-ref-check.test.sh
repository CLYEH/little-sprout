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
#   ⑧（LS-318；LS-96 池項 `6fee5681`）形狀不明（如 `Design: 見上方截圖`，不是「板名（id）」也不是純
#     id token）→ 綠、印「（略過）」提示行、exit 0——這是 design_ref_check.py:110,160-164 既有的
#     `skipped` 分支，這支腳本落地以來零夾具命中過它
#   ⑨–⑭（LS-489）`Design:` 行指定 .pen 路徑（`<路徑>.pen:` 前綴）：⑨ 提案稿新格式 → 綠；⑩ 提案稿 id 不存在 → 紅；
#     ⑪ 路徑不存在 → 紅；⑫ 路徑在 allowlist 外 → 紅；⑬ 前綴與主稿並存（兩行 Design:）各查各的 → 綠；
#     ⑭ mutation（拿掉路徑解析，前綴行改回對主稿查）→ ⑨ 由綠轉紅
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

# ⑧（LS-318）形狀不明：不是「板名（id）」也不是純 id token（票文範例「見上方截圖」）→ 綠、印
#   「（略過）」提示、exit 0；不得出現「✗ Design 行」（沒有東西被判定違規，只是沒核對）
b8=$(body_file body-8.md 'Design: 見上方截圖')
expect 0 '⑧ 形狀不明（Design: 見上方截圖）→ 綠、印略過提示' '（略過）Design 行「見上方截圖」：無法解析為「板名（id）」或純 id，未核對（design-ref-check 盲區）' '✗ Design 行' "$b8" design/littlesprout.pen

# ---- LS-489：提案稿路徑 ----
# 提案稿板 Pr0pAb（與主稿的 Ab12Cd 刻意不同 id，證明「查對檔」）、Pr0pCm
mkdir -p "$R/docs/design-proposals/p1"
prop=docs/design-proposals/p1/p.pen
printf '{"version":"2.17","children":[%s,%s]}\n' "$(board Pr0pAb 'C / 01 提案板')" "$(board Pr0pCm 'cmp/提案元件')" > "$R/$prop"
g add "$prop"; g commit -qm proposal

# ⑨ 提案稿新格式（行級路徑前綴＋板名（id）、純 id 混用）→ 綠
b9=$(body_file body-9.md "Design: ${prop}: C / 01 提案板（\`Pr0pAb\`）、Pr0pCm")
expect 0 '⑨ 提案稿路徑前綴＋板名（id）／純 id → 綠' '條目 2 筆、缺 id 0、名稱不符 0、略過 0、路徑錯誤 0' '✗' "$b9" design/littlesprout.pen

# ⑩ 提案稿 id 不存在（Ab12Cd 在主稿但不在提案稿）→ 紅，且列出該提案稿路徑
b10=$(body_file body-10.md "Design: ${prop}: Ab12Cd")
expect 1 '⑩ 提案稿內查無該 id（id 只在主稿）→ 紅' "id Ab12Cd 不在 .pen 頂層節點內" '' "$b10" design/littlesprout.pen

# ⑪ 路徑不存在（allowlist 內但檔案不存在）→ 紅
b11=$(body_file body-11.md 'Design: docs/design-proposals/nope/x.pen: Pr0pAb')
expect 1 '⑪ 提案稿路徑在 head 不存在 → 紅' '路徑「docs/design-proposals/nope/x.pen」：在 head 不存在' '' "$b11" design/littlesprout.pen

# ⑫ 路徑在 allowlist 外（即便檔案存在）→ 紅
mkdir -p "$R/other"; cp "$R/$prop" "$R/other/q.pen"; g add other/q.pen; g commit -qm other
b12=$(body_file body-12.md 'Design: other/q.pen: Pr0pAb')
expect 1 '⑫ 路徑在 allowlist 外 → 紅' '路徑「other/q.pen」：不在 allowlist' '' "$b12" design/littlesprout.pen
b12b=$(body_file body-12b.md 'Design: docs/design-proposals/../../other/q.pen: Pr0pAb')
expect 1 '⑫b 路徑含 .. 逃出 allowlist → 紅' 'allowlist' '' "$b12b" design/littlesprout.pen

# ⑬ 主稿舊格式行與提案稿前綴行並存，各查各的 → 綠
b13=$(body_file body-13.md 'Design: 01 板（`Ab12Cd`）' "Design: ${prop}: Pr0pAb")
expect 0 '⑬ 主稿舊格式行＋提案稿前綴行並存 → 綠' '缺 id 0、名稱不符 0、略過 0、路徑錯誤 0' '✗' "$b13" design/littlesprout.pen

# ⑭ mutation：拿掉路徑解析（split_pen_prefix 永遠回 None），⑨ 由綠轉紅（前綴行被當成不明形狀或對主稿查）
mut_dir="$work/mut-gates"; mkdir -p "$mut_dir"
cp "${root}/scripts/gates/design-ref-check.sh" "${root}/scripts/gates/design_ref_check.py" "$mut_dir/"
python3 - "$mut_dir/design_ref_check.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
a = '    m = PEN_PREFIX_RE.match(content)\n'
assert a in s, "mutation 錨點不見了——design_ref_check.py 的 split_pen_prefix 改過，請更新這裡"
open(p, "w", encoding="utf-8").write(s.replace(a, '    m = None\n', 1))
PY
mut_out="$(cd "$R" && bash "$mut_dir/design-ref-check.sh" "$b9" design/littlesprout.pen 2>&1)"; mut_rc=$?
if [ "$mut_rc" -ne 0 ] && has "$mut_out" "不在 .pen 頂層節點內"; then
  echo "✓ ⑭ mutation：拿掉路徑解析後 ⑨ 的新格式由綠轉紅（rc=${mut_rc}）"
else
  echo "✗ ⑭ mutation：拿掉路徑解析後 ⑨ 仍綠或訊息不符（rc=${mut_rc}）——路徑解析沒被自測守住" >&2
  printf '%s\n' "$mut_out" | sed 's/^/    /' >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "design-ref-check.test.sh：全數通過"
else
  echo "design-ref-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
