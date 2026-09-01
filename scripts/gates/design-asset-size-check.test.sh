#!/bin/bash
# design-asset-size-check.sh 的自測（LS-74）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若判定退化成用副檔名猜二進位（誤放行沒有 .png 副檔名的二進位、
# 或誤擋大型文字檔）、門檻反轉（>／< 顛倒）、邊界算錯（500 KB 本身該放行卻被擋、500 KB+1 該擋卻放行）、
# 誤把既有未觸碰的大檔一併掃到、誤擋刪除、或 --base 模式沒真的接上，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/design-asset-size-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 臨時 repo 與本機全域／系統 git 設定隔離：自測結果不能因人而異
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# mkbin <相對路徑> <bytes>：全零內容（保證含 NUL、git 判定為二進位）
mkbin() { local p=$1 n=$2; mkdir -p "$work/repo/$(dirname "$p")"; head -c "$n" /dev/zero > "$work/repo/$p"; }
# mktxt <相對路徑> <bytes>：純文字內容（無 NUL、git 判定為文字，可 delta）
mktxt() { local p=$1 n=$2; mkdir -p "$work/repo/$(dirname "$p")"; yes hello | head -c "$n" > "$work/repo/$p"; }

expect() {
  local want=$1 name=$2 must=${3:-} out got
  out="$(bash "$checker" "$work/repo" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

mkdir -p "$work/repo"
g init -q

# ① design/ 下小型二進位（<500KB）→ 綠
mkbin design/small.png 1000
g add design/small.png
expect 0 '① design/ 下小型二進位（1000 bytes）→ 綠'
g commit -qm base1

# ② design/ 下大型二進位（600000 bytes）→ 紅，點名該檔
mkbin design/big.png 600000
g add design/big.png
expect 1 '② design/big.png（二進位，600000 bytes）→ 紅' 'design/big.png'
g rm -q --cached design/big.png

# ③ design/ 下大型文字檔（.pen JSON 模擬，600000 bytes）→ 綠（文字不限）
mktxt design/littlesprout.pen 600000
g add design/littlesprout.pen
expect 0 '③ design/littlesprout.pen（文字，600000 bytes）→ 綠（不限）'
g rm -q --cached design/littlesprout.pen

# ④ design/ 外的大型二進位（LittleSprout/Assets.xcassets/）→ 綠（範圍只看 design/）
mkbin LittleSprout/Assets.xcassets/icon.png 600000
g add LittleSprout/Assets.xcassets/icon.png
expect 0 '④ design/ 外大型二進位（Assets.xcassets）→ 綠（範圍限定 design/）'
g rm -q --cached LittleSprout/Assets.xcassets/icon.png

# ⑤ 既有大型二進位已 commit、這次 diff 完全沒碰到 → 綠（不重寫歷史、不掃未觸碰檔）
mkbin design/existing-big.png 600000
g add design/existing-big.png
g commit -qm 'existing big png'
mktxt design/unrelated.txt 10
g add design/unrelated.txt
expect 0 '⑤ 既有大型二進位未被本次 diff 觸碰 → 綠'
g commit -qm unrelated

# ⑥ 純改名既有大型二進位（內容不變）→ 紅（--no-renames 拆成 delete+add，改名仍算碰了這個路徑）
g mv design/existing-big.png design/renamed-big.png
expect 1 '⑥ 純改名既有大型二進位 → 紅（改名視為觸碰）' 'design/renamed-big.png'
g mv design/renamed-big.png design/existing-big.png

# ⑦ 修改既有大型二進位內容（同路徑）→ 紅
mkbin design/existing-big.png 650000
g add design/existing-big.png
expect 1 '⑦ 修改既有大型二進位內容（同路徑）→ 紅' 'design/existing-big.png'
g checkout -q HEAD -- design/existing-big.png

# ⑧ 邊界：剛好 500 KB（512000 bytes）→ 綠（只有「嚴格大於」才擋）
mkbin design/boundary.png 512000
g add design/boundary.png
expect 0 '⑧ 邊界：剛好 512000 bytes → 綠'
g rm -q --cached design/boundary.png

# ⑨ 邊界：500 KB + 1 byte（512001 bytes）→ 紅
mkbin design/boundary2.png 512001
g add design/boundary2.png
expect 1 '⑨ 邊界：512001 bytes → 紅' 'design/boundary2.png'
g rm -q --cached design/boundary2.png

# ⑩ 刪除既有大型二進位（staged D）→ 綠（清掉大檔要放行，同 evidence-path-check 的邏輯）
g rm -q design/existing-big.png
expect 0 '⑩ 刪除既有大型二進位（staged D）→ 綠'
g commit -qm 'remove big png'

# ⑪ 多檔命中一次全列（不是碰到第一個就停）
mkbin design/multi-a.png 600000
mkbin design/multi-b.png 700000
g add design/multi-a.png design/multi-b.png
expect 1 '⑪ 多檔命中一次全列（第一檔）' 'design/multi-a.png'
expect 1 '⑪′ 多檔命中一次全列（第二檔）' 'design/multi-b.png'
g rm -q --cached design/multi-a.png design/multi-b.png

# ⑫ design/evidence/*.json 大型文字（LS-68 溢出掃描收據）→ 綠（相容性明驗）
mktxt design/evidence/LS-74-r1-overflow.json 600000
g add design/evidence/LS-74-r1-overflow.json
expect 0 '⑫ design/evidence/LS-74-r1-overflow.json（文字，LS-68 收據）→ 綠'
g rm -q --cached design/evidence/LS-74-r1-overflow.json

# ⑬ 非 git 目錄 → exit 2 fail closed，且不噴 git diff 原始 usage
mkdir -p "$work/notrepo"
out="$(bash "$checker" "$work/notrepo" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'fail closed' && ! printf '%s' "$out" | grep -qF 'usage: git diff'; then
  echo '✓ ⑬ 非 git 目錄 → exit 2 fail closed、無 usage 噴版'
else
  echo "✗ ⑬ 非 git 目錄 → exit 2 fail closed、無 usage 噴版（實得 ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi

# ⑭ --base 缺 ref 參數 → exit 2 fail closed
out="$(bash "$checker" --base 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'fail closed'; then
  echo '✓ ⑭ --base 缺 ref 參數 → exit 2 fail closed'
else
  echo "✗ ⑭ --base 缺 ref 參數 → exit 2 fail closed（實得 ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi

# ⑮ --base 指到不存在的 ref → exit 2 fail closed
out="$(bash "$checker" --base does-not-exist-ref "$work/repo" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'fail closed'; then
  echo '✓ ⑮ --base 指到不存在的 ref → exit 2 fail closed'
else
  echo "✗ ⑮ --base 指到不存在的 ref → exit 2 fail closed（實得 ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi

# ⑯／⑰ --base 模式：對 base...HEAD 套同一套規則——CI rules job 對 PR merge ref 跑的正是這個模式。
# 若實作忽略 --base、悄悄退回看 --cached（staged 是空的，因為違規檔是 commit 進 head 分支、不是
# staged），⑯ 會從期望的紅假綠成綠，當場抓到接線斷掉。
base_ref="$(g rev-parse HEAD)"
g checkout -qb pr-violates "$base_ref"
mkbin design/violate.png 600000
g add design/violate.png
g commit -qm violate
out="$(bash "$checker" --base "$base_ref" "$work/repo" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'design/violate.png'; then
  echo '✓ ⑯ --base 模式：head 分支 committed（非 staged）違規檔 → 紅，點名路徑'
else
  echo "✗ ⑯ --base 模式：head 分支 committed 違規檔 → 紅，點名路徑（實得 ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi

g checkout -q "$base_ref"
g checkout -qb pr-clean "$base_ref"
mktxt design/clean.txt 10
g add design/clean.txt
g commit -qm clean
out="$(bash "$checker" --base "$base_ref" "$work/repo" 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then
  echo '✓ ⑰ --base 模式：head 分支只有乾淨變更 → 綠'
else
  echo "✗ ⑰ --base 模式：head 分支只有乾淨變更 → 綠（實得 ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi
g checkout -q "$base_ref"

if [ "$fail" -ne 0 ]; then
  echo "✗ design-asset-size-check 自測失敗" >&2
  exit 1
fi
echo "✓ design-asset-size-check 自測通過"
