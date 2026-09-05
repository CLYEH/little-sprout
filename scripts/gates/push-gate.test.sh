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
# 合成 repo 沒有 docs/API.md／LittleSprout/Errors/AppError.swift／supabase/migrations，所以 api 契約對帳
# （步驟 3）／migration 分級（步驟 5）等「目錄存在才跑」的步驟自然跳過；但 error-codes-check.sh（步驟 4）
# 無條件跑，合成 repo 沒有這支腳本本身。LS-65 之前，步驟 2（xcodebuild）在步驟 4 之前，trap 早已設好，
# 之後不論第幾步造成整支腳本退出都無所謂，這裡才能放著不管、任由步驟 4 找不到腳本而失敗。LS-65 把
# 步驟 3／3b／4／5／6／7 前移到步驟 2 之前後，這個「放著不管」會變成「步驟 2（本檔案真正要驗的模擬器
# shutdown 行為）根本沒機會執行」——所以 setup 一開始就把 error-codes-check.sh stub 成 `exit 0`（⑦
# 另外換成會 sleep 的假身測「鎖仍在時跳過 shutdown」，跑完會還原回這裡的預設假身；hf_root／hf2_root 兩個
# 獨立合成 repo 同理各自補上）。下面只斷言「xcrun simctl shutdown 有沒有被叫到、UDID 對不對」，不糾結
# push-gate.sh 整體的最終 exit code（②除外——那組刻意驗 xcodebuild test 失敗本身會讓整支腳本非 0；⑨
# 另外驗 shutdown 本身失敗不影響整體 exit code）。
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
# R1 I3：新版 1b 對 .xcode-version 缺檔 fail-closed（F5），所以這裡從一開始就要有這個檔——
# 舊版在 ⑪ 才用「還原」的名義第一次建立它，但 $R 從頭到尾沒有這個檔，那句「還原」其實是建立
# （R1 I3 finding）；搬到 setup 這裡建立，後面案例要測不一致/缺檔時才是真的「暫時改掉、跑完還原」。
# 內容與下面 xcodebuild 假身的 STUB_XCODE_VERSION 預設值一致（99.9），讓①～⑨這些不關心 1b 的
# 案例維持「版本一致，略過對齊」路徑，不需要為了 1b 額外調整。
printf '99.9\n' > "$R/.xcode-version"
# LS-205：`.ios-runtime` 是同款 fail-closed 單一來源（比照上面 `.xcode-version` 的 I3 理由）——
# 從一開始就要有這個檔，不然完全跟本檔案模擬器 shutdown 行為無關的案例也會在這裡就先擋下。
printf '26.0\n' > "$R/.ios-runtime"

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
# R1：$DEVELOPER_DIR_LOG 設定時，每次呼叫都記一行「第一個參數\tDEVELOPER_DIR 當下的值」，供
# ⑬ 斷言 push-gate.sh 的 1b 真的把 DEVELOPER_DIR 接到後面每一次 xcodebuild 呼叫（resolve／test）。
if [ -n "${DEVELOPER_DIR_LOG:-}" ]; then
  printf '%s\t%s\n' "${1:-<none>}" "${DEVELOPER_DIR:-<unset>}" >> "$DEVELOPER_DIR_LOG"
fi
# 1b 步先呼叫 `xcodebuild -version`（固定第一個參數）判斷主次版與 .xcode-version 是否一致。
if [ "$1" = -version ]; then
  printf 'Xcode %s\nBuild version %s\n' "${STUB_XCODE_VERSION:-99.9}" "${STUB_XCODE_BUILD:-ZZ000Z}"
  exit 0
fi
for a in "$@"; do
  case "$a" in
    -resolvePackageDependencies) exit 0 ;;
    test)
      # LS-199：STUB_TEST_SCRIPT 設定時改跑該腳本（看門狗自測：掛住／印 crash 樣式／寫假 session log），其 exit code 即測試結果
      if [ -n "${STUB_TEST_SCRIPT:-}" ]; then bash "$STUB_TEST_SCRIPT"; exit $?; fi
      exit "${STUB_TEST_RC:-0}" ;;
    build) printf '%s\n' "$*" >> "${BUILD_LOG:-/dev/null}"; exit "${STUB_BUILD_RC:-0}" ;;
  esac
done
exit 0
STUB
chmod +x "$work/bin/xcodebuild"
# ⑯～⑳（LS-76）：真的加了 .swift 檔到 $R 之後 step 1 的 `git ls-files '*.swift'` 不再是空的，會走到
# 「有 Swift 檔」分支——stub 掉 swiftlint（PATH 前置，蓋過本機真的 swiftlint），不依賴 rules job（ubuntu）
# 是否裝了 swiftlint，也不對這個合成的假 repo 真的跑 lint。
cat > "$work/bin/swiftlint" <<'STUB'
#!/bin/bash
exit "${STUB_SWIFTLINT_RC:-0}"
STUB
chmod +x "$work/bin/swiftlint"

# LS-65：步驟 4（error-codes-check.sh）前移到步驟 2 之前無條件執行，合成 repo 沒有這支腳本——理由見
# 檔頭「合成 repo 沒有 docs/API.md…」那段——這裡先給一個永遠成功的假身，①起的案例才走得到步驟 2。
cat > "$R/scripts/gates/error-codes-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$R/scripts/gates/error-codes-check.sh"

db="$work/devices.db"
printf '%s\t%s\n%s\t%s\n%s\t%s\n' \
  "main-iPhone17Pro" "$ded_udid" \
  "iPhone 17 Pro" "$shared_udid_test" \
  "demo-iPhone17Pro" "$demo_udid_test" > "$db"
export STUB_DB="$db"

SHUTDOWN_LOG="$work/shutdown.log"; export SHUTDOWN_LOG
: > "$SHUTDOWN_LOG"

# LS-95（merge-review R1 m4）：tap-target-check.sh 假身寫入這個 log，證明 push-gate.sh 新增的
# Features/／DesignSystem/ 觸發區塊「有沒有呼叫它」（見上方 tap-target-check.sh stub）。
TAP_TARGET_LOG="$work/tap-target.log"; export TAP_TARGET_LOG
: > "$TAP_TARGET_LOG"

# I2：鎖目錄固定指到 $work 底下（mktemp -d 出來的路徑），不再用 /tmp/simulator-lock-<固定字面值>。
export SIMULATOR_LOCK_DIR="$work/simlock"

# run_gate <env 指定…>：在合成 repo 內跑 push-gate.sh；stdin 接 /dev/null（非 tty）讓開頭的
# push-ref-check.sh 照跑——空 stdin＝seen=0＝exit 0（既有行為，維持完整 gate）。FAKE_DEST_UDID
# 預設本 worktree 專屬機（$ded_udid），呼叫端可在 "$@" 覆寫成共用機／demo 機的 UDID。
run_gate() {
  rm -rf "$SIMULATOR_LOCK_DIR"
  # R1：XCODE_APPS_DIR 預設指到一個不存在的目錄，讓 1b 的 pin 目錄查找在每個案例裡都是「找不到」
  # 起跳、且不受這台跑測試的機器實際裝了什麼 Xcode 影響（否則本機若剛好有 /Applications/Xcode_99.9.app
  # 這種巧合，測試結果會跟著本機環境漂移）；⑬ 用 "$@" 覆寫成真的有 Xcode_<pin>.app 的 stub 目錄。
  # LS-199：GITHUB_ACTIONS 清空——CI rules job 跑本檔時它是 true，push-gate.sh 會跳過看門狗直接前景執行，
  # ㉘～㉛ 的掛住假身就會真的掛到永遠；本機開發機才是看門狗的生產路徑，自測一律走它（㉞ 另外驗 true 時不啟用）。
  ( cd "$R" && env FAKE_DEST_UDID="$ded_udid" PATH="$work/bin:$PATH" \
      XCODE_APPS_DIR="$work/no-such-apps" GITHUB_ACTIONS= "$@" \
      bash scripts/gates/push-gate.sh </dev/null 2>&1 )
}

# run_gate_keep_lock：同 run_gate，但不清空 SIMULATOR_LOCK_DIR（㊲ 專用——驗證「別人持有、非本次看門狗
# 殺掉的子孫」那把鎖不會被誤收，呼叫前得先自己把鎖布置好，run_gate 開頭的 rm -rf 會把它清掉）。
run_gate_keep_lock() {
  ( cd "$R" && env FAKE_DEST_UDID="$ded_udid" PATH="$work/bin:$PATH" \
      XCODE_APPS_DIR="$work/no-such-apps" GITHUB_ACTIONS= "$@" \
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
# LS-205：unit tests 前印出「simulator: <name> <udid> iOS <實際版>（pinned <釘住版>）」可見化那一行
# （合成 repo 的 stub xcrun 只有單一 OS 分節 26.0，`.ios-runtime` 也設 26.0，兩者相符）。
if printf '%s' "$out1" | grep -qE "simulator: main-iPhone17Pro ${ded_udid} iOS 26\.0（pinned 26\.0）"; then
  echo "✓ ① 印出「simulator: <name> <udid> iOS <ver>（pinned <ver>）」（LS-205）"
else
  echo "✗ ① 沒有印出模擬器 runtime 可見化那一行（LS-205）" >&2
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
#        error-codes-check.sh 換成會 sleep 的假身，貼出一段時間窗（LS-65 之後這段 sleep 跑在
#        「執行 xcodebuild test」之前，不是之後——本案例要驗的只是「trap 觸發那一刻鎖是否仍在」，
#        跟 sleep 排在前後無關）：給背景程序 1 秒頭香確保先跑，接著它合法搶到同一把鎖（模擬「另一個
#        worktree 正在用這台專屬機」），握著遠比 error-codes-check 的 sleep 長的時間；push-gate.sh
#        自己那段 xcodebuild test 用的是下面的假鎖（近乎瞬間跑完），trap 因此幾乎緊接在 sleep 結束後
#        觸發，此時背景程序仍握著鎖 → 應跳過 shutdown、印出訊息，且不能在 trap 內重新取鎖（否則會卡到
#        simulator-lock.sh 的 timeout，同該腳本檔頭理由）。simulator-lock.sh 換成不真的加鎖的假身，
#        避免我們自己手動製造的時序被 push-gate.sh 內部「執行 xcodebuild test」那段鎖擋住（那段鎖不是
#        本案例要驗的對象——⑧ 才是驗真鎖排隊的時序）----
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
# LS-65：⑦專用的 sleep 4 假身還原回 setup 節的預設「成功」假身——不還原的話，後面重複用 $R 的
# 案例（⑨、⑫～㉖）每個 run_gate 都會平白多等 4 秒（步驟 4 現在跑在步驟 2 之前）。
cat > "$R/scripts/gates/error-codes-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$R/scripts/gates/error-codes-check.sh"
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
  # 模擬 push-gate 第 3～7 步耗時（真環境要好幾秒；LS-65 之後這幾步跑在「執行 xcodebuild test」之前，
  # 不是之後——sleep 一樣代表這段耗時，只是現在發生在兩個 worktree 各自搶鎖之前，不影響下面 ⑧ 要驗的
  # 東西：真鎖有沒有讓兩邊的 xcodebuild test 各自序列排隊、共用機全程不設 shutdown trap）
  printf '#!/bin/bash\nsleep 3\nexit 0\n' > "$d/scripts/gates/error-codes-check.sh"
  chmod +x "$d/scripts/gates/error-codes-check.sh"
  mkdir -p "$d/Fake.xcodeproj"
  # LS-106：1b 步要求 .xcode-version 存在；版本與 racebin 的 stub xcodebuild -version 預設值相同，
  # 讓這組時序重現案例的 1b 判定一致、直接略過，不干擾本案例要驗的東西（見下方 racebin/xcodebuild）。
  printf '99.9\n' > "$d/.xcode-version"
  printf '26.0\n' > "$d/.ios-runtime"   # LS-205：同款單一來源，fail-closed
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
mkdir -p "$xg_root/LittleSprout.xcodeproj/xcshareddata/xcschemes"
printf 'PBX-COMMITTED\n' > "$xg_root/LittleSprout.xcodeproj/project.pbxproj"
# R1 F1：committed 版本也要有 xcscheme，才能驗「pbxproj 相同、xcscheme 不同」這個舊版漏放的案例（⑪）。
printf 'SCHEME-COMMITTED\n' > "$xg_root/LittleSprout.xcodeproj/xcshareddata/xcschemes/LittleSprout.xcscheme"
printf '99.9\n' > "$xg_root/.xcode-version"
printf '26.0\n' > "$xg_root/.ios-runtime"   # LS-205：同款單一來源，fail-closed
mkdir -p "$work/xgbin"
# 假身 xcodegen：不真的解析 project.yml，`generate` 直接把 $STUB_XCODEGEN_OUTPUT／$STUB_XCODEGEN_SCHEME
# 的內容寫成 project.pbxproj／xcscheme——本組案例要驗的是 push-gate.sh 對 generate 結果與 commit 版本的
# diff 判斷，不是 xcodegen 本身的正確性（那由 ubuntu-latest 的 rules job 環境跑不動真正的 xcodegen／Xcode）。
cat > "$work/xgbin/xcodegen" <<'STUB'
#!/bin/bash
if [ "$1" = --version ]; then
  echo "Version: 9.9.9"
  exit 0
fi
if [ "$1" = generate ]; then
  mkdir -p LittleSprout.xcodeproj/xcshareddata/xcschemes
  printf '%s\n' "${STUB_XCODEGEN_OUTPUT:-PBX-COMMITTED}" > LittleSprout.xcodeproj/project.pbxproj
  printf '%s\n' "${STUB_XCODEGEN_SCHEME:-SCHEME-COMMITTED}" > LittleSprout.xcodeproj/xcshareddata/xcschemes/LittleSprout.xcscheme
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

# ---- ⑪ XcodeGen 漂移：project.pbxproj 相同、只有 xcscheme 不同（R1 F1；PR review 實測重現——改
#        project.yml 的 parallelizable 卻沒重跑 xcodegen 同型）→ 舊版 1a 只 diff project.pbxproj，這個
#        情境會本機綠、CI 紅；新版走訪暫存目錄產生側的整個檔案集合逐檔比對，仍要擋下 ----
out11=$( cd "$xg_root" && env PATH="$work/xgbin:$PATH" STUB_XCODEGEN_SCHEME="SCHEME-DIFFERENT" \
  bash scripts/gates/push-gate.sh </dev/null 2>&1 ); rc11=$?
if [ "$rc11" -ne 0 ] && printf '%s' "$out11" | grep -qF 'xcshareddata/xcschemes/LittleSprout.xcscheme'; then
  echo "✓ ⑪ project.pbxproj 相同、僅 xcscheme 不同 → 仍被擋下（exit ${rc11}），差異檔清單含 xcscheme（R1 F1 負向控制：拿掉 F1 修法這組會轉綠）"
else
  echo "✗ ⑪ project.pbxproj 相同但 xcscheme 不同時沒有被擋下（exit ${rc11}）——舊版「只比 project.pbxproj」的洞還在" >&2
  printf '%s\n' "$out11" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ⑫ .xcode-version 不存在（R1 F5）→ push-gate.sh fail-closed 擋下，與 CI 的 xcode-select 步驟
#        缺檔必紅一致；暫時搬走、跑完搬回，不影響後面案例 ----
mv "$R/.xcode-version" "$work/xcode-version.bak"
out12=$(run_gate); rc12=$?
mv "$work/xcode-version.bak" "$R/.xcode-version"
if [ "$rc12" -ne 0 ] && printf '%s' "$out12" | grep -qF '缺 .xcode-version'; then
  echo "✓ ⑫ .xcode-version 不存在 → push-gate.sh 擋下（exit ${rc12}），fail-closed 與 CI 一致"
else
  echo "✗ ⑫ .xcode-version 缺檔時沒有被擋下（exit ${rc12}）" >&2
  printf '%s\n' "$out12" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ⑬ pin 的 Xcode 本機已安裝（R1 F2 (b)；stub XCODE_APPS_DIR 模擬 /Applications/Xcode_<pin>.app
#        存在）→ 整支 gate 剩下的 xcodebuild 呼叫全部改用該 DEVELOPER_DIR，不論本機預設工具鏈版本
#        是否已經一致 ----
devdir_log13="$work/devdir13.log"; : > "$devdir_log13"
pinned_root13="$work/pinned-apps-13"
mkdir -p "$pinned_root13/Xcode_99.9.app/Contents/Developer"
out13=$(run_gate STUB_TEST_RC=0 DEVELOPER_DIR_LOG="$devdir_log13" XCODE_APPS_DIR="$pinned_root13")
if printf '%s' "$out13" | grep -qF '本次 push gate 剩下的 xcodebuild 全部改用此版本執行'; then
  echo "✓ ⑬ pin 的 Xcode 本機已安裝（stub 目錄）→ 印出對齊訊息"
else
  echo "✗ ⑬ pin 目錄存在卻沒有印出對齊訊息" >&2
  printf '%s\n' "$out13" | sed 's/^/    /' >&2
  fail=1
fi
resolve_line13=$(printf '%s\t%s' '-resolvePackageDependencies' "${pinned_root13}/Xcode_99.9.app/Contents/Developer")
test_line13=$(printf '%s\t%s' 'test' "${pinned_root13}/Xcode_99.9.app/Contents/Developer")
if grep -qF "$resolve_line13" "$devdir_log13" && grep -qF "$test_line13" "$devdir_log13"; then
  echo "✓ ⑬ DEVELOPER_DIR 確實接線到 xcodebuild 的 SPM 解析與 test 呼叫（真的對齊，不是只印訊息）"
else
  echo "✗ ⑬ DEVELOPER_DIR 沒有接線到 xcodebuild 呼叫" >&2
  echo "    devdir_log 內容：$(cat "$devdir_log13" 2>/dev/null)" >&2
  fail=1
fi

# ---- ⑭ pin 的 Xcode 本機未安裝、且與本機預設版本不一致（R1 F2 (a)）→ 只印警告＋安裝建議，不再
#        呼叫任何額外 build（R1 F3 隨之自然解：沒有 build-only 步驟需要顧慮鎖） ----
build_log14="$work/build14.log"; : > "$build_log14"
printf '1.0\n' > "$R/.xcode-version"
out14=$(run_gate STUB_TEST_RC=0 BUILD_LOG="$build_log14")
printf '99.9\n' > "$R/.xcode-version"   # 還原（setup 建立的版本）
if printf '%s' "$out14" | grep -qF '本機未安裝 pin 版本' && printf '%s' "$out14" | grep -qF 'xcodes install 1.0'; then
  echo "✓ ⑭ 版本不一致且 pin 目錄不存在 → 印出警告＋安裝建議"
else
  echo "✗ ⑭ 版本不一致時的警告訊息不完整" >&2
  printf '%s\n' "$out14" | sed 's/^/    /' >&2
  fail=1
fi
if [ ! -s "$build_log14" ]; then
  echo "✓ ⑭ 沒有呼叫任何額外 build（替代 build 已移除）"
else
  echo "✗ ⑭ 版本不一致卻仍呼叫了額外 build：$(cat "$build_log14")" >&2
  fail=1
fi

# ---- ⑮ 版本一致（本機／.xcode-version 皆預設值，pin 目錄不存在）→ 印出略過對齊訊息，不需要
#        DEVELOPER_DIR 介入 ----
out15=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out15" | grep -qF '主次版號一致，略過對齊'; then
  echo "✓ ⑮ 版本一致 → 印出略過對齊訊息"
else
  echo "✗ ⑮ 版本一致時未印出略過對齊訊息" >&2
  printf '%s\n' "$out15" | sed 's/^/    /' >&2
  fail=1
fi


# ---- ⑯～㉑（LS-76）：本分支相對 target 無 Swift／專案檔變更 → 跳過 SwiftLint／unit tests 兩步；有
#        Swift／`.swiftlint.yml`／`Config/*.xcconfig`／`.xcode-version` 變更 → 兩步照跑；target ref 未
#        fetch → 不跳過（安全預設，退回原行為，不是新的失敗模式）。⑳／㉑（R1 F1／F2）：xcconfig 與
#        .xcode-version 是 R1 review 抓到的 allowlist 缺口——xcconfig 是 project.yml configFiles 指向的
#        live build-config（LS-49：格式錯會啟動崩潰），內容不寫進 pbxproj，改前不會命中任何既有 pattern。
#        沿用 $R（已有 Fake.xcodeproj／.xcode-version／stub bin）——①～⑮ 全程跑在
#        $R 的 main 分支，落在新邏輯的排除清單（main/test/development/DETACHED）內，skip_swift_steps
#        恆為 0，這就是為什麼那十五組案例完全不必為了本票修改就能繼續通過（見 push-gate.sh 0b 節的排除
#        清單）；本節案例切到 feature／hotfix 分支，會第一次讓 push-gate.sh 走到第 6／7 步
#        （branch-ticket-check.sh／merge-conflict-check.sh，非保護分支一律要跑）——這兩支各自有專屬
#        自測（branch-ticket-check.test.sh／merge-conflict-check.test.sh），這裡不重覆驗證它們的行為，
#        比照本檔案對 detect-simulator.sh 的既有作法，換成無條件放行的假身，只隔離驗證本票新增的
#        skip_swift_steps 邏輯。先加一個「基準」Swift 檔到 origin/development，讓 git ls-files 探得到
#        Swift 檔（觸發 SwiftLint 步驟的外層判斷），但這個基準檔本身不在任何一個案例分支「相對
#        origin/development 的 diff」裡（早就在 target 裡了），不影響各案例的跳過判定 ----
cat > "$R/scripts/gates/branch-ticket-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$R/scripts/gates/branch-ticket-check.sh"
cat > "$R/scripts/gates/merge-conflict-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$R/scripts/gates/merge-conflict-check.sh"
mkdir -p "$R/LittleSprout"
echo 'struct Baseline {}' > "$R/LittleSprout/Baseline.swift"
g add LittleSprout/Baseline.swift
g commit -qm 'chore: LS-0 baseline swift for ls-files probe'
# LS-205 R2：`.ios-runtime` 併進這個基準 commit（只加這一個檔，不是 `-A`——`.xcode-version` 仍要
# 維持「origin/development 從未追蹤過」的既有假設，好幾個既有案例故意靠這點測方向矩陣／未 fetch
# 分支）。跟 `.xcode-version` 不同：`.ios-runtime` 沒有任何案例測「它相對 origin/development 的
# diff」，只是單純需要「存在、有個值」讓 push-gate.sh 的 fail-closed 不擋——併進基準後所有從
# origin/development 切出的分支都天生帶著它，不必像 `.xcode-version` 那樣每個案例各自
# `printf > $R/.xcode-version` 重建一次（那個重建模式是為了保留「從未追蹤」這個測試前提，這裡
# 沒有這個前提要保留，直接併進基準最省事）。
g add .ios-runtime
g commit -qm 'chore: LS-205 baseline ios-runtime for fail-closed check'
g update-ref refs/remotes/origin/development HEAD

# LS-95（merge-review R1 m4）：tap-target-check.sh 假身——記一行到 $TAP_TARGET_LOG 證明「真的被
# 呼叫」，不驗 XCUITest 量測本身（那是 tap-target-check.test.sh／LittleSproutUITests 的責任，見
# tap-target-check.sh 檔頭注解），只驗 push-gate.sh 新增的 Features/／DesignSystem/ 觸發區塊
# 有沒有正確決定「這次要不要呼叫它」。
cat > "$R/scripts/gates/tap-target-check.sh" <<'STUB'
#!/bin/bash
printf 'called udid=%s scheme=%s\n' "$1" "$2" >> "${TAP_TARGET_LOG:?TAP_TARGET_LOG 未設定}"
exit "${STUB_TAP_TARGET_RC:-0}"
STUB
chmod +x "$R/scripts/gates/tap-target-check.sh"
# 3b（LS-95 M1）新增的 Features 畫面覆蓋對帳步驟——一旦 $R 出現 LittleSprout/Features/ 目錄
# 就會無條件跑，跟本檔要驗的「tap-target-check.sh 觸發區塊」是不同的關注點，這裡放行即可。
cat > "$R/scripts/gates/tap-target-registry-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$R/scripts/gates/tap-target-registry-check.sh"

# ⑯ feature 分支只改文件（docs/foo.md）→ SwiftLint／unit tests 兩步都印跳過訊息，且完全不呼叫模擬器
#    （驗收：純文件 PR 在 30 秒內完成——不進 xcodebuild 分支就不會被模擬器啟動 flake 拖住）
: > "$SHUTDOWN_LOG"
g checkout -q -b feature/LS-76-docs-only origin/development
mkdir -p "$R/docs"; echo doc > "$R/docs/foo.md"; g add docs/foo.md; g commit -qm 'docs: LS-76 demo'
out16=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out16" | grep -qF '無 Swift 變更，跳過 SwiftLint' && printf '%s' "$out16" | grep -qF '無 Swift 變更，跳過 unit tests'; then
  echo "✓ ⑯ 只改文件（相對 origin/development）→ SwiftLint／unit tests 兩步都印出跳過訊息"
else
  echo "✗ ⑯ 只改文件時沒有印出兩步的跳過訊息" >&2
  printf '%s\n' "$out16" | sed 's/^/    /' >&2
  fail=1
fi
if [ ! -s "$SHUTDOWN_LOG" ]; then
  echo "✓ ⑯ 只改文件 → 完全沒有模擬器 shutdown 呼叫（沒有進 xcodebuild test 分支）"
else
  echo "✗ ⑯ 只改文件卻仍呼叫了模擬器 shutdown（不該進 xcodebuild 分支）" >&2
  fail=1
fi

# ⑰ 同一分支再改一個 Swift 檔（LittleSprout/Foo.swift）→ 兩步都照跑（不印跳過訊息，真的執行 unit
#    tests、模擬器有 shutdown）——驗「含 Swift 變更的 PR 行為不變」
: > "$SHUTDOWN_LOG"
mkdir -p "$R/LittleSprout"; echo 'struct Foo {}' > "$R/LittleSprout/Foo.swift"; g add LittleSprout/Foo.swift; g commit -qm 'feat: LS-76 demo swift'
out17=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out17" | grep -qF '無 Swift 變更'; then
  echo "✗ ⑰ 改了 Swift 檔卻仍被判定跳過" >&2
  printf '%s\n' "$out17" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ⑰ 改 Swift 檔 → 不印跳過訊息"
fi
if printf '%s' "$out17" | grep -qF '執行 unit tests' && grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then
  echo "✓ ⑰ 改 Swift 檔 → unit tests 正常照跑（真的執行、模擬器有 shutdown，行為與改動前一致）"
else
  echo "✗ ⑰ 改 Swift 檔時 unit tests 沒有正常執行" >&2
  printf '%s\n' "$out17" | sed 's/^/    /' >&2
  fail=1
fi

# ⑱ 只改 .swiftlint.yml（非 .swift 檔本身）→ 仍判定為「有變更」，不跳過（regex 命中 .swiftlint.yml 分支，
#    獨立乾淨分支，不與 ⑰ 的 Foo.swift 糾纏）
g checkout -q -b feature/LS-76-lintcfg origin/development
printf 'disabled_rules: []\n' > "$R/.swiftlint.yml"
g add .swiftlint.yml; g commit -qm 'chore: LS-76 demo swiftlint yml'
out18=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out18" | grep -qF '無 Swift 變更'; then
  echo "✗ ⑱ 只改 .swiftlint.yml 卻仍被判定跳過" >&2
  printf '%s\n' "$out18" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ⑱ 只改 .swiftlint.yml（非 .swift 檔）→ 仍判定為有變更，不跳過"
fi

# ⑲ target ref 未 fetch（origin/development 被刪除，模擬本機還沒 fetch 過）→ 不跳過，退回原行為
#    （安全預設：抓不到 target 就不省這步，不是新的失敗模式）
g checkout -q -b feature/LS-76-noref origin/development
mkdir -p "$R/docs"; echo doc > "$R/docs/bar.md"; g add docs/bar.md; g commit -qm 'docs: LS-76 demo no ref'
g update-ref -d refs/remotes/origin/development
: > "$SHUTDOWN_LOG"
out19=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out19" | grep -qF '無 Swift 變更'; then
  echo "✗ ⑲ target ref 不存在時不應跳過，卻印出了跳過訊息" >&2
  printf '%s\n' "$out19" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ⑲ origin/development 不存在（未 fetch）→ 不跳過，退回原行為（安全預設）"
fi
g update-ref refs/remotes/origin/development HEAD   # 還原，避免影響後面若有更多案例

# ⑳ R1 F1（major）：只改 Config/Base.xcconfig（非 .swift／.xcodeproj／project.yml）→ 仍判定為「有變更」，
#    不跳過——這是 project.yml 的 configFiles 指向的 live build-config（注入 SUPABASE_URL／ANON_KEY，
#    LS-49：格式錯會啟動崩潰），xcconfig 內容不寫進 pbxproj，改前（R1 review 當下）不會命中任何既有
#    pattern，是本票 R1 才補上的 allowlist 缺口
g checkout -q -b feature/LS-76-xcconfig origin/development
: > "$SHUTDOWN_LOG"
mkdir -p "$R/Config"; printf 'SUPABASE_URL = https://example.test\n' > "$R/Config/Base.xcconfig"
g add Config/Base.xcconfig; g commit -qm 'chore: LS-76 demo xcconfig'
out20=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out20" | grep -qF '無 Swift 變更'; then
  echo "✗ ⑳ 只改 Config/Base.xcconfig 卻仍被判定跳過（R1 F1 的回歸：live build-config 誤跳本機 build/test）" >&2
  printf '%s\n' "$out20" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ⑳ 只改 Config/Base.xcconfig（非 .swift／.xcodeproj／project.yml）→ 仍判定為有變更，不跳過（R1 F1）"
fi
if printf '%s' "$out20" | grep -qF '執行 unit tests' && grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then
  echo "✓ ⑳ 只改 xcconfig → unit tests 真的照跑（不是只印訊息，模擬器有 shutdown）"
else
  echo "✗ ⑳ 只改 xcconfig 時 unit tests 沒有正常執行" >&2
  printf '%s\n' "$out20" | sed 's/^/    /' >&2
  fail=1
fi

# ㉑ R1 F2（minor）：只改 .xcode-version（bump Xcode pin）→ 同理仍判定為有變更，不跳過（連帶不會誤跳
#    1b 工具鏈對齊步）
g checkout -q -b feature/LS-76-xcodeversion origin/development
printf '100.0\n' > "$R/.xcode-version"
g add .xcode-version; g commit -qm 'chore: LS-76 demo xcode-version bump'
out21=$(run_gate STUB_TEST_RC=0)
printf '99.9\n' > "$R/.xcode-version"   # 還原（setup 建立的版本；未 commit，run_gate 用的是 working tree 內容）
if printf '%s' "$out21" | grep -qF '無 Swift 變更'; then
  echo "✗ ㉑ 只改 .xcode-version 卻仍被判定跳過（R1 F2 的回歸：連帶誤跳 1b 工具鏈對齊）" >&2
  printf '%s\n' "$out21" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ㉑ 只改 .xcode-version（非 .swift／.xcodeproj／project.yml）→ 仍判定為有變更，不跳過（R1 F2）"
fi

# ---- ㉒（LS-76）：hotfix/* 分支的 target 是 origin/main，不是 origin/development（方向矩陣須與第
#        5／7 步一致）。獨立小 repo：origin/main 落後（僅純文件狀態）、origin/development 領先一個
#        Swift 變更（模擬 development 已經合併別票）；hotfix 分支從 origin/development 切出、只再加一個
#        文件變更——若誤用 origin/development 當 target，會判定「無 Swift 變更」而跳過；用正確的
#        origin/main 才會判定「有 Swift 變更」（Bar.swift 相對 main 是新增）而不跳過。用 push-gate.sh 既有
#        「尚未建立 Xcode 專案」訊息（此 repo 沒有 xcodeproj）與 LS-76 的「無 Swift 變更，跳過」訊息互斥，
#        精準區分兩種路徑 ----
hf_root="$work/hotfix-target"
mkdir -p "$hf_root/scripts/gates"
git -C "$hf_root" init -q -b main
gh_() { git -C "$hf_root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
echo a > "$hf_root/f.txt"; gh_ add -A; gh_ commit -qm 'chore: LS-0 seed'
cp "$gate_src" "$hf_root/scripts/gates/push-gate.sh"
cp "${root}/scripts/gates/push-ref-check.sh" "$hf_root/scripts/gates/push-ref-check.sh"
cat > "$hf_root/scripts/gates/branch-ticket-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$hf_root/scripts/gates/branch-ticket-check.sh"
cat > "$hf_root/scripts/gates/merge-conflict-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$hf_root/scripts/gates/merge-conflict-check.sh"
# LS-65：步驟 4 前移到步驟 2（本案例要驗的「尚未建立 Xcode 專案」訊息就在步驟 2 裡）之前，
# 同 setup 節理由，這個獨立合成 repo 也要補一份會成功的假身。
cat > "$hf_root/scripts/gates/error-codes-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$hf_root/scripts/gates/error-codes-check.sh"
gh_ update-ref refs/remotes/origin/main HEAD
gh_ checkout -q -b development
mkdir -p "$hf_root/LittleSprout"; echo 'struct Bar {}' > "$hf_root/LittleSprout/Bar.swift"
gh_ add LittleSprout/Bar.swift; gh_ commit -qm 'feat: LS-77 demo swift on development'
gh_ update-ref refs/remotes/origin/development HEAD
gh_ checkout -q -b hotfix/LS-76-demo
mkdir -p "$hf_root/docs"; echo doc > "$hf_root/docs/hotfix.md"
gh_ add docs/hotfix.md; gh_ commit -qm 'docs: LS-76 hotfix demo'
out22=$( cd "$hf_root" && env PATH="$work/bin:$PATH" bash scripts/gates/push-gate.sh </dev/null 2>&1 ); rc22=$?
if printf '%s' "$out22" | grep -qF '無 Swift 變更，跳過 unit tests'; then
  echo "✗ ㉒ hotfix 分支被誤判「無 Swift 變更」——方向矩陣可能誤用了 origin/development 當 target" >&2
  printf '%s\n' "$out22" | sed 's/^/    /' >&2
  fail=1
elif printf '%s' "$out22" | grep -qF '尚未建立 Xcode 專案，跳過 unit tests'; then
  echo "✓ ㉒ hotfix/* 分支的 target 正確地是 origin/main（不是 origin/development）：相對 main 判定為有 Swift 變更（Bar.swift 是 development 已領先的內容），不誤判跳過"
else
  echo "✗ ㉒ 預期看到「尚未建立 Xcode 專案」訊息（本 synth repo 沒有 xcodeproj），實際輸出不符（exit ${rc22}）" >&2
  printf '%s\n' "$out22" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ㉓～㉖（LS-95 merge-review R1 m4）：push-gate.sh 新增的 ≥44pt 點擊目標 gate 觸發區塊
#        （Features/／DesignSystem/ diff 比對、方向矩陣、target ref 找不到就跳過）先前一條測試
#        都沒有——既有 ⑯～㉒ 全部只驗 LS-76 那組 skip_swift_steps 判斷，寫反了不會有任何測試
#        紅。這裡用上面新增的 tap-target-check.sh 假身（記錄呼叫到 $TAP_TARGET_LOG）驗證 ----

# ㉑ 最後一步把 .xcode-version 工作目錄內容改回 99.9 但沒 commit（該分支 HEAD 仍是 100.0）——
# 這裡是本檔第一個在 ㉑ 之後於 $R 上再切分支的案例，先 commit 這個還原，工作目錄才乾淨、能切
# 分支（否則 `git checkout -b` 會因為 .xcode-version 有未 commit 的異動而拒絕，且不會是「切換
# 失敗、指令中止」這麼乾脆——後面的 mkdir/commit 會誤植到還沒切走的舊分支上，讓案例之間互相
# 汙染而給出偽陽性）。
g add .xcode-version; g commit -qm 'chore: LS-95 test checkpoint restore xcode-version to 99.9'

# ㉑b（LS-205 R2；merge-review R1 m1）：只改 .ios-runtime（CI runtime 釘住版 bump）→ 同理仍判定為
#    有變更，不跳過——本 PR 自己在 worktree 實跑就重現過這個 bug（改了 .ios-runtime，push-gate.sh
#    印「無 Swift 變更，跳過」）；CI runner 升版時最需要在新 runtime 上跑一次 unit tests，偏偏最容易
#    被本機這條捷徑跳過。$R 在上一行已經 commit 乾淨（同 ㉑ 尾端的既有作法），這裡才能安全
#    `checkout -q -b`，不必 `-f`。
g checkout -q -b feature/LS-205-iosruntime origin/development
printf '99.9\n' > "$R/.xcode-version"   # origin/development 從未含這個檔（同 ⑯～㉑ 的既有作法：未 commit、只在工作目錄）
printf '26.3\n' > "$R/.ios-runtime"
g add .ios-runtime; g commit -qm 'chore: LS-205 demo ios-runtime bump'
out21b=$(run_gate STUB_TEST_RC=0)
if printf '%s' "$out21b" | grep -qF '無 Swift 變更'; then
  echo "✗ ㉑b 只改 .ios-runtime 卻仍被判定跳過（m1 的回歸：CI runtime 升版時本機不會跑一次 unit tests）" >&2
  printf '%s\n' "$out21b" | sed 's/^/    /' >&2
  fail=1
else
  echo "✓ ㉑b 只改 .ios-runtime（非 .swift／.xcodeproj／project.yml）→ 仍判定為有變更，不跳過（merge-review R1 m1）"
fi
# 還原並直接 commit（同 ㉑ 結尾那句的既有模式，不留 dirty）——下一案（㉓）要在 $R 上再切一次
# 分支，得先讓工作目錄乾淨，`checkout -q -b` 才不會被 `.ios-runtime` 的未 commit 異動拒絕。
printf '26.0\n' > "$R/.ios-runtime"
g add .ios-runtime; g commit -qm 'chore: LS-205 revert ios-runtime for test isolation'

# ㉓ feature 分支 diff 含 Features/ → tap-target-check.sh 被呼叫
g checkout -q -b feature/LS-95-features-diff origin/development
printf '99.9\n' > "$R/.xcode-version"   # origin/development 從未含這個檔（同 ⑯～㉑ 的既有作法：未 commit、只在工作目錄）
mkdir -p "$R/LittleSprout/Features"; echo 'struct NewScreen: View {}' > "$R/LittleSprout/Features/NewScreenView.swift"
g add LittleSprout/Features/NewScreenView.swift; g commit -qm 'feat: LS-95 demo features diff'
: > "$TAP_TARGET_LOG"
out23=$(run_gate STUB_TEST_RC=0)
if grep -qF 'called' "$TAP_TARGET_LOG"; then
  echo "✓ ㉓ diff 含 Features/ → tap-target-check.sh 有被呼叫"
else
  echo "✗ ㉓ diff 含 Features/ 卻沒有呼叫 tap-target-check.sh" >&2
  printf '%s\n' "$out23" | sed 's/^/    /' >&2
  fail=1
fi

# ㉔ feature 分支 diff 含 DesignSystem/（merge-review R1 m1）→ tap-target-check.sh 被呼叫
g checkout -q -b feature/LS-95-designsystem-diff origin/development
printf '99.9\n' > "$R/.xcode-version"
mkdir -p "$R/LittleSprout/DesignSystem"; echo 'struct NewToken {}' > "$R/LittleSprout/DesignSystem/NewToken.swift"
g add LittleSprout/DesignSystem/NewToken.swift; g commit -qm 'feat: LS-95 demo designsystem diff'
: > "$TAP_TARGET_LOG"
out24=$(run_gate STUB_TEST_RC=0)
if grep -qF 'called' "$TAP_TARGET_LOG"; then
  echo "✓ ㉔ diff 含 DesignSystem/ → tap-target-check.sh 有被呼叫（R1 m1）"
else
  echo "✗ ㉔ diff 含 DesignSystem/ 卻沒有呼叫 tap-target-check.sh（R1 m1 的回歸）" >&2
  printf '%s\n' "$out24" | sed 's/^/    /' >&2
  fail=1
fi

# ㉕ mutation-style 負控：feature 分支 diff 只有非 UI 的 Swift 變更（Services/）→ 不該呼叫
#    tap-target-check.sh（不是每個 Swift 變更都要付 XCUITest 開 app 的成本）
g checkout -q -b feature/LS-95-services-diff origin/development
printf '99.9\n' > "$R/.xcode-version"
mkdir -p "$R/LittleSprout/Services"; echo 'struct NewService {}' > "$R/LittleSprout/Services/NewService.swift"
g add LittleSprout/Services/NewService.swift; g commit -qm 'feat: LS-95 demo services-only diff'
: > "$TAP_TARGET_LOG"
out25=$(run_gate STUB_TEST_RC=0)
if [ ! -s "$TAP_TARGET_LOG" ]; then
  echo "✓ ㉕ diff 只有 Services/（非 Features／DesignSystem）→ 不呼叫 tap-target-check.sh"
else
  echo "✗ ㉕ diff 只有 Services/ 卻仍呼叫了 tap-target-check.sh（觸發條件過寬）" >&2
  printf '%s\n' "$out25" | sed 's/^/    /' >&2
  fail=1
fi

# ㉖ hotfix/* 分支的方向矩陣須用 origin/main（同 ㉒ 的道理，但這裡驗的是 tap-target 觸發區塊，
#    不是 LS-76 skip_swift_steps）：獨立小 repo，origin/main 落後、origin/development 領先一個
#    Features 變更（模擬 development 已合併別票），hotfix 分支從 origin/development 切出、只再
#    加一個 Features 變更——若誤用 origin/development 當 target，NewOnDev.swift 已經在 target
#    裡、不會出現在「相對 target 的 diff」中，只剩 hotfix 自己那個 Features 檔——兩種 target 這裡
#    都會觸發，所以改用「只加一個非 UI 檔在 hotfix 分支、Features 變更留在 development」來讓兩個
#    target 產生不同結果：用 origin/development 當 target（誤）→ diff 不含 Features/，不觸發；
#    用 origin/main 當 target（對）→ diff 含 development 帶來的 Features/，觸發
hf2_root="$work/hotfix-target-2"
mkdir -p "$hf2_root/scripts/gates" "$hf2_root/scripts/ops" "$hf2_root/Fake.xcodeproj"
git -C "$hf2_root" init -q -b main
gh2_() { git -C "$hf2_root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
echo a > "$hf2_root/f.txt"; gh2_ add -A; gh2_ commit -qm 'chore: LS-0 seed'
printf '99.9\n' > "$hf2_root/.xcode-version"
printf '26.0\n' > "$hf2_root/.ios-runtime"   # LS-205：同款單一來源，fail-closed
cp "$gate_src" "$hf2_root/scripts/gates/push-gate.sh"
cp "${root}/scripts/gates/push-ref-check.sh" "$hf2_root/scripts/gates/push-ref-check.sh"
cp "${root}/scripts/ops/simulator-lock.sh" "$hf2_root/scripts/ops/simulator-lock.sh"
cat > "$hf2_root/scripts/gates/detect-simulator.sh" <<EOF
#!/bin/bash
printf 'platform=iOS Simulator,id=%s\n' "\${FAKE_DEST_UDID:-$ded_udid}"
EOF
chmod +x "$hf2_root/scripts/gates/detect-simulator.sh"
# LS-65：error-codes-check.sh（步驟 4）併入這裡一起 stub——同 hf_root／setup 節理由，步驟 4 前移到
# 步驟 2（本案例要驗的 tap-target-check.sh 呼叫就在步驟 2 裡）之前，找不到腳本會讓步驟 2 永遠跑不到。
for s in branch-ticket-check.sh merge-conflict-check.sh error-codes-check.sh; do
  cat > "$hf2_root/scripts/gates/$s" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$hf2_root/scripts/gates/$s"
done
cat > "$hf2_root/scripts/gates/tap-target-check.sh" <<'STUB'
#!/bin/bash
printf 'called udid=%s scheme=%s\n' "$1" "$2" >> "${TAP_TARGET_LOG:?TAP_TARGET_LOG 未設定}"
exit "${STUB_TAP_TARGET_RC:-0}"
STUB
chmod +x "$hf2_root/scripts/gates/tap-target-check.sh"
cat > "$hf2_root/scripts/gates/tap-target-registry-check.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$hf2_root/scripts/gates/tap-target-registry-check.sh"
gh2_ update-ref refs/remotes/origin/main HEAD
gh2_ checkout -q -b development
mkdir -p "$hf2_root/LittleSprout/Features"
echo 'struct OnDev: View {}' > "$hf2_root/LittleSprout/Features/OnDevView.swift"
gh2_ add LittleSprout/Features/OnDevView.swift; gh2_ commit -qm 'feat: LS-95 demo features on development'
gh2_ update-ref refs/remotes/origin/development HEAD
gh2_ checkout -q -b hotfix/LS-95-demo
mkdir -p "$hf2_root/LittleSprout/Services"
echo 'struct HotfixOnly {}' > "$hf2_root/LittleSprout/Services/HotfixOnly.swift"
gh2_ add LittleSprout/Services/HotfixOnly.swift; gh2_ commit -qm 'fix: LS-95 hotfix demo non-ui change'
: > "$TAP_TARGET_LOG"
out26=$( cd "$hf2_root" && env FAKE_DEST_UDID="$ded_udid" PATH="$work/bin:$PATH" \
    XCODE_APPS_DIR="$work/no-such-apps" TAP_TARGET_LOG="$TAP_TARGET_LOG" STUB_TEST_RC=0 \
    bash scripts/gates/push-gate.sh </dev/null 2>&1 )
if grep -qF 'called' "$TAP_TARGET_LOG"; then
  echo "✓ ㉖ hotfix/* 分支的 tap-target 觸發方向矩陣正確用 origin/main（development 帶進的 Features/ 變更有被算進 diff）"
else
  echo "✗ ㉖ hotfix/* 分支的 tap-target 觸發區塊可能誤用了 origin/development 當 target（漏算 Features/ 變更）" >&2
  printf '%s\n' "$out26" | sed 's/^/    /' >&2
  fail=1
fi


# ---- ㉗（LS-65 merge-review R1 M1）：本票唯一的 deliverable 是「便宜檢查排在 xcodebuild 之前」
#        這個物理順序，先前沒有任何一個 case 釘住它——把 push-gate.sh 整個換回 base 9803b0d（完整
#        回退 LS-65）拿本檔案跑，37/37 照樣全綠，日後順序被誰不小心搬回去、或新插一個昂貴步驟在
#        便宜檢查之前，自測不會有任何訊號。照 ④（:223-245）同一套 idiom：對 $gate_src 取第一個
#        非註解（跳過 `^[ \t]*#` 開頭的行）的 error-codes-check.sh／merge-conflict-check.sh 呼叫行號，
#        斷言兩者都小於第一個非註解 `xcodebuild test` 行號——回退即紅（reviewer 實測：head 171／230 <
#        352；base 318／377 > 265）----
ordered=$(awk '
  /^[ \t]*#/ { next }
  /error-codes-check\.sh/ && !saw_errcodes { saw_errcodes = NR }
  /merge-conflict-check\.sh/ && !saw_mergeconflict { saw_mergeconflict = NR }
  /xcodebuild test/ && !saw_xcodebuild_test { saw_xcodebuild_test = NR }
  END {
    if (saw_errcodes && saw_mergeconflict && saw_xcodebuild_test \
        && saw_errcodes < saw_xcodebuild_test && saw_mergeconflict < saw_xcodebuild_test) print "yes"
  }
' "$gate_src")
if [ "$ordered" = yes ]; then
  echo "✓ ㉗ error-codes-check.sh／merge-conflict-check.sh 的呼叫行號都在 xcodebuild test 之前（LS-65 順序沒有被回退）"
else
  echo "✗ ㉗ error-codes-check.sh／merge-conflict-check.sh 沒有都排在 xcodebuild test 之前——LS-65 的便宜檢查前移順序被回退了" >&2
  fail=1
fi

# ---- ㉘～㉟（LS-199）：unit tests 看門狗——逾時／宿主 crash 早期偵測／收尾一致（殺整棵行程樹、回收鎖、關專屬機）。
#        來源 LS-197 R2 push：測試宿主 app 啟動即 crash 後 xcodebuild 0% CPU 掛 28 分鐘。stub xcodebuild 的 test
#        分支改跑 $work/wd-test-script.sh（行為由 WD_* 環境變數控制，見該檔檔頭）；HOME 換成 $work/wd-home，
#        裡面放一個 WorkspacePath 指向 $R/Fake.xcodeproj 的假 DerivedData（本 worktree）＋一個指向別處的假
#        DerivedData（別的 worktree，㉝ 驗 scoping）＋一份假 LittleSprout-*.ips（兩行 JSON，形狀照真檔）。
#        逾時用 PUSH_GATE_XCODEBUILD_TIMEOUT_SEC 秒級覆寫、grace 用 PUSH_GATE_CRASH_GRACE_SEC。
#        mutation 鑑別力（PR 記錄）：拿掉 wd_run 迴圈裡的 crash 樣式掃描 → ㉚／㉛ 改走逾時路徑、印「逾時」而非
#        「宿主 crash」→ 紅；拿掉 info.plist 的 WorkspacePath 比對 → ㉝ 把別票的 crash 當自己的中止 → 紅 ----
g checkout -q -b feature/LS-199-watchdog origin/development
printf '99.9\n' > "$R/.xcode-version"
mkdir -p "$R/LittleSprout/Services"; echo 'struct Watchdog {}' > "$R/LittleSprout/Services/Watchdog.swift"
g add LittleSprout/Services/Watchdog.swift; g commit -qm 'feat: LS-199 demo swift for watchdog cases'
wd_home="$work/wd-home"
wd_home_empty="$work/wd-home-empty"
wd_dd="$wd_home/Library/Developer/Xcode/DerivedData"
wd_R_phys="$(cd "$R" && pwd -P)"   # push-gate.sh 用 pwd -P 比對 WorkspacePath；macOS 的 mktemp 路徑經過 /var → /private/var 符號連結
mkdir -p "$wd_dd/LittleSprout-thisworktree" "$wd_dd/LittleSprout-otherworktree" "$wd_dd/LittleSprout-nestedworktree" "$wd_home/Library/Logs/DiagnosticReports" "$wd_home_empty"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s/Fake.xcodeproj</string></dict></plist>\n' "$wd_R_phys" > "$wd_dd/LittleSprout-thisworktree/info.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s/LittleSprout.xcodeproj</string></dict></plist>\n' "$work/some-other-worktree" > "$wd_dd/LittleSprout-otherworktree/info.plist"
# LS-205 R2（merge-review R1 i1）：「巢狀」的別票 worktree——真實佈局裡 worktree 慣例放在
# `<主 checkout>/.claude/worktrees/LS-<n>/` 底下，這台的 WorkspacePath 字面上正是
# `${wd_repo_root}/` 開頭（字首相同），但中間隔了 `.claude/worktrees/LS-999/` 這一段、不是
# 直接緊接 `<repo根>/<單一檔名>.xcodeproj`。舊版 `grep -qF "<string>${wd_repo_root}/"`（純字首）
# 會誤判這裡也算「自己的」；新版 `grep -qE` 要求 `${wd_repo_root}/` 後面只能有一段不含 `/` 的
# 名稱就接 `.xcodeproj`／`.xcworkspace`，正確排除。既有 `LittleSprout-otherworktree` 用完全
# 不同的頂層路徑，兩種舊版寫法都排除得掉，測不出這個 bug（i1 指出的「零回歸覆蓋」）。
mkdir -p "$wd_dd/LittleSprout-nestedworktree"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s/.claude/worktrees/LS-999/LittleSprout.xcodeproj</string></dict></plist>\n' "$wd_R_phys" > "$wd_dd/LittleSprout-nestedworktree/info.plist"
# Staging 底下真實路徑含空白（「Test Scheme Action」），照抄以驗路徑處理
wd_staging_rel="Logs/Test/Test-LittleSprout-2026.09.05_14-38-00-+0800.xcresult/Staging/1_Test/Diagnostics/LittleSproutTests-AAAA-Configuration-Test Scheme Action-Iteration-1/LittleSproutTests-BBBB/Session-LittleSproutTests-2026-09-05_143800-abc123.log"
wd_session_this="$wd_dd/LittleSprout-thisworktree/$wd_staging_rel"
wd_session_other="$wd_dd/LittleSprout-otherworktree/$wd_staging_rel"
wd_session_nested="$wd_dd/LittleSprout-nestedworktree/$wd_staging_rel"
wd_ips="$wd_home/Library/Logs/DiagnosticReports/LittleSprout-2026-09-05-143904.ips"
cat > "$wd_ips" <<'IPS'
{"app_name":"LittleSprout","timestamp":"2026-09-05 14:39:04.00 +0800","app_version":"0.1.0","bug_type":"309","name":"LittleSprout"}
{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","codes":"0x0000000000000001, 0x00000001970f7c94"},"termination":{"namespace":"SIGNAL","code":5,"indicator":"Trace/BPT trap: 5"},"faultingThread":0,"threads":[{"frames":[{"symbol":"_assertionFailure(_:_:file:line:flags:)","imageIndex":1},{"symbol":"static SupabaseClientFactory.makeClient()","sourceFile":"SupabaseClientFactory.swift","sourceLine":36,"imageIndex":0},{"symbol":"LittleSproutApp.init()","sourceFile":"LittleSproutApp.swift","sourceLine":32,"imageIndex":0},{"symbol":"FOURTH_FRAME_MUST_NOT_PRINT","imageIndex":0}]}],"usedImages":[{"name":"LittleSprout.debug.dylib"},{"name":"libswiftCore.dylib"}]}
IPS
# 假 session log 內容（printf %b 展開 \n）：健康版沒有 crash 樣式也沒有 test case；crash 版照 LS-197 實際 log
wd_ok_session="15:07:01.000 xcodebuild[1:1] Beginning test session LittleSproutTests-X\\nWD-SESSION-TAIL-MARKER"
wd_crash_session="15:07:01.000 xcodebuild[1:1] Beginning test session LittleSproutTests-X\\n15:07:02.000 xcodebuild[1:1] Handling Crash: LittleSprout at <external symbol>\\n15:07:02.001 xcodebuild[1:1] Dropping test runner session call because the test runner hasn't connected yet\\nWD-SESSION-TAIL-MARKER"
cat > "$work/wd-test-script.sh" <<'STUB'
#!/bin/bash
# LS-199 看門狗自測用的 xcodebuild test 假身行為（由 $work/bin/xcodebuild 的 test 分支呼叫）：
#   WD_SESSION_FILE／WD_SESSION_CONTENT  開跑就寫一份假 Staging Session log（模擬 Xcode 測試進行中寫 log；mtime 自然晚於看門狗啟動）
#   WD_STDOUT                            先印一行（模擬 xcodebuild 自己印的 crash 樣式）
#   WD_TOUCH                             touch 這個檔（讓假 .ips 晚於看門狗啟動）
#   WD_THEN_SLEEP／WD_THEN_STDOUT        隔 N 秒（預設 1）再印一行（模擬 test case 開始／單純耗時）
#   WD_TAIL_SLEEP                        印完再活 N 秒才結束——看門狗每秒輪詢一次，假身若在第一次輪詢前就結束，
#                                        輪詢連一次都不會掃到（㉜ 併行跑三份自測時曾因此假紅）
#   WD_HANG                              掛住：背景 sleep 120、把「自己 pid 與 sleep pid」寫進 WD_PID_FILE 供斷言整棵行程樹被殺；
#                                        沒設就正常結束 exit 0
#   WD_LATE_SPAWN（LS-205，隨 WD_HANG 一起用）  收到 TERM 才 fork 一個新的孫行程（模擬「清理中又起
#                                        helper 行程」）、自己再多活 10 秒（比 wd_kill_tree 的 TERM→KILL
#                                        等待窗最多 3 秒長，確保 KILL 送出時這個晚生的孫行程仍在）——
#                                        新孫行程 pid 寫進這個路徑指到的檔案。
if [ -n "${WD_SESSION_FILE:-}" ]; then
  mkdir -p "$(dirname "$WD_SESSION_FILE")"
  printf '%b\n' "${WD_SESSION_CONTENT:-}" > "$WD_SESSION_FILE"
fi
if [ -n "${WD_TOUCH:-}" ]; then touch "$WD_TOUCH"; fi
if [ -n "${WD_STDOUT:-}" ]; then printf '%s\n' "$WD_STDOUT"; fi
if [ -n "${WD_THEN_STDOUT:-}" ]; then
  sleep "${WD_THEN_SLEEP:-1}"
  printf '%s\n' "$WD_THEN_STDOUT"
fi
if [ -n "${WD_TAIL_SLEEP:-}" ]; then sleep "$WD_TAIL_SLEEP"; fi
if [ -n "${WD_HANG:-}" ]; then
  if [ -n "${WD_LATE_SPAWN:-}" ]; then
    trap 'sleep 120 & echo $! > "$WD_LATE_SPAWN"; sleep 10; exit 143' TERM
  fi
  sleep 120 &
  printf '%s %s\n' "$$" "$!" > "${WD_PID_FILE:?WD_PID_FILE 未設定}"
  wait
fi
exit 0
STUB
chmod +x "$work/wd-test-script.sh"
wd_pids_dead() {   # $1＝WD_PID_FILE；兩個 pid 都不存在才 0
  local a b
  read -r a b < "$1" || return 1
  [ -n "$a" ] && [ -n "$b" ] || return 1
  ! kill -0 "$a" 2>/dev/null && ! kill -0 "$b" 2>/dev/null
}
# 收尾斷言共用：exit 124、專屬機有 shutdown、鎖目錄不在、行程樹全死、elapsed 上限
wd_assert_aborted() {   # $1＝案號 $2＝rc $3＝elapsed $4＝elapsed 上限 $5＝pid file $6＝輸出
  if [ "$2" -eq 124 ]; then echo "✓ ${1} 看門狗中止 → exit 124"; else echo "✗ ${1} 看門狗中止應 exit 124（實得 ${2}）" >&2; printf '%s\n' "$6" | sed 's/^/    /' >&2; fail=1; fi
  if grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then echo "✓ ${1} 中止後專屬機仍被 shutdown（EXIT trap 沿既有收尾）"; else echo "✗ ${1} 中止後沒有 shutdown 專屬機" >&2; printf '%s\n' "$6" | sed 's/^/    /' >&2; fail=1; fi
  if [ ! -d "$SIMULATOR_LOCK_DIR" ]; then echo "✓ ${1} 中止後 simulator-lock 已釋放"; else echo "✗ ${1} 中止後 simulator-lock 目錄仍在：$(cat "$SIMULATOR_LOCK_DIR/holder" 2>/dev/null | tr '\n' ' ')" >&2; fail=1; fi
  if wd_pids_dead "$5"; then echo "✓ ${1} 整棵行程樹已殺（假身 bash 與其 sleep 子行程皆不存在）"; else echo "✗ ${1} 行程樹沒殺乾淨：$(cat "$5" 2>/dev/null)" >&2; fail=1; fi
  if [ "$3" -le "$4" ]; then echo "✓ ${1} 耗時 ${3}s（上限 ${4}s）"; else echo "✗ ${1} 耗時 ${3}s 超過上限 ${4}s——看門狗沒有及時中止" >&2; fail=1; fi
}

# ㉘ 逾時（3 秒）：假身掛住、本 worktree 有 session log、.ips 剛被 touch → 印「逾時」＋session log 尾（含標記行與路徑）
#    ＋crash report 摘要（exception／faultingThread 前三幀，第四幀不印；不帶「早於」註記）＋erase 建議；收尾一致
: > "$SHUTDOWN_LOG"
wd_pidfile28="$work/wd28.pid"; rm -f "$wd_pidfile28"
t28=$(date +%s)
out28=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=3 \
  WD_HANG=1 WD_PID_FILE="$wd_pidfile28" WD_SESSION_FILE="$wd_session_this" WD_SESSION_CONTENT="$wd_ok_session" WD_TOUCH="$wd_ips"); rc28=$?
el28=$(( $(date +%s) - t28 ))
if printf '%s' "$out28" | grep -qF 'unit tests 逾時'; then echo "✓ ㉘ 印出「逾時」"; else echo "✗ ㉘ 未印出「逾時」" >&2; printf '%s\n' "$out28" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s' "$out28" | grep -qF 'WD-SESSION-TAIL-MARKER' && printf '%s' "$out28" | grep -qF 'Session-LittleSproutTests-2026-09-05_143800-abc123.log'; then
  echo "✓ ㉘ 印出本 worktree 的 xcresult session log 路徑與尾行（含空白路徑）"
else echo "✗ ㉘ 沒有印出 session log 尾／路徑" >&2; printf '%s\n' "$out28" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s' "$out28" | grep -qF 'EXC_BREAKPOINT' && printf '%s' "$out28" | grep -qF 'SupabaseClientFactory.swift:36' && ! printf '%s' "$out28" | grep -qF 'FOURTH_FRAME_MUST_NOT_PRINT'; then
  echo "✓ ㉘ crash report 摘要：exception 型別＋faultingThread 前三幀（第四幀不印）"
else echo "✗ ㉘ crash report 摘要不完整或印了第四幀" >&2; printf '%s\n' "$out28" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s' "$out28" | grep -qF '最新 crash report：' && ! printf '%s' "$out28" | grep -qF '早於本次看門狗啟動'; then
  echo "✓ ㉘ .ips 晚於看門狗啟動 → 不帶「早於」註記"
else echo "✗ ㉘ .ips 剛被 touch 卻帶了「早於」註記（或沒印路徑）" >&2; fail=1; fi
if printf '%s' "$out28" | grep -qF "xcrun simctl erase ${ded_udid}"; then echo "✓ ㉘ 印出環境性 flake 建議（erase 本次 UDID 後重跑）"; else echo "✗ ㉘ 未印出 erase 建議" >&2; fail=1; fi
wd_assert_aborted "㉘" "$rc28" "$el28" 25 "$wd_pidfile28" "$out28"

# ㉙ 逾時、但 HOME 底下沒有 DerivedData 也沒有 .ips → 兩處都明說「找不到」，其餘收尾一致
: > "$SHUTDOWN_LOG"
wd_pidfile29="$work/wd29.pid"; rm -f "$wd_pidfile29"
t29=$(date +%s)
out29=$(run_gate HOME="$wd_home_empty" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=3 \
  WD_HANG=1 WD_PID_FILE="$wd_pidfile29"); rc29=$?
el29=$(( $(date +%s) - t29 ))
if printf '%s' "$out29" | grep -qF '找不到本次的 xcresult session log' && printf '%s' "$out29" | grep -qF '找不到 crash report'; then
  echo "✓ ㉙ 無 session log／無 .ips → 兩處都印「找不到」"
else echo "✗ ㉙ 缺診斷來源時沒有明說找不到" >&2; printf '%s\n' "$out29" | sed 's/^/    /' >&2; fail=1; fi
wd_assert_aborted "㉙" "$rc29" "$el29" 25 "$wd_pidfile29" "$out29"

# ㉚ 宿主 crash 早期偵測——LS-197 形狀：xcodebuild -quiet 什麼都不印、crash 樣式只在 session log；grace 1 秒、
#    逾時 30 秒 → 應在遠早於逾時前以「宿主 crash」中止（mutation：拿掉樣式掃描 → 走逾時、印「逾時」→ 紅）
: > "$SHUTDOWN_LOG"
wd_pidfile30="$work/wd30.pid"; rm -f "$wd_pidfile30"
t30=$(date +%s)
out30=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=30 PUSH_GATE_CRASH_GRACE_SEC=1 \
  WD_HANG=1 WD_PID_FILE="$wd_pidfile30" WD_SESSION_FILE="$wd_session_this" WD_SESSION_CONTENT="$wd_crash_session"); rc30=$?
el30=$(( $(date +%s) - t30 ))
if printf '%s' "$out30" | grep -qF 'unit tests 宿主 crash' && ! printf '%s' "$out30" | grep -qF 'unit tests 逾時'; then
  echo "✓ ㉚ session log 出現 crash 樣式、grace 內無 test case → 以「宿主 crash」中止（不是等到逾時）"
else echo "✗ ㉚ 沒有走宿主 crash 路徑（走了逾時或沒中止）" >&2; printf '%s\n' "$out30" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s' "$out30" | grep -qF '早於本次看門狗啟動'; then echo "✓ ㉚ .ips 早於本次啟動 → 帶「早於」註記"; else echo "✗ ㉚ 舊 .ips 沒有帶「早於」註記" >&2; fail=1; fi
wd_assert_aborted "㉚" "$rc30" "$el30" 15 "$wd_pidfile30" "$out30"

# ㉛ 宿主 crash 樣式出現在 xcodebuild 自己的輸出（`Early unexpected exit`）、本 worktree 沒有新的 session log
#    （上一案留下的檔早於本次看門狗啟動，須被 -newer 排除 → 印「找不到」）→ 同樣以「宿主 crash」中止
: > "$SHUTDOWN_LOG"
wd_pidfile31="$work/wd31.pid"; rm -f "$wd_pidfile31"
t31=$(date +%s)
out31=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=30 PUSH_GATE_CRASH_GRACE_SEC=1 \
  WD_HANG=1 WD_PID_FILE="$wd_pidfile31" WD_STDOUT='Early unexpected exit, operation never finished bootstrapping - no restart will be attempted'); rc31=$?
el31=$(( $(date +%s) - t31 ))
if printf '%s' "$out31" | grep -qF 'unit tests 宿主 crash' && ! printf '%s' "$out31" | grep -qF 'unit tests 逾時'; then
  echo "✓ ㉛ xcodebuild 輸出出現 crash 樣式 → 以「宿主 crash」中止"
else echo "✗ ㉛ stdout 的 crash 樣式沒有觸發早期偵測" >&2; printf '%s\n' "$out31" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s' "$out31" | grep -qF '找不到本次的 xcresult session log'; then echo "✓ ㉛ 早於本次啟動的舊 session log 被排除（印「找不到」）"; else echo "✗ ㉛ 拿了早於本次啟動的舊 session log" >&2; printf '%s\n' "$out31" | sed 's/^/    /' >&2; fail=1; fi
wd_assert_aborted "㉛" "$rc31" "$el31" 15 "$wd_pidfile31" "$out31"

# ㉜ 假警報：crash 樣式之後 1 秒就有 `Test Case '-[` 開始（grace 3 秒），再活 3 秒讓輪詢看得到兩個階段 → 取消判定、
#    跑完正常結束（exit 0、正常路徑 shutdown）
: > "$SHUTDOWN_LOG"
out32=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=30 PUSH_GATE_CRASH_GRACE_SEC=3 \
  WD_STDOUT='Handling Crash: LittleSprout at <external symbol>' WD_THEN_SLEEP=1 WD_THEN_STDOUT="Test Case '-[LittleSproutTests.FooTests testBar]' started." WD_TAIL_SLEEP=3); rc32=$?
if [ "$rc32" -eq 0 ] && printf '%s' "$out32" | grep -qF '取消宿主 crash 判定' && ! printf '%s' "$out32" | grep -qF '已中止'; then
  echo "✓ ㉜ crash 樣式後 grace 內看到 test case 開始 → 取消判定、正常結束（exit 0）"
else echo "✗ ㉜ 假警報沒有被取消（exit ${rc32}）" >&2; printf '%s\n' "$out32" | sed 's/^/    /' >&2; fail=1; fi
if grep -qF "shutdown ${ded_udid}" "$SHUTDOWN_LOG"; then echo "✓ ㉜ 正常路徑仍關專屬機"; else echo "✗ ㉜ 正常路徑沒關專屬機" >&2; fail=1; fi

# ㉝ scoping：crash 樣式只在「別的 worktree」的 DerivedData session log（WorkspacePath 指向別處），本 worktree 的
#    run 還在跑（假身耗時 3 秒 > grace 1 秒）→ 不得被當成自己的 crash 中止（mutation：拿掉 WorkspacePath 比對 → 紅）
: > "$SHUTDOWN_LOG"
out33=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=30 PUSH_GATE_CRASH_GRACE_SEC=1 \
  WD_SESSION_FILE="$wd_session_other" WD_SESSION_CONTENT="$wd_crash_session" WD_THEN_SLEEP=3 WD_THEN_STDOUT='done'); rc33=$?
if [ "$rc33" -eq 0 ] && ! printf '%s' "$out33" | grep -qF '出現宿主 crash 樣式' && ! printf '%s' "$out33" | grep -qF '已中止'; then
  echo "✓ ㉝ 別的 worktree 的 crash session log 不觸發本 worktree 的看門狗（只認 WorkspacePath 落在本 repo 的 DerivedData）"
else echo "✗ ㉝ 別票的 crash 被當成自己的（exit ${rc33}）——scoping 失效會殺掉健康的 run" >&2; printf '%s\n' "$out33" | sed 's/^/    /' >&2; fail=1; fi

# ㉝b（LS-205 R2；merge-review R1 i1）：同 ㉝，但別票 worktree「巢狀」在 `${wd_repo_root}/` 底下
#    （真實佈局：worktree 放在 `<主 checkout>/.claude/worktrees/LS-999/`）——舊版
#    `grep -qF "<string>${wd_repo_root}/"`（純字首）會把這個巢狀路徑也誤判成「自己的」；㉝ 的
#    fixture 用完全不同頂層路徑，測不出這個 bug（i1：零回歸覆蓋）。mutation 手動驗證：改回舊版
#    `-qF` 字首比對 → 本案紅（見 R2 handoff）。
: > "$SHUTDOWN_LOG"
out33b=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=30 PUSH_GATE_CRASH_GRACE_SEC=1 \
  WD_SESSION_FILE="$wd_session_nested" WD_SESSION_CONTENT="$wd_crash_session" WD_THEN_SLEEP=3 WD_THEN_STDOUT='done'); rc33b=$?
if [ "$rc33b" -eq 0 ] && ! printf '%s' "$out33b" | grep -qF '出現宿主 crash 樣式' && ! printf '%s' "$out33b" | grep -qF '已中止'; then
  echo "✓ ㉝b 巢狀在本 repo 根之下的別票 worktree 的 crash 不觸發本 worktree 的看門狗（精確比對，不是純字首；LS-205 i1）"
else echo "✗ ㉝b 巢狀別票的 crash 被當成自己的（exit ${rc33b}）——字首比對誤判（i1 指出的回歸）" >&2; printf '%s\n' "$out33b" | sed 's/^/    /' >&2; fail=1; fi

# ㉞ CI（GITHUB_ACTIONS=true）不啟用看門狗；本機（清空）啟用並印一行說明
out34a=$(run_gate STUB_TEST_RC=0 GITHUB_ACTIONS=true)
out34b=$(run_gate STUB_TEST_RC=0)
if ! printf '%s' "$out34a" | grep -qF '看門狗啟用' && printf '%s' "$out34b" | grep -qF '看門狗啟用'; then
  echo "✓ ㉞ GITHUB_ACTIONS=true 不啟用看門狗；本機啟用並印出逾時／grace 設定"
else echo "✗ ㉞ 看門狗啟用條件不對（CI 應不啟用、本機應啟用）" >&2; printf '%s\n' "$out34a" | sed 's/^/    [CI] /' >&2; printf '%s\n' "$out34b" | sed 's/^/    [local] /' >&2; fail=1; fi

# ㉟ 逾時／grace 環境變數不是正整數 → fail loud（不靜默退回預設，也不會算出 0 秒立刻逾時）
out35=$(run_gate STUB_TEST_RC=0 PUSH_GATE_XCODEBUILD_TIMEOUT_MIN=abc); rc35=$?
out35b=$(run_gate STUB_TEST_RC=0 PUSH_GATE_CRASH_GRACE_SEC=0); rc35b=$?
if [ "$rc35" -ne 0 ] && printf '%s' "$out35" | grep -qF '須為正整數' && [ "$rc35b" -ne 0 ] && printf '%s' "$out35b" | grep -qF '須為正整數'; then
  echo "✓ ㉟ 逾時分鐘數非數字／grace 為 0 → 擋下並指出變數"
else echo "✗ ㉟ 非法的看門狗設定沒有被擋（exit ${rc35}／${rc35b}）" >&2; printf '%s\n' "$out35" | sed 's/^/    /' >&2; fail=1; fi


# ㊱（LS-205，LS-96 池項 37a390d0 (3)）：TERM 之後才 fork 的晚生孫行程也要被殺乾淨——wd-test-script.sh
# 在 WD_LATE_SPAWN 時收到 TERM 才 fork 一個新的 `sleep 120`、自己再多活 10 秒（比 wd_kill_tree 的
# TERM→KILL 等待窗最多 3 秒長，逾時後的 alive-check 迴圈會跑滿全部 6 次才進 KILL），這個晚生孫行程若
# 只用「送 TERM 前那份舊清單」去 KILL 就不會被殺到（mutation：拿掉 KILL 前重新收集子孫那行 → 紅）。
: > "$SHUTDOWN_LOG"
wd_pidfile36="$work/wd36.pid"; rm -f "$wd_pidfile36"
wd_late36="$work/wd36.late"; rm -f "$wd_late36"
t36=$(date +%s)
out36=$(run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=3 \
  WD_HANG=1 WD_LATE_SPAWN="$wd_late36" WD_PID_FILE="$wd_pidfile36"); rc36=$?
el36=$(( $(date +%s) - t36 ))
wd_assert_aborted "㊱" "$rc36" "$el36" 25 "$wd_pidfile36" "$out36"
late_pid36=$(cat "$wd_late36" 2>/dev/null)
if [ -z "$late_pid36" ]; then
  echo "✗ ㊱ 沒讀到晚生孫行程的 pid（${wd_late36} 是空的？自測本身沒運作）" >&2
  printf '%s\n' "$out36" | sed 's/^/    /' >&2
  fail=1
else
  # kill -KILL 是非同步訊號，行程不會瞬間消失——輪詢至多 3 秒
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$late_pid36" 2>/dev/null || break; sleep 0.3; done
  if ! kill -0 "$late_pid36" 2>/dev/null; then
    echo "✓ ㊱ TERM 之後才 fork 的晚生孫行程（pid ${late_pid36}）被 KILL 前重新收集抓到、殺乾淨"
  else
    echo "✗ ㊱ 晚生孫行程（pid ${late_pid36}）沒被殺乾淨——KILL 前沒有重新收集子孫" >&2
    kill -KILL "$late_pid36" 2>/dev/null   # 測試自己收尾，不留一顆 sleep 120 在背景
    fail=1
  fi
fi

# ㊲（LS-205，LS-96 池項 37a390d0 (2)）：sim_lock_dir 若是被「非本次看門狗殺掉的行程」持有（例如巧合
#    搶到同一顆 UDID、正在跑 xcodebuild test 的另一支呼叫），逾時中止時這把「別人的」鎖必須原封不動
#    留著，不能因為看門狗自己中止了就順手 rm -rf（mutation：拿掉「holder 必須是被殺子孫」那段判斷、
#    只要 sim_lock_dir/holder 存在就一律回收 → 紅）。背景先用真正的 simulator-lock.sh 抓住
#    $SIMULATOR_LOCK_DIR（非本次 push-gate.sh 行程樹的子孫，是本檔案自己開的獨立行程）、放夠久，
#    讓 push-gate.sh 那次 xcodebuild test 呼叫在鎖外面排隊等到逾時；run_gate_keep_lock 不會在起跑前
#    清空這把鎖。
: > "$SHUTDOWN_LOG"
rm -rf "$SIMULATOR_LOCK_DIR"
bash "$work/simulator-lock.sh.real" --dir "$SIMULATOR_LOCK_DIR" -- sleep 10 &
foreign_pid37=$!
sleep 0.5   # 讓背景鎖先落地（holder 檔寫好）
foreign_holder_before=$(cat "$SIMULATOR_LOCK_DIR/holder" 2>/dev/null)
# STUB_TEST_SCRIPT／WD_HANG 不必帶——鎖被別人占走，push-gate.sh 這次的 xcodebuild test 呼叫從頭到尾
# 卡在等鎖那一步，根本沒機會執行到 xcodebuild（也就沒機會跑到 wd-test-script.sh）。
out37=$(run_gate_keep_lock HOME="$wd_home" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=3); rc37=$?
if [ "$rc37" -eq 124 ]; then echo "✓ ㊲ 看門狗中止 → exit 124（等鎖等到逾時，xcodebuild 從未真的跑起來）"; else echo "✗ ㊲ 應 exit 124（實得 ${rc37}）" >&2; printf '%s\n' "$out37" | sed 's/^/    /' >&2; fail=1; fi
if [ -d "$SIMULATOR_LOCK_DIR" ] && [ "$(cat "$SIMULATOR_LOCK_DIR/holder" 2>/dev/null)" = "$foreign_holder_before" ]; then
  echo "✓ ㊲ 別人持有、非本次看門狗子孫的鎖原封不動留著（holder 未變）"
else
  echo "✗ ㊲ 別人的鎖被誤收了（中止後 ${SIMULATOR_LOCK_DIR} 消失或 holder 變了）" >&2
  printf '%s\n' "$out37" | sed 's/^/    /' >&2
  fail=1
fi
kill "$foreign_pid37" 2>/dev/null; wait "$foreign_pid37" 2>/dev/null
rm -rf "$SIMULATOR_LOCK_DIR"

# ㊳（LS-205 R2；merge-review R1 i2）：㊲ 的外來 holder 是活著的（`sleep 10`），單靠「holder 是否
#    存活」這道防線就已經擋住誤收，測不出「holder 必須是被殺子孫」這個條件本身有沒有被鎖住
#    （reviewer 的 mutation M5：拿掉 `case " $wd_killed_pids "` 那段判斷、只留 `kill -0` 存活檢查，
#    ㊲ 仍全綠）。這裡讓 run_unit_tests 的 simulator-lock.sh 正常拿到鎖（holder＝真正的子孫 pid），
#    等它寫好 holder 檔之後，直接竄改檔案內容成一個**已死、且不是這次看門狗任何子孫**的 pid——
#    不透過 simulator-lock.sh 自己的 `mkdir`／`is_stale` 迴圈操作（那條路徑一旦偵測到死鎖會自己
#    搶先回收，測不到 push-gate.sh 自己的收尾邏輯），模擬「檢查那一刻 holder 檔內容已經不是本次
#    子孫寫的」這個 TOCTOU 情境。正確行為：這把鎖不屬於 wd_killed_pids 任何一員，即使已死也不該
#    被回收（不只看死活，還要看是不是自己殺的）。
: > "$SHUTDOWN_LOG"
( : ) & foreign_dead_pid38=$!
wait "$foreign_dead_pid38" 2>/dev/null   # 確保真的死透、已被 reap
wd_pidfile38="$work/wd38.pid"; rm -f "$wd_pidfile38"
rm -rf "$SIMULATOR_LOCK_DIR"
run_gate HOME="$wd_home" STUB_TEST_SCRIPT="$work/wd-test-script.sh" PUSH_GATE_XCODEBUILD_TIMEOUT_SEC=5 \
  WD_HANG=1 WD_PID_FILE="$wd_pidfile38" > "$work/out38.txt" 2>&1 &
gate_pid38=$!
holder_seen38=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -f "$SIMULATOR_LOCK_DIR/holder" ]; then holder_seen38=1; break; fi
  sleep 0.2
done
if [ "$holder_seen38" -eq 1 ]; then
  printf 'pid=%s\nstarted=%s\n' "$foreign_dead_pid38" "$(date +%s)" > "$SIMULATOR_LOCK_DIR/holder"
else
  echo "✗ ㊳ 沒等到 simulator-lock.sh 寫好 holder 檔，自測本身沒運作" >&2
  fail=1
fi
wait "$gate_pid38"; rc38=$?
out38=$(cat "$work/out38.txt" 2>/dev/null)
if [ "$rc38" -eq 124 ] && [ -d "$SIMULATOR_LOCK_DIR" ] && grep -qF "pid=${foreign_dead_pid38}" "$SIMULATOR_LOCK_DIR/holder" 2>/dev/null; then
  echo "✓ ㊳ holder 檔被竄改成已死、非本次子孫的 pid 後仍不回收（LS-205 i2：holder 必須是被殺子孫，不是只看死活）"
else
  echo "✗ ㊳ 已死但非本次子孫的 holder 被誤收（exit ${rc38}；i2 的 mutation 未被鎖住）" >&2
  printf '%s\n' "$out38" | sed 's/^/    /' >&2
  fail=1
fi
rm -rf "$SIMULATOR_LOCK_DIR"

if [ "$fail" -eq 0 ]; then
  echo "✓ push-gate 模擬器自測通過"
fi
exit "$fail"
