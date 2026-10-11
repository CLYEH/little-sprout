#!/bin/bash
# emulator-lock.sh 的自測（LS-477）。CI rules job 跑。
# 範圍：命令 exit code 透傳＋釋放、同 serial 互斥（序列化）、不同 serial 不競爭、等待逾時 124 並印持有者、死鎖
# （holder pid 不存在）自動回收、--status 三態、參數驗證（serial 不得夾路徑）、SIGTERM 時釋放、mutation（拿掉 stale
# 判斷 → 死鎖案例逾時）。鎖根目錄一律 EMULATOR_LOCK_ROOT 指到 mktemp -d，不碰 /tmp 上真實鎖。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_sh="${root}/scripts/ops/emulator-lock.sh"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"; kill $(jobs -p) 2>/dev/null' EXIT
export EMULATOR_LOCK_ROOT="$work/locks"; mkdir -p "$EMULATOR_LOCK_ROOT"
export EMULATOR_LOCK_POLL=0.2

# ① 命令 exit code 透傳、執行後鎖已釋放
out=$(bash "$lock_sh" --serial emulator-5554 -- bash -c 'exit 7' 2>&1); rc=$?
expect_exit 7 "$rc" "① 命令 exit code 透傳"
if [ ! -d "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5554" ]; then ok "① 跑完鎖目錄已釋放"; else fail "① 鎖目錄殘留"; fi

# ② 同 serial 互斥：A 持鎖 1 秒，B 在 A 持鎖期間啟動 → B 必須等 A 結束才進臨界區（log 順序 A-in A-out B-in B-out）
log="$work/order.log"; : > "$log"
bash "$lock_sh" --serial emulator-5554 -- bash -c "echo A-in >> '$log'; sleep 1; echo A-out >> '$log'" &
pa=$!
sleep 0.4   # 確保 A 先取到鎖
bash "$lock_sh" --serial emulator-5554 -- bash -c "echo B-in >> '$log'; echo B-out >> '$log'" 2>/dev/null &
pb=$!
wait "$pa" "$pb"
if [ "$(tr '\n' ' ' < "$log")" = "A-in A-out B-in B-out " ]; then ok "② 同 serial 序列化（A 結束後 B 才進）"; else fail "② 同 serial 應序列化，實得：$(tr '\n' ' ' < "$log")"; fi

# ③ 不同 serial 不競爭：A 持 5554 鎖時，5556 立刻跑完（< 1 秒）
bash "$lock_sh" --serial emulator-5554 -- sleep 2 &
pa=$!
sleep 0.4
t0=$(date +%s)
bash "$lock_sh" --serial emulator-5556 -- true; rc=$?
t1=$(date +%s)
if [ "$rc" -eq 0 ] && [ $((t1 - t0)) -lt 2 ]; then ok "③ 不同 serial 不互等"; else fail "③ 不同 serial 不該互等（rc ${rc}，耗時 $((t1 - t0))s）"; fi
wait "$pa"

# ④ 等待逾時 → 124 並印持有者
bash "$lock_sh" --serial emulator-5554 -- sleep 3 &
pa=$!
sleep 0.4
out=$(bash "$lock_sh" --serial emulator-5554 --timeout 1 -- true 2>&1); rc=$?
expect_exit 124 "$rc" "④ 等待逾時 exit 124"
expect_has "$out" "held pid=" "④ 逾時訊息印持有者 pid"
wait "$pa"

# ⑤ 死鎖自動回收：手工布一把 holder pid 不存在的鎖
dead=$(bash -c 'echo $$')   # 子 shell 已結束的 pid
mkdir "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5558"
printf 'pid=%s\nstarted=%s\n' "$dead" "$(date +%s)" > "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5558/holder"
out=$(bash "$lock_sh" --serial emulator-5558 --timeout 5 -- echo got-it 2>&1); rc=$?
expect_exit 0 "$rc" "⑤ 死鎖自動回收後跑成"
expect_has "$out" "回收死鎖" "⑤ 印回收提示"
expect_has "$out" "got-it" "⑤ 命令有執行"

# ⑥ --status 三態
out=$(bash "$lock_sh" --status --serial emulator-5560 2>&1); rc=$?
expect_exit 0 "$rc" "⑥a --status exit 0"
expect_has "$out" "free" "⑥a 無鎖 → free"
bash "$lock_sh" --serial emulator-5560 -- sleep 2 &
pa=$!
sleep 0.4
out=$(bash "$lock_sh" --status --serial emulator-5560 2>&1)
expect_has "$out" "held pid=" "⑥b 持鎖中 → held pid="
expect_not_has "$out" "stale" "⑥b 活鎖不標 stale"
wait "$pa"
mkdir "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5562"
printf 'pid=%s\nstarted=%s\n' "$dead" "$(date +%s)" > "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5562/holder"
out=$(bash "$lock_sh" --status --serial emulator-5562 2>&1)
expect_has "$out" "⚠ stale" "⑥c 死鎖 → 標 ⚠ stale"
if [ -d "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5562" ]; then ok "⑥c --status 唯讀，不回收死鎖"; else fail "⑥c --status 不該動鎖目錄"; fi

# ⑦ 參數驗證
out=$(bash "$lock_sh" --serial '../evil' -- true 2>&1); rc=$?
expect_exit 2 "$rc" "⑦a serial 含路徑分隔符 → exit 2"
out=$(bash "$lock_sh" -- true 2>&1); rc=$?
expect_exit 2 "$rc" "⑦b 缺 --serial → exit 2"
out=$(bash "$lock_sh" --serial emulator-5554 2>&1); rc=$?
expect_exit 2 "$rc" "⑦c 缺命令 → exit 2"
out=$(EMULATOR_LOCK_ROOT=relative/path bash "$lock_sh" --serial x -- true 2>&1); rc=$?
expect_exit 2 "$rc" "⑦d EMULATOR_LOCK_ROOT 非絕對路徑 → exit 2"
out=$(bash "$lock_sh" --serial emulator-5554 --bogus -- true 2>&1); rc=$?
expect_exit 2 "$rc" "⑦e 未知參數 → exit 2"

# ⑧ SIGTERM 時釋放（EXIT trap 靠顯式 exit 143 觸發）
bash "$lock_sh" --serial emulator-5564 -- sleep 30 &
pa=$!
sleep 0.5
# 模擬終端機 Ctrl-C／kill 整個前景行程組：持鎖腳本與它底下的 sleep 30 同時收到 TERM（bash 在前景子行程跑完前不會執行 trap，
# 只殺腳本會等 30 秒——與 simulator-lock.sh 同一個既有行為，不是本腳本的缺陷）
child8=$(pgrep -P "$pa" | head -1)
kill -TERM "$pa" ${child8:+"$child8"} 2>/dev/null; wait "$pa" 2>/dev/null
sleep 0.3
if [ ! -d "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5564" ]; then ok "⑧ SIGTERM（腳本＋前景子行程）後鎖目錄已釋放"; else fail "⑧ SIGTERM 後鎖目錄殘留"; fi

# ⑨ mutation：拿掉 stale 判斷（is_stale 恆為偽）→ ⑤ 的死鎖案例逾時（證明 ⑤ 釘住該判斷）
mut="$work/mut"; mkdir -p "$mut"
python3 - "$lock_sh" "$mut/emulator-lock.sh" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
anchor = "is_stale() {   # 0＝這把鎖是死的（pid 不存在、或建好 30s 仍沒 holder）\n"
assert anchor in s, "anchor missing"
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(anchor, anchor + "  return 1\n", 1))
PY
mkdir "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5566"
printf 'pid=%s\nstarted=%s\n' "$dead" "$(date +%s)" > "$EMULATOR_LOCK_ROOT/emulator-lock-emulator-5566/holder"
out=$(bash "$mut/emulator-lock.sh" --serial emulator-5566 --timeout 1 -- true 2>&1); rc=$?
if [ "$rc" -eq 124 ]; then ok "⑨ mutant：拿掉 stale 判斷後死鎖案例逾時 124（⑤ 確由 is_stale 造成）"; else fail "⑨ mutant 應讓死鎖案例逾時（exit ${rc}）"; fi

if [ "$fail" -eq 0 ] && [ "${selftest_helpers_fail:-0}" -eq 0 ]; then echo "✓ emulator-lock 自測通過"; exit 0; fi
exit 1
