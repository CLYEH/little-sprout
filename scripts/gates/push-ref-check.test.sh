#!/bin/bash
# push-ref-check.sh 的自測（LS-85 G4／LS-87 G4）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若退化成手動 push test／main 放行、非 FF 放行、沒 fetch 也放行、刪除／tag 仍跑整套 gate、
# feature push 被早退跳過 gate、或 push-gate.sh 沒接上本腳本——這裡會紅。合成 repo 只需要幾個 commit 的祖先關係。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/push-ref-check.sh"
gate="${root}/scripts/gates/push-gate.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
R="$work/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

g init -q -b main
echo a > "$R/f.txt"; g add -A; g commit -qm 'chore: LS-0 c0'; c0=$(g rev-parse HEAD)
echo b > "$R/f.txt"; g commit -qam 'chore: LS-0 c1'; c1=$(g rev-parse HEAD)          # c0 → c1（FF）
g checkout -q -b side "$c0"; echo s > "$R/s.txt"; g add -A; g commit -qm 'chore: LS-0 c2'; c2=$(g rev-parse HEAD)   # c0 → c2，與 c1 分岔
g checkout -q main
ZERO=0000000000000000000000000000000000000000
NOPE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

out=; rc=
# expect <期望 exit> <名稱> <輸出必含|''> <stdin 內容> [VAR=value…]
expect() {
  local want=$1 name=$2 must=$3 input=$4; shift 4
  out="$(cd "$R" && printf '%s' "$input" | env "$@" bash "$check" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then echo "✓ ${name}"
  else echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
}

DEL="(delete) ${ZERO} refs/heads/feature/LS-1-x ${c1}"$'\n'
TAG="refs/tags/v1.0.0 ${c1} refs/tags/v1.0.0 ${ZERO}"$'\n'
FEAT="refs/heads/feature/LS-1-x ${c1} refs/heads/feature/LS-1-x ${ZERO}"$'\n'
DEV="refs/heads/development ${c1} refs/heads/development ${c0}"$'\n'
PROMO_TEST="refs/remotes/origin/development ${c1} refs/heads/test ${c0}"$'\n'
PROMO_MAIN_NONFF="refs/remotes/origin/test ${c2} refs/heads/main ${c1}"$'\n'
PROMO_MAIN_UNKNOWN="refs/remotes/origin/test ${c1} refs/heads/main ${NOPE}"$'\n'
PROMO_TEST_NEW="refs/remotes/origin/development ${c1} refs/heads/test ${ZERO}"$'\n'
PROMO_TEST_SHA="${c1} ${c1} refs/heads/test ${c0}"$'\n'            # promote.sh 推 <sha>:refs/heads/test 的形狀（R1 F1）
DEL_TEST="(delete) ${ZERO} refs/heads/test ${c1}"$'\n'

# ---- 早退（LS-87 G4）----
expect 3 '① 刪除分支 → exit 3 不需 gate' '刪除 refs/heads/feature/LS-1-x' "$DEL"
expect 3 '② 推 tag → exit 3 不需 gate' '非分支' "$TAG"
expect 3 '③ 刪除＋tag 同一次 push → exit 3' '' "${DEL}${TAG}"
expect 3 '③′ 刪除 test（git push origin :test）→ client 早退、靠 server allow_deletions=false（R1 F6）' '刪除 refs/heads/test' "$DEL_TEST"

# ---- 需要完整 gate ----
expect 0 '④ feature 分支 push → exit 0（跑完整 gate）' '' "$FEAT"
expect 0 '⑤ 刪除＋feature 同一次 push → exit 0（有一條要驗就跑）' '' "${DEL}${FEAT}"
expect 0 '⑥ development 直接 push → exit 0（GitHub 端 require PR 擋，這裡不另判）' '' "$DEV"
expect 0 '⑦ 空 stdin（手動執行）→ exit 0 維持既有行為' '' ''

# ---- test／main（LS-85 G4）----
expect 1 '⑧ 手動 push test（無 PROMOTE_VIA_SCRIPT）→ 擋' 'promote.sh' "$PROMO_TEST"
expect 1 '⑨ PROMOTE_VIA_SCRIPT=yes（不是 1）→ 擋' 'promote.sh' "$PROMO_TEST" PROMOTE_VIA_SCRIPT=yes
expect 3 '⑩ promote.sh 且 FF → exit 3（晉升，不需完整 gate）' 'fast-forward' "$PROMO_TEST" PROMOTE_VIA_SCRIPT=1
expect 3 '⑩′ promote.sh 推 <sha>:refs/heads/test（local ref 欄是 sha）且 FF → exit 3' 'fast-forward' "$PROMO_TEST_SHA" PROMOTE_VIA_SCRIPT=1
expect 1 '⑪ promote.sh 但非 FF → 擋並指示 back-merge' 'back-merge' "$PROMO_MAIN_NONFF" PROMOTE_VIA_SCRIPT=1
expect 1 '⑫ promote.sh 但遠端 tip 本機沒有 → 擋（先 fetch，fail closed）' 'git fetch origin' "$PROMO_MAIN_UNKNOWN" PROMOTE_VIA_SCRIPT=1
expect 1 '⑬ promote.sh 但遠端沒有 test → 擋' '遠端沒有 test' "$PROMO_TEST_NEW" PROMOTE_VIA_SCRIPT=1
expect 0 '⑭ 晉升＋feature 同一次 push → exit 0（feature 那條要驗）' '' "${PROMO_TEST}${FEAT}" PROMOTE_VIA_SCRIPT=1
expect 1 '⑮ 晉升被擋＋feature 同一次 push → 擋優先' 'promote.sh' "${PROMO_TEST}${FEAT}"

# ---- 格式 ----
expect 2 '⑯ stdin 不是 4 欄 → exit 2' '4 欄' "refs/heads/x ${c1} refs/heads/x"$'\n'

# ---- 接線：push-gate.sh 開頭讀 stdin 交給本腳本——早退 exit 0、擋 exit 1，都不跑後面的 lint／tests ----
if grep -q 'push-ref-check.sh' "$gate"; then echo "✓ ⑰ push-gate.sh 有呼叫 push-ref-check.sh"; else echo "✗ ⑰ push-gate.sh 沒接 push-ref-check.sh" >&2; fail=1; fi
mkdir -p "$R/scripts/gates"; cp "$gate" "$check" "$R/scripts/gates/"
out="$(cd "$R" && printf '%s' "$DEL" | bash scripts/gates/push-gate.sh 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '無需完整 gate'; then echo "✓ ⑰ 經 push-gate.sh：刪除分支 → exit 0 早退"; else echo "✗ ⑰ 經 push-gate.sh 刪除分支應 exit 0 早退（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
out="$(cd "$R" && printf '%s' "$PROMO_TEST" | bash scripts/gates/push-gate.sh 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'promote.sh'; then echo "✓ ⑰ 經 push-gate.sh：手動 push test → exit 1"; else echo "✗ ⑰ 經 push-gate.sh 手動 push test 應 exit 1（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
out="$(cd "$R" && printf '%s' "$PROMO_TEST" | PROMOTE_VIA_SCRIPT=1 bash scripts/gates/push-gate.sh 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '無需完整 gate'; then echo "✓ ⑰ 經 push-gate.sh：promote.sh FF → exit 0 早退"; else echo "✗ ⑰ 經 push-gate.sh promote FF 應 exit 0 早退（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ push-ref-check 自測失敗" >&2
  exit 1
fi
echo "✓ push-ref-check 自測通過（18 組＋接線 4 項）"
