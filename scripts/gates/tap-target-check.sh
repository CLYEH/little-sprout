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
# 內容本身就會 ≥44pt，量了無意義。
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
if xcodebuild test \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=${udid}" \
  -only-testing:LittleSproutUITests \
  -parallel-testing-enabled NO \
  > "$log" 2>&1; then
  echo "✓ tap-target-check：所有量測畫面的 Button／tappable 元件皆 ≥44×44pt（一般字級 content_size large 量測）"
  exit 0
fi

violations=$(grep 'TAP-TARGET-FAIL:' "$log" || true)
if [ -n "$violations" ]; then
  echo "✗ tap-target-check：以下元件 <44×44pt（一般字級 content_size large 量測，長輩硬約束 ≥44pt）：" >&2
  printf '%s\n' "$violations" | sed 's/^/    /' >&2
  exit 1
fi

echo "✗ tap-target-check：xcodebuild test 失敗，但輸出裡沒有 TAP-TARGET-FAIL 標記——不是點擊目標違規，可能是編譯或其他測試失敗。log 尾段：" >&2
tail -n 60 "$log" >&2
exit 1
