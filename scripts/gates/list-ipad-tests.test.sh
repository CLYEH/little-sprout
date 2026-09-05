#!/bin/bash
# list-ipad-tests.sh 的自測（LS-209）。CI rules job 每個 PR 都跑。
#
# 覆蓋：真 repo 現況（SettingsViewIPadTests＋TapTargetGateTests/testSettingsViewRegular）、多檔多類別下方法正確
# 歸屬各自類別（不會把 B 檔的 Regular 方法錯記成 A 檔類別底下）、`IPadTests` 類別本身若又有 Regular 方法會兩筆都
# 列（整類別＋單一方法，形狀不同不是重複）、只有 `func test…` 才算（非 test 開頭的方法即使含 Regular 也不算）、
# 普通類別＋普通方法不進清單、空目錄／全無比對／目錄不存在／參數錯誤的 exit code、target 名稱取自目錄
# basename（不是寫死 LittleSproutUITests）。Mutation：拿掉 IPadTests／Regular 兩條判定各自的负样本必須消失。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/list-ipad-tests.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "${4:-}" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- ① 真 repo：LittleSproutUITests 現況 ----
out1="$(bash "$checker" "${root}/LittleSproutUITests" 2>&1)"; rc=$?
rc_is '① 真 repo → exit 0' 0 "$rc" "$out1"
has   '① 真 repo：含 SettingsViewIPadTests（整個類別）' "$out1" 'LittleSproutUITests/SettingsViewIPadTests'
has   '① 真 repo：含 TapTargetGateTests/testSettingsViewRegular（單一方法）' "$out1" 'LittleSproutUITests/TapTargetGateTests/testSettingsViewRegular'
out1b="$(bash "$checker" 2>&1)"; rc=$?   # 不帶參數＝預設 LittleSproutUITests（相對 cwd）
rc_is '① 不帶參數在 repo 根跑（預設目錄）→ exit 0' 0 "$rc" "$out1b"

# ---- ② 合成 fixture：多檔多類別，方法正確歸屬各自類別；只有 func test… 算；普通類別/方法不進；
#        IPadTests 類別自己也有 Regular 方法時兩筆都列（整類別＋單一方法，形狀不同） ----
fx="$work/fixtures/MyUITests"
mkdir -p "$fx"
cat > "$fx/A.swift" <<'EOF'
import XCTest
final class WelcomeIPadTests: XCTestCase {
    func testLayoutRegular() {}
    func testPlainCase() {}
}
EOF
cat > "$fx/B.swift" <<'EOF'
import XCTest
final class SettingsGateTests: XCTestCase {
    func testSettingsRegular() {}
    func helperRegularThing() {}
    func testUnrelated() {}
}
final class PlainTests: XCTestCase {
    func testNothingSpecial() {}
}
EOF
out2="$(bash "$checker" "$fx" 2>&1)"; rc=$?
rc_is '② 合成 fixture → exit 0' 0 "$rc" "$out2"
has   '② IPadTests 類別本身也進清單（整類別）' "$out2" 'MyUITests/WelcomeIPadTests'
has   '② IPadTests 類別內的 Regular 方法「額外」單獨也列一筆（形狀不同，不是重複）' "$out2" 'MyUITests/WelcomeIPadTests/testLayoutRegular'
hasnt '② 同類別內非 Regular 的普通方法不列' "$out2" 'testPlainCase'
has   '② B 檔的 Regular 方法正確歸屬 SettingsGateTests（不是 WelcomeIPadTests）' "$out2" 'MyUITests/SettingsGateTests/testSettingsRegular'
hasnt '② 方法名含 Regular 但不是 func test 開頭 → 不列（helperRegularThing）' "$out2" 'helperRegularThing'
if printf '%s\n' "$out2" | grep -qxF 'MyUITests/SettingsGateTests'; then echo "✗ ② SettingsGateTests 不應以整類別形式出現（它不是 *IPadTests）" >&2; fail=1; else echo "✓ ② SettingsGateTests 確實只以方法形式出現，不是整類別"; fi
hasnt '② PlainTests（普通類別＋普通方法）完全不進清單' "$out2" 'PlainTests'
n2=$(printf '%s\n' "$out2" | grep -c .); [ "$n2" -eq 3 ] && echo "✓ ② 清單恰三筆（WelcomeIPadTests 整類別＋testLayoutRegular＋SettingsGateTests/testSettingsRegular）" || { echo "✗ ② 清單應恰三筆（實得 ${n2}）：${out2}" >&2; fail=1; }

# ---- ③ target 名稱取自目錄 basename（不是寫死 LittleSproutUITests）----
has '③ -only-testing 前綴用目錄 basename（MyUITests，不是 LittleSproutUITests）' "$out2" 'MyUITests/'
hasnt '③ 不會誤植成 LittleSproutUITests' "$out2" 'LittleSproutUITests/WelcomeIPadTests'

# ---- ④ 空目錄（無 .swift 檔）→ exit 1 ----
mkdir -p "$work/empty"
out4="$(bash "$checker" "$work/empty" 2>&1)"; rc=$?
rc_is '④ 無 .swift 檔 → exit 1' 1 "$rc" "$out4"
has   '④ 訊息說明沒有 .swift 檔' "$out4" '沒有任何 .swift 檔'

# ---- ⑤ 有 .swift 檔但完全沒有比對（無 IPadTests、無 Regular）→ exit 1（fail loud，不得靜默略過）----
mkdir -p "$work/nomatch"
cat > "$work/nomatch/C.swift" <<'EOF'
import XCTest
final class FooTests: XCTestCase {
    func testBar() {}
}
EOF
out5="$(bash "$checker" "$work/nomatch" 2>&1)"; rc=$?
rc_is '⑤ 有檔但無比對 → exit 1（fail loud）' 1 "$rc" "$out5"
has   '⑤ 訊息明說「清單為空」與「不得靜默略過」' "$out5" '清單為空'

# ---- ⑥ 目錄不存在 → exit 2；參數過多 → exit 2 ----
out6="$(bash "$checker" "$work/does-not-exist" 2>&1)"; rc=$?
rc_is '⑥ 目錄不存在 → exit 2' 2 "$rc" "$out6"
out6b="$(bash "$checker" "$fx" extra 2>&1)"; rc=$?
rc_is '⑥ 多參數 → exit 2' 2 "$rc" "$out6b"

# ---- mutation：拿掉 IPadTests 字尾判定（改成永不命中的字串）→ ② 的 WelcomeIPadTests 整類別負樣本必須消失 ----
mut_ipad="$work/list-ipad-tests.no-ipadtests.sh"
sed 's/cls ~ \/IPadTests\$\//cls ~ \/ZZZNOPE\$\//' "$checker" > "$mut_ipad"
if grep -q 'ZZZNOPE' "$mut_ipad" && ! grep -q 'cls ~ /IPadTests\$/' "$mut_ipad"; then echo "✓ mutant(IPadTests) 確實已改判準"; else echo "✗ mutant(IPadTests) 改判準失敗（負控本身無效）" >&2; fail=1; fi
out_mut_ipad="$(bash "$mut_ipad" "$fx" 2>&1)"; rc=$?
if printf '%s' "$out_mut_ipad" | grep -qxF 'MyUITests/WelcomeIPadTests'; then
  echo "✗ mutant(IPadTests) 應該不再列出整類別（實得含該行）" >&2; fail=1
else
  echo "✓ mutant(IPadTests)：拿掉字尾判定後，WelcomeIPadTests 整類別負樣本消失（判定確實是原因）"
fi
has 'mutant(IPadTests)：Regular 方法清單仍保留（另一條判定未受影響）' "$out_mut_ipad" 'MyUITests/WelcomeIPadTests/testLayoutRegular'

# ---- mutation：拿掉 Regular 子字串判定（改成永不命中）→ ② 的 Regular 方法負樣本必須消失 ----
mut_reg="$work/list-ipad-tests.no-regular.sh"
sed 's/m ~ \/Regular\//m ~ \/ZZZNOPE\//' "$checker" > "$mut_reg"
if grep -q 'ZZZNOPE' "$mut_reg" && ! grep -q 'm ~ /Regular/' "$mut_reg"; then echo "✓ mutant(Regular) 確實已改判準"; else echo "✗ mutant(Regular) 改判準失敗（負控本身無效）" >&2; fail=1; fi
out_mut_reg="$(bash "$mut_reg" "$fx" 2>&1)"; rc=$?
hasnt 'mutant(Regular)：拿掉子字串判定後 testLayoutRegular 方法負樣本消失' "$out_mut_reg" 'testLayoutRegular'
hasnt 'mutant(Regular)：SettingsGateTests/testSettingsRegular 也消失' "$out_mut_reg" 'testSettingsRegular'
has  'mutant(Regular)：WelcomeIPadTests 整類別仍在（另一條判定未受影響）' "$out_mut_reg" 'MyUITests/WelcomeIPadTests'

if [ "$fail" -ne 0 ]; then
  echo "✗ list-ipad-tests 自測失敗" >&2
  exit 1
fi
echo "✓ list-ipad-tests 自測通過"
