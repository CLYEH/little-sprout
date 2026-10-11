#!/usr/bin/env bash
# LS-466：把最新 release tag 與 commit 數注入 Xcode 建置設定。
#
# 寫出 Config/Version.xcconfig（gitignored）：
#   MARKETING_VERSION       = 最新 `v*` tag 去掉開頭 v（無 tag → 0.0.0）
#   CURRENT_PROJECT_VERSION = `git rev-list --count HEAD`
# Config/Base.xcconfig 以 `#include? "Version.xcconfig"` 讀取；沒跑本腳本時退回
# project.yml 的 fallback（0.0.0／1），build 仍過。可重跑，內容只取決於當下 git 狀態。
#
# LS-474：同時寫 android/version.properties（gitignored）：
#   VERSION_NAME = 同 MARKETING_VERSION，VERSION_CODE = 同 CURRENT_PROJECT_VERSION
# android/app/build.gradle.kts 讀取；缺檔時 Gradle 端 fallback 0.0.0／1。
#
# 用法：bash scripts/ops/release-version.sh   （上傳 TestFlight 前、CI archive job 內先跑）
# 需要完整 history 與 tags（CI checkout 用 fetch-depth: 0）。

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
out="$root/Config/Version.xcconfig"
android_out="$root/android/version.properties"

if tag="$(git -C "$root" describe --tags --match 'v*' --abbrev=0 2>/dev/null)"; then
  version="${tag#v}"
else
  version="0.0.0"
fi
build="$(git -C "$root" rev-list --count HEAD)"

printf 'MARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' "$version" "$build" > "$out"
mkdir -p "$root/android"
printf 'VERSION_NAME=%s\nVERSION_CODE=%s\n' "$version" "$build" > "$android_out"

echo "MARKETING_VERSION=$version"
echo "CURRENT_PROJECT_VERSION=$build"
