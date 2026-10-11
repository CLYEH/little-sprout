#!/bin/bash
# QA 端到端情境驅動（Android 版，LS-478；iOS 對應物：qa-e2e.sh）：不依賴 mobile-mcp，用 androidTest 的
# `com.clyeh.sproutday.qa.QaSmokeTest`（內含 QaDriver：App 內畫面用 Compose 語意節點、系統層用 UiAutomator）對本機 Supabase 容器實跑情境，
# 截圖與 logcat 落地成驗收證據。
#
# 用法：qa-e2e-android.sh <login|publish|browse> [--ticket LS-<n>]
#   login    app 冷啟動 → 首頁文字可見（目前 app 只有骨架，歡迎頁／Email／OTP 步驟等登入畫面票補）
#   publish  骨架：等新增回憶畫面票；現在會 fail loud（exit 1，訊息「情境 publish 尚未實作」），不假綠
#   browse   骨架：等時間軸／詳情畫面票；同上
#   --ticket 票號；預設從目前 worktree 目錄名推（`.claude/worktrees/LS-<n>`），推不出就要求明給。只影響證據路徑——
#            emulator 由 detect-emulator.sh 依 worktree 名挑（`LS-<n>-Pixel8`，固定 QA worktree 則是 `main-Pixel8`）。
#   **前置**：App 一啟動就建 Supabase client（LS-479），所以要有 android/local.properties（gitignored，範本 local.properties.example）；login 情境
#            不連後端，佔位值即可（SUPABASE_URL／SUPABASE_ANON_KEY 非空）。缺檔時 instrument 紅、訊息「SUPABASE_URL 為空」。
#            注意：local.properties 存在時 core-supabase 的 JVM contract test 會改打該 URL，跑 unit test 前先移走佔位檔。
#   **只准在票 worktree 內跑**：supabase-lock.sh --hold 的持有者判定看 worktree（LS-170 §6），主 checkout 一律 exit 2。
#
# 做的事（順序即防線）：
#   1. 情境名／票號檢查（錯即 exit 2，不碰任何工具）。
#   2. 本機 Android 環境：android-env-check.sh --require-emulator（JDK／SDK／emulator）與 adb——不齊 → 印 ⚠ 並 **exit 3**
#      （本機沒裝是常態；呼叫端自行決定怎麼跳過，不當成情境紅）。
#   3. `supabase status -o env` 讀 API_URL／ANON_KEY／MAILPIT_URL＋Mailpit／GoTrue health（取不到＝容器沒跑，exit 2）。
#   4. `./gradlew :app:assembleDebug :app:assembleDebugAndroidTest`（鎖之外：建置久，不占著 hold）。
#   5. **鎖順序固定：先 supabase 後 AVD**。`supabase-lock.sh --hold "<票> qa-e2e-android <情境>"`（呼叫者已持有＝exit 3，沿用、
#      不代釋放）→ `detect-emulator.sh`（找／建／開本票專屬 AVD；stderr 沒印「重用」＝本腳本 boot 的）→
#      `emulator-lock.sh --serial <serial> -- <裝置端整段>`（裝 APK、pm clear、`am instrument`、`adb exec-out screencap`、pull）。
#   6. 收工（EXIT trap，含 INT／TERM 轉成帶碼 exit）：釋放自己取得的 supabase hold；自己 boot 的 emulator 用
#      `adb -s <serial> emu kill` 關（永遠帶 -s，從不 kill 別台）。AVD 鎖由 emulator-lock.sh 自己的 trap 釋放。
#      已知小縫隙：emulator 在 AVD 鎖釋放之後才關——同票同 AVD 的第二個程序在這段間隙拿到鎖會撞上正在關的機器。
# 證據：`.claude/evidence/<票號>/qa-e2e/<情境>-<時間>/`——screens/（QaDriver 每步 `<情境>-<序號>-<步驟>.png`＋收工時
#   `adb exec-out screencap` 的 `<情境>-99-final-screencap.png`，失敗也有）、config.txt（帶進裝置的種子，不含 anon key）、
#   gradle.log、instrument.log、logcat.log。
# `am instrument` 不論測試紅綠 exit code 都是 0，所以判定看輸出：要有 `OK (` 行且沒有 `FAILURES!!!`／`INSTRUMENTATION_FAILED`。
# emulator 內連宿主機容器用 10.0.2.2：API／Mailpit URL 的 127.0.0.1／localhost 在交給裝置前改寫。
# exit：0＝情境通過；1＝情境失敗（建置或 instrument 紅，log 尾段印出）；2＝參數／環境／lock／emulator 錯誤（fail closed）；
#   3＝本機 Android 環境不齊（⚠，不是情境紅）。
# 環境變數（測試 seam，同 qa-e2e.sh 的 LS_LOCK_SH 先例；正式呼叫都不設）：LS_LOCK_SH、LS_EMULATOR_LOCK_SH、LS_DETECT_EMULATOR_SH、
#   LS_ENV_CHECK_SH；LS_QA_MAILPIT 覆寫 Mailpit URL。
# 自測：qa-e2e-android.test.sh（PATH shim，不實跑 gradle／adb）。規約：.claude/agents/qa.md、docs/COLLABORATION.md §7 Android 區塊。
set -uo pipefail

usage() { echo "用法：qa-e2e-android.sh <login|publish|browse> [--ticket LS-<n>]"; }

scenario=; ticket=
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket)
      [ -n "${2:-}" ] || { echo "✗ qa-e2e-android：--ticket 缺值" >&2; exit 2; }
      ticket=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "✗ qa-e2e-android：未知參數 $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$scenario" ]; then echo "✗ qa-e2e-android：多餘參數「$1」（情境只能一個）" >&2; usage >&2; exit 2; fi
      scenario=$1; shift ;;
  esac
done
[ -n "$scenario" ] || { echo "✗ qa-e2e-android：缺情境名" >&2; usage >&2; exit 2; }
case "$scenario" in
  login|publish|browse) ;;
  *) echo "✗ qa-e2e-android：情境「${scenario}」不存在，只接受 login|publish|browse" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../gates/lib/android-tools.sh
source "$here/../gates/lib/android-tools.sh"
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ qa-e2e-android：不在 git repo 內（在票 worktree 執行）" >&2; exit 2; }
git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -z "$git_dir" ] || [ "$git_dir" = "$common_dir" ]; then
  echo "✗ qa-e2e-android：這是主 checkout（${root}）——請在票 worktree（.claude/worktrees/LS-<n>）內跑：hold 的持有者判定看 worktree，主 checkout 的 hold 會讓所有主 checkout 程序直通（LS-170 §6）" >&2
  exit 2
fi
if [ -z "$ticket" ]; then
  ticket=$(basename "$root" | grep -oE 'LS-[0-9]+' | head -1)
  [ -n "$ticket" ] || { echo "✗ qa-e2e-android：從 worktree 目錄名「$(basename "$root")」推不出票號——請在 .claude/worktrees/LS-<n> 內跑；固定 QA worktree（qa-test）才用 --ticket LS-<n>" >&2; exit 2; }
fi
case "$ticket" in
  LS-[0-9]*) ;;
  *) echo "✗ qa-e2e-android：--ticket 須為 LS-<n>（得到「${ticket}」）" >&2; exit 2 ;;
esac

# ---- 2. 本機 Android 環境（不齊＝exit 3）----
env_check=${LS_ENV_CHECK_SH:-$here/../gates/android-env-check.sh}
env_out=$(bash "$env_check" --require-emulator --repo "$root" 2>&1); env_rc=$?
if [ "$env_rc" -eq 3 ]; then
  printf '%s\n' "$env_out" >&2
  echo "⚠ qa-e2e-android：本機 Android 環境不齊，無法跑情境（exit 3）——不是情境紅；以 CI android-connected 為準，handoff 標 PLAUSIBLE" >&2
  exit 3
elif [ "$env_rc" -ne 0 ]; then
  printf '%s\n' "$env_out" >&2
  exit 2
fi
adb=$(android_tool adb "$root")
if [ -z "$adb" ]; then
  echo "⚠ qa-e2e-android：找不到 adb（SDK platform-tools 或 PATH），無法跑情境（exit 3）" >&2
  exit 3
fi

# ---- 3. 本機容器 ----
status=; attempt=0
while [ "$attempt" -lt 3 ]; do
  status=$(supabase status -o env 2>/dev/null) && printf '%s' "$status" | grep -q '^API_URL=' && break
  attempt=$((attempt + 1)); sleep 2
done
env_value() { printf '%s\n' "$status" | sed -n "s/^$1=//p" | head -1 | tr -d '"'; }
api_url=$(env_value API_URL)
anon_key=$(env_value ANON_KEY)
mailpit=${LS_QA_MAILPIT:-$(env_value MAILPIT_URL)}
[ -n "$mailpit" ] || mailpit=http://127.0.0.1:54324
if [ -z "$api_url" ] || [ -z "$anon_key" ]; then
  echo "✗ qa-e2e-android：supabase status 取不到 API_URL／ANON_KEY（本機容器有跑嗎？在 repo 根 supabase start）" >&2
  exit 2
fi
http_code() { local code; code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null); printf '%s' "${code:-000}"; }
code=$(http_code "${mailpit}/api/v1/info")
[ "$code" = 200 ] || { echo "✗ qa-e2e-android：Mailpit ${mailpit} 不可達（HTTP ${code}）——OTP 取碼靠它（supabase start 會一起起）" >&2; exit 2; }
code=$(http_code -H "apikey: ${anon_key}" "${api_url}/auth/v1/health")
[ "$code" = 200 ] || { echo "✗ qa-e2e-android：GoTrue ${api_url}/auth/v1/health 回 HTTP ${code}——容器不健康" >&2; exit 2; }

# ---- 證據目錄 ----
stamp=$(date +%Y%m%d-%H%M%S)
out="${root}/.claude/evidence/${ticket}/qa-e2e/${scenario}-${stamp}"
mkdir -p "$out/screens" || { echo "✗ qa-e2e-android：建不出證據目錄 ${out}" >&2; exit 2; }

# ---- 4. 建置（鎖之外）----
app_apk="${root}/android/app/build/outputs/apk/debug/app-debug.apk"
test_apk="${root}/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
echo "→ qa-e2e-android：建置 debug＋androidTest APK（log：${out}/gradle.log）"
if ! ( cd "$root/android" && ./gradlew --no-daemon :app:assembleDebug :app:assembleDebugAndroidTest ) > "$out/gradle.log" 2>&1; then
  echo "✗ qa-e2e-android：gradle 建置失敗——log 尾段（完整：${out}/gradle.log）：" >&2
  tail -n 20 "$out/gradle.log" | sed 's/^/    /' >&2
  exit 1
fi
[ -f "$app_apk" ] && [ -f "$test_apk" ] || { echo "✗ qa-e2e-android：建置成功但找不到 APK（${app_apk}／${test_apk}）" >&2; exit 2; }

# ---- 5. 鎖（先 supabase 後 AVD）----
lock_sh=${LS_LOCK_SH:-$here/supabase-lock.sh}
emu_lock_sh=${LS_EMULATOR_LOCK_SH:-$here/emulator-lock.sh}
detect_sh=${LS_DETECT_EMULATOR_SH:-$here/../gates/detect-emulator.sh}
held_by_me=0; booted_by_me=0; serial=
cleanup() {
  [ "$held_by_me" -eq 1 ] && bash "$lock_sh" --release
  if [ "$booted_by_me" -eq 1 ] && [ -n "$serial" ]; then
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 && echo "→ qa-e2e-android：emulator ${serial} 已關（本腳本 boot 的）"
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT   # 同 qa-e2e.sh／supabase-lock.sh：訊號轉成帶碼的 exit，EXIT trap 一定跑到
trap 'exit 143' TERM

hold_out=$(bash "$lock_sh" --hold "${ticket} qa-e2e-android ${scenario}" --max-minutes 25 2>&1); hold_rc=$?
case "$hold_rc" in
  0) held_by_me=1; echo "→ qa-e2e-android：${hold_out}" ;;
  3) echo "→ qa-e2e-android：沿用呼叫者既有的 hold，收工不代釋放（${hold_out}）" ;;
  *) echo "✗ qa-e2e-android：取不到 Supabase lock（supabase-lock.sh exit ${hold_rc}）：${hold_out}" >&2; exit 2 ;;
esac

detect_err="$out/detect-emulator.log"
detect_out=$(bash "$detect_sh" 2>"$detect_err"); detect_rc=$?
if [ "$detect_rc" -ne 0 ]; then
  cat "$detect_err" >&2
  [ "$detect_rc" -eq 3 ] && { echo "⚠ qa-e2e-android：detect-emulator 回報本機環境不齊（exit 3）" >&2; exit 3; }
  echo "✗ qa-e2e-android：detect-emulator.sh 失敗（exit ${detect_rc}）" >&2; exit 2
fi
serial=$(printf '%s\n' "$detect_out" | awk '/^emulator: /{print $3; exit}')
[ -n "$serial" ] || { echo "✗ qa-e2e-android：讀不到 detect-emulator.sh 印的 serial（輸出：${detect_out}）" >&2; exit 2; }
grep -q '重用' "$detect_err" || booted_by_me=1
echo "→ qa-e2e-android：${detect_out}（$([ "$booted_by_me" -eq 1 ] && echo '本腳本 boot，收工會關' || echo '重用既有，收工不關')）"

# 宿主機容器對 emulator 是 10.0.2.2
to_device_url() { printf '%s' "$1" | sed -e 's#//127\.0\.0\.1#//10.0.2.2#' -e 's#//localhost#//10.0.2.2#'; }
dev_api=$(to_device_url "$api_url"); dev_mailpit=$(to_device_url "$mailpit")
test_pkg=com.clyeh.sproutday.test
app_pkg=com.clyeh.sproutday
runner=androidx.test.runner.AndroidJUnitRunner

run_on_device() {   # 在 emulator-lock 內執行（子 bash：變數 export、函式 export -f）
  local rc=0
  "$adb" -s "$serial" install -r -t "$app_apk" >> "$out/instrument.log" 2>&1 \
    && "$adb" -s "$serial" install -r -t "$test_apk" >> "$out/instrument.log" 2>&1 \
    || { echo "✗ qa-e2e-android：adb install 失敗（見 ${out}/instrument.log）" >&2; return 2; }
  "$adb" -s "$serial" shell pm clear "$app_pkg" >> "$out/instrument.log" 2>&1 || true   # 每情境從乾淨狀態開始（同 iOS 的 keychain reset）
  "$adb" -s "$serial" logcat -c >/dev/null 2>&1 || true
  "$adb" -s "$serial" shell am instrument -w \
    -e LS_QA_SCENARIO "$scenario" -e LS_QA_API_URL "$dev_api" -e LS_QA_ANON_KEY "$anon_key" \
    -e LS_QA_MAILPIT "$dev_mailpit" -e LS_QA_EMAIL "${LS_QA_EMAIL:-qa-e2e@ls.test}" \
    -e class com.clyeh.sproutday.qa.QaSmokeTest \
    "${test_pkg}/${runner}" >> "$out/instrument.log" 2>&1 || rc=1
  # am instrument 的 exit code 恆為 0：判定看輸出
  if [ "$rc" -eq 0 ] && grep -q '^OK (' "$out/instrument.log" \
     && ! grep -qE 'FAILURES!!!|INSTRUMENTATION_FAILED|INSTRUMENTATION_STATUS_CODE: -[12]' "$out/instrument.log"; then
    rc=0
  else
    rc=1
  fi
  # 成功失敗都收：最後一張 screencap（失敗時就是失敗當下的畫面）、QaDriver 的逐步截圖、logcat
  "$adb" -s "$serial" exec-out screencap -p > "$out/screens/${scenario}-99-final-screencap.png" 2>/dev/null || echo "⚠ qa-e2e-android：screencap 失敗" >&2
  "$adb" -s "$serial" pull "/sdcard/Android/data/${app_pkg}/files/qa-e2e/${scenario}/." "$out/screens/" >> "$out/instrument.log" 2>&1 \
    || echo "⚠ qa-e2e-android：adb pull 逐步截圖失敗（裝置端沒有 qa-e2e/${scenario}？）" >&2
  [ -f "$out/screens/config.txt" ] && mv "$out/screens/config.txt" "$out/config.txt"
  "$adb" -s "$serial" logcat -d -v time > "$out/logcat.log" 2>&1 || true
  return "$rc"
}
export adb serial out scenario app_apk test_apk dev_api anon_key dev_mailpit test_pkg app_pkg runner
export -f run_on_device

echo "→ qa-e2e-android：${scenario} @ ${serial} → ${out}"
bash "$emu_lock_sh" --serial "$serial" -- bash -c run_on_device
rc=$?

shots=$(ls "$out/screens" 2>/dev/null | wc -l | tr -d ' ')
case "$rc" in
  0) echo "✓ qa-e2e-android：${scenario} 通過——截圖 ${shots} 張：${out}/screens/；instrument：${out}/instrument.log"; exit 0 ;;
  124) echo "✗ qa-e2e-android：等 emulator 鎖逾時（emulator-lock.sh exit 124）——見上方持有者" >&2; exit 2 ;;
  2) exit 2 ;;
esac
echo "✗ qa-e2e-android：${scenario} 失敗——截圖 ${shots} 張：${out}/screens/；完整 log：${out}/instrument.log" >&2
grep -E 'AssertionError|FAILURES|INSTRUMENTATION_|Failed|尚未實作|java\.lang\.' "$out/instrument.log" | head -n 20 | sed 's/^/    /' >&2
exit 1
