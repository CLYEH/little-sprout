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
# LS-231：真的 xcodebuild 會在 -resultBundlePath 指定的路徑建立 bundle 目錄——模擬這個行為，
# 讓自測能驗證 tap-target-check.sh 對它的處理（成功清掉／失敗保留）。
prev=""
for a in "$@"; do
  if [ "$prev" = "-resultBundlePath" ]; then
    mkdir -p "$a"
  fi
  prev="$a"
done
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
  fail_with_violation_and_other_test)
    echo "Test Suite 'TapTargetGateTests' started."
    echo "/repo/LittleSproutUITests/TapTargetGateTests.swift:24: error: -[LittleSproutUITests.TapTargetGateTests testSettingsView] : failed - TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt（需 ≥44×44pt）"
    echo "Test Case '-[LittleSproutUITests.TapTargetGateTests testSettingsView]' failed (1.0 seconds)."
    echo "/repo/LittleSproutUITests/UploadQueueAlignmentTests.swift:80: error: -[LittleSproutUITests.UploadQueueAlignmentTests testM1Alignment] : failed - XCTAssertEqual failed: (\"31.04\") is not equal to (\"24.0\")"
    echo "Test Case '-[LittleSproutUITests.UploadQueueAlignmentTests testM1Alignment]' failed (0.5 seconds)."
    echo "** TEST FAILED **"
    exit 65
    ;;
  fail_with_unmatched_crash)
    # LS-231 負控樣本：一支違規 TAP-TARGET-FAIL＋一支「Test Case ... failed」但 log 裡找不到
    # 對應 `: failed - ` 格式的 assertion 行（模擬 setUp／tearDown 崩潰，xcodebuild 只印得出
    # Test Case 那一行）——這支測試只該印測試名，不能因為找不到 assertion 行就讓腳本壞掉或
    # 誤吞掉其餘筆數。
    echo "/repo/LittleSproutUITests/TapTargetGateTests.swift:24: error: -[LittleSproutUITests.TapTargetGateTests testSettingsView] : failed - TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt（需 ≥44×44pt）"
    echo "Test Case '-[LittleSproutUITests.TapTargetGateTests testSettingsView]' failed (1.0 seconds)."
    echo "*** Terminating app due to uncaught exception"
    echo "Test Case '-[LittleSproutUITests.CrashyTests testCrashesInSetUp]' failed (0.1 seconds)."
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
# LS-231：result_bundle 的路徑是腳本內部用 `git rev-parse --show-toplevel` 算出來的絕對路徑——
# 在 macOS 上 mktemp -d 落在 /tmp（symlink 到 /private/tmp），文字上跟 $R 不同，這裡另外算一次
# 「腳本自己會算出的」路徑，後面驗 result bundle 存在／不存在時用這個，不用 $R 本身。
result_bundle="$(cd "$R" && git rev-parse --show-toplevel)/tap-target-check.xcresult"

run() {   # run <FAKE_XCODEBUILD_MODE> [udid 個數覆寫用的額外參數…]
  local mode=$1; shift
  # LS-231：清掉 GITHUB_ACTIONS／GITHUB_JOB／GITHUB_RUN_ATTEMPT——自測若剛好在 GitHub Actions
  # runner 上跑（rules job 本身就是），這三個環境變數會被 runner 自動注入並繼承給子行程，讓
  # print_result_bundle_hint() 走到 CI 分支、輸出文字不穩定（隨呼叫端的 job／run attempt 漂移）。
  # 這裡固定走本機分支，斷言才穩定。
  ( cd "$R" && unset GITHUB_ACTIONS GITHUB_JOB GITHUB_RUN_ATTEMPT
    PATH="$bin:$PATH" FAKE_XCODEBUILD_MODE="$mode" bash "$checker" "$@" 2>&1 )
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

# ⑩ LS-207（16e6b7f9）：高度違規＋另一支不相關的紅測試同時存在 → 兩者都要在摘要（舊版只擷取 TAP-TARGET-FAIL，
#    LS-167 自 R3 起每次 CI 其實紅在兩處、直到高度修好第二處才露出，多燒一輪）
# LS-231：連不相關紅測試的 assertion 訊息本體（非 TAP-TARGET-FAIL 那支的 XCTAssertEqual 訊息）也要
# 印出來——只印測試名看不出「為什麼」（正控樣本）。
out=$(run fail_with_violation_and_other_test UDID SCHEME); got=$?
expect 1 '⑩ 高度違規＋不相關紅測試 → 兩者都在摘要，各附 assertion 訊息' "$got" "$out" \
  'TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt' \
  '本輪所有失敗測試' \
  "Test Case '-[LittleSproutUITests.UploadQueueAlignmentTests testM1Alignment]' failed" \
  'XCTAssertEqual failed: ("31.04") is not equal to ("24.0")'

# ⑪ LS-231 mutation-style 負控：找不到對應 assertion 行的失敗測試（例如 setUp／tearDown 崩潰，
#    log 裡沒有 `: failed - ` 這個格式）→ 只印測試名、不能讓腳本壞掉或吞掉其餘筆數的列印
#    （其餘那支違規照樣完整列出）。
out=$(run fail_with_unmatched_crash UDID SCHEME); got=$?
expect 1 '⑪ 找不到 assertion 行的測試 → 僅印測試名、不影響其餘筆數' "$got" "$out" \
  'TAP-TARGET-FAIL: 登出 frame=34.0x20.3pt' \
  "Test Case '-[LittleSproutUITests.CrashyTests testCrashesInSetUp]' failed" \
  'xcresult 已保留在'

# ⑫ LS-231：失敗時 result bundle（xcresult）要保留在原地，不能被清掉——CI 失敗後緊接的
# `if: failure()` 上傳步驟得靠它還在才撈得到。
rm -rf "$result_bundle"
out=$(run fail_with_violation UDID SCHEME); got=$?
if [ "$got" -eq 1 ] && [ -d "$result_bundle" ]; then
  echo "✓ ⑫ 失敗時 xcresult（result bundle）保留在原地"
else
  echo "✗ ⑫ 失敗時 xcresult 應保留在 ${result_bundle}（實得 exit ${got}，是否存在：$([ -d "$result_bundle" ] && echo 是 || echo 否)）" >&2
  fail=1
fi
rm -rf "$result_bundle"

# ⑬ LS-231：成功時 result bundle 要清掉，不留垃圾在工作目錄（本機重跑 push-gate.sh 會多次呼叫
# 這支腳本，累積的 xcresult 不該堆在 repo 裡）。
out=$(run pass UDID SCHEME); got=$?
if [ "$got" -eq 0 ] && [ ! -e "$result_bundle" ]; then
  echo "✓ ⑬ 成功時 xcresult 已清掉，不留在工作目錄"
else
  echo "✗ ⑬ 成功時 xcresult 應被清掉（實得 exit ${got}，是否仍存在：$([ -e "$result_bundle" ] && echo 是 || echo 否)）" >&2
  fail=1
fi

# ⑭ LS-231：-resultBundlePath 真的有帶給 xcodebuild（固定相對路徑），供 CI 上傳步驟撈同一個路徑。
args_file2="$work/xcodebuild-resultbundle.args"
rm -rf "$result_bundle"
out=$(cd "$R" && unset GITHUB_ACTIONS GITHUB_JOB GITHUB_RUN_ATTEMPT
  PATH="$bin:$PATH" FAKE_XCODEBUILD_MODE=fail_with_violation FAKE_XCODEBUILD_ARGS_FILE="$args_file2" bash "$checker" UDID SCHEME 2>&1); got=$?
if grep -qxF -- '-resultBundlePath' "$args_file2" && grep -qxF -- "$result_bundle" "$args_file2"; then
  echo "✓ ⑭ xcodebuild 有帶 -resultBundlePath ${result_bundle}"
else
  echo "✗ ⑭ xcodebuild 應帶 -resultBundlePath ${result_bundle}" >&2
  sed 's/^/    /' "$args_file2" >&2 2>/dev/null
  fail=1
fi
rm -rf "$result_bundle"

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
