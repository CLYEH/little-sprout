#!/bin/bash
# qa-e2e-android.sh 的自測（LS-478）。CI rules job 每個 PR 都跑。
#
# 比照 qa-e2e.test.sh：PATH 換上假的 adb／supabase／curl，gradlew 是夾具 worktree 裡的 stub，env-check／detect-emulator／
# supabase-lock／emulator-lock 以 LS_*_SH seam 換成 stub——完全不碰真容器、真 emulator、真 Gradle。
# 驗腳本自己的防線：參數／情境名／主 checkout／票號、本機 Android 環境不齊 exit 3（含缺 adb）、容器環境、建置紅、
# 鎖順序（先 supabase 後 AVD）與逆序釋放、自己 boot 的 emulator 才關且一律帶 -s、重用既有 emulator 不關、
# instrument 紅仍收證據仍釋放、INT／TERM 轉成帶碼 exit 後仍釋放與關機、證據目錄命名。
# 「QaDriver 真的能驅動 app」不是這支腳本的責任，那是 androidTest 的，只有 CI android-connected／專屬 emulator 驗得到。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/qa-e2e-android.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FAKE_WORK="$work"
unset LS_QA_MAILPIT LS_LOCK_SH LS_EMULATOR_LOCK_SH LS_DETECT_EMULATOR_SH LS_ENV_CHECK_SH ANDROID_HOME ANDROID_SDK_ROOT

bin="$work/bin"; mkdir -p "$bin"
# order.log：所有 stub 依發生順序各記一行，驗鎖順序用
cat > "$bin/supabase" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-supabase"
case "${FAKE_SUPABASE_MODE:-ok}" in
  ok) printf 'ANON_KEY="fake-anon"\nAPI_URL="http://127.0.0.1:54321"\nMAILPIT_URL="http://127.0.0.1:54324"\n' ;;
  empty) ;;
esac
STUB
cat > "$bin/curl" <<'STUB'
#!/bin/bash
url=; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
case "$url" in
  */api/v1/info) printf '%s' "${FAKE_CURL_MAILPIT:-200}" ;;
  */auth/v1/health) printf '%s' "${FAKE_CURL_AUTH:-200}" ;;
  *) printf '000' ;;
esac
STUB
cat > "$bin/adb" <<'STUB'
#!/bin/bash
echo "adb $*" >> "$FAKE_WORK/calls.log"; echo "adb $*" >> "$FAKE_WORK/order.log"
case "$*" in
  *"exec-out screencap"*) printf 'FAKEPNG' ;;
  *"am instrument"*)
    echo "INSTRUMENTATION_RESULT: stream="
    if [ "${FAKE_INSTRUMENT:-pass}" = pass ]; then printf '\nOK (1 test)\n'; else printf 'java.lang.AssertionError: 情境 publish 尚未實作\nFAILURES!!!\nTests run: 1,  Failures: 1\n'; fi ;;
  *" pull "*)
    dest=${@: -1}; mkdir -p "$dest"; : > "$dest/${FAKE_SCENARIO:-login}-01-launch.png"; echo "LS_QA_API_URL=x" > "$dest/config.txt" ;;
  *"logcat -d"*) echo "fake logcat line" ;;
esac
exit 0
STUB
cat > "$bin/env-check-stub.sh" <<'STUB'
#!/bin/bash
echo "env-check $*" >> "$FAKE_WORK/order.log"
case "${FAKE_ENV_RC:-0}" in
  0) echo "✓ android-env：stub" ;;
  3) echo "⚠ android-env：本機 Android 環境不齊：" ; echo "  - 找不到可用的 JDK（stub）" ;;
  *) echo "✗ android-env：缺釘住檔（stub）" >&2 ;;
esac
exit "${FAKE_ENV_RC:-0}"
STUB
cat > "$bin/detect-stub.sh" <<'STUB'
#!/bin/bash
echo "detect-emulator" >> "$FAKE_WORK/order.log"
case "${FAKE_DETECT_MODE:-boot}" in
  boot) echo "→ detect-emulator：起機 LS-321-Pixel8（port 5554）" >&2; echo "emulator: LS-321-Pixel8 emulator-5554 API 36（pinned 36）" ;;
  reuse) echo "→ detect-emulator：選到 LS-321-Pixel8（emulator-5554，已在跑，重用）" >&2; echo "emulator: LS-321-Pixel8 emulator-5554 API 36（pinned 36）" ;;
  rc3) echo "⚠ detect-emulator：本機 Android 環境不齊，無法起 emulator（exit 3）" >&2; exit 3 ;;
  fail) echo "✗ detect-emulator：缺 system image" >&2; exit 1 ;;
esac
STUB
cat > "$bin/lock-stub.sh" <<'STUB'
#!/bin/bash
echo "supabase-lock $*" >> "$FAKE_WORK/order.log"
case "$1" in
  --hold)
    case "${FAKE_LOCK_MODE:-ok}" in
      ok) echo "held pid=1 label=$2 expires=00:00 log=/dev/null"; exit 0 ;;
      already) echo "✗ supabase-lock：已持有 hold（stub）" >&2; exit 3 ;;
      fail) echo "✗ supabase-lock：等待 1s 逾時（stub）" >&2; exit 124 ;;
    esac ;;
  --release) echo "→ supabase-lock：已釋放 hold（stub）" >&2; exit 0 ;;
esac
exit 0
STUB
cat > "$bin/emu-lock-stub.sh" <<'STUB'
#!/bin/bash
echo "emulator-lock $*" >> "$FAKE_WORK/order.log"
[ "${FAKE_EMU_LOCK_RC:-0}" = 0 ] || { echo "✗ emulator-lock：等待逾時（stub）" >&2; exit "$FAKE_EMU_LOCK_RC"; }
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
if [ "${FAKE_EMU_LOCK_MODE:-run}" = hang ]; then echo $$ > "$FAKE_WORK/emu-lock.pid"; sleep 60; fi
"$@"
rc=$?
echo "emulator-lock released" >> "$FAKE_WORK/order.log"
exit "$rc"
STUB
chmod +x "$bin"/*

# 假 repo：base＝主 checkout；LS-321／plain＝真 worktree
base="$work/base"; mkdir -p "$base"
git -C "$base" init -q
git -C "$base" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$base" worktree add -q "$work/wt/LS-321" -b wt-321
git -C "$base" worktree add -q "$work/wt/plain" -b wt-plain
wt="$work/wt/LS-321"
mkdir -p "$wt/android"
cat > "$wt/android/gradlew" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-gradlew"; echo "gradlew $*" >> "$FAKE_WORK/order.log"
[ "${FAKE_GRADLE:-ok}" = ok ] || { echo "FAILURE: Build failed with an exception. (stub)"; exit 1; }
mkdir -p app/build/outputs/apk/debug app/build/outputs/apk/androidTest/debug
: > app/build/outputs/apk/debug/app-debug.apk; : > app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
STUB
chmod +x "$wt/android/gradlew"

run() {   # run <目錄> [參數…]
  ( cd "$1" && shift && PATH="$bin:$PATH" LS_ENV_CHECK_SH="$bin/env-check-stub.sh" LS_DETECT_EMULATOR_SH="$bin/detect-stub.sh" \
      LS_LOCK_SH="$bin/lock-stub.sh" LS_EMULATOR_LOCK_SH="$bin/emu-lock-stub.sh" bash "$script" "$@" 2>&1 )
}
expect() {   # expect <期望 exit> <名稱> <實得 exit> <輸出> [必含…]
  local want=$1 name=$2 got=$3 out=$4; shift 4
  local good=1 must
  [ "$got" -eq "$want" ] || good=0
  for must in "$@"; do printf '%s' "$out" | grep -qF -- "$must" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
}
reset_logs() { rm -f "$work"/INVOKED-* "$work/calls.log" "$work/order.log" "$work/emu-lock.pid"; : > "$work/calls.log"; : > "$work/order.log"; rm -rf "$wt/.claude" "$wt/android/app"; }
log_has()   { if grep -qF -- "$3" "$work/$2"; then ok "$1"; else echo "✗ ${1}（${2} 應含「${3}」）" >&2; sed 's/^/    /' "$work/$2" >&2; fail=1; fi; }
log_hasnt() { if grep -qF -- "$3" "$work/$2"; then echo "✗ ${1}（${2} 不應含「${3}」）" >&2; sed 's/^/    /' "$work/$2" >&2; fail=1; else ok "$1"; fi; }
lineno() { grep -nF -- "$2" "$work/order.log" | head -1 | cut -d: -f1; }   # lineno <_> <字串>
order() {   # order <名稱> <先出現的字串> <後出現的字串>
  local a b; a=$(lineno x "$2"); b=$(lineno x "$3")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else echo "✗ ${1}（「$2」行 ${a:-無} 應早於「$3」行 ${b:-無}）" >&2; sed 's/^/    /' "$work/order.log" >&2; fail=1; fi
}
no_tools() {
  local name=$1 t bad=0
  for t in supabase gradlew; do [ -e "$work/INVOKED-$t" ] && { echo "✗ ${name}：不該呼叫 ${t}" >&2; bad=1; }; done
  [ "$bad" -eq 0 ] && ok "${name}：未碰 supabase／gradlew"
  reset_logs
}
reset_logs

# ---- ① 參數 ----
out=$(run "$wt"); got=$?
expect 2 '① 無參數 → exit 2、印用法' "$got" "$out" '用法：qa-e2e-android.sh'
out=$(run "$wt" fly); got=$?
expect 2 '② 情境名錯 → exit 2、列出合法集合' "$got" "$out" '情境「fly」不存在' 'login|publish|browse'
out=$(run "$wt" child-avatar); got=$?
expect 2 '② iOS 才有的情境名 → exit 2' "$got" "$out" '不存在'
out=$(run "$wt" login browse); got=$?
expect 2 '② 兩個情境 → exit 2' "$got" "$out" '多餘參數'
out=$(run "$wt" login --ticket); got=$?
expect 2 '② --ticket 缺值 → exit 2' "$got" "$out" '--ticket 缺值'
out=$(run "$wt" login --bogus); got=$?
expect 2 '② 未知旗標 → exit 2' "$got" "$out" '未知參數'
out=$(run "$wt" --help); got=$?
expect 0 '① --help → exit 0' "$got" "$out" '用法：qa-e2e-android.sh'
no_tools '①②'

# ---- ③ 主 checkout／票號 ----
out=$(run "$base" login --ticket LS-1); got=$?
expect 2 '③ 主 checkout（即使帶 --ticket）→ exit 2' "$got" "$out" '這是主 checkout' '.claude/worktrees/LS-<n>'
out=$(run "$work/wt/plain" login); got=$?
expect 2 '③ worktree 目錄名無票號且無 --ticket → exit 2' "$got" "$out" '推不出票號'
out=$(run "$work/wt/plain" login --ticket nope); got=$?
expect 2 '③ --ticket 格式錯 → exit 2' "$got" "$out" '--ticket 須為 LS-<n>'
out=$(cd "$work" && PATH="$bin:$PATH" bash "$script" login 2>&1); got=$?
expect 2 '③ 不在 git repo 內 → exit 2' "$got" "$out" '不在 git repo 內'
no_tools '③'

# ---- ④ 本機 Android 環境不齊 → exit 3（不是情境紅）----
out=$(FAKE_ENV_RC=3 run "$wt" login); got=$?
expect 3 '④ env-check exit 3 → exit 3、印 ⚠、點名 CI 為準' "$got" "$out" '⚠ qa-e2e-android：本機 Android 環境不齊' 'android-connected'
no_tools '④ env 不齊'
out=$(FAKE_ENV_RC=1 run "$wt" login); got=$?
expect 2 '④ env-check exit 1（釘住檔壞）→ exit 2，不當成「沒裝」' "$got" "$out" '缺釘住檔'
no_tools '④ env 壞'
# 缺 adb：PATH 只剩系統目錄（無 adb shim）；若系統目錄本身就有 adb 則 SKIP
sysbin="$work/sysbin"; mkdir -p "$sysbin"
for t in git sed awk grep tr head cut date ls wc mkdir cat dirname basename sleep tail mv rm touch env bash; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$sysbin/$t"
done
if PATH="$sysbin" command -v adb >/dev/null 2>&1; then
  echo "⊘ ④ 缺 adb 案例 SKIP（系統目錄已有 adb）"
else
  out=$( cd "$wt" && PATH="$sysbin" LS_ENV_CHECK_SH="$bin/env-check-stub.sh" LS_DETECT_EMULATOR_SH="$bin/detect-stub.sh" LS_LOCK_SH="$bin/lock-stub.sh" \
         LS_EMULATOR_LOCK_SH="$bin/emu-lock-stub.sh" "$sysbin/bash" "$script" login 2>&1 ); got=$?
  expect 3 '④ env 過但找不到 adb → exit 3、印 ⚠' "$got" "$out" '⚠ qa-e2e-android：找不到 adb'
  [ -e "$work/INVOKED-supabase" ] && { echo "✗ ④ 缺 adb 不該碰 supabase" >&2; fail=1; } || ok '④ 缺 adb 未碰 supabase'
  reset_logs
fi

# ---- ⑤ 容器環境 ----
out=$(FAKE_SUPABASE_MODE=empty run "$wt" login); got=$?
expect 2 '⑤ supabase status 無 API_URL／ANON_KEY → exit 2' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_CURL_MAILPIT=000 run "$wt" login); got=$?
expect 2 '⑤ Mailpit 不可達 → exit 2' "$got" "$out" 'Mailpit http://127.0.0.1:54324 不可達（HTTP 000）'
out=$(FAKE_CURL_AUTH=503 run "$wt" login); got=$?
expect 2 '⑤ GoTrue health 非 200 → exit 2' "$got" "$out" 'auth/v1/health 回 HTTP 503'
[ -e "$work/INVOKED-gradlew" ] && { echo "✗ ⑤ 容器不通不該 build" >&2; fail=1; } || ok '⑤ 容器不通不 build'
log_hasnt '⑤ 容器不通不取鎖' order.log 'supabase-lock'
reset_logs

# ---- ⑥ 建置紅 → exit 1、尚未取任何鎖 ----
out=$(FAKE_GRADLE=fail run "$wt" login); got=$?
expect 1 '⑥ gradle 失敗 → exit 1、印 log 尾段' "$got" "$out" 'gradle 建置失敗' 'Build failed with an exception'
log_hasnt '⑥ 建置紅時尚未取 supabase 鎖（建置在鎖之外）' order.log 'supabase-lock'
log_hasnt '⑥ 建置紅時尚未起 emulator' order.log 'detect-emulator'
reset_logs

# ---- ⑦ 正常路徑（自己 boot 的 emulator）----
out=$(run "$wt" login); got=$?
expect 0 '⑦a 全綠 → exit 0' "$got" "$out" '✓ qa-e2e-android：login 通過' '本腳本 boot，收工會關' 'emulator emulator-5554 已關'
order '⑦b 鎖順序：supabase hold 先於 detect-emulator' 'supabase-lock --hold' 'detect-emulator'
order '⑦b 鎖順序：detect-emulator 先於 emulator-lock（先 supabase 後 AVD）' 'detect-emulator' 'emulator-lock --serial emulator-5554'
order '⑦b 釋放順序：AVD 鎖先放（emulator-lock released）再放 supabase hold' 'emulator-lock released' 'supabase-lock --release'
order '⑦b 建置先於 supabase hold（hold 期間不 build）' 'gradlew' 'supabase-lock --hold'
log_has '⑦c hold label 含票號、腳本名與情境' order.log 'supabase-lock --hold LS-321 qa-e2e-android login --max-minutes 25'
log_has '⑦c 兩支 APK 都用 -s <serial> -r -t 安裝' calls.log 'adb -s emulator-5554 install -r -t'
log_has '⑦c instrument 帶情境' calls.log '-e LS_QA_SCENARIO login'
log_has '⑦c instrument 只跑 QaSmokeTest' calls.log '-e class com.clyeh.sproutday.qa.QaSmokeTest'
log_has '⑦c instrument runner 是 test package／AndroidJUnitRunner' calls.log 'com.clyeh.sproutday.test/androidx.test.runner.AndroidJUnitRunner'
log_has '⑦d API URL 對 emulator 改寫成 10.0.2.2' calls.log '-e LS_QA_API_URL http://10.0.2.2:54321'
log_has '⑦d Mailpit URL 對 emulator 改寫成 10.0.2.2' calls.log '-e LS_QA_MAILPIT http://10.0.2.2:54324'
log_has '⑦e 收尾 screencap 用 adb exec-out' calls.log 'adb -s emulator-5554 exec-out screencap -p'
log_has '⑦f 自己 boot 的 emulator 只關自己那台（-s serial emu kill）' calls.log 'adb -s emulator-5554 emu kill'
bad_kill=$(grep -E ' emu kill' "$work/calls.log" | grep -vF -- ' -s emulator-' || true)
if [ -z "$bad_kill" ]; then ok '⑦f 所有 emu kill 都帶 -s <serial>（從不無 -s kill）'; else echo "✗ ⑦f 出現無 -s 的 emu kill：${bad_kill}" >&2; fail=1; fi
ev=$(ls -d "$wt"/.claude/evidence/LS-321/qa-e2e/login-* 2>/dev/null | head -1)
if [ -n "$ev" ] && printf '%s' "$ev" | grep -qE '/login-[0-9]{8}-[0-9]{6}$'; then ok '⑦g 證據目錄 .claude/evidence/<票>/qa-e2e/<情境>-<YYYYMMDD-HHMMSS>'; else echo "✗ ⑦g 證據目錄命名不符：${ev:-無}" >&2; fail=1; fi
for f in screens/login-99-final-screencap.png screens/login-01-launch.png config.txt gradle.log instrument.log logcat.log; do
  if [ -f "$ev/$f" ]; then ok "⑦g 證據含 $f"; else echo "✗ ⑦g 證據缺 $f（$ev）" >&2; fail=1; fi
done
if [ ! -f "$ev/screens/config.txt" ]; then ok '⑦g config.txt 移出 screens/'; else echo "✗ ⑦g config.txt 應在證據根目錄" >&2; fail=1; fi
reset_logs

# ---- ⑧ 重用既有 emulator → 不關 ----
out=$(FAKE_DETECT_MODE=reuse run "$wt" login); got=$?
expect 0 '⑧ 重用既有 emulator → exit 0、印「收工不關」' "$got" "$out" '重用既有，收工不關'
log_hasnt '⑧ 重用的 emulator 收工不 kill' calls.log 'emu kill'
reset_logs

# ---- ⑨ supabase hold 三路徑 ----
out=$(FAKE_LOCK_MODE=already run "$wt" login); got=$?
expect 0 '⑨a hold 回 3（呼叫者已持有）→ 沿用、照跑、exit 0' "$got" "$out" '沿用呼叫者既有的 hold' '通過'
log_hasnt '⑨a 沿用時不代釋放（無 --release）' order.log 'supabase-lock --release'
reset_logs
out=$(FAKE_LOCK_MODE=fail run "$wt" login); got=$?
expect 2 '⑨b hold 失敗（124）→ exit 2、印 lock 的 exit code' "$got" "$out" '取不到 Supabase lock（supabase-lock.sh exit 124）'
log_hasnt '⑨b hold 失敗不起 emulator' order.log 'detect-emulator'
log_hasnt '⑨b hold 失敗不 --release（沒有 hold 可放）' order.log 'supabase-lock --release'
reset_logs

# ---- ⑩ 情境紅：仍收證據、仍釋放、仍關自己 boot 的機器 ----
out=$(FAKE_INSTRUMENT=fail run "$wt" publish); got=$?
expect 1 '⑩a instrument 紅（am instrument 本身 exit 0）→ exit 1、印失敗訊息' "$got" "$out" 'publish 失敗' '尚未實作'
ev=$(ls -d "$wt"/.claude/evidence/LS-321/qa-e2e/publish-* 2>/dev/null | head -1)
[ -f "$ev/screens/publish-99-final-screencap.png" ] && ok '⑩a 失敗時仍有收尾 screencap（失敗當下畫面）' || { echo "✗ ⑩a 失敗仍應收 screencap" >&2; fail=1; }
log_has '⑩a 失敗也 --release' order.log 'supabase-lock --release'
log_has '⑩a 失敗也關自己 boot 的 emulator' calls.log 'adb -s emulator-5554 emu kill'
log_has '⑩a publish 情境名傳進 instrument' calls.log '-e LS_QA_SCENARIO publish'
reset_logs
out=$(FAKE_EMU_LOCK_RC=124 run "$wt" login); got=$?
expect 2 '⑩b 等 emulator 鎖逾時 → exit 2' "$got" "$out" '等 emulator 鎖逾時'
log_has '⑩b 逾時仍 --release supabase hold' order.log 'supabase-lock --release'
log_has '⑩b 逾時仍關自己 boot 的 emulator' calls.log 'adb -s emulator-5554 emu kill'
log_hasnt '⑩b 逾時沒進裝置端（沒裝 APK）' calls.log ' install '
reset_logs
out=$(FAKE_DETECT_MODE=rc3 run "$wt" login); got=$?
expect 3 '⑩c detect-emulator exit 3 → exit 3（⚠）' "$got" "$out" '本機環境不齊'
log_has '⑩c 仍釋放 hold' order.log 'supabase-lock --release'
reset_logs
out=$(FAKE_DETECT_MODE=fail run "$wt" login); got=$?
expect 2 '⑩d detect-emulator 其他失敗 → exit 2' "$got" "$out" 'detect-emulator.sh 失敗（exit 1）'
reset_logs

# ---- ⑪ TERM：轉成 exit 143，EXIT trap 仍釋放 hold 並關自己 boot 的 emulator ----
# exec：讓背景行程的 pid 就是腳本本身（不是外面包的 subshell），TERM 才打得到腳本的 trap
( cd "$wt" && exec env PATH="$bin:$PATH" LS_ENV_CHECK_SH="$bin/env-check-stub.sh" LS_DETECT_EMULATOR_SH="$bin/detect-stub.sh" \
    LS_LOCK_SH="$bin/lock-stub.sh" LS_EMULATOR_LOCK_SH="$bin/emu-lock-stub.sh" FAKE_EMU_LOCK_MODE=hang \
    bash "$script" login > "$work/term.out" 2>&1 ) &
spid=$!
i=0; while [ ! -s "$work/emu-lock.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ -s "$work/emu-lock.pid" ]; then
  # bash 在前景子行程結束前不跑 trap：先 TERM 腳本本身（trap 排隊），再 TERM 前景的 emulator-lock stub（模擬終端機把訊號送給整個前景行程群），
  # 子行程一結束 trap 就轉成 exit 143、EXIT trap 跟著釋放。
  kill -TERM "$spid" 2>/dev/null
  sleep 0.3
  kill -TERM "$(cat "$work/emu-lock.pid")" 2>/dev/null
  wait "$spid"; got=$?
  if [ "$got" -eq 143 ]; then ok '⑪ TERM 中斷 → exit 143（trap 轉成帶碼 exit）'; else echo "✗ ⑪ TERM 後應 exit 143（得 ${got}）" >&2; fail=1; fi
  log_has '⑪ TERM 後仍 --release supabase hold' order.log 'supabase-lock --release'
  log_has '⑪ TERM 後仍關自己 boot 的 emulator（-s）' calls.log 'adb -s emulator-5554 emu kill'
else
  kill -9 "$spid" 2>/dev/null; echo "✗ ⑪ 等不到 emulator-lock stub 進入 hang" >&2; fail=1
fi
reset_logs

if [ "$fail" -ne 0 ]; then echo "✗ qa-e2e-android.test.sh：有失敗" >&2; exit 1; fi
echo "✓ qa-e2e-android.test.sh：${n} 項通過"
