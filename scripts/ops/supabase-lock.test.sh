#!/bin/bash
# supabase-lock.sh 的自測（LS-70）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 lock 本身也適用：若互斥退化（第二個不等）、exit code 沒傳回、逾時不 fail loud、死鎖不回收
# 或回收得太急（剛建好的鎖被殺；判定 stale 之後 mv 到的卻是別人剛建、holder 未落地的活鎖——PR #122 R1 M1）、
# holder 寫入失敗還帶匿名鎖跑（R1 m1）、重入路徑不 export（R1 m2）、殘留或假造的 SUPABASE_LOCK_HELD 能繞過鎖（R1 m3）、
# 收到 TERM 不釋放、run.sh 不再經 lock 重跑——這裡會紅。全程用合成 lock 目錄（SUPABASE_LOCK_DIR），不碰真的
# /tmp/supabase-lock-*、不碰容器；M1／m1 用 PATH shim 放大既有空窗（只在自測程序的 PATH，不改 repo 檔）。
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
has   '⑪ holder 檔含 pid／started／host／worktree／branch／cmd' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null | cut -d= -f1 | paste -s -d, -)" 'pid,started,host,worktree,branch,cmd'
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
# host 故意寫別的名字：/tmp 不跨主機、macOS hostname 會飄，回收不得比 host（PR #122 R1 m4）
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=/dead/wt\nbranch=feature/LS-0-dead\ncmd=sleep 999\n' "$dead" "$(date +%s)" "some-other-host.local" > "$SUPABASE_LOCK_DIR/holder"
st="$(L --status 2>&1)"
has   '⑤ --status 對死鎖標 stale（holder host 不同也一樣）' "$st" 'stale'
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
out="$(SUPABASE_LOCK_POLL=0 L -- true 2>&1)"; rc_is '⑨ SUPABASE_LOCK_POLL=0（busy-spin）→ exit 2（R1 i4）' 2 "$?" "$out"
out="$(SUPABASE_LOCK_POLL=0.1 L -- true 2>&1)"; rc_is '⑨ SUPABASE_LOCK_POLL 低於 0.2 → exit 2（R1 i4）' 2 "$?" "$out"
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

# ---- ⑬ M1（PR #122 R1）：判定 stale 之後、mv 到的卻是別人剛建好、holder 還沒落地的活鎖 → 必須搬回、不得回收 ----
# 用 PATH shim 放大空窗：ps 對這個死 pid 的 -p 查詢延遲 1s（其餘原樣轉交 /bin/ps）。B 在 is_stale 讀到死 holder、卡在
# ps 的那 1 秒內，自測把死鎖換成一個全新的空目錄（＝A 剛 mkdir）；B 回來 mv 到的是活鎖，tomb 無 holder 且很新。
shim="$work/shim"; mkdir -p "$shim"
dead=$(sh -c 'echo $$')
cat > "$shim/ps" <<EOS
#!/bin/bash
if [ "\$1" = -p ] && [ "\$2" = "$dead" ]; then sleep 1; exit 1; fi
exec /bin/ps "\$@"
EOS
chmod +x "$shim/ps"
mkdir "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/dead\nbranch=b\ncmd=c\n' "$dead" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
PATH="$shim:$PATH" bash "$lock_sh" --timeout 3 -- sh -c 'echo B-took-lock' > "$work/m1.out" 2> "$work/m1.err" &
b=$!
sleep 0.4                                   # B 已讀到死 holder、正卡在 shim 的 ps 裡
mv "$SUPABASE_LOCK_DIR" "$work/gone"; mkdir "$SUPABASE_LOCK_DIR"    # ＝A 回收後剛 mkdir，holder 尚未寫
sleep 1.2                                   # B 的 mv 已發生（t≈1.0s）
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/A\nbranch=b\ncmd=A\n' "$$" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder" 2>/dev/null   # A 的 holder 落地
wait "$b"; rc=$?
rc_is '⑬ M1：B 不得取得（等到逾時 124）' 124 "$rc" "$(cat "$work/m1.err")"
hasnt '⑬ M1：B 沒有執行命令' "$(cat "$work/m1.out")" 'B-took-lock'
hasnt '⑬ M1：B 沒有印「回收死鎖」（搬到的是活鎖）' "$(cat "$work/m1.err")" '回收死鎖'
if [ -d "$SUPABASE_LOCK_DIR" ] && grep -q "^pid=$$\$" "$SUPABASE_LOCK_DIR/holder" 2>/dev/null; then echo "✓ ⑬ M1：A 的活鎖仍在原位、holder 是 A"; else echo "✗ ⑬ M1：A 的活鎖被殺或被搬走" >&2; ls -la "$SUPABASE_LOCK_DIR" "$work" >&2; fail=1; fi
if ls -d "$SUPABASE_LOCK_DIR".stale.* >/dev/null 2>&1; then echo "✗ ⑬ M1：殘留 tomb" >&2; ls -d "$SUPABASE_LOCK_DIR".stale.* >&2; fail=1; else echo "✓ ⑬ M1：無殘留 tomb"; fi
rm -rf "$SUPABASE_LOCK_DIR" "$work/gone"

# ---- ⑭ m1（PR #122 R1）：holder 寫不進去 → 不得帶匿名鎖執行：exit 2、自己建的空目錄清掉、命令不跑 ----
cat > "$shim/mv" <<'EOS'
#!/bin/bash
case "${2:-}" in */holder) exit 1 ;; esac
exec /bin/mv "$@"
EOS
chmod +x "$shim/mv"
out="$(PATH="$shim:$PATH" bash "$lock_sh" -- sh -c 'echo ran-anonymous' 2>&1)"; rc=$?
rc_is '⑭ m1：holder 寫入失敗 → exit 2' 2 "$rc" "$out"
has   '⑭ m1：印 holder 寫入失敗' "$out" 'holder 寫入失敗'
hasnt '⑭ m1：命令沒跑' "$out" 'ran-anonymous'
gone  '⑭ m1：自己建的空 lock 目錄已清掉'
rm -f "$shim/mv"

# ---- ⑮ m2（PR #122 R1）：重入路徑也 export SUPABASE_LOCK_HELD；--held 只看祖先、不看變數 ----
out="$(L -- bash -c 'env -u SUPABASE_LOCK_HELD bash "$1" -- sh -c "echo held=\$SUPABASE_LOCK_HELD"' _ "$lock_sh" 2>/dev/null)"; rc=$?
rc_is '⑮ m2：變數被洗掉後重入仍成功' 0 "$rc" "$out"
has   '⑮ m2：重入路徑有 export SUPABASE_LOCK_HELD' "$out" "held=$SUPABASE_LOCK_DIR"
L -- bash -c 'env -u SUPABASE_LOCK_HELD bash "$1" --held' _ "$lock_sh" 2>/dev/null; rc_is '⑮ --held：在 lock 內（變數已洗掉）→ 0' 0 "$?" ''
SUPABASE_LOCK_HELD="$SUPABASE_LOCK_DIR" L --held 2>/dev/null; rc_is '⑮ --held：未持有、只有假變數 → 1' 1 "$?" ''
bash "$lock_sh" -- sleep 2 2>/dev/null &
a=$!
sleep 0.3
SUPABASE_LOCK_HELD="$SUPABASE_LOCK_DIR" L --held 2>/dev/null; rc_is '⑮ --held：別人持有（目錄真的在）、假變數 → 1' 1 "$?" ''
wait "$a"

if [ "$fail" -eq 0 ]; then
  echo "✓ supabase-lock 自測通過"
fi
exit "$fail"
