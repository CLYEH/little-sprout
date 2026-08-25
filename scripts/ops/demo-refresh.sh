#!/bin/bash
# 本機 demo（LS-102）：把 detached worktree `.claude/worktrees/demo` 移到指定 ref（預設 origin/main；可給 origin/test 看 QA 中的版本），
# 缺 Config/Secrets.xcconfig 就從本機 `supabase status` 產生（gitignored，本機值），建／重用 `demo-iPhone17Pro` 模擬器，build → install → launch。
# 用法：bash scripts/ops/demo-refresh.sh [ref]     前提：`supabase start` 已跑、Xcode 可用。看完請關模擬器（結尾印指令）。
# 不入版控的東西：Secrets.xcconfig（gitignored）、DerivedData（/tmp）。腳本不讀 .env。
set -uo pipefail
# 主 repo 根目錄：在 ticket worktree 內執行時 --show-toplevel 會是該 worktree，改用 --git-common-dir 反推（R1 F2）
common=$(git rev-parse --git-common-dir 2>/dev/null) || { echo "✗ 不在 git repo 內" >&2; exit 2; }
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
ROOT=$(cd "$(dirname "$common")" && pwd -P)
WT="$ROOT/.claude/worktrees/demo"; REF=${1:-origin/main}; SIM_NAME=demo-iPhone17Pro; DD=/tmp/little-sprout-demo-dd
git -C "$ROOT" fetch -q origin || { echo "✗ git fetch 失敗" >&2; exit 2; }
if [ ! -d "$WT" ]; then git -C "$ROOT" worktree add --detach "$WT" "$REF" >/dev/null || { echo "✗ worktree add 失敗" >&2; exit 2; }; fi
cd "$WT" || exit 2
git checkout -q --detach "$REF" || { echo "✗ checkout $REF 失敗" >&2; exit 2; }
echo "demo @ $(git log --oneline -1)"
if [ ! -f Config/Secrets.xcconfig ]; then
  url=$(supabase status -o env 2>/dev/null | grep -E '^API_URL=' | cut -d= -f2- | tr -d '"')
  anon=$(supabase status -o env 2>/dev/null | grep -E '^ANON_KEY=' | cut -d= -f2- | tr -d '"')
  [ -n "$url" ] && [ -n "$anon" ] || { echo "✗ 本機 supabase 沒跑（先 supabase start）" >&2; exit 2; }
  # xcconfig 把 // 當註解，要寫成 /$()/；bash 3.2 的 ${var//…} 會留字面反斜線（R1 F1），改用 sed
  url_x=$(printf '%s' "$url" | sed 's#//#/$()/#')
  printf 'SUPABASE_URL = %s\nSUPABASE_ANON_KEY = %s\n' "$url_x" "$anon" > Config/Secrets.xcconfig
  echo "Config/Secrets.xcconfig 已產生（本機值，gitignored）"
fi
udid=$(xcrun simctl list devices available | grep "$SIM_NAME" | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$udid" ]; then
  rt=$(xcrun simctl list runtimes | grep -E 'iOS' | tail -1 | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS[-0-9]+')
  # devicetype：優先 iPhone 17 Pro，沒有就取清單第一個 iPhone（R1 I1）
  dt=$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-17-Pro\b' | head -1)
  [ -n "$dt" ] || dt=$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone[-A-Za-z0-9]*' | head -1)
  [ -n "$rt" ] && [ -n "$dt" ] || { echo "✗ 找不到 iOS runtime／iPhone devicetype" >&2; exit 2; }
  udid=$(xcrun simctl create "$SIM_NAME" "$dt" "$rt") || { echo "✗ 建立模擬器失敗" >&2; exit 2; }
fi
xcrun simctl boot "$udid" 2>/dev/null || true
rm -rf "$DD/Build/Products"   # 不留上一次的 .app，build 失敗不會靜默裝舊版（R1 F3）
xcodebuild -project LittleSprout.xcodeproj -scheme LittleSprout -configuration Debug -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DD" build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | tail -3
build_rc=${PIPESTATUS[0]}; [ "$build_rc" -eq 0 ] || { echo "✗ xcodebuild 失敗（rc=$build_rc）" >&2; exit 1; }
app=$(find "$DD/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' | head -1); [ -n "$app" ] || { echo "✗ 找不到 .app" >&2; exit 1; }
bundle=$(defaults read "$app/Info.plist" CFBundleIdentifier 2>/dev/null); [ -n "$bundle" ] || { echo "✗ 讀不到 bundle id" >&2; exit 1; }
xcrun simctl install "$udid" "$app" && xcrun simctl launch "$udid" "$bundle" >/dev/null && open -a Simulator && echo "✓ 已啟動 $SIM_NAME（$udid）。看完：xcrun simctl shutdown $udid"
