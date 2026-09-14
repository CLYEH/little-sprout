#!/bin/bash
# qa-e2e.sh 的自測（LS-158）。CI rules job 每個 PR 都跑。
#
# 比照 tap-target-check.test.sh：PATH 換上假的 supabase／curl／xcrun／xcodebuild／docker，完全不碰真容器、
# 真模擬器；supabase-lock.sh 以 LS_LOCK_SH 換成 stub（R1 N2——真 lock 是以絕對路徑呼叫、PATH shim 攔不到）。
# 驗腳本自己的防線——參數與情境名檢查、主 checkout 擋、票號推導、容器環境變數與 health 檢查——全部要在碰到
# xcrun／xcodebuild 之前就 fail closed（假 xcrun／xcodebuild／docker 一旦被呼叫就落標記檔，這些案例都斷言標記不存在）；
# 再以「smart xcrun」＋ lock stub 走到步驟 5／6／cleanup：取得 hold→跑完→`--release`＋關自己 boot 的模擬器；hold 回 3
# （呼叫者已持有）→沿用、不代釋放；hold 失敗→exit 2 不碰 xcodebuild；xcodebuild 紅→exit 1 仍釋放；模擬器本來就
# Booted→不關。「XCUITest 真的能驅動 app」不是這支腳本的責任，那是 LittleSproutUITests/QA 的。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/qa-e2e.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FAKE_WORK="$work"
unset LS_QA_MAILPIT LS_LOCK_SH

bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/supabase" <<'STUB'
#!/bin/bash
case "${FAKE_SUPABASE_MODE:-ok}" in
  ok) printf 'ANON_KEY="fake-anon"\nAPI_URL="http://127.0.0.1:54321"\nMAILPIT_URL="http://127.0.0.1:54324"\nSERVICE_ROLE_KEY="fake-service"\n' ;;
  # LS-264：舊版 CLI／欄位改名的形狀——有 API_URL／ANON_KEY 但沒有 SERVICE_ROLE_KEY，探針該整段略過
  nokey) printf 'ANON_KEY="fake-anon"\nAPI_URL="http://127.0.0.1:54321"\nMAILPIT_URL="http://127.0.0.1:54324"\n' ;;
  empty) ;;
  down) echo "failed to inspect container health" >&2; exit 1 ;;
esac
STUB
cat > "$bin/curl" <<'STUB'
#!/bin/bash
# 只回 -w 的 http_code：FAKE_CURL_MAILPIT／FAKE_CURL_AUTH 依 URL 選；none＝完全沒輸出（I-2：腳本要自己補 000）
url=; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
case "$url" in
  */api/v1/info) [ "${FAKE_CURL_MAILPIT:-200}" = none ] || printf '%s' "${FAKE_CURL_MAILPIT:-200}" ;;
  */auth/v1/health) printf '%s' "${FAKE_CURL_AUTH:-200}" ;;
  # LS-264：PostgREST 授權快取探針。FAKE_CURL_REST 可給逗號分隔序列（第 n 次呼叫取第 n 個，
  # 用完沿用最後一個），用來模擬「第一次 401、reload 後 200」這種兩段式情境。
  */rest/v1/*)
    seq=${FAKE_CURL_REST:-200}
    c=$(cat "$FAKE_WORK/rest-calls" 2>/dev/null || echo 0); c=$((c + 1)); printf '%s' "$c" > "$FAKE_WORK/rest-calls"
    old=$IFS; IFS=,; set -- $seq; IFS=$old
    [ "$c" -le $# ] || c=$#
    eval "printf '%s' \"\${$c}\"" ;;
  *) printf '000' ;;
esac
STUB
# LS-264：psql stub——記錄 notify 呼叫；FAKE_PSQL_RC 模擬失敗
cat > "$bin/psql" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-psql"; echo "psql $*" >> "$FAKE_WORK/calls.log"
exit "${FAKE_PSQL_RC:-0}"
STUB
# xcrun：預設（dumb）一律 exit 99；FAKE_XCRUN_MODE=sim 時扮演一台專屬機 LS-321-iPhone17Pro（狀態 FAKE_SIM_STATE）
cat > "$bin/xcrun" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-xcrun"; echo "xcrun $*" >> "$FAKE_WORK/calls.log"
[ "${FAKE_XCRUN_MODE:-dumb}" = sim ] || exit 99
case "$1 $2 $3" in
  "simctl list devicetypes") echo "iPhone 17 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)" ;;
  "simctl list runtimes") echo "iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator.SimRuntime.iOS-26-5" ;;
  "simctl list devices") printf -- '== Devices ==\n-- iOS 26.5 --\n    LS-321-iPhone17Pro (FAKE-UDID-0001) (%s)\n' "${FAKE_SIM_STATE:-Shutdown}" ;;
  "xcresulttool export attachments") exit 1 ;;
esac
exit 0
STUB
cat > "$bin/xcodebuild" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-xcodebuild"; echo "xcodebuild $*" >> "$FAKE_WORK/calls.log"
case "${FAKE_XCODEBUILD_MODE:-none}" in
  pass) echo "Test Suite 'All tests' passed"; exit 0 ;;
  fail) echo "error: -[LittleSproutUITests.QASmokeTests testScenario] : failed - 步驟 3"; echo "** TEST FAILED **"; exit 65 ;;
  *) exit 99 ;;
esac
STUB
cat > "$bin/docker" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-docker"; echo "docker $*" >> "$FAKE_WORK/calls.log"
exit 0
STUB
# lock stub（LS_LOCK_SH）：--hold 依 FAKE_LOCK_MODE 回 0（取得）／3（已持有，沿用）／124（逾時）；一切呼叫記到 lock.log
cat > "$bin/lock-stub.sh" <<'STUB'
#!/bin/bash
echo "lock $*" >> "$FAKE_WORK/lock.log"
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
chmod +x "$bin"/*

# 假 repo：base＝主 checkout；LS-321／plain＝真 worktree（qa-e2e.sh 以 git-dir≠git-common-dir 判定 worktree，R1 N1）
base="$work/base"; mkdir -p "$base"
git -C "$base" init -q
git -C "$base" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$base" worktree add -q "$work/wt/LS-321" -b wt-321
git -C "$base" worktree add -q "$work/wt/plain" -b wt-plain
wt="$work/wt/LS-321"

run() {   # run <目錄> [參數…]；FAKE_* 由呼叫端 export
  ( cd "$1" && shift && PATH="$bin:$PATH" bash "$script" "$@" 2>&1 )
}
expect() {   # expect <期望 exit> <名稱> <實得 exit> <輸出> [必含…]
  local want=$1 name=$2 got=$3 out=$4; shift 4
  local good=1 must
  [ "$got" -eq "$want" ] || good=0
  for must in "$@"; do printf '%s' "$out" | grep -qF -- "$must" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
  fi
}
no_tools() {   # 斷言 xcrun／xcodebuild／docker 都沒被叫到
  local name=$1 tool bad=0
  for tool in xcrun xcodebuild docker; do [ -e "$work/INVOKED-$tool" ] && { echo "✗ ${name}：不該呼叫 ${tool}" >&2; bad=1; }; done
  [ "$bad" -eq 0 ] && ok "${name}：未實跑 xcrun／xcodebuild／docker"
  reset_logs
}
reset_logs() { rm -f "$work"/INVOKED-* "$work/calls.log" "$work/lock.log" "$work/rest-calls"; : > "$work/calls.log"; : > "$work/lock.log"; }
log_has()   { if grep -qF -- "$3" "$work/$2"; then ok "$1"; else echo "✗ ${1}（${2} 應含「${3}」）" >&2; sed 's/^/    /' "$work/$2" >&2; fail=1; fi; }
log_hasnt() { if grep -qF -- "$3" "$work/$2"; then echo "✗ ${1}（${2} 不應含「${3}」）" >&2; sed 's/^/    /' "$work/$2" >&2; fail=1; else ok "$1"; fi; }
reset_logs

# ---- ① 參數 ----
out=$(run "$wt"); got=$?
expect 2 '① 無參數 → exit 2、印用法' "$got" "$out" '用法：qa-e2e.sh'
out=$(run "$wt" fly); got=$?
expect 2 '② 情境名錯 → exit 2、列出合法集合' "$got" "$out" '情境「fly」不存在' 'login|publish|browse'
no_tools '②'
out=$(run "$wt" login browse); got=$?
expect 2 '② 兩個情境 → exit 2' "$got" "$out" '多餘參數'
out=$(run "$wt" login --sim); got=$?
expect 2 '② --sim 缺值 → exit 2' "$got" "$out" '--sim 缺值'
out=$(run "$wt" login --bogus); got=$?
expect 2 '② 未知旗標 → exit 2' "$got" "$out" '未知參數'
out=$(run "$wt" --help); got=$?
expect 0 '① --help → exit 0' "$got" "$out" '用法：qa-e2e.sh'

# ---- ③ 主 checkout／票號（R1 N1）----
out=$(run "$base" login --ticket LS-1); got=$?
expect 2 '③ N1：主 checkout（即使帶 --ticket）→ exit 2、指示到票 worktree' "$got" "$out" '這是主 checkout' '.claude/worktrees/LS-<n>'
no_tools '③ N1'
out=$(run "$work/wt/plain" login); got=$?
expect 2 '③ worktree 目錄名無票號且無 --ticket → exit 2' "$got" "$out" '推不出票號' '請在 .claude/worktrees/LS-<n> 內跑'
if printf '%s' "$out" | grep -qF -- '加 --ticket'; then echo "✗ ③ N1：推不出票號的訊息不得再建議「加 --ticket」繞過" >&2; fail=1; else ok '③ N1：推不出票號的訊息不建議 --ticket 繞過'; fi
out=$(run "$work/wt/plain" login --ticket nope); got=$?
expect 2 '③ --ticket 格式錯 → exit 2' "$got" "$out" '--ticket 須為 LS-<n>'
out=$(cd "$work" && PATH="$bin:$PATH" bash "$script" login 2>&1); got=$?
expect 2 '③ 不在 git repo 內 → exit 2' "$got" "$out" '不在 git repo 內'
no_tools '③'

# ---- ④ 容器環境（缺環境變數紅）----
out=$(FAKE_SUPABASE_MODE=empty run "$wt" login); got=$?
expect 2 '④ supabase status 無 API_URL／ANON_KEY → exit 2' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_SUPABASE_MODE=down run "$wt" publish); got=$?
expect 2 '④ supabase status 失敗 → exit 2' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_SUPABASE_MODE=empty run "$work/wt/plain" browse --ticket LS-7); got=$?
expect 2 '④ 固定 worktree 帶合法 --ticket → 走到容器檢查（票號推導不擋）' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_CURL_MAILPIT=000 run "$wt" login); got=$?
expect 2 '④ Mailpit 不可達 → exit 2、HTTP 000（不是 000000，I-2）' "$got" "$out" 'Mailpit http://127.0.0.1:54324 不可達（HTTP 000）'
out=$(FAKE_CURL_MAILPIT=none run "$wt" login); got=$?
expect 2 '④ I-2：curl 完全沒輸出 → 補成 000' "$got" "$out" '不可達（HTTP 000）'
out=$(LS_QA_MAILPIT=http://127.0.0.1:1 FAKE_CURL_MAILPIT=000 run "$wt" login); got=$?
expect 2 '④ LS_QA_MAILPIT 覆寫值被採用' "$got" "$out" 'Mailpit http://127.0.0.1:1 不可達'
out=$(FAKE_CURL_AUTH=503 run "$wt" login); got=$?
expect 2 '④ GoTrue health 非 200 → exit 2' "$got" "$out" 'auth/v1/health 回 HTTP 503'
no_tools '④'

# ---- ⑤ 環境齊全才會碰模擬器：假 xcrun（dumb）立刻失敗、腳本 exit 2 且沒碰 xcodebuild ----
out=$(run "$wt" login); got=$?
expect 2 '⑤ 環境齊全 → 進到模擬器階段（假 xcrun 失敗）' "$got" "$out" '找不到 iPhone 17 Pro devicetype'
if [ -e "$work/INVOKED-xcrun" ] && [ ! -e "$work/INVOKED-xcodebuild" ]; then ok '⑤ 呼叫了 xcrun、未碰 xcodebuild'; else echo "✗ ⑤ 應呼叫 xcrun 且不碰 xcodebuild" >&2; fail=1; fi
reset_logs
out=$(run "$wt" login --sim no-such-sim); got=$?
expect 2 '⑤ --sim 指定不存在的模擬器 → exit 2（不自建）' "$got" "$out" '--sim「no-such-sim」不存在'
[ -e "$work/INVOKED-xcodebuild" ] && { echo "✗ ⑤ 不該呼叫 xcodebuild" >&2; fail=1; }
reset_logs

# ---- ⑥ hold 三路徑＋cleanup（R1 N2；smart xcrun＋lock stub＋假 xcodebuild）----
e2e() { FAKE_XCRUN_MODE=sim LS_LOCK_SH="$bin/lock-stub.sh" run "$@"; }
out=$(FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑥a 取得 hold → 跑 xcodebuild → 通過 exit 0' "$got" "$out" '通過' 'held pid=1 label=LS-321 qa-e2e login'
log_has   '⑥a lock：--hold 帶票號＋情境 label' lock.log 'lock --hold LS-321 qa-e2e login --max-minutes 25'
log_has   '⑥a cleanup：自己取得的 hold 收工 --release' lock.log 'lock --release'
log_has   '⑥a xcodebuild 只跑 QASmokeTests' calls.log '-only-testing:LittleSproutUITests/QASmokeTests'
log_has   '⑥a 每情境先 keychain reset' calls.log 'simctl keychain FAKE-UDID-0001 reset'
log_has   '⑥a 自己 boot 的模擬器收工關' calls.log 'simctl shutdown FAKE-UDID-0001'
reset_logs
out=$(FAKE_LOCK_MODE=already FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑥b hold 回 3（呼叫者已持有）→ 沿用、照跑、exit 0' "$got" "$out" '沿用呼叫者既有的 hold' '通過'
log_hasnt '⑥b 沿用時不代釋放（無 --release）' lock.log 'lock --release'
[ -e "$work/INVOKED-xcodebuild" ] && ok '⑥b 沿用時仍跑 xcodebuild' || { echo "✗ ⑥b 應跑 xcodebuild" >&2; fail=1; }
reset_logs
out=$(FAKE_LOCK_MODE=fail FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 2 '⑥c hold 失敗（124）→ exit 2、印 lock 的 exit code' "$got" "$out" '取不到 Supabase lock（supabase-lock.sh exit 124）'
[ -e "$work/INVOKED-xcodebuild" ] && { echo "✗ ⑥c hold 失敗不該跑 xcodebuild" >&2; fail=1; } || ok '⑥c hold 失敗不碰 xcodebuild'
log_hasnt '⑥c hold 失敗不 --release（沒有 hold 可放）' lock.log 'lock --release'
log_has   '⑥c hold 失敗仍關自己 boot 的模擬器' calls.log 'simctl shutdown FAKE-UDID-0001'
reset_logs
out=$(FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=fail e2e "$wt" login); got=$?
expect 1 '⑥d xcodebuild 紅 → exit 1、印 log 尾段' "$got" "$out" 'login 失敗（xcodebuild exit 65）' '步驟 3'
log_has   '⑥d 失敗也 --release（trap EXIT）' lock.log 'lock --release'
log_has   '⑥d 失敗也關自己 boot 的模擬器' calls.log 'simctl shutdown FAKE-UDID-0001'
reset_logs
out=$(FAKE_SIM_STATE=Booted FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑥e 模擬器本來就 Booted → 通過' "$got" "$out" '通過'
log_hasnt '⑥e 不是自己 boot 的模擬器收工不關' calls.log 'simctl shutdown'
log_hasnt '⑥e 本來就 Booted 就不再 boot' calls.log 'simctl boot '
reset_logs
out=$(FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" publish); got=$?
expect 2 '⑥f publish 缺 fixture（假 repo 沒有 QA/Fixtures）→ exit 2、不碰 lock／xcodebuild' "$got" "$out" '缺 fixture'
log_hasnt '⑥f 缺 fixture 不 --hold' lock.log 'lock --hold'
[ -e "$work/INVOKED-xcodebuild" ] && { echo "✗ ⑥f 不該跑 xcodebuild" >&2; fail=1; } || ok '⑥f 缺 fixture 不碰 xcodebuild'
reset_logs

# ---- ⑦ PostgREST 授權快取自癒（LS-264；來源 LS-96 池項 `2ce0014f`(a)；R2 m1 改成無條件先 reload）----
#      LS-260 實測：登入後首個 REST 請求連兩次 401 permission denied（決定性），reset 後才過。
#      R1 版本是「先探、非 2xx 才 reload」，但探針（service_role／`profiles`）與原事故
#      （`authenticated`／`app_settings`）角色與表都不同，角色特定故障探不到＝自癒沒接上（merge-review R1 m1）。
#      R2 改成：先無條件 `notify pgrst, 'reload schema'`（與角色無關），探針退化成 reload 後的 fail-loud
#      健康檢查。本段驗：健康也要 reload、reload 後仍紅要再 reload 一次、兩次仍紅才 exit 2 且不燒 xcodebuild、
#      reload 打不出去只 ⚠ 不擋、沒有 SERVICE_ROLE_KEY 仍然 reload。
out=$(FAKE_CURL_REST=200 FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑦a 探針 200 → 仍無條件 reload 過一次、印健康那行、照跑' "$got" "$out" \
  "已在 hold 內發 notify pgrst, 'reload schema'" 'REST 授權快取探針 HTTP 200（reload 後健康' '通過'
log_has '⑦a（R2 m1）健康路徑也真的發了 notify（不再「健康就不碰」）' calls.log "notify pgrst, 'reload schema'"
reset_logs
out=$(FAKE_CURL_REST=401,200 FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑦b 探針 401 → 等 3 秒再 reload 一次 → 再探 200 → 自癒後照跑' "$got" "$out" \
  'REST 探針回 HTTP 401' '第二次 reload schema 後' '已自癒' '通過'
if [ "$(grep -c "notify pgrst, 'reload schema'" "$work/calls.log")" -eq 2 ]; then
  ok '⑦b 非 2xx 路徑一共發兩次 notify（無條件那次＋重試那次）'
else
  echo "✗ ⑦b 應發兩次 notify（實得 $(grep -c "notify pgrst, 'reload schema'" "$work/calls.log") 次）" >&2
  sed 's/^/    /' "$work/calls.log" >&2; fail=1
fi
reset_logs
out=$(FAKE_CURL_REST=401,401 FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 2 '⑦c 兩次 reload 後仍 401 → exit 2（fail loud），並指向 lock 內整組重啟' "$got" "$out" \
  '兩次後 REST 探針仍回 HTTP 401' 'supabase stop && supabase start'
[ -e "$work/INVOKED-xcodebuild" ] && { echo "✗ ⑦c 探針沒救回來不該燒 xcodebuild" >&2; fail=1; } || ok '⑦c 探針沒救回來不跑 xcodebuild'
log_has '⑦c 仍釋放自己取得的 hold（trap EXIT）' lock.log 'lock --release'
reset_logs
# R2 m1：reload 打不出去不再直接 exit 2（PR 前根本沒有這一步，failure 代表「沒修成」不是「更差」）——
# 只 ⚠ 並繼續探；探針健康就照跑，探針紅才 fail loud（下一格）。
out=$(FAKE_CURL_REST=200 FAKE_PSQL_RC=1 FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑦d notify 發不出去但探針健康 → ⚠ 不擋、照跑（fail-soft 邊界）' "$got" "$out" \
  'notify pgrst 發不出去' 'host psql' '通過'
reset_logs
out=$(FAKE_CURL_REST=401,401 FAKE_PSQL_RC=1 FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 2 '⑦d2 notify 發不出去且探針紅 → exit 2、不燒 xcodebuild' "$got" "$out" 'notify pgrst 發不出去' '仍回 HTTP 401'
[ -e "$work/INVOKED-xcodebuild" ] && { echo "✗ ⑦d2 不該燒 xcodebuild" >&2; fail=1; } || ok '⑦d2 notify 失敗且探針紅時不跑 xcodebuild'
reset_logs
# 負控：SERVICE_ROLE_KEY 缺席時只略過「探測」，reload 照發（reload 不需要任何金鑰）
out=$(FAKE_SUPABASE_MODE=nokey FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass e2e "$wt" login); got=$?
expect 0 '⑦e 無 SERVICE_ROLE_KEY → 只略過探測、不擋（fail-soft）' "$got" "$out" '略過 PostgREST 授權快取探測' '通過'
log_has '⑦e（R2 m1）缺金鑰仍然 reload 過（自癒不靠探針觸發）' calls.log "notify pgrst, 'reload schema'"
reset_logs
# ⑦f（LS-264 R2 m2；merge-review R1 m2）：`pgrst_reload` 的 **docker exec 分支**——本機沒有 host `psql`，
#      實跑走的就是這條，但上面每一格的 PATH 都有 psql stub，等於零覆蓋：容器名前綴或 `docker exec` 參數
#      日後改動，自測全綠、真跑時 notify 靜默失敗，而 exit 2 的訊息還會把人指去「整組重啟」。
#      做法：另備一個「除了 psql 以外的 stub 都在」的 bin 目錄（shim 之外若系統真的裝了 psql 就 SKIP，
#      同本 repo 對無 jq 的既有慣例），docker stub 回一個容器名，斷言 calls.log 出現 docker exec … psql … notify。
bin_nopsql="$work/bin-nopsql"; mkdir -p "$bin_nopsql"
for f in "$bin"/*; do
  case "${f##*/}" in psql) continue ;; esac
  ln -sf "$f" "$bin_nopsql/${f##*/}"
done
cat > "$bin_nopsql/docker" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-docker"; echo "docker $*" >> "$FAKE_WORK/calls.log"
# `docker ps --filter name=supabase_db --format {{.Names}}` → 回容器名；其餘（exec／logs）只記錄。
# 真的比對 filter 值：filter 打錯（例如容器名前綴改掉）就回空，讓 ⑦f 轉紅——不比對的話這格是空跑。
if [ "$1" = ps ]; then
  for a in "$@"; do
    case "$a" in name=supabase_db) echo "supabase_db_little-sprout" ;; esac
  done
fi
exit 0
STUB
chmod +x "$bin_nopsql/docker"
if PATH="$bin_nopsql:$PATH" command -v psql >/dev/null 2>&1; then
  echo "SKIP 2 組（系統路徑上有真的 psql）：⑦f docker exec 分支無法在本機隔離"
else
  out=$( cd "$wt" && PATH="$bin_nopsql:$PATH" FAKE_XCRUN_MODE=sim LS_LOCK_SH="$bin/lock-stub.sh" \
         FAKE_CURL_REST=200 FAKE_LOCK_MODE=ok FAKE_XCODEBUILD_MODE=pass bash "$script" login 2>&1 ); got=$?
  expect 0 '⑦f 無 host psql → 走 docker exec 分支、印該通道、照跑' "$got" "$out" \
    'docker exec supabase_db_little-sprout psql' '通過'
  log_has '⑦f docker exec 真的帶了 psql 與 notify pgrst, reload schema' calls.log "docker exec supabase_db_little-sprout psql -U postgres -d postgres -v ON_ERROR_STOP=1 --no-psqlrc -q -c notify pgrst, 'reload schema'"
fi
reset_logs

if [ "$fail" -ne 0 ]; then echo "✗ qa-e2e 自測失敗" >&2; exit 1; fi
echo "✓ qa-e2e 自測通過（${n} 組樣本）"
