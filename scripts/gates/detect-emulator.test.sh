#!/bin/bash
# detect-emulator.sh 的自測（LS-477）。CI rules job 跑。
# 本機沒有真 SDK／emulator／KVM：adb／emulator／avdmanager／java 全用假身，狀態放 $FAKE_STATE 檔（avds、devices）。
# 這驗的是「選擇／建立／重用／port 分配／序列化／輸出格式／關機」的邏輯；真 emulator 的起機時間、system image 檔名、
# `avdmanager create` 的真實參數相容性只能在裝好 SDK 後驗（PLAUSIBLE，handoff 標註）。
# mutation：拿掉 alloc 鎖（直接跑 start_emulator）→ 兩個 worktree 併發起機會挑到同一個 port。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export FAKE_STATE="$work/state"; mkdir -p "$FAKE_STATE" "$work/locks" "$work/tmp"

# ---- 假 SDK ----
sdk="$work/sdk"
mkdir -p "$sdk/platform-tools" "$sdk/emulator" "$sdk/cmdline-tools/latest/bin" "$sdk/platforms/android-36" \
         "$sdk/system-images/android-36/google_apis/arm64-v8a"
cat > "$sdk/platform-tools/adb" <<'FAKE'
#!/bin/bash
st="${FAKE_STATE:?}"
S=
if [ "${1:-}" = -s ]; then S=$2; shift 2; fi
case "${1:-}" in
  devices)
    echo "List of devices attached"
    while IFS=$'\t' read -r s state name || [ -n "$s" ]; do [ -n "$s" ] && printf '%s\t%s\n' "$s" "$state"; done < "$st/devices"
    echo ;;
  emu)
    case "${2:-}" in
      avd) awk -F'\t' -v s="$S" '$1==s{print $3}' "$st/devices"; echo OK ;;
      kill) printf 'emu kill S=%s\n' "$S" >> "$st/adb.log"
            [ -n "$S" ] && { grep -v "^${S}	" "$st/devices" > "$st/devices.tmp"; mv "$st/devices.tmp" "$st/devices"; }
            echo OK ;;
    esac ;;
  shell)
    case "${3:-}" in
      sys.boot_completed)
        n=$(cat "$st/boot.count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$st/boot.count"
        if [ "$n" -ge "${FAKE_BOOT_AFTER:-1}" ]; then printf '1\r\n'; else printf '\r\n'; fi ;;
      ro.build.version.sdk) printf '%s\r\n' "${FAKE_API:-36}" ;;
    esac ;;
esac
FAKE
cat > "$sdk/emulator/emulator" <<'FAKE'
#!/bin/bash
st="${FAKE_STATE:?}"
printf '%s\n' "$*" >> "$st/emulator.log"
name=; port=
while [ $# -gt 0 ]; do case "$1" in -avd) name=$2; shift 2 ;; -port) port=$2; shift 2 ;; *) shift ;; esac; done
[ "${FAKE_EMU_NOREGISTER:-0}" = 1 ] && exit 0
sleep "${FAKE_EMU_REGISTER_DELAY:-0}"
printf 'emulator-%s\tdevice\t%s\n' "$port" "$name" >> "$st/devices"
FAKE
cat > "$sdk/cmdline-tools/latest/bin/avdmanager" <<'FAKE'
#!/bin/bash
st="${FAKE_STATE:?}"
case "$1 $2" in
  "list avd") cat "$st/avds" ;;
  "create avd")
    printf '%s\n' "$*" >> "$st/avdmanager.log"
    [ "${FAKE_AVD_CREATE_RC:-0}" -ne 0 ] && { echo "Error: create failed" >&2; exit "$FAKE_AVD_CREATE_RC"; }
    n=; shift 2; while [ $# -gt 0 ]; do case "$1" in -n) n=$2; shift 2 ;; *) shift ;; esac; done
    echo "$n" >> "$st/avds" ;;
esac
FAKE
chmod +x "$sdk/platform-tools/adb" "$sdk/emulator/emulator" "$sdk/cmdline-tools/latest/bin/avdmanager"
mkdir -p "$work/jdk/bin"
printf '#!/bin/bash\necho "openjdk version \\"17.0.10\\" 2025-01-21" >&2\n' > "$work/jdk/bin/java"; chmod +x "$work/jdk/bin/java"

reset_state() { : > "$FAKE_STATE/avds"; : > "$FAKE_STATE/devices"; : > "$FAKE_STATE/adb.log"; : > "$FAKE_STATE/emulator.log"; : > "$FAKE_STATE/avdmanager.log"; rm -f "$FAKE_STATE/boot.count"; rm -rf "$work/locks"/*; }

mkrepo() {  # $1=目錄名（決定票號）→ echo 路徑；腳本複製進去，detect-emulator.sh 以自己所在 repo 為準
  local r="$work/$1"
  mkdir -p "$r/scripts/gates/lib" "$r/scripts/ops"
  cp "${root}/scripts/gates/detect-emulator.sh" "${root}/scripts/gates/android-env-check.sh" "$r/scripts/gates/"
  cp "${root}/scripts/gates/lib/android-tools.sh" "$r/scripts/gates/lib/"
  cp "${root}/scripts/ops/emulator-lock.sh" "$r/scripts/ops/"
  printf '17\n' > "$r/.jdk-version"; printf '36\n' > "$r/.android-api"; printf '8.14.5\n' > "$r/.gradle-version"
  echo "$r"
}
run() {  # run <repo> [env…] -- [args…]：結果在 $out（合併 stdout+stderr）、$sout（只 stdout）、$rc
  local r=$1; shift
  local envs=(); while [ "${1:-}" != -- ]; do envs+=("$1"); shift; done; shift
  local errf="$work/err.txt"
  sout=$(env JAVA_HOME="$work/jdk" ANDROID_HOME="$sdk" EMULATOR_LOCK_ROOT="$work/locks" EMULATOR_LOCK_POLL=0.2 \
      DETECT_EMULATOR_POLL=0.2 DETECT_EMULATOR_ABI=arm64-v8a TMPDIR="$work/tmp" "${envs[@]}" \
      bash "$r/scripts/gates/detect-emulator.sh" "$@" 2>"$errf"); rc=$?
  out="${sout}"$'\n'"$(cat "$errf")"
}

R1=$(mkrepo LS-123)

# ① 冷啟動：沒有 AVD、沒有機 → 建 AVD（pixel_8＋.android-api 的 system image）、起機（port 5554、無視窗）、印約定格式
reset_state
run "$R1" --
expect_exit 0 "$rc" "① 冷啟動 exit 0"
expect_has "$sout" "emulator: LS-123-Pixel8 emulator-5554 API 36（pinned 36）" "① stdout 約定格式"
expect_has "$(cat "$FAKE_STATE/avdmanager.log")" "create avd -n LS-123-Pixel8 -k system-images;android-36;google_apis;arm64-v8a -d pixel_8" "① 建 AVD 參數（名稱／system image 讀 .android-api／pixel_8）"
expect_has "$(cat "$FAKE_STATE/emulator.log")" "-avd LS-123-Pixel8 -port 5554 -no-window" "① 起機參數（port 5554、無視窗）"
if [ ! -d "$work/locks/emulator-lock-alloc" ]; then ok "① alloc 鎖已釋放"; else fail "① alloc 鎖殘留"; fi
expect_has "$out" "用完請關" "① 提示用完要關"

# ② 已在跑 → 重用：不再建 AVD、不再起機
run "$R1" --
expect_exit 0 "$rc" "② 重跑 exit 0"
expect_has "$out" "已在跑，重用" "② 印重用"
if [ "$(wc -l < "$FAKE_STATE/emulator.log" | tr -d ' ')" = 1 ] && [ "$(wc -l < "$FAKE_STATE/avdmanager.log" | tr -d ' ')" = 1 ]; then ok "② 沒有第二次起機／建 AVD"; else fail "② 不該重複起機或建 AVD"; fi

# ③ AVD 已存在但沒在跑，且 5554 被別票的 emulator 占用 → 不建 AVD、挑下一個 port 5556
reset_state
echo "LS-123-Pixel8" > "$FAKE_STATE/avds"
printf 'emulator-5554\tdevice\tLS-999-Pixel8\n' > "$FAKE_STATE/devices"
run "$R1" --
expect_has "$sout" "emulator: LS-123-Pixel8 emulator-5556 API 36" "③ 5554 被占用 → 5556"
if [ ! -s "$FAKE_STATE/avdmanager.log" ]; then ok "③ AVD 已存在不重建"; else fail "③ 不該重建已存在的 AVD"; fi
expect_has "$out" "AVD LS-123-Pixel8 已存在" "③ 印 AVD 已存在"

# ④ --serial-only：stdout 只有 serial
run "$R1" -- --serial-only
if [ "$sout" = "emulator-5556" ]; then ok "④ --serial-only stdout 只有 serial"; else fail "④ --serial-only stdout 應只有 serial，實得：${sout}"; fi

# ⑤ API 與釘住版不同 → 仍成功，但 stderr 印 ⚠ 且輸出行帶實際 API
reset_state
run "$R1" FAKE_API=35 --
expect_has "$sout" "API 35（pinned 36）" "⑤ 輸出行帶實際 API 與釘住版"
expect_has "$out" "⚠ detect-emulator：LS-123-Pixel8 是 API 35，與釘住版 API 36 不同" "⑤ 版本差 ⚠"

# ⑥ system image 沒裝 → exit 1，印 sdkmanager 指令，不建 AVD
reset_state
mv "$sdk/system-images/android-36" "$work/si-bak"
run "$R1" --
mv "$work/si-bak" "$sdk/system-images/android-36"
expect_exit 1 "$rc" "⑥ 缺 system image → exit 1"
expect_has "$out" 'sdkmanager "system-images;android-36;google_apis;arm64-v8a"' "⑥ 印要跑的 sdkmanager 指令"
if [ ! -s "$FAKE_STATE/avdmanager.log" ]; then ok "⑥ 沒有嘗試建 AVD"; else fail "⑥ 缺 image 不該建 AVD"; fi

# ⑦ 本機環境不齊（沒有 ANDROID_HOME）→ exit 3 ⚠
reset_state
sout=$(env -u ANDROID_HOME -u ANDROID_SDK_ROOT JAVA_HOME="$work/jdk" HOME="$work" PATH="/usr/bin:/bin" EMULATOR_LOCK_ROOT="$work/locks" bash "$R1/scripts/gates/detect-emulator.sh" 2>&1); rc=$?
expect_exit 3 "$rc" "⑦ 環境不齊 → exit 3"
expect_has "$sout" "本機 Android 環境不齊，無法起 emulator" "⑦ 印 ⚠"

# ⑧ --stop：只關本票的（-s <serial>），別票的不動；再 stop 一次印沒在跑
reset_state
printf 'emulator-5554\tdevice\tLS-999-Pixel8\n' > "$FAKE_STATE/devices"
run "$R1" -- >/dev/null
run "$R1" -- --stop
expect_exit 0 "$rc" "⑧ --stop exit 0"
expect_has "$(cat "$FAKE_STATE/adb.log")" "emu kill S=emulator-5556" "⑧ 用 adb -s emulator-5556 emu kill（帶 -s）"
if ! grep -q 'S=$' "$FAKE_STATE/adb.log" && grep -q 'LS-999-Pixel8' "$FAKE_STATE/devices"; then ok "⑧ 沒有無 -s 的 kill、別票 emulator 還在"; else fail "⑧ 不該動別票 emulator"; fi
run "$R1" -- --stop
expect_has "$out" "沒在跑，不需要關" "⑧ 第二次 --stop 印沒在跑"

# ⑨ 起機後一直沒出現在 adb devices → exit 1
reset_state
run "$R1" FAKE_EMU_NOREGISTER=1 DETECT_EMULATOR_REGISTER_TIMEOUT=1 --
expect_exit 1 "$rc" "⑨ 註冊逾時 → exit 1"
expect_has "$out" "沒出現在 adb devices" "⑨ 訊息"

# ⑩ boot_completed 一直不是 1 → exit 1
reset_state
run "$R1" FAKE_BOOT_AFTER=99999 DETECT_EMULATOR_BOOT_TIMEOUT=1 --
expect_exit 1 "$rc" "⑩ 開機逾時 → exit 1"
expect_has "$out" "sys.boot_completed 仍不是 1" "⑩ 訊息"

# ⑪ avdmanager create 失敗 → exit 1 並帶原因
reset_state
run "$R1" FAKE_AVD_CREATE_RC=1 --
expect_exit 1 "$rc" "⑪ 建 AVD 失敗 → exit 1"
expect_has "$out" "avdmanager create avd LS-123-Pixel8 失敗" "⑪ 訊息"

# ⑫ 主 checkout（目錄名無票號、非 git）→ main-Pixel8
reset_state
RM=$(mkrepo repo-main)
run "$RM" --
expect_has "$sout" "emulator: main-Pixel8 emulator-5554" "⑫ 無票號 → main-Pixel8"

# ⑬ 參數錯 → exit 2；缺 .android-api → exit 1
run "$R1" -- --bogus
expect_exit 2 "$rc" "⑬a 未知參數 → exit 2"
RN=$(mkrepo LS-130); rm "$RN/.android-api"
run "$RN" --
expect_exit 1 "$rc" "⑬b 缺 .android-api → exit 1"

# ⑭ 併發：兩個 worktree 同時起機，alloc 鎖讓它們挑到不同 port（fake emulator 延遲註冊 1 秒，沒有鎖時兩邊都會看到 5554 空著）
race() {  # race <腳本根目錄> → 設 p1 p2（兩邊挑到的 serial）
  reset_state
  local ra rb
  ra=$(mkrepo LS-201); rb=$(mkrepo LS-202)
  ( env JAVA_HOME="$work/jdk" ANDROID_HOME="$sdk" EMULATOR_LOCK_ROOT="$work/locks" EMULATOR_LOCK_POLL=0.2 DETECT_EMULATOR_POLL=0.2 \
      DETECT_EMULATOR_ABI=arm64-v8a TMPDIR="$work/tmp" FAKE_EMU_REGISTER_DELAY=1 bash "$ra/scripts/gates/detect-emulator.sh" --serial-only > "$work/race-a.txt" 2>/dev/null ) &
  local pa=$!
  ( env JAVA_HOME="$work/jdk" ANDROID_HOME="$sdk" EMULATOR_LOCK_ROOT="$work/locks" EMULATOR_LOCK_POLL=0.2 DETECT_EMULATOR_POLL=0.2 \
      DETECT_EMULATOR_ABI=arm64-v8a TMPDIR="$work/tmp" FAKE_EMU_REGISTER_DELAY=1 bash "$rb/scripts/gates/detect-emulator.sh" --serial-only > "$work/race-b.txt" 2>/dev/null ) &
  local pb=$!
  wait "$pa" "$pb"
  p1=$(cat "$work/race-a.txt"); p2=$(cat "$work/race-b.txt")
}
race
if [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ]; then ok "⑭ 併發起機挑到不同 port（${p1}／${p2}）"; else fail "⑭ 併發起機應挑不同 port，實得 ${p1:-空}／${p2:-空}"; fi

# ⑮ mutation：拿掉 alloc 鎖（直接跑 start_emulator）→ ⑭ 的併發會挑到同一個 port
mutroot="$work/mut"; mkdir -p "$mutroot"
python3 - "${root}/scripts/gates/detect-emulator.sh" "$mutroot/detect-emulator.sh" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
old = 'bash "$here/../ops/emulator-lock.sh" --serial alloc -- bash -c start_emulator'
assert old in s, "anchor missing"
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(old, "bash -c start_emulator", 1))
PY
cp "$mutroot/detect-emulator.sh" "$work/LS-201/scripts/gates/detect-emulator.sh"; cp "$mutroot/detect-emulator.sh" "$work/LS-202/scripts/gates/detect-emulator.sh"
# race 會重新 mkrepo（覆寫成原版）——mutation 版需在 mkrepo 之後套上：改用旗標讓 race 之後替換
reset_state
( env JAVA_HOME="$work/jdk" ANDROID_HOME="$sdk" EMULATOR_LOCK_ROOT="$work/locks" EMULATOR_LOCK_POLL=0.2 DETECT_EMULATOR_POLL=0.2 DETECT_EMULATOR_ABI=arm64-v8a TMPDIR="$work/tmp" FAKE_EMU_REGISTER_DELAY=1 bash "$work/LS-201/scripts/gates/detect-emulator.sh" --serial-only > "$work/race-a.txt" 2>/dev/null ) &
pa=$!
( env JAVA_HOME="$work/jdk" ANDROID_HOME="$sdk" EMULATOR_LOCK_ROOT="$work/locks" EMULATOR_LOCK_POLL=0.2 DETECT_EMULATOR_POLL=0.2 DETECT_EMULATOR_ABI=arm64-v8a TMPDIR="$work/tmp" FAKE_EMU_REGISTER_DELAY=1 bash "$work/LS-202/scripts/gates/detect-emulator.sh" --serial-only > "$work/race-b.txt" 2>/dev/null ) &
pb=$!
wait "$pa" "$pb"
m1=$(cat "$work/race-a.txt"); m2=$(cat "$work/race-b.txt")
if [ "$m1" = "$m2" ] && [ -n "$m1" ]; then ok "⑮ mutant：拿掉 alloc 鎖後兩邊挑到同一個 port（${m1}）——⑭ 的不同 port 確由鎖造成"; else fail "⑮ mutant 應讓併發撞同一個 port，實得 ${m1:-空}／${m2:-空}"; fi

if [ "$fail" -eq 0 ] && [ "${selftest_helpers_fail:-0}" -eq 0 ]; then echo "✓ detect-emulator 自測通過"; exit 0; fi
exit 1
