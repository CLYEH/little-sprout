#!/bin/bash
# scripts/gates/lib/android-tools.sh — Android 工具定位共用庫（LS-477）
#
# 給 android-env-check.sh／detect-emulator.sh／emulator-lock.sh／cleanup-merged.sh／patrol.sh source，
# 不各自重寫「SDK 在哪、adb／emulator／avdmanager 在哪」。只定位、不執行、不改環境。
#
#   android_sdk_root [repo_root]   印 SDK 根目錄（存在的目錄才印），找不到印空字串。優先序：
#                                   $ANDROID_HOME → $ANDROID_SDK_ROOT → <repo>/android/local.properties 的 sdk.dir
#                                   （README 要使用者填的那個；Gradle 自己也讀它，所以 env-check 必須認同一份）
#   android_tool <name> [repo_root] name＝adb｜emulator｜avdmanager｜sdkmanager；印可執行檔路徑，找不到印空字串。
#                                   先看 SDK 內的固定位置（SDK 版本與 PATH 上的可能不同，以 Gradle 實際用的為準），
#                                   再退 PATH（`command -v`）。avdmanager／sdkmanager 在 cmdline-tools/latest/bin
#                                   或 cmdline-tools/<ver>/bin。
#
# 自測：scripts/gates/android-env-check.test.sh（假 SDK 目錄結構）。
# shellcheck shell=bash

android_sdk_root() {
  local repo=${1:-} c lp
  for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    if [ -n "$c" ] && [ -d "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  if [ -n "$repo" ] && [ -f "$repo/android/local.properties" ]; then
    lp=$(sed -n 's/^sdk\.dir[[:space:]]*=[[:space:]]*//p' "$repo/android/local.properties" | head -1)
    # local.properties 是 Java properties：反斜線轉義（Windows 路徑）這裡不處理，macOS 路徑沒有
    if [ -n "$lp" ] && [ -d "$lp" ]; then printf '%s' "$lp"; return 0; fi
  fi
  printf ''
}

android_tool() {
  local name=$1 repo=${2:-} root p
  root=$(android_sdk_root "$repo")
  if [ -n "$root" ]; then
    case "$name" in
      adb) p="$root/platform-tools/adb"; [ -x "$p" ] && { printf '%s' "$p"; return 0; } ;;
      emulator) p="$root/emulator/emulator"; [ -x "$p" ] && { printf '%s' "$p"; return 0; } ;;
      avdmanager|sdkmanager)
        for p in "$root/cmdline-tools/latest/bin/$name" "$root"/cmdline-tools/*/bin/"$name"; do
          [ -x "$p" ] && { printf '%s' "$p"; return 0; }
        done ;;
    esac
  fi
  p=$(command -v "$name" 2>/dev/null) || p=
  printf '%s' "$p"
}
