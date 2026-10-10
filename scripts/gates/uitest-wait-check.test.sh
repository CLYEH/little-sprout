#!/bin/bash
# uitest-wait-check.sh 的自測（LS-458）。CI `rules` job 跑。
# 合成 .swift 夾具（不碰真的 LittleSproutUITests）驗口徑逐條：
#   規則 i  ：單行／跨行 `XCTAssertFalse(… waitForExistence …)` 紅；`XCTAssertTrue(x.waitForNonExistence…)` 與
#             `XCTAssertFalse(x.exists)` 不紅；
#   規則 ii ：`.exists`／`.label`／`.value` 前同 func 內 N 行有 wait 才不紅、wait 在上一個 func 不算、
#             N 行邊界（25 內過、26 紅）、註解裡的 waitFor 不算、字串字面值裡的 `.exists` 不算；
#   豁免    ：行內 `uitest-wait-ok: <理由>`（斷言行／緊鄰上一行；空理由不算）、allowlist 只吃規則 ii、
#             allowlist 棘輪（已無命中／檔案不存在 → 紅）；
#   fail closed：參數錯 exit 2、掃描範圍空 exit 1。
# 並附「修前原文」回歸樣本（LS-458 修掉的 DeleteConfirmationUITests:61 逐字照搬 → 必紅）與五組 mutation：
# 每組改一份 gate 副本，對應夾具的斷言必須翻轉，證明該斷言有牙（不是別條規則碰巧擋下）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/uitest-wait-check.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# run <gate> <scan-dir> [額外參數…] → 設 out／rc
run() { local g=$1 d=$2; shift 2; out=$(bash "$g" --scan-dir "$d" --allowlist "$work/none.txt" "$@" 2>&1); rc=$?; }
expect() {   # expect <期望 exit> <名稱> [必含…]（讀全域 out／rc）
  local want=$1 name=$2; shift 2
  local good=1 must
  [ "$rc" -eq "$want" ] || good=0
  for must in "$@"; do has "$out" "$must" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else
    echo "✗ ${name}（期望 exit ${want}，實得 ${rc}）" >&2; sed 's/^/    /' <<<"$out" >&2; fail=1
  fi
}
refute() { if has "$out" "$2"; then bad "${1}（輸出不該含「${2}」）"; sed 's/^/    /' <<<"$out" >&2; else ok "$1"; fi; }

# fixture <目錄> <檔名> <func 內文…>：產一個含單一 test func 的 .swift 檔
fixture() {
  local dir=$1 name=$2; shift 2
  mkdir -p "$dir"
  { printf 'import XCTest\n\nfinal class Sample: XCTestCase {\n    func testSample() {\n'
    printf '%s\n' "$@"
    printf '    }\n}\n'; } > "${dir}/${name}"
}

# ---------------- 規則 i ----------------
d="$work/i-pos-single"
# 修前原文：LittleSproutUITests/DeleteConfirmationUITests.swift:61（LS-458 修掉的那行，逐字照搬）
fixture "$d" ADeleteUITests.swift '        XCTAssertFalse(app.buttons["刪除這篇日記"].waitForExistence(timeout: 3), "確認後 sheet 應該關閉")'
run "$check" "$d"
expect 1 '① 修前原文 XCTAssertFalse(waitForExistence) 單行 → exit 1、點名檔:行號與規則' 'ADeleteUITests.swift:5 [規則 i]' '刪除這篇日記'

d="$work/i-pos-multi"
fixture "$d" AMultiUITests.swift '        XCTAssertFalse(' '            app.staticTexts["要刪除這則留言嗎？"].waitForExistence(timeout: 3),' '            "PreviewCommentAPIClient 呼叫必成功，確認後 sheet 應該關閉"' '        )'
run "$check" "$d"
expect 1 '② 跨行 XCTAssertFalse(\n…waitForExistence…\n) → exit 1' 'AMultiUITests.swift:5 [規則 i]'

d="$work/i-neg"
fixture "$d" ANegUITests.swift \
  '        XCTAssertTrue(app.buttons["x"].waitForNonExistence(timeout: 5), "消失用 waitForNonExistence")' \
  '        XCTAssertFalse(app.buttons["y"].exists, "一次性快照 .exists 的 Bool 反向不是規則 i")' \
  '        XCTAssertTrue(app.buttons["z"].waitForExistence(timeout: 5))' \
  '        XCTAssertFalse(' '            app.staticTexts["不含等待的跨行斷言"].isHittable,' '            "msg"' '        )' \
  '        XCTAssertFalse(app.buttons["w"].isHittable, "waitForExistence 只出現在訊息字串裡：waitForExistence(timeout: 3)")'
run "$check" "$d"
expect 0 '③ 負樣本：waitForNonExistence／XCTAssertFalse(.exists)／訊息字串裡的 waitForExistence → 不紅' '無缺等待的斷言'

d="$work/i-marker"
fixture "$d" AMarkerUITests.swift \
  '        // uitest-wait-ok: 反向斷言刻意在 3 秒視窗內不得出現（取消不應送出檢舉）' \
  '        XCTAssertFalse(app.staticTexts["已送出"].waitForExistence(timeout: 3), "取消不應該送出檢舉")' \
  '        XCTAssertFalse(app.staticTexts["已送出"].waitForExistence(timeout: 3), "同行") // uitest-wait-ok: 同行標記也算'
run "$check" "$d"
expect 0 '④ 行內標記 uitest-wait-ok: <理由>（上一行／同行）→ 豁免' '無缺等待的斷言'

d="$work/i-marker-empty"
fixture "$d" AEmptyUITests.swift \
  '        // uitest-wait-ok:' \
  '        XCTAssertFalse(app.staticTexts["已送出"].waitForExistence(timeout: 3))'
run "$check" "$d"
expect 1 '⑤ 空理由標記不算豁免' 'AEmptyUITests.swift:6 [規則 i]'

# ---------------- 規則 ii ----------------
d="$work/ii-pos"
fixture "$d" APosUITests.swift \
  '        let app = XCUIApplication()' '        app.launch()' \
  '        XCTAssertEqual(app.buttons["foodEntry.openBook"].label, "看整本飲食圖鑑")' \
  '        XCTAssertTrue(app.staticTexts["標題"].exists)' \
  '        XCTAssertNotNil(app.textFields["f"].value)'
run "$check" "$d"
expect 1 '⑥ .label／.exists／.value 前沒有 wait → exit 1、逐處點名' 'APosUITests.swift:7 [規則 ii]' 'APosUITests.swift:8 [規則 ii]' 'APosUITests.swift:9 [規則 ii]'

d="$work/ii-neg"
fixture "$d" ANegUITests.swift \
  '        XCTAssertTrue(app.buttons["a"].waitForExistence(timeout: 5))' \
  '        XCTAssertEqual(app.buttons["a"].label, "A")' \
  '        XCTAssertTrue(app.buttons["b"].waitForHittable(timeout: 5) && app.buttons["b"].exists)' \
  '        XCTAssertTrue(app.buttons["c"].waitUntilGone(timeout: 5))' \
  '        XCTAssertFalse(app.buttons["d"].exists)'
run "$check" "$d"
expect 0 '⑦ 同 func 內前面有 waitFor／waitUntilGone → 不紅（含斷言本身帶 wait）' '無缺等待的斷言'

# wait 在「上一個 func」→ 不算
d="$work/ii-prevfunc"; mkdir -p "$d"
cat > "$d/APrevUITests.swift" <<'SWIFT'
import XCTest

final class Sample: XCTestCase {
    func testFirst() {
        XCTAssertTrue(app.buttons["a"].waitForExistence(timeout: 5))
    }

    func testSecond() {
        XCTAssertEqual(app.buttons["a"].label, "A")
    }
}
SWIFT
run "$check" "$d"
expect 1 '⑧ wait 在上一個 func 不算（lookback 不跨 func 宣告）' 'APrevUITests.swift:9 [規則 ii]'

# N 行邊界：wait 在斷言前第 25 行 → 過；第 26 行 → 紅（預設 --lookback 25）
mk_gap() {   # mk_gap <目錄> <wait 與斷言之間的空行數>
  mkdir -p "$1"
  { printf 'import XCTest\n\nfinal class Sample: XCTestCase {\n    func testGap() {\n'
    printf '        XCTAssertTrue(app.buttons["a"].waitForExistence(timeout: 5))\n'
    local i; for ((i = 0; i < $2; i++)); do printf '        let filler%d = 0\n' "$i"; done
    printf '        XCTAssertEqual(app.buttons["a"].label, "A")\n    }\n}\n'; } > "$1/AGapUITests.swift"
}
mk_gap "$work/gap-in" 24; run "$check" "$work/gap-in"
expect 0 '⑨ wait 在斷言前第 25 行（邊界內）→ 不紅' '無缺等待的斷言'
mk_gap "$work/gap-out" 25; run "$check" "$work/gap-out"
expect 1 '⑨b wait 在斷言前第 26 行（邊界外）→ 紅' 'AGapUITests.swift:31 [規則 ii]'
run "$check" "$work/gap-out" --lookback 30
expect 0 '⑨c --lookback 30 可調 → 邊界外變過' '無缺等待的斷言'

d="$work/ii-comment-string"
fixture "$d" ACommentUITests.swift \
  '        // 這裡本來該 waitForExistence 再讀，但只是註解' \
  '        XCTAssertTrue(app.buttons["a"].isHittable, "訊息字串裡提到 .exists／.label 不算：x.exists")' \
  '        let ok = app.buttons["b"].isEnabled // .exists 在行尾註解不算'
run "$check" "$d"
expect 0 '⑩ 字串字面值／註解裡的 .exists 與 waitFor 都不參與判斷（本例無讀取 → 不紅）' '無缺等待的斷言'
d="$work/ii-comment-wait"
fixture "$d" ACommentWaitUITests.swift \
  '        // 這裡本來該 waitForExistence 再讀，但只是註解' \
  '        XCTAssertTrue(app.buttons["a"].exists)'
run "$check" "$d"
expect 1 '⑩b 註解裡的 waitForExistence 不算等待 → 仍紅' 'ACommentWaitUITests.swift:6 [規則 ii]'

d="$work/ii-marker"
fixture "$d" AIiMarkerUITests.swift \
  '        let row = entryRow(in: app)' \
  '        // uitest-wait-ok: entryRow(in:) 內已 waitForExistence' \
  '        XCTAssertEqual(row.label, "x")'
run "$check" "$d"
expect 0 '⑪ 規則 ii 行內標記（同步點在 helper 內）→ 豁免' '無缺等待的斷言'

# ---------------- allowlist 與棘輪 ----------------
d="$work/allow"
fixture "$d" ALegacyUITests.swift '        XCTAssertTrue(app.buttons["a"].exists)'
printf '%s\n' "# 歷史債" "$(basename "$d")/ALegacyUITests.swift  # LS-458 落地時 1 處" > "$work/allow.txt"
out=$(bash "$check" --scan-dir "$d" --allowlist "$work/allow.txt" 2>&1); rc=$?
expect 0 '⑫ allowlist 具名檔的規則 ii 命中 → 豁免' '無缺等待的斷言'

d="$work/allow-i"
fixture "$d" ALegacyUITests.swift '        XCTAssertFalse(app.buttons["a"].waitForExistence(timeout: 3))'
printf '%s\n' "$(basename "$d")/ALegacyUITests.swift" > "$work/allow-i.txt"
out=$(bash "$check" --scan-dir "$d" --allowlist "$work/allow-i.txt" 2>&1); rc=$?
expect 1 '⑫b allowlist 不豁免規則 i（只吃規則 ii；且該條目因無規則 ii 命中同時被標過期）' '[規則 i]' 'allowlist 過期'

d="$work/allow-stale"
fixture "$d" AFixedUITests.swift '        XCTAssertTrue(app.buttons["a"].waitForExistence(timeout: 5))' '        XCTAssertTrue(app.buttons["a"].exists)'
printf '%s\n' "$(basename "$d")/AFixedUITests.swift" "$(basename "$d")/Gone.swift" > "$work/allow-stale.txt"
out=$(bash "$check" --scan-dir "$d" --allowlist "$work/allow-stale.txt" 2>&1); rc=$?
expect 1 '⑬ 棘輪：allowlist 條目已無命中／檔案不存在 → exit 1 並點名（債只減不留）' 'allowlist 過期' 'AFixedUITests.swift' 'Gone.swift'

# ---------------- fail closed ----------------
run "$check" "$work/no-such-dir"
expect 2 '⑭ 掃描目錄不存在 → exit 2' '找不到掃描目錄'
mkdir -p "$work/empty"; run "$check" "$work/empty"
expect 1 '⑭b 掃描目錄沒有 *.swift → exit 1（範圍空＝gate 形同虛設）' '找不到任何 *.swift'
out=$(bash "$check" --bogus 2>&1); rc=$?
expect 2 '⑭c 未知參數 → exit 2' '未知參數'
out=$(bash "$check" --lookback abc 2>&1); rc=$?
expect 2 '⑭d --lookback 非數字 → exit 2' '--lookback 須為非負整數'
out=$(bash "$check" --scan-dir 2>&1); rc=$?
expect 2 '⑭e --scan-dir 缺值 → exit 2' '--scan-dir 缺值'

# ---------------- mutation：每組改一份 gate 副本，對應夾具的結果必須翻轉 ----------------
mutant() {   # mutant <名稱> <sed 參數…>：合成副本；回傳副本路徑到 $mut，沒有實際改到就 fail
  local name=$1; shift
  mut="$work/mut-${name}.sh"
  if [ "$#" -eq 1 ]; then sed "$1" "$check" > "$mut"; else sed "$@" "$check" > "$mut"; fi
  if cmp -s "$check" "$mut"; then bad "mutant ${name} 沒被合成（gate 的對應行形狀變了，請同步更新本自測）"; return 1; fi
}
flipped() {  # flipped <名稱> <夾具目錄> <期望原本的 exit> ：mutant 跑同一夾具，exit 必須與原 gate 不同
  local name=$1 dir=$2 orig=$3
  local o r; o=$(bash "$mut" --scan-dir "$dir" --allowlist "${4:-$work/none.txt}" 2>&1); r=$?
  if [ "$r" -ne "$orig" ]; then ok "mutation：${name}（原 gate exit ${orig} → mutant exit ${r}）"
  else bad "mutation：${name} 未翻轉——對應斷言沒有牙（mutant 仍 exit ${r}）"; sed 's/^/    /' <<<"$o" >&2; fi
}

# M1：規則 i 不再認 waitForExistence → 修前原文 ① 變綠
mutant rule-i 's#stmt ~ /waitForExistence/#0#' && flipped '拿掉規則 i 的 waitForExistence 判斷，① 修前原文由紅轉綠' "$work/i-pos-single" 1
# M2：lookback 跨 func（拿掉 fstart 下限）→ ⑧ 由紅轉綠
mutant prevfunc 's#if (lo < fstart) lo = fstart;##' && flipped '拿掉 lookback 的 func 下限，⑧ 上一個 func 的 wait 被誤算而轉綠' "$work/ii-prevfunc" 1
# M3：不剔除 `//` 註解 → ⑩b 由紅轉綠
mutant comment -e 's#sub(/\\/\\/\.\*\$/, "", s)##' -e 's#if (b ~ /^\\/\\//) continue##' && flipped '不再剔除 // 註解，⑩b 註解裡的 waitForExistence 被誤算而轉綠' "$work/ii-comment-wait" 1
# M4：拿掉 allowlist 棘輪 → ⑬ 由紅轉綠
mutant ratchet 's#^stale=.*#stale=#' && flipped '拿掉 allowlist 棘輪，⑬ 過期條目不再被抓' "$work/allow-stale" 1 "$work/allow-stale.txt"
# M5：拿掉行內標記豁免 → ④ 由綠轉紅
mutant marker 's#L\[k\] ~ /uitest-wait-ok:\[ \\t\]\*\[^ \\t\]/#0#' && flipped '拿掉行內標記豁免，④ 由綠轉紅' "$work/i-marker" 0

if [ "$fail" -ne 0 ]; then echo "✗ uitest-wait-check 自測失敗" >&2; exit 1; fi
echo "✓ uitest-wait-check 自測通過（${n} 組樣本）"
