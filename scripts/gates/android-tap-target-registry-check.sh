#!/bin/bash
# android-tap-target-registry-check.sh — Android 48dp 點擊目標登記制對帳（LS-478；iOS 對應物：tap-target-registry-check.sh）。
#
# `android/app/src/main/**` 每個 `fun <Name>Screen(`（畫面 composable 的命名慣例，見 HomeScreen.kt）要嘛在
# `android/app/src/androidTest/kotlin/com/clyeh/sproutday/TapTargetGateScreens.kt` 登記（`TapTargetScreen(name = "<Name>Screen"`），
# 要嘛在 `android/tap-target-exemptions.txt` 具名排除並附理由，否則擋。反向也擋：登記了卻在主程式碼找不到的名字
# （畫面改名／刪除後登記表沒跟著動，測的就不是現在的畫面）。純文字比對，不需 JDK／SDK／emulator。
#
# 用法：android-tap-target-registry-check.sh [--repo-root <dir>]（只給自測塞夾具）
# exit：0＝對帳一致；1＝有缺漏或過期登記；2＝找不到必要檔案（fail closed）。
# 自測：scripts/gates/android-tap-target-registry-check.test.sh（CI rules job）。規約：docs/COLLABORATION.md §7 Android 區塊。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) root=${2:-}; [ -n "$root" ] || { echo "✗ android-tap-target-registry：--repo-root 缺值" >&2; exit 2; }; shift 2 ;;
    *) echo "✗ android-tap-target-registry：未知參數「$1」。用法：android-tap-target-registry-check.sh [--repo-root <dir>]" >&2; exit 2 ;;
  esac
done

main_dir="$root/android/app/src/main"
registry="$root/android/app/src/androidTest/kotlin/com/clyeh/sproutday/TapTargetGateScreens.kt"
exemptions="$root/android/tap-target-exemptions.txt"
[ -d "$main_dir" ] || { echo "✗ android-tap-target-registry：找不到 ${main_dir}" >&2; exit 2; }
[ -r "$registry" ] || { echo "✗ android-tap-target-registry：找不到 ${registry}" >&2; exit 2; }
[ -r "$exemptions" ] || { echo "✗ android-tap-target-registry：找不到 ${exemptions}" >&2; exit 2; }

screens=$(grep -rhoE 'fun [A-Za-z0-9]+Screen\(' "$main_dir" --include='*.kt' | sed -E 's/^fun ([A-Za-z0-9]+)\($/\1/' | sort -u)
registered=$(grep -oE 'TapTargetScreen\(name = "[A-Za-z0-9]+Screen"' "$registry" | sed -E 's/.*"(.*)"/\1/' | sort -u)
exempted=$(grep -vE '^[[:space:]]*(#|$)' "$exemptions" | sed -E 's/：.*//' | sort -u)

bad=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$registered" | grep -qxF "$name" && continue
  printf '%s\n' "$exempted" | grep -qxF "$name" && continue
  echo "✗ android-tap-target-registry：畫面 ${name} 既未在 TapTargetGateScreens.kt 登記、也不在 android/tap-target-exemptions.txt 具名排除" >&2
  bad=1
done <<<"$screens"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$screens" | grep -qxF "$name" && continue
  echo "✗ android-tap-target-registry：登記了 ${name}，但 android/app/src/main 找不到 fun ${name}(（改名或刪除後登記表沒跟著動）" >&2
  bad=1
done <<<"$registered"
if [ "$bad" -ne 0 ]; then
  echo "  處理：① 在 TapTargetGateScreens.kt 加 TapTargetScreen(name = \"<Name>Screen\", minClickables = <n>) { … }；② 或在 android/tap-target-exemptions.txt 加一行「<Name>Screen：<理由>」；過期登記就刪掉或改名。" >&2
  exit 1
fi
echo "✓ android-tap-target-registry：android/app 的 *Screen 全數已登記或具名排除（畫面 $(printf '%s\n' "$screens" | grep -c .) 個）"
