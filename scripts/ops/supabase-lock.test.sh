#!/bin/bash
# supabase-lock.sh 的自測（LS-70）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 lock 本身也適用：若互斥退化（第二個不等）、exit code 沒傳回、逾時不 fail loud、死鎖不回收
# 或回收得太急（剛建好的鎖被殺）、殘留的 SUPABASE_LOCK_HELD 能繞過鎖、收到 TERM 不釋放、run.sh 不再經 lock
# 重跑——這裡會紅。全程用合成 lock 目錄（SUPABASE_LOCK_DIR），不碰真的 /tmp/supabase-lock-*、不碰容器。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_sh="${root}/scripts/ops/supabase-lock.sh"
run_sh="${root}/supabase/tests/run.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export SUPABASE_LOCK_DIR="$work/lock"
export SUPABASE_LOCK_POLL=0.2
unset SUPABASE_LOCK_HELD SUPABASE_LOCK_TIMEOUT

L() { bash "$lock_sh" "$@"; }   # 前景用；背景持有者一律直接 bash "$lock_sh" … &——經函式背景化時 $! 是子 shell、不是 lock 腳本本身（pid／kill 都會對錯）
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }
gone()  { if [ -e "$SUPABASE_LOCK_DIR" ]; then echo "✗ ${1}（lock 目錄仍在）" >&2; ls -la "$SUPABASE_LOCK_DIR" >&2; fail=1; else echo "✓ $1"; fi; }

# ---- ① 基本：命令 stdout 原樣、exit 0、結束後 lock 釋放；`--` 可省 ----
out="$(L -- sh -c 'echo hello' 2>/dev/null)"; rc=$?
rc_is '① 命令成功 → exit 0' 0 "$rc" "$out"
has   '① 命令 stdout 原樣傳回' "$out" 'hello'
gone  '① 結束後 lock 釋放'
out="$(L sh -c 'echo nodash' 2>/dev/null)"; rc=$?
rc_is '① 省略 -- 也可' 0 "$rc" "$out"
has   '① 省略 -- 輸出' "$out" 'nodash'

# ---- ② exit code 傳回 ----
out="$(L -- sh -c 'exit 7' 2>&1)"; rc=$?
rc_is '② 命令 exit 7 → 包裝也 exit 7' 7 "$rc" "$out"
gone  '② 失敗也釋放 lock'

# ---- ③ 互斥：A 持有 1.5s，B 0.5s 後來必須等到 A 結束（log 順序 A-start A-end B）並印持有者 ----
log="$work/order.log"; : > "$log"
bash "$lock_sh" -- sh -c "echo A-start >> '$log'; sleep 1.5; echo A-end >> '$log'" 2>/dev/null &
a=$!
sleep 0.5
berr="$(L -- sh -c "echo B >> '$log'" 2>&1 >/dev/null)"; rc=$?
wait "$a"
rc_is '③ B 最終成功 exit 0' 0 "$rc" "$berr"
if [ "$(paste -s -d ' ' "$log")" = "A-start A-end B" ]; then echo "✓ ③ B 等到 A 結束才執行（順序 A-start A-end B）"; else echo "✗ ③ 順序錯：$(paste -s -d ' ' "$log")" >&2; fail=1; fi
has   '③ B 等待訊息含持有者 pid' "$berr" "held pid=${a}"
has   '③ B 等待訊息含持有者 worktree' "$berr" 'worktree='
has   '③ B 取得後印等了幾秒' "$berr" '取得 lock'
gone  '③ 全部結束後 lock 釋放'

# ---- ④ 逾時 fail loud：A 持有 3s，B --timeout 1 → exit 124、印逾時與持有者 ----
bash "$lock_sh" -- sleep 3 2>/dev/null &
a=$!
sleep 0.5
berr="$(L --timeout 1 -- true 2>&1)"; rc=$?
rc_is '④ 等待逾時 → exit 124' 124 "$rc" "$berr"
has   '④ 逾時訊息' "$berr" '逾時'
has   '④ 逾時訊息含持有者 pid' "$berr" "held pid=${a}"
has   '④ 逾時訊息含持有者 cmd' "$berr" 'cmd=sleep 3'
# ---- ⑧ --status（趁 A 還持有）：held → free ----
st="$(L --status 2>&1)"
has   '⑧ --status 持有中：held pid=' "$st" "held pid=${a}"
has   '⑧ --status 持有中：含 branch=' "$st" 'branch='
hasnt '⑧ --status 持有中、pid 活著：不標 stale' "$st" 'stale'
has   '⑪ holder 檔含 pid／started／host／worktree／branch／cmd' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null | cut -d= -f1 | paste -s -d, -)" 'pid,started,started_at,host,worktree,branch,cmd'
# ---- 殘留的 SUPABASE_LOCK_HELD 不能繞過鎖（持有者不是祖先）----
berr="$(SUPABASE_LOCK_HELD="$SUPABASE_LOCK_DIR" L --timeout 1 -- true 2>&1)"; rc=$?
rc_is '⑦ 殘留 SUPABASE_LOCK_HELD、持有者非祖先 → 照樣等、逾時 124' 124 "$rc" "$berr"
wait "$a"
st="$(L --status 2>&1)"
has   '⑧ --status 釋放後：free' "$st" 'free'
gone  '④ A 結束後 lock 釋放'
p="$(L --path 2>&1)"
has   '⑧ --path 印 lock 路徑' "$p" "$SUPABASE_LOCK_DIR"

# ---- ⑤ 死鎖回收：holder pid 不存在 → 自動回收、命令照跑；--status 先標 stale ----
dead=$(sh -c 'echo $$')
mkdir "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=/dead/wt\nbranch=feature/LS-0-dead\ncmd=sleep 999\n' "$dead" "$(date +%s)" "$(hostname)" > "$SUPABASE_LOCK_DIR/holder"
st="$(L --status 2>&1)"
has   '⑤ --status 對死鎖標 stale' "$st" 'stale'
out="$(L --timeout 5 -- sh -c 'echo after-reclaim' 2>&1)"; rc=$?
rc_is '⑤ 死鎖自動回收後命令成功' 0 "$rc" "$out"
has   '⑤ 印回收訊息' "$out" '回收死鎖'
has   '⑤ 回收訊息含死鎖 worktree' "$out" '/dead/wt'
has   '⑤ 命令執行' "$out" 'after-reclaim'
gone  '⑤ 結束後 lock 釋放'

# ---- ⑥ holder 檔缺失：建好 >30s 視為死鎖回收；剛建好的不回收（負向，避免殺掉正在寫 holder 的新鎖）----
mkdir "$SUPABASE_LOCK_DIR"; touch -t 202001010000 "$SUPABASE_LOCK_DIR"
out="$(L --timeout 5 -- sh -c 'echo ok6' 2>&1)"; rc=$?
rc_is '⑥ 無 holder 且目錄很老 → 回收、命令成功' 0 "$rc" "$out"
has   '⑥ 命令執行' "$out" 'ok6'
gone  '⑥ 結束後 lock 釋放'
mkdir "$SUPABASE_LOCK_DIR"
out="$(L --timeout 1 -- true 2>&1)"; rc=$?
rc_is '⑥ 無 holder 但剛建好 → 不回收、逾時 124' 124 "$rc" "$out"
if [ -d "$SUPABASE_LOCK_DIR" ]; then echo "✓ ⑥ 剛建好的 lock 目錄沒被殺"; else echo "✗ ⑥ 剛建好的 lock 目錄被誤殺" >&2; fail=1; fi
rmdir "$SUPABASE_LOCK_DIR"

# ---- ⑦ 重入：lock 內再呼叫 lock（持有者是祖先）直接執行、不等自己 ----
out="$(L -- bash -c 'SUPABASE_LOCK_TIMEOUT=1 bash "$1" -- echo inner' _ "$lock_sh" 2>&1)"; rc=$?
rc_is '⑦ 重入 exit 0（沒等到逾時）' 0 "$rc" "$out"
has   '⑦ 重入直接執行' "$out" 'inner'
has   '⑦ 重入印「已在 lock 內」' "$out" '已在 lock 內'
gone  '⑦ 外層結束後 lock 釋放'

# ---- ⑨ 參數錯誤 fail closed（exit 2）----
out="$(L 2>&1)"; rc_is '⑨ 缺命令 → exit 2' 2 "$?" "$out"
out="$(L -- 2>&1)"; rc_is '⑨ -- 後無命令 → exit 2' 2 "$?" "$out"
out="$(L --timeout abc -- true 2>&1)"; rc_is '⑨ --timeout 非整數 → exit 2' 2 "$?" "$out"
out="$(L --timeout 2>&1)"; rc_is '⑨ --timeout 缺值 → exit 2' 2 "$?" "$out"
out="$(L --bogus -- true 2>&1)"; rc_is '⑨ 未知參數 → exit 2' 2 "$?" "$out"
out="$(SUPABASE_LOCK_POLL=x L -- true 2>&1)"; rc_is '⑨ SUPABASE_LOCK_POLL 非數字 → exit 2' 2 "$?" "$out"
out="$(SUPABASE_LOCK_DIR= L --path 2>&1)"; rc=$?
# 沒設 SUPABASE_LOCK_DIR 時走 config.toml 的 project_id（真 repo 有 config.toml → 印 /tmp/supabase-lock-<id>）
if [ -f "$root/supabase/config.toml" ]; then
  rc_is '⑨ 預設路徑自 config.toml project_id 推得' 0 "$rc" "$out"
  has   '⑨ 預設路徑 /tmp/supabase-lock-<project_id>' "$out" '/tmp/supabase-lock-'
fi

# ---- ⑩ 信號：持有者收到 TERM → 等命令結束、釋放 lock、exit 143 ----
bash "$lock_sh" -- sleep 1 2>/dev/null &
a=$!
sleep 0.3
kill -TERM "$a"
wait "$a"; rc=$?
rc_is '⑩ TERM → exit 143' 143 "$rc" ''
gone  '⑩ TERM 後 lock 釋放'

# ---- ⑫ run.sh 未在 lock 內會自己經 lock 重跑（A 持有 2s、逾時 1s → 124，且沒走到連線那一步）----
if [ -f "$run_sh" ]; then
  bash "$lock_sh" -- sleep 2 2>/dev/null &
  a=$!
  sleep 0.3
  out="$(SUPABASE_LOCK_TIMEOUT=1 bash "$run_sh" 2>&1)"; rc=$?
  wait "$a"
  rc_is '⑫ run.sh 裸跑 → 經 lock 等待、逾時 124' 124 "$rc" "$out"
  has   '⑫ run.sh 印「改經 lock 重新執行」' "$out" '重新執行'
  has   '⑫ 等待訊息含持有者' "$out" "held pid=${a}"
  hasnt '⑫ 沒拿到 lock 就不得連 DB' "$out" '連線方式'
else
  echo "✗ ⑫ 找不到 ${run_sh}" >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ supabase-lock 自測通過"
fi
exit "$fail"
