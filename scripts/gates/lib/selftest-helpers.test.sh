#!/bin/bash
# scripts/gates/lib/selftest-helpers.sh 的自測（LS-301）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支共用庫本身也適用：has()／expect_exit()／expect_has()／expect_not_has() 任一個
# 對「餵錯」沒有回非 0，這裡就要紅。另外驗證：source 真正的庫時自動跑過自檢（不用任何呼叫端就能看到
# 它在跑）；呼叫端已自行定義 ok()／fail() 時不被覆寫（既有 6 支換用的檔案各自的 n／fail 計數慣例不受
# 影響）；以及票文指定的 mutation——把 has() 改成永遠 return 0，source 這份壞掉的庫要整個炸掉並印
# 「助手自檢失敗」，不能悄悄放行。
#
# 注意：本檔自己的計數函式刻意命名為 mark_ok／mark_bad（不叫 ok／fail）——`source "$lib"` 都在
# `$(...)` 子殼層裡執行，子殼層會繼承目前殼層已定義的函式；若這裡也定義一個叫 `ok` 的頂層函式，
# 子殼層裡 `declare -F ok` 會看到它已存在，共用庫的 guard 就不會安裝自己的預設 ok()，導致
# `selftest_helpers_n` 這類計數斷言失真（本檔開發過程中實際踩到這個坑，才確定要避開這個名字）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="${root}/scripts/gates/lib/selftest-helpers.sh"
fail=0
n=0
mark_ok() { echo "✓ $1"; n=$((n + 1)); }
mark_bad() { echo "✗ $1" >&2; fail=1; }

[ -f "$lib" ] || { echo "✗ 找不到 ${lib}" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- ① source 真正的庫不炸、has() 提供的行為正確 ----
(
  set -uo pipefail
  source "$lib"
  has 'abcdef' 'cde' && has 'abcdef' 'zzz'
) >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  mark_ok '① source 真正的庫成功、has() 對命中回 0、對沒命中回非 0（複合條件因後者而整體非 0）'
else
  mark_bad '① source 應成功且複合條件應為非 0（實得 0）'
fi

# ---- ② has()：命中／沒命中的獨立正負樣本 ----
( source "$lib"; has 'abcdef' 'cde' )
[ $? -eq 0 ] && mark_ok '② has 命中 → exit 0' || mark_bad '② has 命中應 exit 0'
( source "$lib"; has 'abcdef' 'zzz' )
[ $? -ne 0 ] && mark_ok '② has 沒命中 → exit 非 0' || mark_bad '② has 沒命中應 exit 非 0'

# ---- ③ expect_exit：命中印 ✓、不命中印 ✗ 且原因清楚；回傳值分別為 0／1 ----
out="$(
  {
  source "$lib"
  expect_exit 0 0 '③a 命中'; echo "rc3a=$?"
  expect_exit 0 1 '③b 不命中'; echo "rc3b=$?"
  } 2>&1
)"
if grep -qF -- '✓ ③a 命中' <<<"$out" && grep -qF -- 'rc3a=0' <<<"$out"; then
  mark_ok '③ expect_exit 命中印 ✓ 且回傳 0'
else
  mark_bad "③ expect_exit 命中應印 ✓ 且回傳 0（實得：${out}）"
fi
if grep -qF -- '✗ ③b 不命中（期望 exit 0，實得 1）' <<<"$out" && grep -qF -- 'rc3b=1' <<<"$out"; then
  mark_ok '③ expect_exit 不命中印 ✗（列出期望/實得）且回傳 1'
else
  mark_bad "③ expect_exit 不命中訊息或回傳值錯（實得：${out}）"
fi

# ---- ④ expect_has／expect_not_has：命中／不命中各自印對訊息、回傳值正確 ----
out="$(
  {
  source "$lib"
  expect_has 'abcdef' 'cde' '④a'; echo "rc4a=$?"
  expect_has 'abcdef' 'zzz' '④b'; echo "rc4b=$?"
  expect_not_has 'abcdef' 'zzz' '④c'; echo "rc4c=$?"
  expect_not_has 'abcdef' 'cde' '④d'; echo "rc4d=$?"
  } 2>&1
)"
if grep -qF -- '✓ ④a' <<<"$out" && grep -qF -- 'rc4a=0' <<<"$out"; then
  mark_ok '④ expect_has 命中印 ✓ 且回傳 0'
else
  mark_bad "④ expect_has 命中應印 ✓ 且回傳 0（實得：${out}）"
fi
if grep -qF -- '✗ ④b（應含「zzz」）' <<<"$out" && grep -qF -- 'rc4b=1' <<<"$out"; then
  mark_ok '④ expect_has 不命中印 ✗（列出缺的 needle）且回傳 1'
else
  mark_bad "④ expect_has 不命中訊息或回傳值錯（實得：${out}）"
fi
if grep -qF -- '✓ ④c' <<<"$out" && grep -qF -- 'rc4c=0' <<<"$out"; then
  mark_ok '④ expect_not_has 不命中（正確）印 ✓ 且回傳 0'
else
  mark_bad "④ expect_not_has 正確情境訊息或回傳值錯（實得：${out}）"
fi
if grep -qF -- '✗ ④d（不應含「cde」）' <<<"$out" && grep -qF -- 'rc4d=1' <<<"$out"; then
  mark_ok '④ expect_not_has 命中（不該有）印 ✗ 且回傳 1'
else
  mark_bad "④ expect_not_has 違規情境訊息或回傳值錯（實得：${out}）"
fi

# ---- ⑤ n／fail 計數：selftest_helpers_n 只數 ok()（同既有慣例，如 agent-tools-check.test.sh 的
#        ok(){ n=$((n+1)) }——失敗只設 fail 旗標，不灌進 n）；expect_has 呼叫一次成功、一次失敗後，
#        selftest_helpers_n 應為 1（只有那次成功的）、selftest_helpers_fail 應為 1 ----
out="$(
  source "$lib"
  expect_has 'abcdef' 'cde' '⑤a' >/dev/null 2>&1
  expect_has 'abcdef' 'zzz' '⑤b' >/dev/null 2>&1
  echo "n=${selftest_helpers_n} fail=${selftest_helpers_fail}"
)" 2>/dev/null
if grep -qF -- 'n=1 fail=1' <<<"$out"; then
  mark_ok '⑤ 計數：selftest_helpers_n 只數成功的那次（=1，同既有 ok() 慣例)、selftest_helpers_fail=1'
else
  mark_bad "⑤ 計數應為 n=1 fail=1（實得：${out}）"
fi

# ---- ⑥ 呼叫端已自行定義 ok()／fail() 時不被共用庫覆寫（六支換用的既有 n／fail 計數慣例）；
#        expect_has 的回傳值仍正確，不受呼叫端覆寫影響 ----
out="$(
  {
  caller_n=0
  ok() { echo "caller-ok:$1"; caller_n=$((caller_n + 1)); }
  fail() { echo "caller-fail:$1"; }
  source "$lib"
  expect_has 'abcdef' 'cde' '⑥a'; echo "rc6a=$?"
  expect_has 'abcdef' 'zzz' '⑥b'; echo "rc6b=$?"
  echo "caller_n=${caller_n}"
  } 2>&1
)"
if grep -qF -- 'caller-ok:⑥a' <<<"$out" && grep -qF -- 'caller-fail:⑥b' <<<"$out" \
   && grep -qF -- 'rc6a=0' <<<"$out" && grep -qF -- 'rc6b=1' <<<"$out" && grep -qF -- 'caller_n=1' <<<"$out"; then
  mark_ok '⑥ 呼叫端已定義的 ok()／fail() 沒被共用庫覆寫（印呼叫端自己的格式），expect_has 回傳值仍正確'
else
  mark_bad "⑥ 呼叫端自訂 ok()／fail() 應保留且回傳值仍正確（實得：${out}）"
fi

# ---- ⑦ 直接執行（非 source）預設什麼都不做、exit 0；SELFTEST_HELPERS_SELFCHECK=1 才單獨跑自檢 ----
out="$(bash "$lib" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  mark_ok '⑦ 直接執行（非 source）預設無輸出、exit 0'
else
  mark_bad "⑦ 直接執行預設應無輸出且 exit 0（實得 exit ${rc}，輸出：${out}）"
fi
out="$(SELFTEST_HELPERS_SELFCHECK=1 bash "$lib" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  mark_ok '⑦b SELFTEST_HELPERS_SELFCHECK=1 直接執行 → 跑自檢、正常庫回 exit 0'
else
  mark_bad "⑦b 正常庫在 SELFTEST_HELPERS_SELFCHECK=1 下應 exit 0（實得 ${rc}）"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑧ mutation（票文指定）：把 has() 改成永遠 return 0 → 自檢紅，source 整個炸掉並印「助手自檢失敗」 ----
mut="$work/selftest-helpers.mutant.sh"
sed "s/^  grep -qF -- \"\$2\" <<<\"\$1\"\$/  return 0/" "$lib" > "$mut"
mut_ok=1
grep -qF 'return 0' "$mut"
[ $? -eq 0 ] || mut_ok=0
grep -qF 'grep -qF -- "$2" <<<"$1"' "$mut"
[ $? -eq 0 ] && mut_ok=0
if [ "$mut_ok" -eq 1 ]; then
  mark_ok '⑧ mutant 已確認：has() 本體被換成永遠 return 0'
else
  mark_bad '⑧ mutant 合成失敗（sed 未命中 has() 本體，mutation 測試本身無效）'
fi
out="$(bash -c "source '$mut'" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF -- '助手自檢失敗' <<<"$out"; then
  mark_ok '⑧ mutant：has() 永遠 return 0 → source 時自檢偵測到、exit 1 並印「助手自檢失敗」（證明自檢本身有牙）'
else
  mark_bad "⑧ mutant 應 exit 1 且印「助手自檢失敗」（實得 exit ${rc}）"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
# 對照：同一支 mutant 用 SELFTEST_HELPERS_SELFCHECK=1 直接執行（非 source）也要紅，兩條路徑都要炸
out="$(SELFTEST_HELPERS_SELFCHECK=1 bash "$mut" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  mark_ok '⑧b mutant：SELFTEST_HELPERS_SELFCHECK=1 直接執行同樣回非 0'
else
  mark_bad "⑧b mutant 在 SELFTEST_HELPERS_SELFCHECK=1 下應非 0（實得 ${rc}）"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ selftest-helpers.test.sh 全部通過（${n} 組＋mutation）"
else
  echo "✗ selftest-helpers.test.sh 有案例失敗" >&2
fi
exit "$fail"
