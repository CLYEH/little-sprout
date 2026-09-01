#!/bin/bash
# design-landing-check.sh 的自測（LS-26 原本沒有專屬 .test.sh，行為靠 pen-land.test.sh 間接涵蓋）。
# 本檔只補 LS-68 新增的 --print-nodes 旗標：design-evidence-check.sh 靠它重用同一套節點計數邏輯
# 比對掃描收據的 TOTAL_NODES，不能悄悄印錯數字、也不能在錯誤路徑下印出看起來像數字的東西。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/design-landing-check.sh"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <checker 參數…>
expect() {
  local want=$1 name=$2 must=$3 out got
  shift 3
  out="$(bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ① 合法 .pen（3 節點）：--print-nodes 只印純整數 3，無其他文字
f="$work/ok.pen"
printf '{"version":1,"children":[{"id":"a","children":[{"id":"b","children":[]}]},{"id":"c","children":[]}]}' > "$f"
out="$(bash "$check" "$f" --print-nodes 2>&1)"; got=$?
if [ "$got" -eq 0 ] && [ "$out" = "3" ]; then
  echo '✓ ① --print-nodes 只印純整數（3），無其他文字'
else
  echo "✗ ① --print-nodes 只印純整數（實得 exit=${got}，輸出「${out}」）" >&2
  fail=1
fi

# ② --expect-nodes 既有行為不受影響（正向對照，防止改動波及舊路徑）
expect 0 '② --expect-nodes 3（節點數相符）仍照舊通過' '節點數與畫布一致' "$f" --expect-nodes 3
expect 1 '② --expect-nodes 99（節點數不符）仍照舊擋下' '節點數' "$f" --expect-nodes 99

# ③ 0 bytes 檔：--print-nodes 模式一樣落在既有錯誤路徑（不印任何數字、exit 1）
empty="$work/empty.pen"
: > "$empty"
out="$(bash "$check" "$empty" --print-nodes 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '0 bytes'; then
  echo '✓ ③ 0 bytes 檔＋--print-nodes → 仍落既有錯誤路徑，不印數字'
else
  echo "✗ ③ 0 bytes 檔＋--print-nodes（實得 exit=${got}，輸出「${out}」）" >&2
  fail=1
fi

# ④ 壞 JSON：--print-nodes 模式一樣落在既有錯誤路徑
bad="$work/bad.pen"
printf '{not json' > "$bad"
out="$(bash "$check" "$bad" --print-nodes 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '不是有效 JSON'; then
  echo '✓ ④ 壞 JSON＋--print-nodes → 仍落既有錯誤路徑'
else
  echo "✗ ④ 壞 JSON＋--print-nodes（實得 exit=${got}，輸出「${out}」）" >&2
  fail=1
fi

# ⑤ --print-nodes 只在「恰好 2 個參數且第二個是 --print-nodes」時生效；3 個參數帶 --print-nodes 落回舊版驗證
expect 1 '⑤ 3 參數帶 --print-nodes（非 --expect-nodes）→ 落回用法錯誤' '第二參數必須恰為 --expect-nodes' "$f" --print-nodes extra

if [ "$fail" -eq 0 ]; then
  echo "design-landing-check.test.sh：全數通過"
else
  echo "design-landing-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
