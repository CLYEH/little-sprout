#!/bin/bash
# push-gate.sh 的自測（LS-100：模擬器用完必關；PR #164 R1 F1／F2／I2 修訂）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支腳本也適用：若退化——xcodebuild test 跑完（不論成功或失敗）沒有關「本 worktree
# 專屬機」、KEEP_SIMULATOR=1 卻還是關了、EXIT／INT／TERM 三個 trap 被搬到 xcodebuild test 之後才設（訊號
# 在執行中發生時就來不及生效）、共用機／demo-* 常駐機被誤關、或鎖仍在時搶著關——這裡會紅。
#
# 真的跑一次 xcodebuild test（甚至整套 push-gate.sh）太重、也不該綁死本機是否已建好 Phase 0 專案，
# 所以比照 detect-simulator.test.sh／push-ref-check.test.sh 的既有模式：把 push-gate.sh 與它會呼叫的
# 腳本（push-ref-check.sh／simulator-lock.sh）複製進合成 repo，PATH 換上 stub 的 xcrun／xcodebuild
# （不碰本機真正的模擬器）。
#
# PR #164 R1 F1：detect-simulator.sh 自己的「專屬／共用／demo／CI」挑選規則已經由
# detect-simulator.test.sh 專測；本檔案改用一支**可控的假身**取代 detect-simulator.sh——只回傳
# `FAKE_DEST_UDID` 指定的 UDID（預設本 worktree 專屬機），讓下面每個案例能精確控制 push-gate.sh 拿到
#的是「專屬機」「共用機」還是「demo 常駐機」，單獨測 push-gate.sh 自己新增的「只關專屬機、鎖仍在就
# 跳過」判斷（原本用 CI=true 走 detect-simulator.sh 的真實共用機路徑沒辦法測到「專屬機」這個分支——
# CI 模式的 shared_udid 依 detect-simulator.sh 自己的排除規則必然指向一台非專屬式命名的裝置）。
# ⑧ 的併發時序重現例外：那組要驗的正是 detect-simulator.sh／push-gate.sh 兩支腳本串接的真實行為，
# 用真正的 detect-simulator.sh（CI=true 走共用第一台）。
#
# I2（PR #164 R1）：鎖目錄一律用 `SIMULATOR_LOCK_DIR` 覆寫到 `mktemp -d` 底下的路徑，不再用固定的
# `/tmp/simulator-lock-SHARED-UDID`——多份 push-gate.test.sh 併行時才不會互刪對方的鎖目錄。
#
# 合成 repo 沒有 docs/API.md／LittleSprout/Errors/AppError.swift／supabase/migrations，所以 push-gate.sh
# 第 4 步（error-codes-check.sh，無條件跑）在①～⑥、⑧一定會失敗（找不到這支腳本），push-gate.sh 整體
# exit code 因此不會是 0——這是預期的、刻意不追求的「全綠」，因為它與本票要驗的行為（模擬器用完必關）
# 無關：trap 在 sim_udid 算出來、判完專屬／共用之後就設好了，不論後面第幾步造成整支腳本退出，trap 都會
# 在那個當下觸發；下面只斷言「xcrun simctl shutdown 有沒有被叫到、UDID 對不對」，不斷言 push-gate.sh
# 整體的最終 exit code（②除外——那組刻意驗 xcodebuild test 失敗本身會讓整支腳本非 0）。
# INT／TERM 訊號傳遞的時機在 bash 裡對「還在等前景指令」的情況沒有跨平台一致保證（同
# scripts/ops/simulator-lock.sh 檔頭理由——它也因此另外顯式接 INT／TERM 成 exit，不只靠裸 EXIT
# trap），所以這裡不模擬真的送訊號中斷，改用靜態接線斷言（同 detect-simulator.test.sh 的 ⑨）釘住
# 「trap 設定的順序在 xcodebuild test 真正執行之前」這件事——這才是訊號中斷也關得掉的機制本身。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate_src="${root}/scripts/gates/push-gate.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ---- 三顆固定但帶 $$ 的 UDID（I2：避免與另一份併行跑的自測撞名；這三顆本身不是鎖目錄路徑，鎖目錄另外
#      由 SIMULATOR_LOCK_DIR 指到 $work 底下，這裡帶 $$ 純粹是同一原則的延伸、也讓輸出訊息在併行跑時
#      各自可辨識）----
ded_udid="DEDICATED-UDID-$$"
shared_udid_test="SHARED-UDID-$$"
demo_udid_test="DEMO-UDID-$$"

R="$work/repo"
mkdir -p "$R/scripts/gates" "$R/scripts/ops"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b main
echo a > "$R/f.txt"; g add -A; g commit -qm 'chore: LS-0 seed'

# ---- 複製 push-gate.sh 會實際呼叫到的腳本；push-gate.sh 內部一律用
#      "$(git rev-parse --show-toplevel)/…" 定路徑，合成 repo 裡就得有這幾份。detect-simulator.sh
#      不複製真的——用下面的可控假身取代（見檔頭說明） ----
cp "$gate_src" "$R/scripts/gates/push-gate.sh"
cp "${root}/scripts/gates/push-ref-check.sh" "$R/scripts/gates/push-ref-check.sh"
cp "${root}/scripts/ops/simulator-lock.sh" "$R/scripts/ops/simulator-lock.sh"
cp "$R/scripts/ops/simulator-lock.sh" "$work/simulator-lock.sh.real"
# 觸發 push-gate.sh「Xcode 專案存在」那個分支；ls -d 只認目錄存在，內容不重要
mkdir -p "$R/Fake.xcodeproj"

# ---- detect-simulator.sh 假身：直接回傳 FAKE_DEST_UDID 指定的 UDID（預設本 worktree 專屬機），
#      隔離測試 push-gate.sh 自己的 dedicated／shared／demo 判斷與 shutdown 邏輯 ----
cat > "$R/scripts/gates/detect-simulator.sh" <<EOF
#!/bin/bash
printf 'platform=iOS Simulator,id=%s\n' "\${FAKE_DEST_UDID:-$ded_udid}"
EOF
chmod +x "$R/scripts/gates/detect-simulator.sh"

# ---- stub xcrun／xcodebuild：不碰本機真正的模擬器／Xcode。xcrun 的裝置清單從 $STUB_DB（tab 分隔
#      name\tudid）讀，讓 push-gate.sh 對「這顆 UDID 是誰」的查詢能查到三種身分（專屬／共用／demo）----
mkdir -p "$work/bin"
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
db="${STUB_DB:?}"
if [ "$1" = simctl ] && [ "$2" = list ] && [ "$3" = devices ] && [ "$4" = available ]; then
  echo "== Devices =="
  echo "-- iOS 26.0 --"
  while IFS=$'\t' read -r n u || [ -n "$n" ]; do
    [ -n "$n" ] || continue
    echo "    ${n} (${u}) (Shutdown)"
  done < "$db"
  exit 0
fi
if [ "$1" = simctl ] && [ "$2" = shutdown ]; then
  printf 'shutdown %s\n' "$3" >> "${SHUTDOWN_LOG:?SHUTDOWN_LOG 未設定}"
  exit "${STUB_SHUTDOWN_RC:-0}"
fi
exit 1
STUB
chmod +x "$work/bin/xcrun"
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
# LS-106：1b 步先呼叫 `xcodebuild -version`（固定第一個參數）；版本不一致時再呼叫
# `xcodebuild build …`（帶 SWIFT_STRICT_CONCURRENCY=complete）——記到 $BUILD_LOG 供 ⑩／⑪ 斷言用。
if [ "$1" = -version ]; then
  printf 'Xcode %s\nBuild version %s\n' "${STUB_XCODE_VERSION:-99.9}" "${STUB_XCODE_BUILD:-ZZ000Z}"
  exit 0
fi
for a in "$@"; do
  case "$a" in
    -resolvePackageDependencies) exit 0 ;;
    test) exit "${STUB_TEST_RC:-0}" ;;
    build) printf '%s\n' "$*" >> "${BUILD_LOG:-/dev/null}"; exit "${STUB_BUILD_RC:-0}" ;;
  esac
done
exit 0
STUB
chmod +x "$work/bin/xcodebuild"

db="$work/devices.db"
printf '%s\t%s\n%s\t%s\n%s\t%s\n' \
  "main-iPhone17Pro" "$ded_udid" \
  "iPhone 17 Pro" "$shared_udid_test" \
  "demo-iPhone17Pro" "$demo_udid_test" > "$db"
export STUB_DB="$db"

SHUTDOWN_LOG="$work/shutdown.log"; export SHUTDOWN_LOG
: > "$SHUTDOWN_LOG"

# I2：鎖目錄固定指到 $work 底下（mktemp -d 出來的路徑），不再用 /tmp/simulator-lock-<固定字面值>。
export SIMULATOR_LOCK_DIR="$work/simlock"

# run_gate <env 指定…>：在合成 repo 內跑 push-gate.sh；stdin 接 /dev/null（非 tty）讓開頭的
# push-ref-check.sh 照跑——空 stdin＝seen=0＝exit 0（既有行為，維持完整 gate）。FAKE_DEST_UDID
# 預設本 worktree 專屬機（$ded_udid），呼叫端可在 "$@" 覆寫成共用機／demo 機的 UDID。
run_gate() {
  rm -rf "$SIMULATOR_LOCK_DIR"
  ( cd "$R" && env FAKE_DEST_UDID="$ded_udid" PATH="$work/bin:$PATH" "$@" \
      bash scripts/gates/push-gate.sh </dev/null 2>&1 )
}

# ---- ① 本 worktree 專屬機、測試成功（STUB_TEST_RC=0）→ 仍要關模擬器 ----
: > "$SHUTDOWN_LOG"
out1=$(run_gate STUB_TEST_RC=0)
if grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then
  echo "✓ ① 專屬機、xcodebuild test 成功 → xcrun simctl shutdown 有被呼叫"
else
  echo "✗ ① 專屬機、xcodebuild test 成功但沒有關模擬器" >&2
  printf '%s\n' "$out1" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ② 本 worktree 專屬機、測試失敗（STUB_TEST_RC=1）→ 仍要關模擬器（成功失敗皆關）----
: > "$SHUTDOWN_LOG"
out2=$(run_gate STUB_TEST_RC=1); rc2=$?
if [ "$rc2" -ne 0 ]; then
  echo "✓ ② xcodebuild test 失敗 → push-gate.sh 整體也非 0（set -e 立即跳出）"
else
  echo "✗ ② xcodebuild test 失敗時 push-gate.sh 應非 0（實得 0）" >&2
  fail=1
fi
if grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then
  echo "✓ ② 專屬機、xcodebuild test 失敗 → 仍有關模擬器（trap 在失敗時一樣觸發）"
else
  echo "✗ ② 專屬機、xcodebuild test 失敗但沒有關模擬器" >&2
  printf '%s\n' "$out2" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ③ 本 worktree 專屬機、KEEP_SIMULATOR=1 → 不關模擬器 ----
: > "$SHUTDOWN_LOG"
out3=$(run_gate STUB_TEST_RC=0 KEEP_SIMULATOR=1)
if [ ! -s "$SHUTDOWN_LOG" ]; then
  echo "✓ ③ KEEP_SIMULATOR=1 → 沒有呼叫 shutdown（保留模擬器）"
else
  echo "✗ ③ KEEP_SIMULATOR=1 卻仍呼叫了 shutdown" >&2
  printf '%s\n' "$out3" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ④ 接線順序：sim_udid 算出來 → KEEP_SIMULATOR 判斷 → 專屬機判斷函式定義（內含真正的
#        shutdown 呼叫）→ EXIT／INT／TERM 三個 trap 都設好，全部在 simulator-lock.sh 包住的
#        xcodebuild test 真正執行「之前」（不是只在旁邊的註解提到；跳過註解行，同
#        detect-simulator.test.sh ⑨ 的模式）。simulator-lock.sh／xcodebuild test 兩個 pattern 只取
#        「第一次」出現（LS-106 1b 在後面又加了一次 simulator-lock.sh 包 xcodebuild build 當替代
#        檢查——若不加 !saw_lock／!saw_test guard，取到的會是那第二次呼叫的行號，把本來就成立的
#        順序誤判成不成立）----
wired=$(awk '
  /^[ \t]*#/ { next }
  /sim_udid=/ && !saw_udid { saw_udid = NR }
  /KEEP_SIMULATOR/ && !saw_keep { saw_keep = NR }
  /shutdown_dedicated_simulator\(\)/ && !saw_func { saw_func = NR }
  /xcrun simctl shutdown "\$sim_udid"/ && !saw_call { saw_call = NR }
  /trap shutdown_dedicated_simulator EXIT/ { saw_exit = NR }
  /trap .*exit 130.*INT/ { saw_int = NR }
  /trap .*exit 143.*TERM/ { saw_term = NR }
  /simulator-lock\.sh/ && !saw_lock { saw_lock = NR }
  /xcodebuild test/ && !saw_test { saw_test = NR }
  END {
    if (saw_udid && saw_keep && saw_func && saw_call && saw_exit && saw_int && saw_term && saw_lock && saw_test \
        && saw_udid < saw_keep && saw_keep < saw_func && saw_func < saw_call && saw_call < saw_exit \
        && saw_exit < saw_lock && saw_lock < saw_test) print "yes"
  }
' "$gate_src")
if [ "$wired" = yes ]; then
  echo "✓ ④ EXIT／INT／TERM 三個 trap（含專屬機判斷函式）都設在 sim_udid／KEEP_SIMULATOR 判斷之後、真正執行 xcodebuild test（simulator-lock.sh 包住那行）之前"
else
  echo "✗ ④ trap 接線順序不對，或缺了 EXIT／INT／TERM 其中之一（中斷可能來不及關模擬器）" >&2
  fail=1
fi

# ---- ⑤ 共用機（名稱「iPhone 17 Pro」不符合專屬式 `^(LS-[0-9]+|main)-`）→ 不呼叫 shutdown
#        （PR #164 R1 F1：R1 之前不分青紅皂白關掉共用機，會在多 worktree 併發退回共用機時
#        把別人正在用的機器關掉，⑧ 另有完整時序重現）----
: > "$SHUTDOWN_LOG"
out5=$(run_gate STUB_TEST_RC=0 FAKE_DEST_UDID="$shared_udid_test")
if [ ! -s "$SHUTDOWN_LOG" ]; then
  echo "✓ ⑤ 共用機（非專屬式名稱）→ 不呼叫 shutdown"
else
  echo "✗ ⑤ 共用機卻仍呼叫了 shutdown" >&2
  printf '%s\n' "$out5" | sed 's/^/    /' >&2
  fail=1
fi
if printf '%s' "$out5" | grep -qF '非本 worktree 專屬機，跳過 shutdown'; then
  echo "✓ ⑤ 印出「非本 worktree 專屬機，跳過 shutdown」訊息"
else
  echo "✗ ⑤ 未印出跳過訊息" >&2
  fail=1
fi

# ---- ⑥ demo-* 常駐機 → 不呼叫 shutdown（PR #164 R1 F2：demo 環境的持久機在 push-gate.sh／
#        patrol.sh／§6 都刻意豁免；這裡直接控制 sim_udid 指到 demo 機，隔離驗 push-gate.sh 自己
#        這一層防線，不糾纏 detect-simulator.sh 是否會選到它——那部分由 detect-simulator.test.sh ⑩ 專測）----
: > "$SHUTDOWN_LOG"
out6=$(run_gate STUB_TEST_RC=0 FAKE_DEST_UDID="$demo_udid_test")
if [ ! -s "$SHUTDOWN_LOG" ]; then
  echo "✓ ⑥ demo-* 常駐機 → 不呼叫 shutdown"
else
  echo "✗ ⑥ demo-* 常駐機卻仍呼叫了 shutdown" >&2
  printf '%s\n' "$out6" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ⑦ 本 worktree 專屬機，但 shutdown 那一刻鎖目錄仍在（第二道防線；PR #164 R1 F1「另加第二道」）：
#        error-codes-check.sh 換成會 sleep 的假身，貼出一段時間窗——push-gate.sh 自己那段
#        xcodebuild test 的鎖用完幾乎瞬間就放；給它 1 秒頭香確保先跑，接著背景程序合法搶到同一把鎖
#        （模擬「另一個 worktree 正在用這台專屬機」），握著遠比 error-codes-check 的 sleep 長的時間；
#        push-gate.sh 的 EXIT trap 觸發時鎖仍在 → 應跳過 shutdown、印出訊息，且不能在 trap 內重新
#        取鎖（否則會卡到 simulator-lock.sh 的 timeout，同該腳本檔頭理由）。simulator-lock.sh 換成
#        不真的加鎖的假身，避免我們自己手動製造的時序被 push-gate.sh 內部「執行 xcodebuild test」
#        那段鎖擋住（那段鎖不是本案例要驗的對象——⑧ 才是驗真鎖排隊的時序）----
: > "$SHUTDOWN_LOG"
lock7="$work/lock7-dir"
rm -rf "$lock7"
printf '#!/bin/bash\nsleep 4\nexit 0\n' > "$R/scripts/gates/error-codes-check.sh"
chmod +x "$R/scripts/gates/error-codes-check.sh"
cat > "$R/scripts/ops/simulator-lock.sh" <<'STUB'
#!/bin/bash
# ⑦ 專用假身：略過真的 mkdir 鎖，直接執行命令——這個案例要測的是「鎖目錄仍在時 push-gate 的第二道
# 防線」，不是 simulator-lock.sh 本身的排隊行為（那由 ⑧／detect-simulator.test.sh ⑤ 專測）。
while [ $# -gt 0 ]; do
  case "$1" in --) shift; break ;; *) shift ;; esac
done
"$@"
STUB
chmod +x "$R/scripts/ops/simulator-lock.sh"
out7_file="$work/out7.log"
( cd "$R" && env FAKE_DEST_UDID="$ded_udid" STUB_TEST_RC=0 SIMULATOR_LOCK_DIR="$lock7" \
    PATH="$work/bin:$PATH" bash scripts/gates/push-gate.sh </dev/null >"$out7_file" 2>&1 ) &
a7_pid=$!
sleep 1
bash "$work/simulator-lock.sh.real" --dir "$lock7" -- sleep 6 >/dev/null 2>&1 &
holder7_pid=$!
wait "$a7_pid"
cp "$work/simulator-lock.sh.real" "$R/scripts/ops/simulator-lock.sh"   # 還原給後面案例用（目前 ⑦ 是最後一個用 $R 的案例，保守起見仍還原）
if [ ! -s "$SHUTDOWN_LOG" ]; then
  echo "✓ ⑦ shutdown 當下鎖目錄仍在（另一個持有者）→ 跳過，不呼叫 shutdown"
else
  echo "✗ ⑦ 鎖目錄仍在卻仍呼叫了 shutdown" >&2
  printf '%s\n' "$(cat "$out7_file")" | sed 's/^/    /' >&2
  fail=1
fi
if grep -qF '仍在，跳過 shutdown' "$out7_file"; then
  echo "✓ ⑦ 印出跳過訊息（鎖仍在）"
else
  echo "✗ ⑦ 未印出跳過訊息" >&2
  printf '%s\n' "$(cat "$out7_file")" | sed 's/^/    /' >&2
  fail=1
fi
kill "$holder7_pid" 2>/dev/null; wait "$holder7_pid" 2>/dev/null
rm -rf "$lock7"

# ---- ⑧ Race 重現（PR #164 R1 F1；貼近 reviewer 重現腳本 LS-100-review-race.sh 的時間軸）：兩個
#        worktree（各自獨立的合成 repo）同時退回共用機（用真正的 detect-simulator.sh、CI=true 走
#        最簡路徑，兩邊拿到同一顆 UDID、名稱「iPhone 17 Pro」不符合專屬式）；A（TEST_SECONDS 短）先
#        完成 xcodebuild test、B（TEST_SECONDS 長）還在跑時，A 若照舊呼叫 shutdown 就會把 B 正在
#        用的機器關掉（R1 F1 描述的失敗時序：A TEST_END → B TEST_START → A SHUTDOWN ← B 測試中途）。
#        新版行為是「共用機根本不設 shutdown trap」，驗證整段跑完，共用 UDID 從頭到尾沒有被
#        shutdown 過一次——不只是「沒有關在 B 測試中途」，而是「壓根不會關」----
race_root="$work/race"
mk_race_repo() {
  local d=$1
  mkdir -p "$d/scripts/gates" "$d/scripts/ops"
  git -C "$d" init -q -b main
  echo a > "$d/f.txt"
  git -C "$d" -c user.name=t -c user.email=t@t add -A
  git -C "$d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm 'chore: LS-0 seed'
  cp "$gate_src" "$d/scripts/gates/push-gate.sh"
  cp "${root}/scripts/gates/push-ref-check.sh" "$d/scripts/gates/push-ref-check.sh"
  cp "${root}/scripts/gates/detect-simulator.sh" "$d/scripts/gates/detect-simulator.sh"
  cp "${root}/scripts/ops/simulator-lock.sh" "$d/scripts/ops/simulator-lock.sh"
  # 模擬 push-gate 第 3～7 步耗時（真環境要好幾秒；貼近 reviewer 重現腳本）
  printf '#!/bin/bash\nsleep 3\nexit 0\n' > "$d/scripts/gates/error-codes-check.sh"
  chmod +x "$d/scripts/gates/error-codes-check.sh"
  mkdir -p "$d/Fake.xcodeproj"
  # LS-106：1b 步要求 .xcode-version 存在；版本與 racebin 的 stub xcodebuild -version 預設值相同，
  # 讓這組時序重現案例的 1b 判定一致、直接略過，不干擾本案例要驗的東西（見下方 racebin/xcodebuild）。
  printf '99.9\n' > "$d/.xcode-version"
}
mk_race_repo "$race_root/A"
mk_race_repo "$race_root/B"
mkdir -p "$work/racebin"
race_log="$work/race.log"; : > "$race_log"
cat > "$work/racebin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = simctl ] && [ "$2" = list ] && [ "$3" = devices ] && [ "$4" = available ]; then
  echo "== Devices =="; echo "-- iOS 26.0 --"; echo "    iPhone 17 Pro (RACE-SHARED-UDID) (Shutdown)"; exit 0
fi
if [ "$1" = simctl ] && [ "$2" = shutdown ]; then
  printf '%s\t%s\tSHUTDOWN %s\n' "$(date +%s.%N)" "${WHO:-?}" "$3" >> "$RACE_LOG"; exit 0
fi
exit 1
STUB
chmod +x "$work/racebin/xcrun"
cat > "$work/racebin/xcodebuild" <<'STUB'
#!/bin/bash
if [ "$1" = -version ]; then
  printf 'Xcode 99.9\nBuild version ZZ000Z\n'
  exit 0
fi
for a in "$@"; do case "$a" in
  -resolvePackageDependencies) exit 0 ;;
  test) printf '%s\t%s\tTEST_START\n' "$(date +%s.%N)" "${WHO:-?}" >> "$RACE_LOG"
        sleep "${RACE_TEST_SECONDS:-2}"
        printf '%s\t%s\tTEST_END\n' "$(date +%s.%N)" "${WHO:-?}" >> "$RACE_LOG"; exit 0 ;;
esac; done
exit 0
STUB
chmod +x "$work/racebin/xcodebuild"
race_lock="$work/race-simlock"
run_race() {   # $1=A/B目錄 basename、$2=RACE_TEST_SECONDS
  ( cd "$race_root/$1" && env WHO="$1" CI=true RACE_TEST_SECONDS="$2" RACE_LOG="$race_log" \
      SIMULATOR_LOCK_POLL=0.2 SIMULATOR_LOCK_DIR="$race_lock" PATH="$work/racebin:$PATH" \
      bash scripts/gates/push-gate.sh </dev/null >/dev/null 2>&1 )
}
rm -rf "$race_lock"
run_race A 1 & race_pid_a=$!
sleep 0.3
run_race B 4 & race_pid_b=$!
wait "$race_pid_a" "$race_pid_b"
if grep -qF 'SHUTDOWN' "$race_log"; then
  echo "✗ ⑧ Race 重現：共用機（非專屬式名稱）不該被 shutdown，但記錄到 shutdown" >&2
  sort "$race_log" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ⑧ Race 重現：兩個 worktree 同時退回共用機，全程沒有任何一方呼叫 shutdown（F1 修復——共用機根本不設 trap）"
fi
if grep -qF 'TEST_START' "$race_log" && grep -qF 'TEST_END' "$race_log"; then
  echo "✓ ⑧ 兩邊的 xcodebuild test 確實都有跑（不是被跳過整段）"
else
  echo "✗ ⑧ 沒看到完整的 TEST_START／TEST_END——時序沒有真的重現" >&2
  sort "$race_log" | sed 's/^/    /' >&2
  fail=1
fi
rm -rf "$race_lock"

# ---- ⑨ 本 worktree 專屬機、xcrun simctl shutdown 本身失敗（STUB_SHUTDOWN_RC 非 0；LS-106 順手項——
#        STUB_SHUTDOWN_RC 這個旋鈕原本沒有任何案例真的把它設成非 0）：shutdown_dedicated_simulator()
#        用 `|| true` 接住 xcrun 的失敗，不能讓 shutdown 本身失敗拖垮整支 gate 的 exit code ----
: > "$SHUTDOWN_LOG"
out9a=$(run_gate STUB_TEST_RC=0); rc9a=$?
: > "$SHUTDOWN_LOG"
out9b=$(run_gate STUB_TEST_RC=0 STUB_SHUTDOWN_RC=1); rc9b=$?
if grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then
  echo "✓ ⑨ shutdown 失敗（STUB_SHUTDOWN_RC=1）仍有嘗試呼叫 xcrun simctl shutdown"
else
  echo "✗ ⑨ shutdown 失敗時沒有嘗試呼叫 shutdown" >&2
  printf '%s\n' "$out9b" | sed 's/^/    /' >&2
  fail=1
fi
if [ "$rc9a" -eq "$rc9b" ]; then
  echo "✓ ⑨ shutdown 失敗不影響 push-gate.sh 整體 exit code（成功與失敗時相同：${rc9a}）"
else
  echo "✗ ⑨ shutdown 失敗改變了 push-gate.sh 整體 exit code（成功時 ${rc9a}、失敗時 ${rc9b}）" >&2
  printf '%s\n' "$out9b" | sed 's/^/    /' >&2
  fail=1
fi


# ---- ⑩ XcodeGen 漂移（LS-106；PR #165 head 4a3bfa9 同型）：project.yml 生出的 project.pbxproj 與
#        commit 的不同 → push-gate.sh 在到達 xcodebuild 之前就擋，印出與 CI 相同的錯誤訊息。獨立小型
#        synth repo（不共用 $R）——這組案例的重點是 1a 步本身，不需要 $R 既有的模擬器／shutdown 佈線 ----
xg_root="$work/xg"
mkdir -p "$xg_root/scripts/gates"
git -C "$xg_root" init -q -b main
echo a > "$xg_root/f.txt"
git -C "$xg_root" -c user.name=t -c user.email=t@t add -A
git -C "$xg_root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm 'chore: LS-0 seed'
cp "$gate_src" "$xg_root/scripts/gates/push-gate.sh"
cp "${root}/scripts/gates/push-ref-check.sh" "$xg_root/scripts/gates/push-ref-check.sh"
echo 'name: Fake' > "$xg_root/project.yml"
mkdir -p "$xg_root/LittleSprout.xcodeproj"
printf 'PBX-COMMITTED\n' > "$xg_root/LittleSprout.xcodeproj/project.pbxproj"
printf '99.9\n' > "$xg_root/.xcode-version"
mkdir -p "$work/xgbin"
# 假身 xcodegen：不真的解析 project.yml，`generate` 直接把 $STUB_XCODEGEN_OUTPUT 的內容寫成
# project.pbxproj——本組案例要驗的是 push-gate.sh 對 generate 結果與 commit 版本的 diff 判斷，
# 不是 xcodegen 本身的正確性（那由 ubuntu-latest 的 rules job 環境跑不動真正的 xcodegen／Xcode）。
cat > "$work/xgbin/xcodegen" <<'STUB'
#!/bin/bash
if [ "$1" = --version ]; then
  echo "Version: 9.9.9"
  exit 0
fi
if [ "$1" = generate ]; then
  mkdir -p LittleSprout.xcodeproj
  printf '%s\n' "${STUB_XCODEGEN_OUTPUT:-PBX-COMMITTED}" > LittleSprout.xcodeproj/project.pbxproj
  exit 0
fi
exit 1
STUB
chmod +x "$work/xgbin/xcodegen"
out10=$( cd "$xg_root" && env PATH="$work/xgbin:$PATH" STUB_XCODEGEN_OUTPUT="PBX-DIFFERENT" \
  bash scripts/gates/push-gate.sh </dev/null 2>&1 ); rc10=$?
if [ "$rc10" -ne 0 ] && printf '%s' "$out10" | grep -qF '不同步——改 project.yml 後須重跑 xcodegen generate'; then
  echo "✓ ⑩ XcodeGen 漂移（project.pbxproj 與 project.yml 生出的不同）→ push-gate.sh 擋下（exit ${rc10}）並印出與 CI 相同的錯誤訊息"
else
  echo "✗ ⑩ XcodeGen 漂移沒有被擋下（exit ${rc10}）" >&2
  printf '%s\n' "$out10" | sed 's/^/    /' >&2
  fail=1
fi


# ---- ⑪ Xcode 版本與 .xcode-version 不一致（LS-106；PR #165 head 8b7a0fa 同型）→ 只警告，並額外呼叫
#        一次帶 SWIFT_STRICT_CONCURRENCY=complete 的 xcodebuild build（只 build 不測）當替代檢查。沿用
#        $R（已有 detect-simulator／xcrun／xcodebuild 佈線），暫時把 .xcode-version 換成不一致的版本號、
#        跑完就換回，不影響後面（若有）案例 ----
build_log11="$work/build11.log"; : > "$build_log11"
printf '1.0\n' > "$R/.xcode-version"
out11=$(run_gate STUB_TEST_RC=0 BUILD_LOG="$build_log11")
printf '99.9\n' > "$R/.xcode-version"   # 還原
if grep -qF 'SWIFT_STRICT_CONCURRENCY=complete' "$build_log11"; then
  echo "✓ ⑪ 版本不一致 → 呼叫了帶 SWIFT_STRICT_CONCURRENCY=complete 的 xcodebuild build"
else
  echo "✗ ⑪ 版本不一致卻沒有呼叫替代 build，或缺 SWIFT_STRICT_CONCURRENCY=complete" >&2
  echo "    build_log 內容：$(cat "$build_log11" 2>/dev/null)" >&2
  printf '%s\n' "$out11" | sed 's/^/    /' >&2
  fail=1
fi
if printf '%s' "$out11" | grep -qF '主次版號不一致'; then
  echo "✓ ⑪ 印出版本不一致的警告訊息"
else
  echo "✗ ⑪ 未印出版本不一致警告訊息" >&2
  fail=1
fi

# ---- ⑫ Xcode 版本與 .xcode-version 一致（LS-106）→ 略過替代檢查，不呼叫額外的 build ----
build_log12="$work/build12.log"; : > "$build_log12"
out12=$(run_gate STUB_TEST_RC=0 BUILD_LOG="$build_log12")
if [ ! -s "$build_log12" ]; then
  echo "✓ ⑫ 版本一致 → 沒有呼叫替代 build"
else
  echo "✗ ⑫ 版本一致卻仍呼叫了替代 build：$(cat "$build_log12")" >&2
  fail=1
fi
if printf '%s' "$out12" | grep -qF '主次版號一致，略過替代檢查'; then
  echo "✓ ⑫ 印出版本一致、略過替代檢查的訊息"
else
  echo "✗ ⑫ 未印出版本一致訊息" >&2
  printf '%s\n' "$out12" | sed 's/^/    /' >&2
  fail=1
fi


if [ "$fail" -eq 0 ]; then
  echo "✓ push-gate 模擬器自測通過"
fi
exit "$fail"
