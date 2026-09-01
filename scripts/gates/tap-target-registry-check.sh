#!/bin/bash
# LS-95 M1（merge-review R1）：畫面覆蓋對帳——`LittleSprout/Features/**/*View.swift` 每一支都要嘛
# 在 `LittleSprout/TapTargetGateScreenName.swift` 掛一個 case（rawValue 等於檔名去掉 `.swift`），
# 要嘛在 `scripts/gates/tap-target-exemptions.txt` 具名排除並附理由，否則擋。
#
# 起因：R1 PR 只在 14 支 Features 畫面裡註冊了 2 支（`OTPVerificationView`／`SettingsView`），
# 卻同一個 PR 把 COLLABORATION §4 的 qa 人工量測拿掉——機械覆蓋 0、人工覆蓋被移除，比併入前更
# 沒保護。這支腳本把「新畫面要嘛被量、要嘛大聲排除，不准靜默通過」變成機械規則：往後新增
# Features 畫面若沒有同步更新註冊表或排除清單，這裡會擋並點名。
#
# 純文字比對，不需要 Xcode／模擬器——跑在 CI 的 rules job（ubuntu-latest）即可，不必等 macOS
# 的 ci job。掛 push-gate.sh（無條件跑，不依賴 Features/ diff：這是檔案清單對帳，不是模擬器
# 量測，成本可忽略）。
#
# exit：0＝全數已註冊或具名排除；1＝有畫面兩邊都沒有，列出來並提示怎麼處理；2＝找不到必要檔案
# （fail closed）。
set -uo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "✗ tap-target-registry gate：不在 git repo 內（fail closed）" >&2
  exit 2
}
cd "$repo"

registry="LittleSprout/TapTargetGateScreenName.swift"
exemptions="scripts/gates/tap-target-exemptions.txt"
[ -r "$registry" ] || { echo "✗ tap-target-registry gate：找不到 ${registry}" >&2; exit 2; }
[ -r "$exemptions" ] || { echo "✗ tap-target-registry gate：找不到 ${exemptions}" >&2; exit 2; }

# 註冊表：case rawValue 形狀是 "XxxView"（只認這個形狀，排除自測樣本 case，如
# SelfTestTooSmall／SelfTestGood 等不含 "View" 結尾字面的值）。
registered=$(grep -oE '= "[A-Za-z0-9]+View"' "$registry" | sed -E 's/= "(.*)"/\1/' | sort -u)
# 排除清單：非空白、非 # 開頭的行，第一個「：」前的字串當畫面名。
exempted=$(grep -vE '^[[:space:]]*(#|$)' "$exemptions" | sed -E 's/：.*//' | sort -u)

missing=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  name=$(basename "$f" .swift)
  printf '%s\n' "$registered" | grep -qxF "$name" && continue
  printf '%s\n' "$exempted" | grep -qxF "$name" && continue
  missing="${missing}    ${f}（${name}）\n"
done < <(find LittleSprout/Features -name '*View.swift' | sort)

if [ -n "$missing" ]; then
  echo "✗ tap-target-registry gate：以下畫面既未在 ${registry} 註冊、也不在 ${exemptions} 具名排除：" >&2
  printf '%b' "$missing" >&2
  echo "  請二選一：① 加一個 case 到 ${registry}，並在 LittleSprout/TapTargetGateHarness.swift 的" >&2
  echo "  hostView(for:) 補對應分支、LittleSproutUITests/TapTargetGateTests.swift 補一個 test 方法；" >&2
  echo "  ② 在 ${exemptions} 加一行「<ViewName>：<理由>」。" >&2
  exit 1
fi
echo "✓ tap-target-registry gate：Features/**/*View.swift 全數已註冊或具名排除"
