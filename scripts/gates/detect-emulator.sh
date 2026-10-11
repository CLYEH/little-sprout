#!/bin/bash
# detect-emulator.sh — 依票號找／建／開本票專屬 Android emulator，印出可供後續 adb 操作的 serial（LS-477，Android 前置 A3）。
# iOS 對應物：detect-simulator.sh（`<票號>-iPhone17Pro`）；這裡是 `LS-<n>-Pixel8`（主 checkout／非票號分支用 `main-Pixel8`）。
#
# 與 detect-simulator.sh 的差異（都是 emulator 的性質，不是疏漏）：
#   - emulator 是長駐行程、占 1–4 GB RAM，所以**用完要關**（`--stop`，或 `adb -s <serial> emu kill`）；patrol.sh 的
#     「Booted emulator」段會把票已結案／worktree 已不在卻還開著的列 ⚠。
#   - 沒有「退回共用第一台」：不同票共用一台 emulator 等於互踩，找不到／建不起來就 fail loud。
#   - system image 不自動下載（約 1 GB）：缺就 exit 1 並印要跑的 `sdkmanager "<package>"`。
#
# 流程：
#   1. 本機工具鏈：android-env-check.sh --require-emulator（JDK 對 .jdk-version、SDK 有 platform-tools＋釘住 API 的 platform、
#      emulator）＋ avdmanager。不齊 → exit 3 並印 ⚠（本機還沒裝是常態，呼叫端自行決定怎麼跳過）。
#   2. AVD `LS-<n>-Pixel8` 不存在就 `avdmanager create avd -n <name> -k system-images;android-<.android-api>;google_apis;<abi> -d pixel_8`
#      （abi：arm64 主機 arm64-v8a、其餘 x86_64；DETECT_EMULATOR_ABI 覆寫）。已存在就直接用（不論 API，API 不符只在最後印 ⚠）。
#   3. 已在跑（`adb devices` 的 emulator-* 且 `adb -s … emu avd name` 等於本 AVD）就重用；否則在 emulator-lock.sh 的 `alloc`
#      鎖內挑未用的偶數 port（5554…5584）起機（無視窗、不存快照），等它出現在 `adb devices` 才放鎖——序列化「挑 port＋起機」，
#      兩個 worktree 不會挑到同一個 port。
#   4. 等 `sys.boot_completed`=1（DETECT_EMULATOR_BOOT_TIMEOUT 秒，預設 240），讀 `ro.build.version.sdk`，印：
#        emulator: <name> <serial> API <ver>（pinned <ver>）            （stdout；ver≠pinned 另在 stderr 印 ⚠）
#
# 用法：detect-emulator.sh [--stop]
#   --stop         關掉本票專屬 emulator（`adb -s <serial> emu kill`——永遠帶 -s，不用無 -s 的 emu kill）；沒在跑就印一行、exit 0
# 環境變數：DETECT_EMULATOR_BOOT_TIMEOUT（預設 240）、DETECT_EMULATOR_REGISTER_TIMEOUT（等出現在 adb devices，預設 90）、
#   DETECT_EMULATOR_ABI、DETECT_EMULATOR_WINDOW=1（顯示視窗）、DETECT_EMULATOR_POLL（輪詢秒，預設 2；自測用）。
# exit：0＝成功；1＝失敗（缺釘住檔／system image／建 AVD 失敗／起機逾時）；2＝參數錯；3＝本機 Android 環境不齊。
# 自測：scripts/gates/detect-emulator.test.sh（假 adb／emulator／avdmanager；真機行為只能在裝好 SDK 後驗）。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-tools.sh
source "$here/lib/android-tools.sh"

stop_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stop) stop_mode=1; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ detect-emulator：未知參數「$1」。用法：detect-emulator.sh [--stop]" >&2; exit 2 ;;
  esac
done

toplevel=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || toplevel=$(cd "$here/../.." && pwd)
branch=$(git -C "$toplevel" symbolic-ref --short -q HEAD 2>/dev/null || true)
extract_ticket() { printf '%s' "$1" | grep -oE 'LS-[0-9]+' | head -1; }
ticket=$(extract_ticket "$(basename "$toplevel")")
[ -n "$ticket" ] || ticket=$(extract_ticket "${branch:-}")
[ -n "$ticket" ] || ticket=main
avd="${ticket}-Pixel8"

[ -f "$toplevel/.android-api" ] || { echo "✗ detect-emulator：缺 .android-api（單一來源釘住檔，LS-474）" >&2; exit 1; }
pin=$(tr -d '[:space:]' < "$toplevel/.android-api")

env_out=$(bash "$here/android-env-check.sh" --require-emulator --repo "$toplevel" 2>&1); env_rc=$?
if [ "$env_rc" -ne 0 ]; then
  [ "$env_rc" -eq 3 ] && { printf '%s\n' "$env_out" >&2; echo "⚠ detect-emulator：本機 Android 環境不齊，無法起 emulator（exit 3）" >&2; exit 3; }
  printf '%s\n' "$env_out" >&2; exit 1
fi
adb=$(android_tool adb "$toplevel"); emulator=$(android_tool emulator "$toplevel"); avdmanager=$(android_tool avdmanager "$toplevel")
if [ -z "$adb" ] || [ -z "$emulator" ] || [ -z "$avdmanager" ]; then
  echo "⚠ detect-emulator：找不到 $([ -z "$adb" ] && echo adb)$([ -z "$emulator" ] && echo ' emulator')$([ -z "$avdmanager" ] && echo ' avdmanager（SDK Manager 裝 Command-line Tools）')，無法起 emulator（exit 3）" >&2
  exit 3
fi
sdk=$(android_sdk_root "$toplevel")

poll=${DETECT_EMULATOR_POLL:-2}
boot_timeout=${DETECT_EMULATOR_BOOT_TIMEOUT:-240}
register_timeout=${DETECT_EMULATOR_REGISTER_TIMEOUT:-90}
for v in "$boot_timeout" "$register_timeout"; do case "$v" in ''|*[!0-9]*) echo "✗ detect-emulator：timeout 環境變數須為整數秒（得到「${v}」）" >&2; exit 2 ;; esac; done

say() { echo "→ detect-emulator：$*" >&2; }

# 目前在跑且 AVD 名等於本票 AVD 的 serial（沒有印空字串）
running_serial() {
  local s name
  for s in $("$adb" devices 2>/dev/null | awk 'NR>1 && $1 ~ /^emulator-[0-9]+$/ && ($2=="device"||$2=="offline"){print $1}'); do
    name=$("$adb" -s "$s" emu avd name 2>/dev/null | tr -d '\r' | head -1)
    if [ "$name" = "$avd" ]; then printf '%s' "$s"; return 0; fi
  done
  printf ''
}

if [ "$stop_mode" -eq 1 ]; then
  s=$(running_serial)
  if [ -z "$s" ]; then echo "→ detect-emulator：${avd} 沒在跑，不需要關"; exit 0; fi
  "$adb" -s "$s" emu kill >/dev/null 2>&1 || { echo "✗ detect-emulator：adb -s ${s} emu kill 失敗" >&2; exit 1; }
  echo "→ detect-emulator：已關 ${avd}（${s}）"
  exit 0
fi

# ---- 2. AVD ----
avd_list=$("$avdmanager" list avd -c 2>/dev/null | tr -d '\r')
if ! grep -qxF "$avd" <<<"$avd_list"; then
  abi=${DETECT_EMULATOR_ABI:-}
  if [ -z "$abi" ]; then case "$(uname -m)" in arm64|aarch64) abi=arm64-v8a ;; *) abi=x86_64 ;; esac; fi
  pkg="system-images;android-${pin};google_apis;${abi}"
  if [ ! -d "${sdk}/system-images/android-${pin}/google_apis/${abi}" ]; then
    echo "✗ detect-emulator：缺 system image ${pkg}（約 1 GB，不自動下載）。請先執行：sdkmanager \"${pkg}\"" >&2
    exit 1
  fi
  say "建 AVD ${avd}（${pkg}，pixel_8）"
  if ! created=$(echo no | "$avdmanager" create avd -n "$avd" -k "$pkg" -d pixel_8 2>&1); then
    echo "✗ detect-emulator：avdmanager create avd ${avd} 失敗：${created}" >&2
    exit 1
  fi
else
  say "AVD ${avd} 已存在，直接用"
fi

# ---- 3. 找已在跑的 / 起機 ----
serial=$(running_serial)
if [ -n "$serial" ]; then
  say "選到 ${avd}（${serial}，已在跑，重用）"
else
  start_emulator() {   # 在 alloc 鎖內執行：挑 port、起機、等它出現在 adb devices
    local used port="" p logf win_args
    used=$("$adb" devices 2>/dev/null | awk 'NR>1 && $1 ~ /^emulator-[0-9]+$/{sub(/^emulator-/,"",$1); print $1}')
    for p in $(seq 5554 2 5584); do
      grep -qx "$p" <<<"$used" && continue
      port=$p; break
    done
    [ -n "$port" ] || { echo "✗ detect-emulator：5554–5584 的 port 都被占用（先關掉不用的 emulator）" >&2; return 1; }
    logf="${TMPDIR:-/tmp}/detect-emulator-${avd}.log"
    win_args="-no-window"; [ "${DETECT_EMULATOR_WINDOW:-0}" = 1 ] && win_args=""
    say "起機 ${avd}（port ${port}，log ${logf}）"
    # shellcheck disable=SC2086
    nohup "$emulator" -avd "$avd" -port "$port" $win_args -no-audio -no-snapshot-save -no-boot-anim >"$logf" 2>&1 </dev/null &
    disown 2>/dev/null || true
    local t0 now
    t0=$(date +%s)
    while ! grep -qx "emulator-${port}" <<<"$("$adb" devices 2>/dev/null | awk 'NR>1{print $1}')"; do
      now=$(date +%s)
      if [ $((now - t0)) -ge "$register_timeout" ]; then
        echo "✗ detect-emulator：emulator-${port} ${register_timeout} 秒內沒出現在 adb devices。log 尾：" >&2
        tail -n 15 "$logf" 2>/dev/null | sed 's/^/    /' >&2
        return 1
      fi
      sleep "$poll"
    done
    printf 'emulator-%s' "$port" > "$alloc_out"
  }
  alloc_out=$(mktemp)
  trap 'rm -f "$alloc_out"' EXIT
  # start_emulator 在子 bash 裡跑（emulator-lock.sh 包住的是外部命令）：函式與變數 export 過去
  export adb emulator avd poll register_timeout alloc_out
  export -f say start_emulator
  if ! bash "$here/../ops/emulator-lock.sh" --serial alloc -- bash -c start_emulator; then
    exit 1
  fi
  serial=$(cat "$alloc_out")
  [ -n "$serial" ] || { echo "✗ detect-emulator：起機後讀不到 serial" >&2; exit 1; }
fi

# ---- 4. 等開機完成 ----
t0=$(date +%s)
while [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r[:space:]')" != 1 ]; do
  now=$(date +%s)
  if [ $((now - t0)) -ge "$boot_timeout" ]; then
    echo "✗ detect-emulator：${avd}（${serial}）${boot_timeout} 秒內 sys.boot_completed 仍不是 1（log：${TMPDIR:-/tmp}/detect-emulator-${avd}.log）" >&2
    exit 1
  fi
  sleep "$poll"
done
ver=$("$adb" -s "$serial" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r[:space:]')
if [ "$ver" != "$pin" ]; then
  echo "⚠ detect-emulator：${avd} 是 API ${ver:-?}，與釘住版 API ${pin} 不同（CI/Gradle compileSdk 為 ${pin}）；不自動重建，如需對齊請 avdmanager delete avd -n ${avd} 後重跑" >&2
fi
printf 'emulator: %s %s API %s（pinned %s）\n' "$avd" "$serial" "${ver:-?}" "$pin"
echo "→ detect-emulator：用完請關：bash scripts/gates/detect-emulator.sh --stop（= adb -s ${serial} emu kill）" >&2
