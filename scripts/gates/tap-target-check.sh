#!/bin/bash
# ≥44pt 點擊目標機械 gate（LS-95）：對 `LittleSproutUITests` 的 `TapTargetGateTests`（真正的
# 產品畫面，見 `LittleSprout/TapTargetGateHarness.swift`）與 `TapTargetGateSelfTests`（自測
# 樣本，見該檔文件註解）跑一次 `xcodebuild test`，任一元件 <44pt 就列出元件 label＋frame、
# exit 1。
#
# 技術路徑（票文列了三選項，這裡選定並記錄理由）：本機 Xcode 26.6 環境沒有 `xcrun simctl`
# accessibility dump 子指令（`simctl help` 列出的子指令沒有任何 accessibility／ui-describe
# 相關項目）；`idb`／`idb_companion` 均未安裝（`which` 落空，且要求另外裝一支 CLI 依賴，
# CI／其他開發環境不保證有）。XCUITest（`XCUIApplication().buttons.allElementsBoundByIndex`
# 讀 `.frame`）是唯一在這個工具鏈組合下實測可行、且與現有 `LittleSproutTests` 共用同一套
# xcodebuild 流程、不需要額外裝 CLI 的路徑——已建成 `LittleSproutUITests` 目標並實測：
#   1. 對現行 main（已修）：`TapTargetGateTests` 兩個 test method 皆綠。
#   2. 對 LS-17 QA1 修正前的 `OTPVerificationView`／`SettingsView`（暫時還原對應片段跑過
#      一次，未 commit）：兩個 test method 皆紅，分別點名「重新寄一次驗證碼
#      frame=163.0x22.0pt」「登出 frame=34.0x20.3pt」，與 PR #148／LS-17 QA1 記錄的
#      162×22pt／32×19pt 吻合（差 1pt 是不同次模擬器渲染的正常誤差）。
#   3. 自測樣本（`TapTargetGateSelfTests`）覆蓋 #148 R1 I4 的漏網型（padding 掛在 Button
#      外層、不參與 hit test）：故意小樣本、44pt 樣本、padding-outside-Button 樣本三條都
#      通過（見該測試檔文件註解）。
#
# 字級固定一般字級（非 AX 放大字級）：`app.launchEnvironment["UIPreferredContentSizeCategoryName"]
# = "UICTContentSizeCategoryL"`（`TapTargetMeasurement.launch`）——#148 R1 F2：放大字級下
# 內容本身就會 ≥44pt，量了無意義。「一般字級」＝ launch environment 覆寫的 large（`UICTContentSizeCategoryL`），
# 這支 gate 不吃模擬器系統設定的 `simctl ui content_size`（launch environment 對這個 process 優先）；
# `scripts/ops/simulator-lock.sh` 的 `--udid` 選項會把系統設定調成同一個值（large）——目前兩者互不相干（本 gate
# 不靠 simulator-lock 提供的系統設定），但字面上要保持一致，避免日後量測方式改用系統設定時靜默偏移（merge-review
# R1 fd783f6c F5）。動這裡的字級常數前，先看 simulator-lock.sh 對應的註解。
#
# 用法：tap-target-check.sh <UDID> <scheme>
# exit：0＝所有量測畫面的 Button／tappable 元件皆 ≥44×44pt；1＝有違規（或其他測試/編譯失敗，
#   log 尾段會印出來，不會被靜默吞掉）；2＝參數錯誤。
set -uo pipefail

if [ $# -ne 2 ]; then
  echo "用法：tap-target-check.sh <UDID> <scheme>" >&2
  exit 2
fi
udid=$1
scheme=$2

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "✗ tap-target-check：不在 git repo 內（fail closed）" >&2
  exit 2
}
cd "$repo"

log=$(mktemp -t tap-target-check.XXXXXX)
trap 'rm -f "$log"' EXIT

#    刻意不帶 `-quiet`：那個旗標會把 xcodebuild 的輸出收斂成「Failing tests: <方法名>」的
#    精簡摘要，連 `TAP-TARGET-FAIL:` 這種來自 `XCTFail` 訊息本體的文字都一起被吞掉（實測
#    重現：帶 `-quiet` 時，故意造出的違規只印得出方法名，抓不到下面要 grep 的標記）。
#    LS-158：`LittleSproutUITests/QA/QASmokeTests`（QA 端到端情境）需要本機 Supabase 容器＋Mailpit，沒環境變數
#    一律 XCTFail（刻意不 XCTSkip），CI 的這支 gate 不得跑到它。`-only-testing` 對 `-skip-testing` 有優先權
#    （man xcodebuild：「-only-testing has precedence over -skip-testing」，實測 `-only-testing:LittleSproutUITests
#    -skip-testing:LittleSproutUITests/QASmokeTests` 仍會跑 QA），所以改成純 `-skip-testing` 組合：跳過 unit test
#    target（維持只跑 UI 測試）＋跳過 QASmokeTests——效果等於原本的整個 UITests target 減去 QA 情境。
#    tap-target-check.test.sh ⑨ 釘住這組旗標。
if xcodebuild test \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=${udid}" \
  -skip-testing:LittleSproutTests \
  -skip-testing:LittleSproutUITests/QASmokeTests \
  -parallel-testing-enabled NO \
  > "$log" 2>&1; then
  # merge-review R1 M1：不印「所有量測畫面」這種聽起來像全域覆蓋的措辭——目前只有
  # LittleSprout/TapTargetGateScreenName.swift 註冊的畫面會被實際量到（其餘 Features 畫面見
  # scripts/gates/tap-target-exemptions.txt 具名排除，或尚待補進註冊表），明確點名以免誤導。
  checked=$(grep -oE '= "[A-Za-z0-9]+View"' "$(git rev-parse --show-toplevel)/LittleSprout/TapTargetGateScreenName.swift" \
    | sed -E 's/= "(.*)"/\1/' | paste -sd '、' -)
  echo "✓ tap-target-check：已量測畫面（${checked:-無}）的 Button／tappable 元件皆 ≥44×44pt（一般字級 content_size large 量測）；其餘 Features 畫面覆蓋見 tap-target-exemptions.txt"
  exit 0
fi

violations=$(grep 'TAP-TARGET-FAIL:' "$log" || true)

# LS-207（16e6b7f9）：TAP-TARGET-FAIL 只在點擊目標違規時出現；同一輪 UITests 若另有不相關的紅測試（LS-167 R3 起：
# iOS 26.2 sheet 縮放讓一支對齊測試同時紅），舊版摘要只擷取 TAP-TARGET-FAIL、把它吞掉，直到高度違規修好第二個紅
# 測試才露出，多燒一輪 CI。這裡另抓 xcodebuild 逐一列印的「Test Case '-[Target.Class testMethod]' failed」行，
# 獨立列出「本輪所有失敗測試」——不論是否已有 TAP-TARGET-FAIL 都列，讓所有紅測試一次看到。
# LS-207 R2（merge-review R1 fd783f6c I1）：這份清單含**全部**失敗的測試方法，觸發 TAP-TARGET-FAIL 的那支自己
# 也會出現在裡面（它本來就是失敗的測試）——標題原本寫「其他…無關」不精確，這裡不刻意濾掉它，簡單、一次看清楚
# 這輪所有紅測試比「排除自己」更不容易漏東西。
other_failed=$(grep -oE "Test Case '-\[[^]']+\]' failed" "$log" | sort -u || true)

if [ -n "$violations" ]; then
  echo "✗ tap-target-check：以下元件 <44×44pt（一般字級 content_size large 量測，長輩硬約束 ≥44pt）：" >&2
  printf '%s\n' "$violations" | sed 's/^/    /' >&2
  if [ -n "$other_failed" ]; then
    echo "本輪所有失敗測試（含觸發上面 TAP-TARGET-FAIL 的那支自己，一併列出避免被吞——LS-167 事故）：" >&2
    printf '%s\n' "$other_failed" | sed 's/^/    /' >&2
  fi
  exit 1
fi

echo "✗ tap-target-check：xcodebuild test 失敗，但輸出裡沒有 TAP-TARGET-FAIL 標記——不是點擊目標違規，可能是編譯或其他測試失敗。" >&2
if [ -n "$other_failed" ]; then
  echo "本輪所有失敗測試：" >&2
  printf '%s\n' "$other_failed" | sed 's/^/    /' >&2
fi
echo "log 尾段：" >&2
tail -n 60 "$log" >&2
exit 1
