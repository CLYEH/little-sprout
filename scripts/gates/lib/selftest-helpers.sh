#!/bin/bash
# scripts/gates/lib/selftest-helpers.sh — 自測共用助手庫（LS-301）
#
# 背景：LS-295（agent-tools-check.test.sh 的 has()）、LS-299（ci-wait.test.sh 的 has()）各自兩次發現
# 手刻的助手在特定寫法下永遠回 0（`printf | grep -q` 在 pipefail 下的 SIGPIPE 誤判、變數展開錯誤）
# ——既有斷言形同虛設，卻要等到 review／實作撞見才發現。自測助手本身沒有 mutation，是整批 *.test.sh
# 的共同盲區（LS-96 池項 `89166199`）。這支共用庫集中最常見的比對邏輯，並在檔尾自帶「故意餵錯必紅」
# 的自檢，讓助手本身的正確性不必再靠每支呼叫端各自把關。
#
# 提供：
#   has <haystack> <needle>                   — here-string 比對（-F 固定字串；LS-295：不受 pipefail
#                                                下 `printf | grep -q` 的 SIGPIPE 影響）
#   expect_exit <want> <got> <name>            — 比對 exit code
#   expect_has <haystack> <needle> <name>      — haystack 含 needle 才 ok，否則印 ✗＋原文
#   expect_not_has <haystack> <needle> <name>  — haystack 不含 needle 才 ok
#   ok <name> / fail <name>                    — 印 ✓／✗ 並計數（selftest_helpers_n／
#     selftest_helpers_fail）；若呼叫端已自行定義 ok()／fail()（多數既有 *.test.sh 早有自己的 ok()／n
#     計數慣例），這裡不覆寫——只在呼叫端還沒定義時提供預設，讓 expect_* 有東西可呼叫又不改變既有輸出。
#
# 用法：
#   scripts/gates/ 下的自測：source "$(dirname "${BASH_SOURCE[0]}")/lib/selftest-helpers.sh"
#   scripts/ops/   下的自測：source "$(dirname "${BASH_SOURCE[0]}")/../gates/lib/selftest-helpers.sh"
#
# 自檢：檔尾 selftest_helpers_selfcheck()——source 這個檔案時一律自動跑一次（故意餵對／餵錯給每個
# 助手，餵錯必須回非 0；只要有一個沒有，印「助手自檢失敗」並 exit 1，讓呼叫端的自測本身也跟著炸，
# 不會悄悄放行壞掉的助手）。直接 `bash selftest-helpers.sh` 執行（非 source）預設什麼都不做；只有
# `SELFTEST_HELPERS_SELFCHECK=1 bash selftest-helpers.sh` 才會單獨跑自檢並用其結果當 exit code——
# 供人工核對這支庫本身是否正常，不必透過任何呼叫端。
# 自測：scripts/gates/lib/selftest-helpers.test.sh（正常路徑＋mutation：把 has 改成永遠 return 0 →
# 自檢紅）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

# has <haystack> <needle>：here-string 比對（-F 固定字串），避免 `printf | grep -q` 在 pipefail 下的
# SIGPIPE 誤判（LS-295）。
has() {
  grep -qF -- "$2" <<<"$1"
}

: "${selftest_helpers_n:=0}"
: "${selftest_helpers_fail:=0}"

if ! declare -F ok >/dev/null 2>&1; then
  ok() { echo "✓ $1"; selftest_helpers_n=$((selftest_helpers_n + 1)); }
fi
if ! declare -F fail >/dev/null 2>&1; then
  fail() { echo "✗ $1" >&2; selftest_helpers_fail=1; }
fi

# expect_exit <want> <got> <name>：比對 exit code。回傳 0＝符合期望，1＝不符合——回傳值本身就代表判定
# 結果，不依賴 ok／fail 的副作用（ok／fail 可能被呼叫端覆寫成不更新計數的版本，見上方 guard 說明；
# 判定結果若綁死在計數副作用上，呼叫端一旦覆寫 fail() 就會連自檢本身都失真）。
expect_exit() {
  local want=$1 got=$2 name=$3
  if [ "$got" -eq "$want" ]; then
    ok "$name"; return 0
  fi
  fail "${name}（期望 exit ${want}，實得 ${got}）"
  return 1
}

# expect_has <haystack> <needle> <name>：haystack 含 needle 才 ok。回傳 0／1 同 expect_exit。
expect_has() {
  local haystack=$1 needle=$2 name=$3
  if has "$haystack" "$needle"; then
    ok "$name"; return 0
  fi
  fail "${name}（應含「${needle}」）"
  printf '%s\n' "$haystack" | sed 's/^/    /' >&2
  return 1
}

# expect_not_has <haystack> <needle> <name>：haystack 不含 needle 才 ok。回傳 0／1 同 expect_exit。
expect_not_has() {
  local haystack=$1 needle=$2 name=$3
  if has "$haystack" "$needle"; then
    fail "${name}（不應含「${needle}」）"
    printf '%s\n' "$haystack" | sed 's/^/    /' >&2
    return 1
  fi
  ok "$name"; return 0
}

# ---- 檔尾自檢：故意餵對／餵錯給 has()，餵錯必須回非 0。只測 has()、不呼叫 expect_exit／expect_has／
#      expect_not_has（那些會呼叫 ok／fail，而 ok／fail 可能是呼叫端已定義的版本、也會動到
#      selftest_helpers_n／_fail——每次 source 都自動跑一次自檢，若自檢本身也去增計數，就會把呼叫端
#      的樣本數（六支換用的檔案各自的 n）悄悄墊高，違反「樣本數與改前一致」。has() 是純 predicate、
#      沒有副作用，也正是 LS-295／LS-299 兩次出包、票文 mutation 指定要守住的那個函式，測它就夠）----
selftest_helpers_selfcheck() {
  local bad=0
  has 'abcdef' 'cde' || { echo "✗ 助手自檢失敗：has() 對命中的 needle 應回 0" >&2; bad=1; }
  has 'abcdef' 'zzz' && { echo "✗ 助手自檢失敗：has() 對沒命中的 needle 應回非 0" >&2; bad=1; }
  return "$bad"
}

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  # 被 source：一律自動自檢，餵錯回非 0 才算過；壞掉就整個 exit 1，不讓呼叫端建立在壞掉的助手上。
  if ! selftest_helpers_selfcheck; then
    echo "✗ selftest-helpers.sh：助手自檢失敗，拒絕提供助手" >&2
    exit 1
  fi
elif [ "${SELFTEST_HELPERS_SELFCHECK:-0}" = 1 ]; then
  selftest_helpers_selfcheck
  exit $?
fi
