#!/bin/bash
# qa-fail-rate.sh 的自測（LS-421 R2 I2）。CI rules job 每個 PR 都跑。
# 守住：FAIL／總數計算、PENDING 不入分母、--non-ui 以「相對前一個 qa-status commit 的區間 diff」判 UI
# （區間內夾一個沒有 status 的 UI commit 要讓下一個 qa commit 算 UI）、design/ 也算 UI、參數錯誤 exit 2；
# mutation：拿掉 design/ 判定、把區間 diff 改成只比親代 → 負樣本必須變綠。
# 夾具：合成 git repo（local branch `test`）＋--statuses-file，不呼叫 gh。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../gates/lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
script="${root}/scripts/ops/qa-fail-rate.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"; st="$work/st.tsv"

g() { git -C "$repo" "$@"; }
mk() { # mk <path> <msg>：在 repo 寫檔並 commit，印 sha
  mkdir -p "$repo/$(dirname "$1")"; echo "$2" >> "$repo/$1"
  g add -A >/dev/null; g -c user.name=t -c user.email=t@t commit -q -m "$2"; g rev-parse HEAD
}
mkdir -p "$repo"; g init -q -b test
c0=$(mk docs/a.md c0)
c1=$(mk docs/b.md c1)                      # qa SUCCESS，非 UI
c2=$(mk LittleSprout/Views/X.swift c2)     # qa FAILURE，UI
c3=$(mk scripts/s.sh c3)                   # qa SUCCESS，非 UI
x=$(mk design/littlesprout.pen x)          # 無 status，但落在 c3..c4 區間
c4=$(mk docs/c.md c4)                      # qa FAILURE，區間含 x → UI
c5=$(mk docs/d.md c5)                      # qa FAILURE，非 UI
c6=$(mk scripts/t.sh c6)                   # qa PENDING，非 UI
: "$c0" "$x"
printf '%s\tSUCCESS\n%s\tFAILURE\n%s\tSUCCESS\n%s\tFAILURE\n%s\tFAILURE\n%s\tPENDING\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" > "$st"

run() { out="$(bash "${SCRIPT:-$script}" --repo "$repo" --ref test --statuses-file "$st" "$@" 2>&1)"; rc=$?; }

run --since 14
expect_exit 0 "$rc" '① 全部 → exit 0'
expect_has "$out" 'FAIL 3／5＝60.0%｜SUCCESS 2｜其他狀態 1' '① 全部：FAIL 3／5、PENDING 不入分母且另列'
expect_has "$out" '全部' '① 範圍標示「全部」'

run --since 14 --non-ui
expect_has "$out" 'FAIL 1／3＝33.3%｜SUCCESS 2｜其他狀態 1' '② --non-ui：只算 c1／c3／c5（c2 動 LittleSprout/、c4 區間含 design/）'
expect_has "$out" '非 UI' '② 範圍標示「非 UI」'

printf '' > "$st"
run --since 7 --non-ui
expect_has "$out" 'FAIL 0／0＝—' '③ 無 qa status → 比例印「—」不除零'
printf '%s\tSUCCESS\n%s\tFAILURE\n%s\tSUCCESS\n%s\tFAILURE\n%s\tFAILURE\n%s\tPENDING\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" > "$st"

run --since abc; expect_exit 2 "$rc" '④ --since 非數字 → exit 2'
run --bogus; expect_exit 2 "$rc" '④ 未知旗標 → exit 2'
out="$(bash "$script" --repo "$repo" --ref nope --statuses-file "$st" 2>&1)"; rc=$?
expect_exit 2 "$rc" '④ ref 不存在 → exit 2'

# ⑤ R2 m1：UI 區間含大量檔案（>64KB 的 diff 輸出）時仍判 UI——`git diff | grep -q` 在 pipefail 下 grep 提早退出、git 收 SIGPIPE，
#    會把 UI 區間誤算成非 UI。UI 檔 `LittleSprout/…` 排序在前、後面接 3000 個長檔名，grep 命中後 git 還在寫。
big="$work/big"; mkdir -p "$big"; git -C "$big" init -q -b test
bg() { git -C "$big" -c user.name=t -c user.email=t@t "$@"; }
echo r > "$big/r.md"; bg add -A >/dev/null; bg commit -q -m r0
mkdir -p "$big/LittleSprout" "$big/docs"; echo v > "$big/LittleSprout/V.swift"
for i in $(seq 1 3000); do : > "$big/docs/long-file-name-for-sigpipe-regression-test-$i.md"; done
bg add -A >/dev/null; bg commit -q -m big; bigsha=$(bg rev-parse HEAD)
printf '%s\tFAILURE\n' "$bigsha" > "$work/big.tsv"
for k in 1 2 3; do
  out="$(bash "$script" --repo "$big" --ref test --statuses-file "$work/big.tsv" --non-ui 2>&1)"; rc=$?
  expect_has "$out" 'FAIL 0／0＝—' "⑤ 大區間（3001 檔）含 UI 檔 → 算 UI、非 UI 樣本為 0（第 ${k} 次）"
done

# ---- mutation：改壞腳本，--non-ui 的負樣本必須變綠（輸出不再是 FAIL 1／3） ----
mut() { # mut <sed 表達式> <case 名>
  local m="$work/mut.sh"; sed "$1" "$script" > "$m"
  if cmp -s "$m" "$script"; then fail "${2}（mutation 沒有改到任何字）"; return; fi
  SCRIPT="$m" run --since 14 --non-ui
  if has "$out" 'FAIL 1／3＝33.3%'; then fail "${2}（mutation 後仍綠）"; else ok "$2"; fi
}
mut 's/|design\/)/)/' 'M1 拿掉 design/ 判定 → ② 紅'
mut 's/base=${prev:-${sha}^}/base=${sha}^/' 'M2 區間 diff 改成只比親代 → ② 紅'

n=${selftest_helpers_n}
if [ "${selftest_helpers_fail}" -ne 0 ]; then
  echo "✗ qa-fail-rate 自測失敗" >&2
  exit 1
fi
echo "✓ qa-fail-rate 自測全綠（${n} 組）"
