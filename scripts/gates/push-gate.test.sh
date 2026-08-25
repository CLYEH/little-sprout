#!/bin/bash
# push-gate.sh 的自測（LS-100：模擬器用完必關）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支腳本也適用：若退化——xcodebuild test 跑完（不論成功或失敗）沒有關模擬器、
# KEEP_SIMULATOR=1 卻還是關了、或 EXIT／INT／TERM 三個 trap 被搬到 xcodebuild test 之後才設（訊號在
# 執行中發生時就來不及生效）——這裡會紅。
#
# 真的跑一次 xcodebuild test（甚至整套 push-gate.sh）太重、也不該綁死本機是否已建好 Phase 0 專案，
# 所以比照 detect-simulator.test.sh／push-ref-check.test.sh 的既有模式：把 push-gate.sh 與它會呼叫的
# 腳本（push-ref-check.sh／detect-simulator.sh／simulator-lock.sh）複製進合成 repo，PATH 換上 stub
# 的 xcrun／xcodebuild（不碰本機真正的模擬器），CI=true 讓 detect-simulator.sh 直接走「共用第一台」
# 那條最簡路徑（不查／不建專屬機、不上鎖，見該腳本檔頭）。
#
# 合成 repo 沒有 docs/API.md／LittleSprout/Errors/AppError.swift／supabase/migrations，所以 push-gate.sh
# 第 4 步（error-codes-check.sh，無條件跑）一定會失敗，push-gate.sh 整體 exit code 因此不會是 0——這是
# 預期的、刻意不追求的「全綠」，因為它與本票要驗的行為（模擬器用完必關）無關：EXIT trap 在 sim_udid
# 算出來後就設好了，不論後面第幾步造成整支腳本退出，trap 都會在那個當下觸發；下面只斷言「xcrun simctl
# shutdown 有沒有被叫到、UDID 對不對」，不斷言 push-gate.sh 整體的最終 exit code。
# INT／TERM 訊號傳遞的時機在 bash 裡對「還在等前景指令」的情況沒有跨平台一致保證（同
# scripts/ops/simulator-lock.sh 檔頭理由——它也因此另外顯式接 INT／TERM 成 exit，不只靠裸 EXIT
# trap），所以這裡不模擬真的送訊號中斷，改用靜態接線斷言（同 detect-simulator.test.sh 的 ⑨）釘住
# 「trap 設定的順序在 xcodebuild test 真正執行之前」這件事——這才是訊號中斷也關得掉的機制本身。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate_src="${root}/scripts/gates/push-gate.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work" "/tmp/simulator-lock-SHARED-UDID"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
R="$work/repo"
mkdir -p "$R/scripts/gates" "$R/scripts/ops"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b main
echo a > "$R/f.txt"; g add -A; g commit -qm 'chore: LS-0 seed'

# ---- 複製 push-gate.sh 會實際呼叫到的腳本；push-gate.sh 內部一律用
#      "$(git rev-parse --show-toplevel)/…" 定路徑，合成 repo 裡就得有這幾份 ----
cp "$gate_src" "$R/scripts/gates/push-gate.sh"
cp "${root}/scripts/gates/push-ref-check.sh" "$R/scripts/gates/push-ref-check.sh"
cp "${root}/scripts/gates/detect-simulator.sh" "$R/scripts/gates/detect-simulator.sh"
cp "${root}/scripts/ops/simulator-lock.sh" "$R/scripts/ops/simulator-lock.sh"
# 觸發 push-gate.sh「Xcode 專案存在」那個分支；ls -d 只認目錄存在，內容不重要
mkdir -p "$R/Fake.xcodeproj"

# ---- stub xcrun／xcodebuild：不碰本機真正的模擬器／Xcode ----
mkdir -p "$work/bin"
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = simctl ] && [ "$2" = list ] && [ "$3" = devices ] && [ "$4" = available ]; then
  echo "== Devices =="
  echo "-- iOS 26.0 --"
  echo "    iPhone 17 Pro (SHARED-UDID) (Shutdown)"
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
for a in "$@"; do
  case "$a" in
    -resolvePackageDependencies) exit 0 ;;
    test) exit "${STUB_TEST_RC:-0}" ;;
  esac
done
exit 0
STUB
chmod +x "$work/bin/xcodebuild"

SHUTDOWN_LOG="$work/shutdown.log"; export SHUTDOWN_LOG
: > "$SHUTDOWN_LOG"

# run_gate <env 指定…>：在合成 repo 內跑 push-gate.sh；stdin 接 /dev/null（非 tty）讓開頭的
# push-ref-check.sh 照跑——空 stdin＝seen=0＝exit 0（既有行為，維持完整 gate）。CI=true 固定給，
# 讓 detect-simulator.sh 走最簡的共用機路徑（不查／不建專屬機、不上鎖）。
run_gate() {
  rm -rf /tmp/simulator-lock-SHARED-UDID
  ( cd "$R" && env CI=true PATH="$work/bin:$PATH" "$@" bash scripts/gates/push-gate.sh </dev/null 2>&1 )
}

# ---- ① 測試成功（STUB_TEST_RC=0）→ 仍要關模擬器 ----
: > "$SHUTDOWN_LOG"
out1=$(run_gate STUB_TEST_RC=0)
if grep -qF 'shutdown SHARED-UDID' "$SHUTDOWN_LOG"; then
  echo "✓ ① xcodebuild test 成功 → xcrun simctl shutdown SHARED-UDID 有被呼叫"
else
  echo "✗ ① xcodebuild test 成功但沒有關模擬器" >&2
  printf '%s\n' "$out1" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ② 測試失敗（STUB_TEST_RC=1）→ 仍要關模擬器（成功失敗皆關）----
: > "$SHUTDOWN_LOG"
out2=$(run_gate STUB_TEST_RC=1); rc2=$?
if [ "$rc2" -ne 0 ]; then
  echo "✓ ② xcodebuild test 失敗 → push-gate.sh 整體也非 0（set -e 立即跳出）"
else
  echo "✗ ② xcodebuild test 失敗時 push-gate.sh 應非 0（實得 0）" >&2
  fail=1
fi
if grep -qF 'shutdown SHARED-UDID' "$SHUTDOWN_LOG"; then
  echo "✓ ② xcodebuild test 失敗 → 仍有關模擬器（trap 在失敗時一樣觸發）"
else
  echo "✗ ② xcodebuild test 失敗但沒有關模擬器" >&2
  printf '%s\n' "$out2" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ③ KEEP_SIMULATOR=1 → 不關模擬器 ----
: > "$SHUTDOWN_LOG"
out3=$(run_gate STUB_TEST_RC=0 KEEP_SIMULATOR=1)
if [ ! -s "$SHUTDOWN_LOG" ]; then
  echo "✓ ③ KEEP_SIMULATOR=1 → 沒有呼叫 shutdown（保留模擬器）"
else
  echo "✗ ③ KEEP_SIMULATOR=1 卻仍呼叫了 shutdown" >&2
  printf '%s\n' "$out3" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ④ 接線順序：sim_udid 算出來 → KEEP_SIMULATOR 判斷 → EXIT／INT／TERM 三個 trap 都設好，
#        全部在 simulator-lock.sh 包住的 xcodebuild test 真正執行「之前」（不是只在旁邊的註解提到；
#        跳過註解行，同 detect-simulator.test.sh ⑨ 的模式）----
wired=$(awk '
  /^[ \t]*#/ { next }
  /sim_udid=/ && !saw_udid { saw_udid = NR }
  /KEEP_SIMULATOR/ && !saw_keep { saw_keep = NR }
  /trap .*xcrun simctl shutdown.*EXIT/ { saw_exit = NR }
  /trap .*exit 130.*INT/ { saw_int = NR }
  /trap .*exit 143.*TERM/ { saw_term = NR }
  /simulator-lock\.sh/ { saw_lock = NR }
  /xcodebuild test/ { saw_test = NR }
  END {
    if (saw_udid && saw_keep && saw_exit && saw_int && saw_term && saw_lock && saw_test \
        && saw_udid < saw_keep && saw_keep < saw_exit && saw_exit < saw_lock && saw_lock < saw_test) print "yes"
  }
' "$gate_src")
if [ "$wired" = yes ]; then
  echo "✓ ④ EXIT／INT／TERM 三個 trap 都設在 sim_udid 算出來之後、KEEP_SIMULATOR 判斷之後、真正執行 xcodebuild test（simulator-lock.sh 包住那行）之前"
else
  echo "✗ ④ trap 接線順序不對，或缺了 EXIT／INT／TERM 其中之一（中斷可能來不及關模擬器）" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ push-gate 模擬器自測通過"
fi
exit "$fail"
