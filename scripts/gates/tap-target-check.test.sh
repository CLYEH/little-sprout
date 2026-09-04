#!/bin/bash
# tap-target-check.sh 的自測（LS-95）。CI rules job 每個 PR 都跑。
#
# 真的跑一次 xcodebuild test（甚至只是 build-for-testing）太重、也不該綁死本機是否已建好
# Xcode 專案／模擬器——比照 push-gate.test.sh 的既有模式：PATH 換上一支可控的假 xcodebuild，
# 不碰本機真正的模擬器。這裡只驗 tap-target-check.sh 自己的邏輯（參數檢查、log 解析、
# exit code）；「XCUITest 真的量得到／量不到某個元件」不是這支腳本的責任，那是
# `LittleSproutUITests`（`TapTargetGateTests`／`TapTargetGateSelfTests`）的責任，兩者的
# 實測證據見 tap-target-check.sh 檔頭注解（golden sample：對 LS-17 QA1 修正前的
# OTPVerificationView／SettingsView 跑出 163.0x22.0pt／34.0x20.3pt，與修正後的綠）。
#
# 「前饋必有反饋」對這支腳本也適用：若退化成把「xcodebuild 失敗但沒有 TAP-TARGET-FAIL
# 標記」誤判成通過（吞掉非點擊目標的失敗）、只印第一個違規就不管其餘（LS-86 retro：全域
# 條件不能遮蔽個別判定路徑）、或參數檢查鬆綁，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/tap-target-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ---- 假 xcodebuild：讀 FAKE_XCODEBUILD_MODE 決定要印什麼、exit 什麼，完全不碰真的模擬器 ----
bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/xcodebuild" <<'STUB'
#!/bin/bash
# LS-158 ⑨：把收到的旗標一行一個記下來，讓自測能斷言 -skip-testing／-only-testing 的組合
printf '%s\n' "$@" > "${FAKE_XCODEBUILD_ARGS_FILE:-/dev/null}"
case "${FAKE_XCODEBUILD_MODE:-pass}" in
  pass)
    echo "Test Suite 'All tests' passed at 2026-09-01 00:00:00."
    exit 0
    ;;
  fail_with_violation)
    echo "Test Suite 'TapTargetGateTests' started."
    echo "/repo/LittleSproutUITests/TapTargetGateTests.swift:24: error: -[LittleSproutUITests.TapTargetGateTests testSettingsView] : failed - TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt（需 ≥44×44pt）"
    echo "Test Case '-[LittleSproutUITests.TapTargetGateTests testSettingsView]' failed (1.0 seconds)."
    echo "** TEST FAILED **"
    exit 65
    ;;
  fail_with_multiple_violations)
    echo "/repo/LittleSproutUITests/TapTargetGateTests.swift:24: error: -[LittleSproutUITests.TapTargetGateTests testOTPVerificationView] : failed - TAP-TARGET-FAIL: 重新寄一次驗證碼 frame=163.0x22.0pt（需 ≥44×44pt）"
    echo "/repo/LittleSproutUITests/TapTargetGateTests.swift:24: error: -[LittleSproutUITests.TapTargetGateTests testSettingsView] : failed - TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt（需 ≥44×44pt）"
    echo "** TEST FAILED **"
    exit 65
    ;;
  fail_no_violation)
    echo "error: Build input files cannot be found: '/repo/LittleSprout/Missing.swift'"
    echo "** TEST FAILED **"
    exit 65
    ;;
esac
STUB
chmod +x "$bin/xcodebuild"

# repo：tap-target-check.sh 只需要 `git rev-parse --show-toplevel` 找得到頂層即可
R="$work/repo"
mkdir -p "$R"
git -C "$R" init -q

run() {   # run <FAKE_XCODEBUILD_MODE> [udid 個數覆寫用的額外參數…]
  local mode=$1; shift
  ( cd "$R" && PATH="$bin:$PATH" FAKE_XCODEBUILD_MODE="$mode" bash "$checker" "$@" 2>&1 )
}

expect() {   # expect <期望 exit code> <名稱> <實得 exit code> <輸出> [輸出必含字串…]
  local want=$1 name=$2 got=$3 out=$4
  shift 4
  local ok=1
  [ "$got" -eq "$want" ] || ok=0
  local must
  for must in "$@"; do
    printf '%s' "$out" | grep -qF -- "$must" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ① 缺參數 → exit 2、印用法
out=$(cd "$R" && PATH="$bin:$PATH" bash "$checker" 2>&1); got=$?
expect 2 '① 缺參數 → exit 2、印用法' "$got" "$out" '用法：tap-target-check.sh'

# ② 只給一個參數 → exit 2
out=$(cd "$R" && PATH="$bin:$PATH" bash "$checker" SOME-UDID 2>&1); got=$?
expect 2 '② 只給 UDID、缺 scheme → exit 2' "$got" "$out"

# ③ 給第三個多餘參數 → exit 2
out=$(cd "$R" && PATH="$bin:$PATH" bash "$checker" UDID SCHEME EXTRA 2>&1); got=$?
expect 2 '③ 多給第三個參數 → exit 2' "$got" "$out"

# ④ 不在 git repo 內 → exit 2（fail closed）
out=$(cd "$work" && PATH="$bin:$PATH" bash "$checker" UDID SCHEME 2>&1); got=$?
expect 2 '④ 不在 git repo 內 → exit 2' "$got" "$out" '不在 git repo 內'

# ⑤ xcodebuild 全綠 → exit 0
out=$(run pass UDID SCHEME); got=$?
expect 0 '⑤ xcodebuild 全綠 → exit 0' "$got" "$out" '✓ tap-target-check'

# ⑥ xcodebuild 失敗、輸出含 1 個 TAP-TARGET-FAIL → exit 1、點名該元件
out=$(run fail_with_violation UDID SCHEME); got=$?
expect 1 '⑥ 1 個違規 → exit 1、點名元件與 frame' "$got" "$out" \
  'TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt'

# ⑦ mutation-style 負控：兩個違規都要被列出來，不能只印第一個就不管其餘
#    （LS-86 retro：全域條件不能遮蔽個別判定路徑——這裡驗的是 grep 沒有被改成只取第一筆）
out=$(run fail_with_multiple_violations UDID SCHEME); got=$?
expect 1 '⑦ 2 個違規都要點名（不是只印第一個）' "$got" "$out" \
  'TAP-TARGET-FAIL: 重新寄一次驗證碼 frame=163.0x22.0pt' \
  'TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt'

# ⑧ mutation-style 負控：xcodebuild 失敗但不是點擊目標違規（例如編譯錯誤）→ 仍要 exit 1、
#    印出 log 尾段——不能因為抓不到 TAP-TARGET-FAIL 就誤判成通過（吞掉真正的失敗）
out=$(run fail_no_violation UDID SCHEME); got=$?
expect 1 '⑧ 失敗但無 TAP-TARGET-FAIL 標記 → 仍 exit 1、印 log 尾段' "$got" "$out" \
  '不是點擊目標違規' 'Build input files cannot be found'

# ⑨ LS-158：QA e2e（LittleSproutUITests/QA/QASmokeTests）需要本機容器，CI 的這支 gate 不得跑到它。
#    `-only-testing` 對 `-skip-testing` 有優先權（man xcodebuild），所以必須是純 -skip-testing 組合：
#    跳過 unit test target＋QASmokeTests，且不得再帶任何 -only-testing（帶了 skip 就失效、QA 會在 CI 假紅）。
args_file="$work/xcodebuild.args"
out=$(cd "$R" && PATH="$bin:$PATH" FAKE_XCODEBUILD_MODE=pass FAKE_XCODEBUILD_ARGS_FILE="$args_file" bash "$checker" UDID SCHEME 2>&1); got=$?
if [ "$got" -eq 0 ] \
   && grep -qxF -- '-skip-testing:LittleSproutUITests/QASmokeTests' "$args_file" \
   && grep -qxF -- '-skip-testing:LittleSproutTests' "$args_file" \
   && ! grep -q -- '^-only-testing' "$args_file"; then
  echo "✓ ⑨ xcodebuild 旗標＝純 -skip-testing 組合（跳過 LittleSproutTests＋QASmokeTests、無 -only-testing）"
else
  echo "✗ ⑨ xcodebuild 旗標應為 -skip-testing:LittleSproutTests＋-skip-testing:LittleSproutUITests/QASmokeTests 且無 -only-testing（實得 exit ${got}）" >&2
  sed 's/^/    /' "$args_file" >&2 2>/dev/null
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ tap-target-check.test.sh 全部通過"
else
  echo "✗ tap-target-check.test.sh 有案例失敗" >&2
fi
exit "$fail"
