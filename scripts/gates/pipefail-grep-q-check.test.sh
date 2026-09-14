#!/bin/bash
# pipefail-grep-q-check.sh 的自測（LS-270）。CI rules job 每個 PR 都跑。
#
# 夾具正負各一是底線（票文驗收）：正＝檔內有 `pipefail` ＋ `| grep -q` → ⚠；負＝同一份內容拿掉
# `set -o pipefail` → 無 ⚠（這也是票文指定的 mutation：「夾具拿掉 pipefail → 無 ⚠」）。另外釘住
# 「informational 不擋」（有 ⚠ 也 exit 0）、`--list` 逐處輸出、純註解行不算（LS-267 R3 之後
# `patrol-filter.test.sh` 只剩註解裡的反例，不該被列）、只掃 `*.test.sh`、拆開寫的旗標（`-F -q`）
# 也算、參數 fail closed。
#
# 本檔自己的斷言一律用 here-string（`grep -qF -- "$pat" <<<"$out"`）而不是 `printf … | grep -q`：
# 這支 gate 要提醒的正是後者（本機 BSD grep 永遠綠、ubuntu 的 GNU grep 在大輸入下回 141）。
# 註：本檔的夾具內容（下面幾個 heredoc）字面上含有 `| grep -q`，所以對真 repo 掃描時本檔會被算進
# ⚠ 的處數——那是誠實的計數（gate 是純文字比對，不看輸入大小），這些夾具的輸入只有幾十位元組。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/gates/pipefail-grep-q-check.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect() {   # expect <期望 exit> <名稱> <實得 exit> <輸出> [必含…]
  local want=$1 name=$2 got=$3 out=$4; shift 4
  local good=1 must
  [ "$got" -eq "$want" ] || good=0
  for must in "$@"; do grep -qF -- "$must" <<<"$out" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2; sed 's/^/    /' <<<"$out" >&2; fail=1
  fi
}
refute() {   # refute <名稱> <輸出> <不該出現的字串>
  if grep -qF -- "$3" <<<"$2"; then bad "${1}（輸出不該含「${3}」）"; sed 's/^/    /' <<<"$2" >&2; else ok "$1"; fi
}

# ---- 夾具 ----
pos="$work/pos"; neg="$work/neg"; mixed="$work/mixed"; empty="$work/empty"
mkdir -p "$pos" "$neg" "$mixed" "$empty"

# 正：pipefail（`set -uo pipefail` 形，repo 內最常見的寫法）＋兩處 `| grep -q`
cat > "$pos/alpha.test.sh" <<'STUB'
#!/bin/bash
set -uo pipefail
out=$(some_command)
printf '%s' "$out" | grep -qF -- '預期字串' || exit 1
printf '%s' "$out" | grep -q 'another' && echo hit
STUB

# 負（票文 mutation）：同一份內容，只拿掉 `set -o pipefail` 那一行
sed '/pipefail/d' "$pos/alpha.test.sh" > "$neg/alpha.test.sh"

# 混合：① 純註解行的反例不算 ② 開了 pipefail 但沒有 grep -q 的檔不算 ③ 非 *.test.sh 不掃
#       ④ 拆開寫的旗標 `grep -F -q` 也算
cat > "$mixed/commented.test.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
# 反例（別這樣寫）：printf '%s' "$big" | grep -q pat
echo ok
STUB
cat > "$mixed/clean.test.sh" <<'STUB'
#!/bin/bash
set -o pipefail
grep -qF -- pat "$file"
STUB
cat > "$mixed/split-flags.test.sh" <<'STUB'
#!/bin/bash
set -uo pipefail
printf '%s' "$out" | grep -F -q -- pat
STUB
cat > "$mixed/not-a-test.sh" <<'STUB'
#!/bin/bash
set -uo pipefail
printf '%s' "$out" | grep -q pat
STUB

# ---- ① 正夾具 → ⚠、但 exit 0（informational 不擋）----
out=$(bash "$script" --scan-dir "$pos" 2>&1); got=$?
expect 0 '① 正夾具：pipefail ＋ | grep -q → ⚠，且 exit 0（informational 不擋）' "$got" "$out" \
  '⚠ pipefail-grep-q-check：2 處' '1 支開了 pipefail 的自測' 'informational，一律 exit 0 不擋'

# ---- ② 負夾具（mutation：拿掉 pipefail）→ 無 ⚠ ----
out=$(bash "$script" --scan-dir "$neg" 2>&1); got=$?
expect 0 '② 負夾具（mutation：拿掉 set -o pipefail）→ 無 ⚠、報「都沒有」' "$got" "$out" \
  '✓ pipefail-grep-q-check：1 支自測都沒有'
refute '② 負夾具不得出現 ⚠' "$out" '⚠'

# ---- ③ 混合夾具：註解不算、無 grep -q 的檔不算、非 .test.sh 不掃、拆開旗標要算 ----
out=$(bash "$script" --scan-dir "$mixed" --list 2>&1); got=$?
expect 0 '③ 混合夾具：只算 split-flags.test.sh 一處（拆開寫的 -F -q 也算）' "$got" "$out" \
  '⚠ pipefail-grep-q-check：1 處' 'split-flags.test.sh'
refute '③a 純註解行的反例不算（LS-267 R3 的 patrol-filter.test.sh 形狀）' "$out" 'commented.test.sh'
refute '③b 開了 pipefail 但沒有 | grep -q 的檔不算' "$out" 'clean.test.sh'
refute '③c 非 *.test.sh 不掃' "$out" 'not-a-test.sh'

# ---- ④ --list 逐處列行號與原文；不帶 --list 只印摘要 ----
out=$(bash "$script" --scan-dir "$pos" --list 2>&1); got=$?
expect 0 '④ --list 逐處列出「檔:行號  原文」' "$got" "$out" 'alpha.test.sh:4' 'alpha.test.sh:5' "grep -qF -- '預期字串'"
out=$(bash "$script" --scan-dir "$pos" 2>&1); got=$?
expect 0 '④b 不帶 --list 只印摘要＋怎麼取清單' "$got" "$out" '逐處清單：bash scripts/gates/pipefail-grep-q-check.sh --list'
refute '④c 不帶 --list 不逐行灌 log' "$out" 'alpha.test.sh:4'

# ---- ⑤ 空目錄／不存在的目錄 → 略過、exit 0 ----
out=$(bash "$script" --scan-dir "$empty" 2>&1); got=$?
expect 0 '⑤ 目錄下沒有 *.test.sh → 略過、exit 0' "$got" "$out" '沒有 *.test.sh，略過'
out=$(bash "$script" --scan-dir "$work/no-such-dir" 2>&1); got=$?
expect 0 '⑤b 目錄不存在 → 略過、exit 0' "$got" "$out" '，略過'

# ---- ⑥ 參數 fail closed ----
out=$(bash "$script" --bogus 2>&1); got=$?
expect 2 '⑥ 未知參數 → exit 2' "$got" "$out" '未知參數'
out=$(bash "$script" --scan-dir 2>&1); got=$?
expect 2 '⑥b --scan-dir 缺值 → exit 2' "$got" "$out" '--scan-dir 缺值'
out=$(bash "$script" --help 2>&1); got=$?
expect 0 '⑥c --help → exit 0、印用法' "$got" "$out" '用法：pipefail-grep-q-check.sh'

# ---- ⑦ 對真 repo：一律 exit 0（gate 掛 rules job，永遠不能因為這支而紅）----
out=$(bash "$script" 2>&1); got=$?
expect 0 '⑦ 對真 repo（預設 scan-dir）exit 0' "$got" "$out" 'pipefail-grep-q-check'

if [ "$fail" -ne 0 ]; then echo "✗ pipefail-grep-q-check 自測失敗" >&2; exit 1; fi
echo "✓ pipefail-grep-q-check 自測通過（${n} 組樣本）"
