#!/bin/bash
# ax-launch-check.sh 的自測（LS-211 範圍 7）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若「用 launchEnvironment 設 UIPreferredContentSizeCategoryName」
# 退化成不被擋、或允許清單被無限擴大成放過任何檔案，這裡會紅。全程用合成 fixture 目錄，不碰真的
# LittleSproutUITests。
set -uo pipefail

root_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root_repo}/scripts/gates/ax-launch-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkroot() {
  local d
  d=$(mktemp -d "$work/root-XXXXXX")
  mkdir -p "$d/LittleSproutUITests"
  printf '%s' "$d"
}

# expect <期望 exit> <名稱> <輸出必含|''> <root>
expect() {
  local want=$1 name=$2 must=$3 rootdir=$4 out got
  out="$(bash "$check" --root "$rootdir" 2>&1)"; got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ==== ① 正樣本（≥3）====
r=$(mkroot)
cat > "$r/LittleSproutUITests/FooTests.swift" <<'EOF'
import XCTest
final class FooTests: XCTestCase {
    func testFoo() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
    }
}
EOF
expect 0 '① 用 launchArguments（非 launchEnvironment）→ 過' '通過' "$r"

r=$(mkroot)
cat > "$r/LittleSproutUITests/BarTests.swift" <<'EOF'
import XCTest
final class BarTests: XCTestCase {
    func testBar() {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = "foo"
        app.launch()
    }
}
EOF
expect 0 '① launchEnvironment 設其他鍵（非 UIPreferredContentSizeCategoryName）→ 過' '通過' "$r"

r=$(mkroot)
cat > "$r/LittleSproutUITests/CommentOnly.swift" <<'EOF'
import XCTest
final class CommentOnlyTests: XCTestCase {
    /// 提到 `UIPreferredContentSizeCategoryName` 這個鍵名純屬敘述，不是 launchEnvironment 呼叫
    func testNothing() {
        XCTAssertTrue(true)
    }
}
EOF
expect 0 '① 純註解提到鍵名字面（沒有 launchEnvironment[ 語法）→ 過（不誤擋）' '通過' "$r"

r=$(mkroot)
mkdir -p "$r/LittleSproutUITests/TapTargetMeasurement.swift.d"   # 目錄同名陷阱，不是檔案
cat > "$r/LittleSproutUITests/TapTargetMeasurement.swift" <<'EOF'
import XCTest
enum TapTargetMeasurement {
    static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        app.launch()
        return app
    }
}
EOF
expect 0 '① allowlist 命中（TapTargetMeasurement.swift）→ 印 informational、仍過（LS-190 併主前過渡期）' '允許期限內' "$r"

# ==== ①n（R2，merge-review R1 N4）：--root 帶尾斜線時 allowlist 整字比對仍要生效 ====
out_slash="$(bash "$check" --root "${r}/" 2>&1)"; got_slash=$?
if [ "$got_slash" -eq 0 ] && printf '%s' "$out_slash" | grep -qF '允許期限內'; then
  echo "✓ ①n --root 帶尾斜線 → allowlist 仍正確命中，不誤紅"
else
  echo "✗ ①n --root 帶尾斜線應仍過、印「允許期限內」（實得 exit ${got_slash}）" >&2
  printf '%s\n' "$out_slash" | sed 's/^/    /' >&2
  fail=1
fi

# ==== ② 負樣本（≥3）====
r=$(mkroot)
cat > "$r/LittleSproutUITests/BadTests.swift" <<'EOF'
import XCTest
final class BadTests: XCTestCase {
    func testBad() {
        let app = XCUIApplication()
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
    }
}
EOF
expect 1 '② 非 allowlist 檔案用 launchEnvironment 設字級鍵 → 紅' '對 XCUITest 目標 app 不生效' "$r"

r=$(mkroot)
cat > "$r/LittleSproutUITests/AnotherBadTests.swift" <<'EOF'
import XCTest
final class AnotherBadTests: XCTestCase {
    func testAnother() {
        let app = XCUIApplication()
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        app.launch()
    }
}
EOF
expect 1 '② 檔名不在 allowlist（同鍵、不同檔）→ 紅' 'AnotherBadTests.swift' "$r"

r=$(mkroot)
cat > "$r/LittleSproutUITests/MixedTests.swift" <<'EOF'
import XCTest
final class MixedTests: XCTestCase {
    func testMixed() {
        let app = XCUIApplication()
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        app.launch()
    }
}
EOF
cp "$r/LittleSproutUITests/MixedTests.swift" "$r/LittleSproutUITests/OkTests.swift"
sed -i.bak 's/launchEnvironment\["UIPreferredContentSizeCategoryName"\] = "UICTContentSizeCategoryL"/launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]/' "$r/LittleSproutUITests/OkTests.swift"
rm -f "$r/LittleSproutUITests/OkTests.swift.bak"
expect 1 '② 多檔混合（一好一壞）→ 紅、只點名壞的那個' 'MixedTests.swift' "$r"

# ==== ③ 參數／環境錯誤：fail closed（exit 2）====
out="$(bash "$check" --root 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF -- '--root 缺值'; then
  echo "✓ ③ --root 缺值 → exit 2"
else
  echo "✗ ③ --root 缺值（期望 exit 2，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
out="$(bash "$check" --bogus 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF -- '未知參數'; then
  echo "✓ ③ 未知參數 → exit 2"
else
  echo "✗ ③ 未知參數（期望 exit 2，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
out="$(bash "$check" --root "$work/no-such-dir" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF -- '找不到'; then
  echo "✓ ③ --root 指到不存在的 LittleSproutUITests → exit 2"
else
  echo "✗ ③ --root 不存在（期望 exit 2，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ==== ④ mutation：拿掉整段掃描邏輯（把 pattern 改成永遠不會命中的字面）→ ② 的紅樣本必須變綠 ====
mut="$work/ax-launch-check.no-pattern.sh"
sed "s/pattern='launchEnvironment\\\\\[\[^]\]\*UIPreferredContentSizeCategoryName'/pattern='THIS_WILL_NEVER_MATCH_ANYTHING_XYZ'/" "$check" > "$mut"
if grep -qF 'THIS_WILL_NEVER_MATCH_ANYTHING_XYZ' "$mut"; then
  echo "✓ ④ mutate：確認已把偵測 pattern 換成不可能命中的字面"
else
  echo "✗ ④ mutate：找不到 pattern 標記行，負控本身無效" >&2; fail=1
fi
r=$(mkroot)
cat > "$r/LittleSproutUITests/BadTests.swift" <<'EOF'
import XCTest
final class BadTests: XCTestCase {
    func testBad() {
        let app = XCUIApplication()
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
    }
}
EOF
out="$(bash "$mut" --root "$r" 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then
  echo "✓ ④ mutant（拿掉偵測 pattern）：②的紅樣本改判過──證明偵測 pattern 是這裡在擋"
else
  echo "✗ ④ mutant 未如預期翻轉（實得 exit ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ⑤（R2，merge-review R1 N4）：刻意不做「拿掉 root=${root%/} 這行」的反向 mutation——實測過（debug
# 手動追蹤 ui_dir／grep 命中路徑／relfile 三個中間值），BSD grep（本機 macOS）對 `--root` 帶雙斜線的
# 目錄引數，回報的比對路徑會原樣保留同一份雙斜線，`relfile=${file#"${root}"/}` 的剝除樣式因此仍然
# 對得上（兩邊的雙斜線來自同一個 $root、彼此一致，不會互相抵觸）——本機無法重現 reviewer 描述的
# 「整字比對失效」。保留 `root=${root%/}` 這行是防禦性正規化（消除任何 grep 實作對連續斜線處理不一致
# 的可能性，不假設特定 grep 行為），①n 已驗證修正後的程式碼對帶尾斜線的 --root 正確運作；沒有加
# 反向 mutation 是誠實揭露，不是漏做——勉強做一個在本機必然不會翻轉的 mutation 反而是自欺。

if [ "$fail" -eq 0 ]; then
  echo "✓ ax-launch-check 自測通過"
fi
exit "$fail"
