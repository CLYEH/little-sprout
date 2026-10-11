#!/bin/bash
# android-tap-target-registry-check.sh 的自測（LS-478）。CI rules job 每個 PR 都跑。
# 夾具 repo 只有 android/ 三處（主程式碼、登記表、排除清單）。涵蓋：登記／排除／雙缺紅／登記過期紅／
# 排除比對是整字（Home 不能放行 HomeScreen）／缺必要檔 exit 2，另有對真 repo 的一致性與 mutation：
# 拿掉真 repo 登記表的 HomeScreen 登記 → 必紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/android-tap-target-registry-check.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"
main="$R/android/app/src/main/kotlin/x"
reg="$R/android/app/src/androidTest/kotlin/com/clyeh/sproutday/TapTargetGateScreens.kt"
exe="$R/android/tap-target-exemptions.txt"
mkdir -p "$main" "$(dirname "$reg")"

screens() { rm -f "$main"/*.kt; local s; for s in "$@"; do printf '@Composable\ninternal fun %s() {}\n' "$s" > "$main/$s.kt"; done; }
registry() { { echo 'object TapTargetGateScreens { val all = listOf('; local s; for s in "$@"; do echo "    TapTargetScreen(name = \"$s\", minClickables = 0) { },"; done; echo ') }'; } > "$reg"; }
exemptions() { { echo '# 註解行'; echo; printf '%s\n' "$@"; } > "$exe"; }

expect() {   # expect <期望 exit> <名稱> [輸出必含…]
  local want=$1 name=$2; shift 2
  local out got good=1 must
  out=$(bash "$checker" --repo-root "$R" 2>&1); got=$?
  [ "$got" -eq "$want" ] || good=0
  for must in "$@"; do printf '%s' "$out" | grep -qF -- "$must" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
}

screens HomeScreen; registry HomeScreen; exemptions
expect 0 '① 畫面已登記 → exit 0' '全數已登記或具名排除'
screens HomeScreen LoginScreen; registry HomeScreen; exemptions 'LoginScreen：表單流程，追蹤於 LS-999'
expect 0 '② 未登記但具名排除（含理由）→ exit 0'
screens HomeScreen LoginScreen; registry HomeScreen; exemptions
expect 1 '③ 既未登記也未排除 → exit 1、點名畫面' 'LoginScreen 既未在 TapTargetGateScreens.kt 登記'
screens HomeScreen; registry HomeScreen; exemptions 'Home：不是整字相符'
expect 0 '④ 排除清單多一行不相干的名字不影響已登記畫面' '全數已登記'
screens HomeScreen; registry; exemptions 'Home：只是前綴，不該放行 HomeScreen'
expect 1 '④ 排除比對是整字：Home 不放行 HomeScreen' 'HomeScreen 既未在'
screens HomeScreen; registry HomeScreen GhostScreen; exemptions
expect 1 '⑤ 登記了主程式碼沒有的畫面 → exit 1（過期登記）' '登記了 GhostScreen'
screens; registry; exemptions
expect 0 '⑥ 還沒有任何畫面 → exit 0（0 個）' '畫面 0 個'
rm -f "$reg"
expect 2 '⑦ 缺登記表 → exit 2（fail closed）' '找不到'
registry HomeScreen; rm -f "$exe"
expect 2 '⑦ 缺排除清單 → exit 2' '找不到'
out=$(bash "$checker" --bogus 2>&1); got=$?
if [ "$got" -eq 2 ]; then ok '⑦ 未知參數 → exit 2'; else echo "✗ 未知參數應 exit 2（得 ${got}）" >&2; fail=1; fi

# 真 repo：目前的主程式碼與登記表一致；mutation：登記表拿掉 HomeScreen → 必紅（證明對帳真的在比）
out=$(bash "$checker" 2>&1); got=$?
if [ "$got" -eq 0 ]; then ok '⑧ 真 repo 一致'; else echo "✗ ⑧ 真 repo 不一致" >&2; printf '%s\n' "$out" >&2; fail=1; fi
M="$work/mut"; mkdir -p "$M"; cp -R "$root/android" "$M/android"
sed -i.bak 's/name = "HomeScreen"/name = "RenamedScreen"/' "$M/android/app/src/androidTest/kotlin/com/clyeh/sproutday/TapTargetGateScreens.kt"
out=$(bash "$checker" --repo-root "$M" 2>&1); got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'HomeScreen 既未在'; then ok '⑧ mutation：登記表改名 → exit 1、點名 HomeScreen'; else echo "✗ ⑧ mutation 應紅（exit ${got}）" >&2; printf '%s\n' "$out" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "✗ android-tap-target-registry-check.test.sh：有失敗" >&2; exit 1; fi
echo "✓ android-tap-target-registry-check.test.sh：${n} 項通過"
