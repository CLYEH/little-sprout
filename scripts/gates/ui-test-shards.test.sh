#!/bin/bash
# ui-test-shards.sh 的自測（LS-385）。CI rules job 每個 PR 都跑。
#
# 覆蓋：真 repo 的分片不變量（每個 XCTestCase 類別恰好落在一片、各片略過清單＝全集減本片、全集與獨立 grep 一致）、
# 合成 fixture 的權重與 LPT 分配（含 `@MainActor final class`、`class func setUp()` 不切換歸屬、0 支測試記權重 1、
# 註解行裡的 class 宣告不算、非 XCTestCase 類別不算）、n=1 空清單、參數／目錄錯 exit 2、掃不到任何類別 exit 1。
# Mutation：(m1) 拿掉 LPT 的「挑最輕分片」→ 分配表變樣，② 的期望紅；(m2) 拿掉註解行略過 → 註解裡的假類別混進分配表。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
checker="${here}/ui-test-shards.sh"
# shellcheck source=lib/selftest-helpers.sh
source "${here}/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

eq() {   # eq <name> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"; printf '    實得：\n%s\n    期望：\n%s\n' "$2" "$3" | sed 's/^/    /' >&2; fi
}

# ---- ① 真 repo 不變量（n＝1..4）----
uitests="${root}/LittleSproutUITests"
all_grep=$(grep -rhoE '^[^/]*class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' "$uitests" --include='*.swift' \
  | sed -E 's/.*class[[:space:]]+([A-Za-z0-9_]+).*/\1/' | sort -u)
[ -n "$all_grep" ] || fail '① 真 repo：獨立 grep 找不到任何 XCTestCase 類別（夾具前提不成立）'
for n in 1 2 3 4; do
  plan=$(bash "$checker" --plan "$n" "$uitests" 2>&1); rc=$?
  expect_exit 0 "$rc" "① 真 repo --plan ${n} → exit 0"
  # 分配表每行「i/n  權重 w  A、B、C」→ 每個類別一行「i<TAB>類別」
  pairs=$(printf '%s\n' "$plan" | awk '{ split($1, a, "/"); $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, ""); m = split($0, c, "、"); for (j = 1; j <= m; j++) if (c[j] != "（無）") print a[1] "\t" c[j] }')
  all_plan=$(printf '%s\n' "$pairs" | cut -f2 | sort)
  eq "① 真 repo n=${n}：分配表的類別全集＝獨立 grep 的 XCTestCase 類別（掃描沒漏）" "$(printf '%s\n' "$all_plan" | sort -u)" "$all_grep"
  eq "① 真 repo n=${n}：每個類別恰好出現在一片（無重複分配）" "$all_plan" "$(printf '%s\n' "$all_plan" | sort -u)"
  for i in $(seq 1 "$n"); do
    skip=$(bash "$checker" --shard "${i}/${n}" "$uitests" 2>&1); rc=$?
    expect_exit 0 "$rc" "① 真 repo --shard ${i}/${n} → exit 0"
    want=$(printf '%s\n' "$pairs" | awk -F '\t' -v s="$i" '$1 != s { print "LittleSproutUITests/" $2 }' | sort)
    eq "① 真 repo ${i}/${n}：略過清單＝全集減本片（其他片的類別，<target>/<Class>）" "$skip" "$want"
  done
done

# ---- ② 合成 fixture：權重與 LPT 分配 ----
fx="${work}/MyUITests"
mkdir -p "$fx"
cat > "$fx/Big.swift" <<'EOF'
import XCTest
final class Big: XCTestCase {
    func testA() {}
    func testB() {}
    func testC() {}
    func testD() {}
    func testE() {}
    func helperNotATest() {}
}
EOF
cat > "$fx/Mid1.swift" <<'EOF'
import XCTest
class Mid1 : XCTestCase, SomeProtocol {
    func testA() {}
    func testB() {}
    func testC() {}
    func testD() {}
}
EOF
cat > "$fx/Mid2.swift" <<'EOF'
import XCTest
// class Fake: XCTestCase —— 註解裡的宣告不算
final class Mid2: XCTestCase {
    func testA() {}
    func testB() {}
    func testC() {}
}
private final class Helper {
    func testLooksLikeATestButHelperDoesNotSwitchOwnership() {}
}
EOF
cat > "$fx/Small.swift" <<'EOF'
import XCTest
@MainActor final class Small: XCTestCase {
    func testA() {}
    override class func setUp() { super.setUp() }
    func testB() {}
}
EOF
cat > "$fx/Zero.swift" <<'EOF'
import XCTest
final class Zero: XCTestCase {
}
final class NotATestCase: NSObject {
    func testIgnored() {}
}
EOF
# 權重：Big 5、Mid1 4、Mid2 3＋Helper 內那支仍歸 Mid2＝4、Small 2、Zero 0→1
# LPT（n=2，同權重依類別名 Mid1 先於 Mid2）：Big 5→1(5)；Mid1 4→2(4)；Mid2 4→2(8，4<5)；Small 2→1(7)；Zero 1→1(8)
want_plan=$'1/2  權重 8  Big、Small、Zero\n2/2  權重 8  Mid1、Mid2'
plan2=$(bash "$checker" --plan 2 "$fx" 2>&1); rc=$?
expect_exit 0 "$rc" '② fixture --plan 2 → exit 0'
eq '② fixture n=2：權重（class func／helper class 不切換歸屬、0 支記 1）與 LPT 分配（同權重依類別名）' "$plan2" "$want_plan"
expect_not_has "$plan2" 'Fake' '② 註解行裡的 class 宣告不算'
expect_not_has "$plan2" 'NotATestCase' '② 非 XCTestCase 類別不算'
expect_not_has "$plan2" 'Helper' '② 非 XCTestCase 的 helper class 不算'
skip1=$(bash "$checker" --shard 1/2 "$fx" 2>&1); rc=$?
expect_exit 0 "$rc" '② fixture --shard 1/2 → exit 0'
eq '② fixture 1/2 略過清單＝第 2 片的類別（target＝目錄 basename）' "$skip1" $'MyUITests/Mid1\nMyUITests/Mid2'

# ---- ③ n=1：略過清單為空（整包跑）----
out=$(bash "$checker" --shard 1/1 "$fx" 2>&1); rc=$?
expect_exit 0 "$rc" '③ --shard 1/1 → exit 0'
eq '③ --shard 1/1 → 略過清單為空' "$out" ''

# ---- ④ 參數／目錄錯 → exit 2 ----
for bad in '' '--shard' '--shard 0/2' '--shard 3/2' '--shard a/2' '--shard 1' '--shard 1/0' '--plan 0' '--plan x' '--bogus 1'; do
  # shellcheck disable=SC2086
  out=$(cd "$work" && bash "$checker" $bad 2>&1); rc=$?
  expect_exit 2 "$rc" "④ 參數「${bad:-（無）}」→ exit 2"
done
out=$(bash "$checker" --shard 1/2 "${work}/no-such-dir" 2>&1); rc=$?
expect_exit 2 "$rc" '④ 目錄不存在 → exit 2'
out=$(bash "$checker" --shard 1/2 "$fx" extra 2>&1); rc=$?
expect_exit 2 "$rc" '④ 多給參數 → exit 2'

# ---- ⑤ 掃不到任何 XCTestCase 類別 → exit 1（fail loud）----
mkdir -p "${work}/Empty" "${work}/NoTests"
printf 'final class Plain: NSObject {}\n' > "${work}/NoTests/Plain.swift"
out=$(bash "$checker" --shard 1/2 "${work}/Empty" 2>&1); rc=$?
expect_exit 1 "$rc" '⑤ 空目錄 → exit 1'
out=$(bash "$checker" --plan 2 "${work}/NoTests" 2>&1); rc=$?
expect_exit 1 "$rc" '⑤ 無 XCTestCase 類別 → exit 1'
expect_has "$out" 'fail loud' '⑤ exit 1 訊息點明 fail loud'

# ---- ⑥ mutation ----
# m1：LPT 退化成永遠放第 1 片 → ② 的分配表必須對不上
m1="${work}/m1.sh"
sed 's/if (load\[s\] < load\[best\]) best = s/best = best/' "$checker" > "$m1"
if cmp -s "$checker" "$m1"; then fail '⑥ m1：sed 沒改到 LPT 那行（mutation 無效，檢查錨點）'; fi
out=$(bash "$m1" --plan 2 "$fx" 2>&1)
if [ "$out" != "$want_plan" ]; then ok '⑥ m1：拿掉「挑最輕分片」→ 分配表與期望不符（② 會紅）'; else fail '⑥ m1：mutant 分配表仍等於期望——② 的斷言沒咬住 LPT'; fi
# m2：拿掉註解行略過 → 註解裡的 Fake 混進分配表
m2="${work}/m2.sh"
grep -v '^    /\^\[\[:space:\]\]\*\\/\\// { next }$' "$checker" > "$m2"
if cmp -s "$checker" "$m2"; then fail '⑥ m2：grep 沒刪到註解略過那行（mutation 無效，檢查錨點）'; fi
out=$(bash "$m2" --plan 2 "$fx" 2>&1)
if has "$out" 'Fake'; then ok '⑥ m2：拿掉註解行略過 → 註解裡的 Fake 被當成類別（② 的 expect_not_has 會紅）'; else fail '⑥ m2：mutant 仍沒有 Fake——② 的斷言沒咬住註解略過'; fi

if [ "$selftest_helpers_fail" -eq 0 ]; then
  echo "✓ ui-test-shards.test.sh 全部通過（${selftest_helpers_n} 項）"
  exit 0
fi
echo "✗ ui-test-shards.test.sh 有案例失敗" >&2
exit 1
