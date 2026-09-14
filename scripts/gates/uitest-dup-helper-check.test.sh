#!/bin/bash
# uitest-dup-helper-check.sh 的自測（LS-267）。CI `rules` job 跑。
# 合成 .swift 夾具（不碰真的 LittleSproutUITests）驗：兩檔同本體要抓到、單檔不誤報、同名不同本體不誤報、
# 只差空白／註解仍算同一份、informational 一律 exit 0、目錄不存在就略過；mutant 證明「去空白正規化」
# 與「≥2 才報」兩條判準各自有覆蓋。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/uitest-dup-helper-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }

mk_helper() { # <檔案> <函式名> <內文>
  mkdir -p "$(dirname "$1")"
  {
    printf 'import XCTest\n\nfinal class Sample: XCTestCase {\n'
    printf '    func testSomething() { XCTAssertTrue(true) }\n\n'
    printf '    private func %s(_ element: XCUIElement) -> Bool {\n' "$2"
    printf '%s\n' "$3"
    printf '    }\n}\n'
  } > "$1"
}

BODY='        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if element.isHittable { return true }
        }
        return false'

# ---- ① 兩檔同本體 → ⚠ 並點名兩個檔 ----
d1="${work}/dup"; mkdir -p "$d1"
mk_helper "${d1}/AUITests.swift" waitForHittable "$BODY"
mk_helper "${d1}/BUITests.swift" waitForHittable "$BODY"
out=$(bash "$check" "$d1" 2>&1); rc=$?
rc_is '① 有重複仍 exit 0（informational，不擋）' 0 "$rc" "$out"
has '① 印 ⚠ 重複 helper' "$out" '⚠ 重複 helper：'
has '① 帶簽名' "$out" 'private func waitForHittable(_ element: XCUIElement) -> Bool'
has '① 帶次數' "$out" '×2'
has '① 點名 A 檔' "$out" 'AUITests.swift:6'
has '① 點名 B 檔' "$out" 'BUITests.swift:6'

# ---- ② 單檔一份 → 不報 ----
d2="${work}/single"; mkdir -p "$d2"
mk_helper "${d2}/AUITests.swift" waitForHittable "$BODY"
out=$(bash "$check" "$d2" 2>&1); rc=$?
rc_is '② 無重複 → exit 0' 0 "$rc" "$out"
hasnt '② 無重複 → 不印 ⚠' "$out" '⚠'
has '② 印無重複的結論（不是靜默）' "$out" '無重複的 private func 本體'

# ---- ③ 同名但本體不同 → 不誤報（真 repo 的 AlbumDetailAX3 vs InteractionRow 形狀）----
d3="${work}/samename"; mkdir -p "$d3"
mk_helper "${d3}/AUITests.swift" waitForHittable "$BODY"
mk_helper "${d3}/BUITests.swift" waitForHittable '        return element.isHittable'
out=$(bash "$check" "$d3" 2>&1); rc=$?
rc_is '③ 同名不同本體 → exit 0' 0 "$rc" "$out"
hasnt '③ 同名不同本體不算複本' "$out" '⚠'

# ---- ④ 只差縮排／行尾註解 → 正規化後仍算同一份 ----
d4="${work}/whitespace"; mkdir -p "$d4"
mk_helper "${d4}/AUITests.swift" waitForHittable "$BODY"
mk_helper "${d4}/BUITests.swift" waitForHittable '        let deadline = Date().addingTimeInterval(5)   // 等 5 秒
        while Date() < deadline {
                if element.isHittable { return true }
        }
        return false'
out=$(bash "$check" "$d4" 2>&1); rc=$?
has '④ 只差縮排／註解仍判為同一份複本' "$out" '⚠ 重複 helper：'
rc_is '④ 仍 exit 0' 0 "$rc" "$out"

# ---- ⑤ 掃描目錄不存在／沒有 .swift → 略過、exit 0 ----
out=$(bash "$check" "${work}/nope" 2>&1); rc=$?
rc_is '⑤ 目錄不存在 → exit 0 略過' 0 "$rc" "$out"
has '⑤ 說明略過原因' "$out" '找不到'
mkdir -p "${work}/empty"
out=$(bash "$check" "${work}/empty" 2>&1); rc=$?
rc_is '⑤ 目錄沒有 .swift → exit 0 略過' 0 "$rc" "$out"
has '⑤ 說明沒有 .swift' "$out" '沒有 .swift'

# ---- ⑥ 真 repo：跑得動且不擋（只驗 exit code 與有輸出，不釘死目前有幾筆——修掉重複不該讓這支紅）----
out=$(bash "$check" 2>&1); rc=$?
rc_is '⑥ 真 repo（LittleSproutUITests/）→ exit 0' 0 "$rc" "$out"
if [ -n "$out" ]; then echo "✓ ⑥ 真 repo 有結論輸出（目前：$(printf '%s' "$out" | head -1 | cut -c1-60)…）"; else echo "✗ ⑥ 真 repo 無任何輸出" >&2; fail=1; fi

# ---- ⑦ mutant：拿掉「去全部空白」的正規化 → ④ 的樣本不再被判為複本 ----
mut="${work}/mut-normalize.sh"
sed 's|^  stripped = line; gsub(/\[\[:space:\]\]/, "", stripped)|  stripped = line|' "$check" > "$mut"
grep -q '^  stripped = line$' "$mut" || { echo "✗ ⑦ mutant 沒被正確合成（正規化那行的形狀變了）" >&2; fail=1; }
out=$(bash "$mut" "$d4" 2>&1); rc=$?
if printf '%s' "$out" | grep -qF '⚠'; then
  echo "✗ ⑦ mutant 未如預期翻轉——④ 的綠（抓到複本）不是來自去空白正規化" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
else
  echo "✓ ⑦ mutant（拿掉去空白正規化）：④ 的複本不再被抓到——證明正規化是它被抓到的原因"
fi
out=$(bash "$mut" "$d1" 2>&1)
has '⑦ mutant 對照：完全相同的兩份（①）仍被抓到，證明 mutant 只動到正規化' "$out" '⚠ 重複 helper：'

# ---- ⑧ mutant：門檻退成 ≥1 → ② 的單份也被報（證明「≥2 才報」這條判準有覆蓋）----
mut2="${work}/mut-threshold.sh"
sed 's|if (count\[b\] >= 2)|if (count[b] >= 1)|' "$check" > "$mut2"
out=$(bash "$mut2" "$d2" 2>&1)
has '⑧ mutant（門檻改 ≥1）：② 的單份被誤報——證明 ② 的綠來自 ≥2 門檻' "$out" '⚠ 重複 helper：'

if [ "$fail" -eq 0 ]; then
  echo "✓ uitest-dup-helper-check 自測通過（8 組樣本）"
fi
exit "$fail"
