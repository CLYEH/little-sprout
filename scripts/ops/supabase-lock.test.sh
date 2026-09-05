#!/bin/bash
# supabase-lock.sh 的自測（LS-70）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 lock 本身也適用：若互斥退化（第二個不等）、exit code 沒傳回、逾時不 fail loud、死鎖不回收
# 或回收得太急（剛建好的鎖被殺；判定 stale 之後 mv 到的卻是別人剛建、holder 未落地的活鎖——PR #122 R1 M1）、
# holder 寫入失敗還帶匿名鎖跑（R1 m1）、重入路徑不 export（R1 m2）、殘留或假造的 SUPABASE_LOCK_HELD 能繞過鎖（R1 m3）、
# 兩個都以為自己取得的程序互相認領對方的 holder 暫存檔（R2 F1）、搬回活鎖時把 tomb 塞進第三者的目錄或不出聲（R2 F3）、
# 殘留 tomb 在 --status 看不到（R2 F2）、收到 TERM 不釋放、run.sh 不再經 lock 重跑——這裡會紅。全程用合成 lock 目錄（SUPABASE_LOCK_DIR），不碰真的
# /tmp/supabase-lock-*、不碰容器；M1／m1 用 PATH shim 放大既有空窗（只在自測程序的 PATH，不改 repo 檔）。
# LS-159 hold（㉑–㉕）：--hold 後非持有者排隊且訊息含 label／持有者重入與 --held／非持有者 --release 被拒／持有者 --release 立即讓出／
# 到期自動釋放／守門被 -9 走既有死鎖回收——退化這裡會紅；心跳與到期用 SUPABASE_LOCK_HOLD_TICK／SUPABASE_LOCK_HOLD_SECONDS 縮成秒級。
# PR #265 R1（㉗–㉙）：守門死後 --release 與等待者回收競爭不得刪第三者新鎖（N1，ps shim 放大窗口）／owner 已死（pid 重用形狀）別的
# worktree 不得通過（N2，ps shim 把活著的 owner 報成不存在）／label 含換行或過長在碰 lock 前就 exit 2（N3）。
# LS-184（㉛）：--hold 在主 checkout（git-dir＝git-common-dir）直接 exit 2＋「cd <worktree> && … --hold」指引、不留 lock／linked worktree 照常／
# LS_LOCK_ALLOW_MAIN=1 明示放行（=0 不算）／`--` 包裝模式在主 checkout 不受此限——夾具用 `git init` 空 repo 與手搭的 linked worktree，不 commit。
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

# 自測裡每一次呼叫 run.sh 都帶這組：DB 指向不存在的 port／容器（離散參數，不寫含帳密的連線字串——secrets 掃描會擋）。
# 就算時序滑掉、run.sh 真的拿到 lock，也只會在連線那一步很快失敗（exit 1），絕不碰共用容器（R2 自測曾因持有者
# 提前結束而實跑到 docker exec 的容器——這組參數是防線，不是最佳化）。
NO_DB=(env -u SUPABASE_DB_URL SUPABASE_DB_HOST=127.0.0.1 SUPABASE_DB_PORT=1 SUPABASE_DB_CONTAINER=no-such-container-LS70)
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
hasnt '⑧ --status 持有中、pid 活著：不標 stale' "$st" '⚠ stale'
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
has   '⑤ --status 對死鎖標 stale（holder host 不同也一樣）' "$st" '⚠ stale'
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
  bash "$lock_sh" -- sleep 4 2>/dev/null &
  a=$!
  sleep 0.3
  has   '⑫ 前提：A 持有中' "$(L --status 2>&1)" "held pid=${a}"
  out="$("${NO_DB[@]}" SUPABASE_LOCK_TIMEOUT=1 bash "$run_sh" 2>&1)"; rc=$?
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

# ---- ⑯ m3（PR #122 R1）：run.sh 不信環境變數——假的／殘留的 SUPABASE_LOCK_HELD 不得繞過 lock ----
bash "$lock_sh" -- sleep 6 2>/dev/null &
a=$!
sleep 0.3
has   '⑯ 前提：A 持有中（案例一）' "$(L --status 2>&1)" "held pid=${a}"
out="$("${NO_DB[@]}" SUPABASE_LOCK_HELD=/tmp/does-not-exist-LS70 SUPABASE_LOCK_TIMEOUT=1 bash "$run_sh" 2>&1)"; rc=$?
rc_is '⑯ m3：假路徑變數 → run.sh 仍經 lock 等待、逾時 124' 124 "$rc" "$out"
hasnt '⑯ m3：沒連 DB' "$out" '連線方式'
has   '⑯ 前提：A 持有中（案例二）' "$(L --status 2>&1)" "held pid=${a}"
out="$("${NO_DB[@]}" SUPABASE_LOCK_HELD="$SUPABASE_LOCK_DIR" SUPABASE_LOCK_TIMEOUT=1 bash "$run_sh" 2>&1)"; rc=$?
rc_is '⑯ m3：變數指向真的 lock 目錄、持有者不是祖先 → 仍等待、逾時 124' 124 "$rc" "$out"
hasnt '⑯ m3：沒連 DB（真目錄假變數）' "$out" '連線方式'
wait "$a"

# ---- ⑰ m2（PR #122 R1）：lock 內、變數被洗掉 → run.sh 不得 exec 回 lock 無窮迴圈，要走過前言到連線那一步 ----
# DB 一樣指向不存在的 port／容器（NO_DB）：走到連線就很快失敗（exit 1）；看門狗 20s 防迴圈（迴圈是單一程序
# 連環 exec，殺 lock 包裝的子程序即可）。
with_watchdog() {   # $1=秒 其餘=命令；逾時殺命令的子程序與命令、回 124
  local secs=$1 pid wd rc; shift
  "$@" & pid=$!
  ( sleep "$secs"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$rc" -eq 143 ] && return 124
  return "$rc"
}
out="$(with_watchdog 20 bash "$lock_sh" -- "${NO_DB[@]}" env -u SUPABASE_LOCK_HELD bash "$run_sh" 2>&1)"; rc=$?
rc_is '⑰ m2：不迴圈、走到連線失敗 exit 1（非看門狗 124）' 1 "$rc" "$out"
hasnt '⑰ m2：前言沒有 exec 回 lock' "$out" '重新執行'
if printf '%s' "$out" | grep -qE '連線方式|找不到 psql'; then echo "✓ ⑰ m2：已走過前言到連線那一步"; else echo "✗ ⑰ m2：沒走到連線那一步" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
gone  '⑰ m2：結束後 lock 釋放'

# ---- ⑱ F1（PR #122 R2）：兩個程序都以為自己 mkdir 成功、holder 寫入交錯——暫存檔以 pid 唯一化，不得互相認領 ----
# shim：mkdir 一律回 0（第二個程序也「取得」）；mv 對 …/holder 先 sleep $MV_SLEEP 再真的搬。P1 先搬（0.3s）、P2 後搬（0.8s）。
# P1 的命令 1.0s 後結束時 holder 已是 P2 的 → P1 不得誤刪；P2 結束才釋放。舊寫法（固定 holder.tmp）：P2 覆寫 P1 的暫存檔、
# P1 搬走的是 P2 的內容、P2 的 mv 找不到來源 → 印「holder 寫入失敗」exit 2——這裡會紅。
cat > "$shim/mkdir" <<'EOS'
#!/bin/bash
/bin/mkdir "$@" 2>/dev/null; exit 0
EOS
cat > "$shim/mv" <<'EOS'
#!/bin/bash
case "${2:-}" in */holder) sleep "${MV_SLEEP:-0}" ;; esac
exec /bin/mv "$@"
EOS
chmod +x "$shim/mkdir" "$shim/mv"
PATH="$shim:$PATH" MV_SLEEP=0.3 bash "$lock_sh" -- sleep 1.0 > /dev/null 2> "$work/p1.err" &
p1=$!
PATH="$shim:$PATH" MV_SLEEP=0.8 bash "$lock_sh" -- sleep 1.5 > /dev/null 2> "$work/p2.err" &
p2=$!
wait "$p1"; rc1=$?
rc_is '⑱ F1：P1 exit 0' 0 "$rc1" "$(cat "$work/p1.err")"
if [ -d "$SUPABASE_LOCK_DIR" ] && grep -q "^pid=${p2}\$" "$SUPABASE_LOCK_DIR/holder" 2>/dev/null; then echo "✓ ⑱ F1：P1 結束時 holder 是 P2 的、P1 沒有誤刪"; else echo "✗ ⑱ F1：P1 結束後 lock 狀態錯" >&2; ls -la "$SUPABASE_LOCK_DIR" 2>&1 | sed 's/^/    /' >&2; fail=1; fi
wait "$p2"; rc2=$?
rc_is '⑱ F1：P2 exit 0' 0 "$rc2" "$(cat "$work/p2.err")"
hasnt '⑱ F1：P1 沒印 holder 寫入失敗' "$(cat "$work/p1.err")" 'holder 寫入失敗'
hasnt '⑱ F1：P2 沒印 holder 寫入失敗（沒認領到 P1 的暫存檔）' "$(cat "$work/p2.err")" 'holder 寫入失敗'
gone  '⑱ F1：P2 結束後釋放'
rm -f "$shim/mkdir" "$shim/mv"

# ---- ⑲ F3／F2（PR #122 R2）：搬回時 $lock 已被第三者建立（非空）→ rename(2) 失敗、tomb 保留原地＋大聲印；--status 列出 tomb ----
# shim：mv 對 …stale… 目標（reclaim 的「搬走」）真的搬完後 sleep 1；那 1 秒內自測 (1) 把 tomb 的 holder 改成別的 pid，讓 B
# 判定「搬到的不是那把死鎖」而搬回，(2) 建第三者 C 的 lock（含 holder、pid 活著）→ 搬回目標非空 → 必須失敗且不塞進去。
cat > "$shim/mv" <<'EOS'
#!/bin/bash
case "${2:-}" in *.stale.*) /bin/mv "$@"; rc=$?; sleep 1; exit "$rc" ;; esac
exec /bin/mv "$@"
EOS
chmod +x "$shim/mv"
dead=$(sh -c 'echo $$')
mkdir "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/dead\nbranch=b\ncmd=c\n' "$dead" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
PATH="$shim:$PATH" bash "$lock_sh" --timeout 3 -- sh -c 'echo B-took-lock' > "$work/f3.out" 2> "$work/f3.err" &
b=$!
sleep 0.5                                   # B 已把死鎖搬到 tomb、卡在 shim 的 sleep
tomb=$(ls -d "$SUPABASE_LOCK_DIR".stale.* 2>/dev/null | head -1)
if [ -n "$tomb" ]; then echo "✓ ⑲ 前提：tomb 已建立"; else echo "✗ ⑲ 前提：找不到 tomb" >&2; fail=1; tomb="$SUPABASE_LOCK_DIR.stale.none"; fi
other=$(sh -c 'echo $$')
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/other\nbranch=b\ncmd=c\n' "$other" "$(date +%s)" > "$tomb/holder" 2>/dev/null
mkdir "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/C\nbranch=b\ncmd=C\n' "$$" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
wait "$b"; rc=$?
rc_is '⑲ F3：B 搬不回 → 改等 C、逾時 124' 124 "$rc" "$(cat "$work/f3.err")"
hasnt '⑲ F3：B 沒有執行命令' "$(cat "$work/f3.out")" 'B-took-lock'
has   '⑲ F3：B 大聲印搬回失敗' "$(cat "$work/f3.err")" '搬回誤搬的活鎖失敗'
if [ -d "$tomb" ] && [ ! -e "$SUPABASE_LOCK_DIR/$(basename "$tomb")" ]; then echo "✓ ⑲ F3：tomb 保留原地、沒被塞進 C 的目錄"; else echo "✗ ⑲ F3：tomb 不在原地或被塞進 lock" >&2; ls -la "$SUPABASE_LOCK_DIR" "$work" 2>&1 | sed 's/^/    /' >&2; fail=1; fi
if grep -q "^pid=$$\$" "$SUPABASE_LOCK_DIR/holder" 2>/dev/null; then echo "✓ ⑲ F3：C 的 lock 完好"; else echo "✗ ⑲ F3：C 的 lock 被動了" >&2; fail=1; fi
st="$(L --status 2>&1)"
has   '⑲ F2：--status 列出殘留 tomb（目錄名）' "$st" "tomb $(basename "$tomb")"
has   '⑲ F2：tomb 行標 ⚠ 並含 age=' "$st" 'age='
has   '⑲ F2：tomb 行含 holder_pid' "$st" "holder_pid=${other}"
rm -rf "$SUPABASE_LOCK_DIR" "$tomb"
st="$(L --status 2>&1)"
hasnt '⑲ F2：清掉後 --status 不再列 tomb' "$st" 'tomb'
has   '⑲ F2：清掉後 free' "$st" 'free'
rm -f "$shim/mv"

# ======== LS-159 QA 持有（hold）========
# 「陌生人」＝從別的 cwd 呼叫（$work 不是 git repo → holder worktree＝pwd）、且 owner（呼叫 --hold 的父 shell）已退出：經
# `bash -c '…; :'` 中介——最後一個命令是 builtin，前面那個 bash 不會被 exec 最佳化掉，owner＝中介 bash、隨即結束。
# 「持有者」兩條腿：同 worktree（wtA→wtA）、或 owner 是祖先（本自測程序直接 --hold、從 wtB 呼叫）。
wtA="$work/wtA"; wtB="$work/wtB"; mkdir -p "$wtA" "$wtB"
hold_log="$SUPABASE_LOCK_DIR.hold.log"
export SUPABASE_LOCK_HOLD_TICK=0.2
palive() { ps -p "$1" -o pid= >/dev/null 2>&1; }
hpid()   { sed -n 's/^pid=//p' "$SUPABASE_LOCK_DIR/holder" 2>/dev/null; }
hold_as_stranger() { (cd "$wtA" && bash -c 'bash "$1" --hold "$2" "${@:3}"; :' _ "$lock_sh" "$@" 2>&1); }   # $1=label 其餘=額外參數

# ---- ㉑ --hold：主程序立即返回（守門不繼承呼叫者的管線）、holder 欄位、--status／等待訊息含「持有中（label，剩餘 n 分）」、
#        非持有者排隊逾時 124 且命令沒跑、持有者（同 worktree）-- 命令重入直接執行、--held 兩邊、心跳前進、已持有再 --hold 被拒 ----
t0=$SECONDS
out="$(hold_as_stranger 'LS-0 QA 冒煙' --max-minutes 1)"; rc=$?
el=$((SECONDS - t0))
rc_is '㉑ --hold exit 0' 0 "$rc" "$out"
if [ "$el" -le 5 ]; then echo "✓ ㉑ --hold 立即返回（${el}s；守門不繼承 stdout／stderr）"; else echo "✗ ㉑ --hold 花了 ${el}s 才返回（守門是否繼承了管線？）" >&2; fail=1; fi
gpid=$(hpid)
has   '㉑ 印 held pid=<守門 pid> label=… expires=hh:mm' "$out" "held pid=${gpid} label=LS-0 QA 冒煙 expires="
has   '㉑ 印 log 路徑' "$out" "log=${hold_log}"
if palive "$gpid"; then echo "✓ ㉑ 守門程序活著（pid ${gpid}）"; else echo "✗ ㉑ 守門程序不在（pid ${gpid}）" >&2; cat "$hold_log" >&2; fail=1; fi
has   '㉑ holder 欄位 pid…cmd＋owner／expires_at／heartbeat' "$(cut -d= -f1 "$SUPABASE_LOCK_DIR/holder" 2>/dev/null | paste -s -d, -)" 'pid,started,host,worktree,branch,cmd,owner,expires_at,heartbeat'
has   '㉑ holder cmd=hold:<label>' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null)" 'cmd=hold:LS-0 QA 冒煙'
has   '㉑ holder worktree＝呼叫 --hold 的 cwd' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null)" "worktree=${wtA}"
st="$(L --status 2>&1)"
has   '㉑ --status 印 持有中（label，剩餘 n 分）' "$st" '持有中（LS-0 QA 冒煙，剩餘 1 分）'
has   '㉑ --status 仍以 held pid= 開頭（巡檢／既有解析不變）' "$st" "held pid=${gpid} "
hasnt '㉑ --status 守門活著不標 stale' "$st" '⚠ stale'
hb1=$(sed -n 's/^heartbeat=//p' "$SUPABASE_LOCK_DIR/holder"); sleep 1.2; hb2=$(sed -n 's/^heartbeat=//p' "$SUPABASE_LOCK_DIR/holder")
if [ -n "$hb1" ] && [ -n "$hb2" ] && [ "$hb2" -gt "$hb1" ]; then echo "✓ ㉑ 守門每 tick 更新 heartbeat（${hb1}→${hb2}）"; else echo "✗ ㉑ heartbeat 沒前進（${hb1}→${hb2}）" >&2; fail=1; fi
berr="$(cd "$wtB" && bash "$lock_sh" --timeout 1 -- sh -c 'echo stranger-ran' 2>&1)"; rc=$?
rc_is '㉑ 非持有者 -- 命令排隊、逾時 124' 124 "$rc" "$berr"
has   '㉑ 等待訊息含 持有中（label，剩餘' "$berr" '等待中'
has   '㉑ 等待／逾時訊息含 label 與剩餘分鐘' "$berr" '持有中（LS-0 QA 冒煙，剩餘'
hasnt '㉑ 非持有者命令沒跑' "$berr" 'stranger-ran'
(cd "$wtB" && bash "$lock_sh" --held 2>/dev/null); rc_is '㉑ 非持有者 --held → 1' 1 "$?" ''
out="$(cd "$wtA" && bash "$lock_sh" --timeout 1 -- sh -c 'echo owner-ran' 2>&1)"; rc=$?
rc_is '㉑ 同 worktree 的 -- 命令走 hold 重入、exit 0' 0 "$rc" "$out"
has   '㉑ 重入印「已在自己的 hold 內」＋label' "$out" '已在自己的 hold 內（LS-0 QA 冒煙'
has   '㉑ 重入命令執行' "$out" 'owner-ran'
hasnt '㉑ 重入沒有等待' "$out" '等待中'
(cd "$wtA" && bash "$lock_sh" --held 2>/dev/null); rc_is '㉑ 同 worktree --held → 0' 0 "$?" ''
if [ "$(hpid)" = "$gpid" ]; then echo "✓ ㉑ 重入命令結束後 hold 仍在（沒被誤釋放）"; else echo "✗ ㉑ 重入命令結束後 hold 不見或換人" >&2; fail=1; fi
out="$(cd "$wtA" && bash "$lock_sh" --hold again 2>&1)"; rc_is '㉑ 已持有再 --hold → 專屬 exit 3（LS-158 R1 N2：呼叫端判碼沿用，不比對訊息）' 3 "$?" "$out"
has   '㉑ 再 --hold 的訊息提示先 --release' "$out" '先 --release'
# 經 wrapper 重入後再 --hold 也回 3（這裡 holder 是守門、非祖先，落在「已持有 hold」分支；「已在 lock 內」分支同碼）
out="$(cd "$wtA" && bash "$lock_sh" -- bash "$lock_sh" --hold nested 2>&1)"; rc_is '㉑ hold 內經 wrapper 重入再 --hold → 也是 exit 3' 3 "$?" "$out"

# ---- ㉔ 非持有者 --release 被拒：exit 2、印持有者資訊、守門仍活、lock 仍在；命令型持有 --release 也拒；free 時 exit 1 ----
out="$(cd "$wtB" && bash "$lock_sh" --release 2>&1)"; rc=$?
rc_is '㉔ 非持有者 --release → exit 2' 2 "$rc" "$out"
has   '㉔ 拒絕訊息含持有者 label' "$out" '持有中（LS-0 QA 冒煙'
has   '㉔ 拒絕訊息含持有者 worktree' "$out" "worktree=${wtA}"
if palive "$gpid"; then echo "✓ ㉔ 守門未被殺"; else echo "✗ ㉔ 守門被非持有者殺掉" >&2; fail=1; fi
if [ "$(hpid)" = "$gpid" ]; then echo "✓ ㉔ lock 仍在、holder 未變"; else echo "✗ ㉔ lock 被非持有者動了" >&2; fail=1; fi

# ---- ㉒ 持有者 --release：同 worktree（owner 已退出）→ exit 0、印持有時長、守門結束、lock 消失；之後另一 worktree 立即取得 ----
out="$(cd "$wtA" && bash "$lock_sh" --release 2>&1)"; rc=$?
rc_is '㉒ 同 worktree --release → exit 0' 0 "$rc" "$out"
has   '㉒ 印持有時長' "$out" '已釋放 hold「LS-0 QA 冒煙」（持有 0 分'
gone  '㉒ --release 後 lock 消失'
sleep 0.3
if palive "$gpid"; then echo "✗ ㉒ 守門仍活著（pid ${gpid}）" >&2; kill -9 "$gpid" 2>/dev/null; fail=1; else echo "✓ ㉒ 守門已結束"; fi
out="$(cd "$wtB" && bash "$lock_sh" --timeout 2 -- sh -c 'echo after-release' 2>&1)"; rc=$?
rc_is '㉒ 釋放後另一 worktree 立即取得、exit 0' 0 "$rc" "$out"
has   '㉒ 命令執行' "$out" 'after-release'
hasnt '㉒ 沒有等待' "$out" '等待中'
gone  '㉒ 命令結束後釋放'
out="$(L --release 2>&1)"; rc_is '㉒ free 時 --release → exit 1（提示可能已到期）' 1 "$?" "$out"
has   '㉒ free 時訊息提示可能已到期' "$out" '可能已到期'
# owner 是祖先、worktree 不同：本自測程序直接 --hold（owner＝本程序、worktree＝repo），從 wtB --release → 允許
# LS_LOCK_ALLOW_MAIN=1：本自測在 CI／主 checkout 執行時 cwd 就是主 checkout，LS-184 起會被拒——這一組驗的是 owner 祖先腿，明示放行（拒絕本身由 ㉛ 驗）
LS_LOCK_ALLOW_MAIN=1 bash "$lock_sh" --hold 'LS-0 祖先' > "$work/anc.out" 2>&1; rc_is '㉒ 前提：本程序直接 --hold' 0 "$?" "$(cat "$work/anc.out")"
gpid=$(hpid)
has   '㉒ 前提：holder owner＝本自測程序' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null)" "owner=$$"
out="$(cd "$wtB" && bash "$lock_sh" --release 2>&1)"; rc=$?
rc_is '㉒ owner 是祖先、worktree 不同 → --release 允許 exit 0' 0 "$rc" "$out"
gone  '㉒ 祖先釋放後 lock 消失'
# 命令型持有不能被 --release
bash "$lock_sh" -- sleep 2 2>/dev/null &
a=$!
sleep 0.3
out="$(L --release 2>&1)"; rc_is '㉒ 命令型持有 --release → exit 2' 2 "$?" "$out"
has   '㉒ 命令型持有拒絕訊息' "$out" '不是 hold'
if [ "$(hpid)" = "$a" ]; then echo "✓ ㉒ 命令型持有未被動"; else echo "✗ ㉒ 命令型持有被 --release 動了" >&2; fail=1; fi
wait "$a"

# ---- ㉓ 到期自動釋放：SUPABASE_LOCK_HOLD_SECONDS=1 → 約 1–2s 後 lock 消失、守門結束、log 印到期一行；之後立即取得、不是「回收死鎖」 ----
out="$(SUPABASE_LOCK_HOLD_SECONDS=1 hold_as_stranger 'LS-0 到期')"; rc_is '㉓ --hold exit 0' 0 "$?" "$out"
gpid=$(hpid)
i=0; while [ -e "$SUPABASE_LOCK_DIR" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
gone  '㉓ 到期後 lock 自動釋放（≤5s）'
sleep 0.3
if palive "$gpid"; then echo "✗ ㉓ 到期後守門仍活著" >&2; kill -9 "$gpid" 2>/dev/null; fail=1; else echo "✓ ㉓ 到期後守門結束"; fi
has   '㉓ log 印到期一行' "$(cat "$hold_log" 2>/dev/null)" 'hold「LS-0 到期」到期'
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} hold「LS-0 到期」到期' "$hold_log" 2>/dev/null; then echo "✓ ㉓ 到期行與其他回溯行同格式（行首時間，PR #276 R1 I-2）"; else echo "✗ ㉓ 到期行行首沒有 YYYY-MM-DD HH:MM:SS" >&2; cat "$hold_log" >&2; fail=1; fi
out="$(cd "$wtB" && bash "$lock_sh" --timeout 2 -- sh -c 'echo after-expiry' 2>&1)"; rc=$?
rc_is '㉓ 到期後另一 worktree 立即取得' 0 "$rc" "$out"
has   '㉓ 命令執行' "$out" 'after-expiry'
hasnt '㉓ 沒有等待' "$out" '等待中'
hasnt '㉓ 是正常釋放、不是死鎖回收' "$out" '回收死鎖'

# ---- ㉕ 守門被 -9：--status 標 stale 仍印 label；持有者 --held 不再算在 lock 內；等待者走既有死鎖回收取得；持有者 --release 也能清掉 ----
out="$(hold_as_stranger 'LS-0 被殺')"; rc_is '㉕ 前提：--hold' 0 "$?" "$out"
gpid=$(hpid); kill -9 "$gpid" 2>/dev/null; sleep 0.3
st="$(L --status 2>&1)"
has   '㉕ 守門死後 --status 標 stale' "$st" '⚠ stale'
has   '㉕ 守門死後 --status 仍印 label' "$st" '持有中（LS-0 被殺'
(cd "$wtA" && bash "$lock_sh" --held 2>/dev/null); rc_is '㉕ 守門死後同 worktree --held → 1（沒有保護了）' 1 "$?" ''
out="$(cd "$wtB" && bash "$lock_sh" --timeout 5 -- sh -c 'echo after-kill' 2>&1)"; rc=$?
rc_is '㉕ 等待者回收死鎖後取得、exit 0' 0 "$rc" "$out"
has   '㉕ 印回收死鎖（含 hold label）' "$out" '回收死鎖'
has   '㉕ 回收訊息含 cmd hold:<label>' "$out" 'hold:LS-0 被殺'
has   '㉕ 命令執行' "$out" 'after-kill'
gone  '㉕ 結束後釋放'
out="$(hold_as_stranger 'LS-0 被殺二')"; rc_is '㉕ 前提：再 --hold' 0 "$?" "$out"
gpid=$(hpid); kill -9 "$gpid" 2>/dev/null; sleep 0.3
out="$(cd "$wtA" && bash "$lock_sh" --release 2>&1)"; rc=$?
rc_is '㉕ 守門死後持有者 --release 仍可清掉、exit 0' 0 "$rc" "$out"
gone  '㉕ --release 清掉死守門的 lock'

# ---- ㉖ 參數 fail closed（exit 2）----
out="$(L --hold 2>&1)"; rc_is '㉖ --hold 缺 label → exit 2' 2 "$?" "$out"
out="$(L --hold x --max-minutes 0 2>&1)"; rc_is '㉖ --max-minutes 0 → exit 2' 2 "$?" "$out"
out="$(L --hold x --max-minutes 61 2>&1)"; rc_is '㉖ --max-minutes 61 → exit 2' 2 "$?" "$out"
out="$(L --hold x --max-minutes abc 2>&1)"; rc_is '㉖ --max-minutes 非整數 → exit 2' 2 "$?" "$out"
out="$(L --hold x -- true 2>&1)"; rc_is '㉖ --hold 接命令 → exit 2' 2 "$?" "$out"
out="$(SUPABASE_LOCK_HOLD_TICK=0.1 L --hold x 2>&1)"; rc_is '㉖ SUPABASE_LOCK_HOLD_TICK 低於 0.2 → exit 2' 2 "$?" "$out"
out="$(SUPABASE_LOCK_HOLD_SECONDS=0 L --hold x 2>&1)"; rc_is '㉖ SUPABASE_LOCK_HOLD_SECONDS=0 → exit 2' 2 "$?" "$out"
out="$(L --hold-guard only-one-arg 2>&1)"; rc_is '㉖ --hold-guard 參數數量錯 → exit 2' 2 "$?" "$out"
gone  '㉖ 參數錯誤沒留下 lock'

# ---- ㉗ N1（PR #265 R1）：守門已死、--release 與等待者的回收競爭——刪除須走 mv→核對→rm，不得刪到第三者剛取得的新鎖 ----
# (a) 釘住修法的案：rm shim 把「對 lock 路徑（含 tomb）的 rm」延遲 1s，放大「核對之後、真正刪除之前」的窗口；那 1 秒內自測扮演
#     等待者：回收死鎖＋mkdir＋寫自己的 holder（pid=$$）。舊寫法（read→rm -rf $lock）：核對時 holder 還是死守門的 → 進 rm →
#     shim 睡 1s 期間第三者取得同一路徑 → 真正 rm 掉的是第三者的鎖——這裡會紅（R1 i6 的缺口，mutation 已驗）。新寫法先原子 mv
#     到 tomb 再核對、rm 的是 tomb，第三者在原路徑 mkdir 的新鎖不受影響。
out="$(hold_as_stranger 'LS-0 N1')"; rc_is '㉗ 前提：--hold' 0 "$?" "$out"
gpid=$(hpid); kill -9 "$gpid" 2>/dev/null; sleep 0.3
cat > "$shim/rm" <<EOS
#!/bin/bash
case " \$* " in *" $SUPABASE_LOCK_DIR"*) sleep 1 ;; esac
exec /bin/rm "\$@"
EOS
chmod +x "$shim/rm"
(cd "$wtA" && PATH="$shim:$PATH" bash "$lock_sh" --release) > "$work/n1.out" 2> "$work/n1.err" &
r=$!
sleep 0.4                                   # --release 已核對完、正卡在 rm shim 的 sleep 裡
mv "$SUPABASE_LOCK_DIR" "$work/n1-gone" 2>/dev/null; rm -rf "$work/n1-gone"; mkdir "$SUPABASE_LOCK_DIR"    # ＝等待者回收死鎖後 mkdir（新寫法下原路徑已被 mv 走，mv 失敗無妨）
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/C\nbranch=b\ncmd=C\n' "$$" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"   # 等待者的 holder 落地
wait "$r"; rc=$?
rc_is '㉗ N1(a)：--release exit 0' 0 "$rc" "$(cat "$work/n1.err")"
if [ -d "$SUPABASE_LOCK_DIR" ] && grep -q "^pid=$$\$" "$SUPABASE_LOCK_DIR/holder" 2>/dev/null; then echo "✓ ㉗ N1(a)：第三者的新鎖仍在原位、holder 是它的（rm 掉的是 tomb）"; else echo "✗ ㉗ N1(a)：第三者的新鎖被 --release 刪掉（check-then-delete）" >&2; ls -la "$SUPABASE_LOCK_DIR" "$work" 2>&1 | sed 's/^/    /' >&2; fail=1; fi
if ls -d "$SUPABASE_LOCK_DIR".stale.* >/dev/null 2>&1; then echo "✗ ㉗ N1(a)：殘留 tomb" >&2; ls -d "$SUPABASE_LOCK_DIR".stale.* >&2; fail=1; else echo "✓ ㉗ N1(a)：死守門的 tomb 已刪、無殘留"; fi
rm -rf "$SUPABASE_LOCK_DIR"; rm -f "$shim/rm"
# (b) 搬回路徑：ps shim 把 alive(死守門) 延遲 1s，讓第三者在 --release 的 mv **之前**就取得——mv 到的是第三者的活鎖，核對不符須搬回、
#     不刪、印「已被其他等待者回收並取得」（舊寫法此案也不刪——它 read 到的已是新 holder——所以 (b) 只驗搬回路徑，釘修法靠 (a)）。
out="$(hold_as_stranger 'LS-0 N1b')"; rc_is '㉗ 前提：--hold（b）' 0 "$?" "$out"
gpid=$(hpid); kill -9 "$gpid" 2>/dev/null; sleep 0.3
cat > "$shim/ps" <<EOS
#!/bin/bash
if [ "\${1:-}" = -p ] && [ "\${2:-}" = "$gpid" ]; then sleep 1; exit 1; fi
exec /bin/ps "\$@"
EOS
chmod +x "$shim/ps"
(cd "$wtA" && PATH="$shim:$PATH" bash "$lock_sh" --release) > "$work/n1b.out" 2> "$work/n1b.err" &
r=$!
sleep 0.4                                   # --release 已過 hold_owner_ok、正卡在 alive(gpid) 的 shim 裡
mv "$SUPABASE_LOCK_DIR" "$work/n1-gone"; rm -rf "$work/n1-gone"; mkdir "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=/C\nbranch=b\ncmd=C\n' "$$" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
wait "$r"; rc=$?
rc_is '㉗ N1(b)：--release exit 0（hold 早已結束）' 0 "$rc" "$(cat "$work/n1b.err")"
has   '㉗ N1(b)：印「已被其他等待者回收並取得」' "$(cat "$work/n1b.err")" '已被其他等待者回收並取得'
if [ -d "$SUPABASE_LOCK_DIR" ] && grep -q "^pid=$$\$" "$SUPABASE_LOCK_DIR/holder" 2>/dev/null; then echo "✓ ㉗ N1(b)：第三者的活鎖被搬回原位"; else echo "✗ ㉗ N1(b)：第三者的活鎖被刪或沒搬回" >&2; ls -la "$SUPABASE_LOCK_DIR" "$work" 2>&1 | sed 's/^/    /' >&2; fail=1; fi
if ls -d "$SUPABASE_LOCK_DIR".stale.* >/dev/null 2>&1; then echo "✗ ㉗ N1(b)：殘留 tomb" >&2; ls -d "$SUPABASE_LOCK_DIR".stale.* >&2; fail=1; else echo "✓ ㉗ N1(b)：無殘留 tomb（搬回成功）"; fi
rm -rf "$SUPABASE_LOCK_DIR"; rm -f "$shim/ps"

# ---- ㉘ N2（PR #265 R1）：owner 腿須先驗 owner 活著——holder owner=本自測 pid（是所有呼叫者的祖先），ps shim 把它報成不存在
#        （＝pid 已被回收重用的形狀）→ 別的 worktree 不得通過（--held／重入／--release）；同 worktree 腿不受影響；不裝 shim（owner 真的活著）owner 腿仍通 ----
sleep 6 & a=$!                              # 只是一個活著的 pid 當 holder pid（守門）
mkdir "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=h\nworktree=%s\nbranch=b\ncmd=hold:LS-0 owner-reuse\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' "$a" "$(date +%s)" "$wtA" "$$" "$(( $(date +%s) + 600 ))" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
(cd "$wtB" && bash "$lock_sh" --held 2>/dev/null); rc_is '㉘ 前提：owner（本自測）活著且是祖先 → 別的 worktree --held 0（owner 腿）' 0 "$?" ''
cat > "$shim/ps" <<EOS
#!/bin/bash
if [ "\${1:-}" = -p ] && [ "\${2:-}" = "$$" ]; then exit 1; fi
exec /bin/ps "\$@"
EOS
chmod +x "$shim/ps"
(cd "$wtB" && PATH="$shim:$PATH" bash "$lock_sh" --held 2>/dev/null); rc_is '㉘ N2：owner pid 已死（重用形狀）→ 別的 worktree --held 1' 1 "$?" ''
out="$(cd "$wtB" && PATH="$shim:$PATH" bash "$lock_sh" --timeout 1 -- sh -c 'echo reuse-ran' 2>&1)"; rc=$?
rc_is '㉘ N2：owner 已死 → 別的 worktree 的 -- 命令不得重入、逾時 124' 124 "$rc" "$out"
hasnt '㉘ N2：命令沒跑' "$out" 'reuse-ran'
out="$(cd "$wtB" && PATH="$shim:$PATH" bash "$lock_sh" --release 2>&1)"; rc_is '㉘ N2：owner 已死 → 別的 worktree --release 拒 2' 2 "$?" "$out"
(cd "$wtA" && PATH="$shim:$PATH" bash "$lock_sh" --held 2>/dev/null); rc_is '㉘ N2：同 worktree 腿不受影響 --held 0' 0 "$?" ''
rm -f "$shim/ps"; kill "$a" 2>/dev/null; wait "$a" 2>/dev/null; rm -rf "$SUPABASE_LOCK_DIR"

# ---- ㉙ N3（PR #265 R1）：label 含換行／CR → 碰 lock 之前就 exit 2、lock 目錄不存在（舊寫法：holder 被注入 pid=1、目錄殘留、
#        pid 1 永遠活著→永不判死鎖，其他人等滿 15 分鐘）；>80 字亦拒；80 字可 ----
out="$(L --hold "$(printf 'probe\npid=1')" 2>&1)"; rc_is '㉙ N3：label 含換行 → exit 2' 2 "$?" "$out"
has   '㉙ N3：訊息點名換行' "$out" '換行'
gone  '㉙ N3：換行 label 沒留下 lock 目錄'
out="$(L --hold "$(printf 'x\rpid=1')" 2>&1)"; rc_is '㉙ N3：label 含 CR → exit 2' 2 "$?" "$out"
gone  '㉙ N3：CR label 沒留下 lock 目錄'
out="$(L --hold "$(printf '%081d' 0)" 2>&1)"; rc_is '㉙ N3：label 81 字 → exit 2' 2 "$?" "$out"
gone  '㉙ N3：過長 label 沒留下 lock 目錄'
out="$(hold_as_stranger "$(printf '%080d' 0)")"; rc_is '㉙ N3：label 80 字可 --hold' 0 "$?" "$out"
out="$(cd "$wtA" && bash "$lock_sh" --release 2>&1)"; rc_is '㉙ N3：釋放 80 字 label 的 hold' 0 "$?" "$out"
gone  '㉙ N3：釋放後 lock 消失'

# ---- ㉚ LS-170 回溯：hold.log 對命令型取得／--hold 取得／--release 各留一行（行首日期時間；回答「是誰在何時動了容器」——
#        命令型持有的 holder 檔在命令結束就刪了，LS-169 那次「來源不明的 reset」事後無從查起）；重入不另記 ----
: > "$hold_log"
# argv 故意夾一個假密鑰（PR #276 R1 (b) reviewer 實測形狀）：持久檔只准留首 token，其餘 argv 不得落地；holder 檔那份不在此驗（命令結束即刪）
out="$(cd "$wtA" && bash "$lock_sh" -- sh -c 'echo trace-ran' --fake-secret=hunter2 2>&1)"; rc_is '㉚ 命令型取得 exit 0' 0 "$?" "$out"
has   '㉚ 命令執行' "$out" 'trace-ran'
log="$(cat "$hold_log" 2>/dev/null)"
has   '㉚ log 記命令型取得（pid=）' "$log" '取得 pid='
has   '㉚ log 含 worktree' "$log" "worktree=${wtA}"
if printf '%s\n' "$log" | grep -qE ' cmd=sh$'; then echo "✓ ㉚ (b) cmd 只記首 token（cmd=sh 收尾）"; else echo "✗ ㉚ (b) 取得行的 cmd= 不是只有首 token" >&2; printf '%s\n' "$log" | sed 's/^/    /' >&2; fail=1; fi
hasnt '㉚ (b) 其餘 argv 不落地（fake-secret）' "$log" 'fake-secret'
hasnt '㉚ (b) 其餘 argv 不落地（echo trace-ran）' "$log" 'echo trace-ran'
if printf '%s\n' "$log" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} 取得 pid='; then echo "✓ ㉚ 取得行行首帶日期時間"; else echo "✗ ㉚ 取得行行首沒有 YYYY-MM-DD HH:MM:SS" >&2; printf '%s\n' "$log" | sed 's/^/    /' >&2; fail=1; fi
out="$(hold_as_stranger 'LS-0 回溯')"; rc_is '㉚ --hold exit 0' 0 "$?" "$out"
has   '㉚ log 記 hold 取得（label）' "$(cat "$hold_log" 2>/dev/null)" 'hold「LS-0 回溯」取得 守門 pid='
n_before=$(grep -c '' "$hold_log" 2>/dev/null)
out="$(cd "$wtA" && bash "$lock_sh" -- sh -c 'echo reentry-ran' 2>&1)"; rc_is '㉚ hold 內重入 exit 0' 0 "$?" "$out"
has   '㉚ 重入命令執行' "$out" 'reentry-ran'
n_after=$(grep -c '' "$hold_log" 2>/dev/null)
if [ "${n_after:-0}" -eq "${n_before:-0}" ]; then echo "✓ ㉚ 重入不另記（${n_before} 行）"; else echo "✗ ㉚ 重入多記了（${n_before}→${n_after} 行）" >&2; cat "$hold_log" >&2; fail=1; fi
out="$(cd "$wtA" && bash "$lock_sh" --release 2>&1)"; rc_is '㉚ --release exit 0' 0 "$?" "$out"
has   '㉚ log 記 hold 釋放（label＋持有時長）' "$(cat "$hold_log" 2>/dev/null)" 'hold「LS-0 回溯」釋放（持有 0 分'
gone  '㉚ 釋放後 lock 消失'

# ---- ㉛ LS-184：--hold 在主 checkout 直接拒（exit 2＋「cd <worktree> && … --hold」指引、不留 lock）；linked worktree 照常；LS_LOCK_ALLOW_MAIN=1 明示放行；
#        `--` 包裝模式在主 checkout 不受此限 ----
# 夾具不 commit：`git init` 的空 repo 已是主 checkout（git-dir＝git-common-dir）；linked worktree 用 `.git` 檔＋`.git/worktrees/<名>/{HEAD,commondir,gitdir}`
# 手搭（`git worktree add` 需要 HEAD 有 commit，commit 又要 user.name／hooks——夾具不該依賴那些）。兩者都在 mktemp 內、與真 repo 無關。
fx="$work/fx"; mkdir -p "$fx"
git init -q "$fx/mainrepo" >/dev/null 2>&1
mkdir -p "$fx/mainrepo/.git/worktrees/wt1" "$fx/wt1"
printf 'ref: refs/heads/wt1\n' > "$fx/mainrepo/.git/worktrees/wt1/HEAD"
printf '../..\n' > "$fx/mainrepo/.git/worktrees/wt1/commondir"
printf '%s/.git\n' "$fx/wt1" > "$fx/mainrepo/.git/worktrees/wt1/gitdir"
printf 'gitdir: %s/.git/worktrees/wt1\n' "$fx/mainrepo" > "$fx/wt1/.git"
gd=$(cd "$fx/mainrepo" && git rev-parse --path-format=absolute --git-dir 2>/dev/null); cdir=$(cd "$fx/mainrepo" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$gd" ] && [ "$gd" = "$cdir" ]; then echo "✓ ㉛ 前提：夾具 mainrepo 是主 checkout（git-dir＝git-common-dir）"; else echo "✗ ㉛ 前提：夾具 mainrepo 不是主 checkout（git-dir=${gd} common=${cdir}）" >&2; fail=1; fi
has   '㉛ 前提：夾具 wt1 是 linked worktree（git-dir 在 .git/worktrees/）' "$(cd "$fx/wt1" && git rev-parse --path-format=absolute --git-dir 2>/dev/null)" '/.git/worktrees/wt1'
out="$(cd "$fx/mainrepo" && bash "$lock_sh" --hold 'LS-0 主 checkout' --max-minutes 5 2>&1)"; rc=$?
rc_is '㉛ 主 checkout --hold → exit 2' 2 "$rc" "$out"
has   '㉛ 拒絕訊息點名主 checkout' "$out" '主 checkout'
has   '㉛ 拒絕訊息給 cd <worktree> && … --hold 同一命令鏈的指引' "$out" 'cd <worktree> && bash scripts/ops/supabase-lock.sh --hold'
has   '㉛ 指引帶回原 label 與 --max-minutes' "$out" '--hold "LS-0 主 checkout" --max-minutes 5'
has   '㉛ 拒絕訊息提示 LS_LOCK_ALLOW_MAIN=1' "$out" 'LS_LOCK_ALLOW_MAIN=1'
gone  '㉛ 主 checkout 被拒沒留下 lock'
out="$(cd "$fx/mainrepo" && LS_LOCK_ALLOW_MAIN=0 bash "$lock_sh" --hold 'LS-0 主 checkout' 2>&1)"; rc_is '㉛ LS_LOCK_ALLOW_MAIN=0 不算放行 → 仍 exit 2' 2 "$?" "$out"
gone  '㉛ =0 被拒沒留下 lock'
out="$(cd "$fx/wt1" && bash "$lock_sh" --hold 'LS-0 worktree' --max-minutes 1 2>&1)"; rc=$?
rc_is '㉛ linked worktree --hold → exit 0' 0 "$rc" "$out"
has   '㉛ holder worktree＝該 worktree 頂層' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null)" "worktree=$(cd "$fx/wt1" && pwd -P)"
out="$(cd "$fx/wt1" && bash "$lock_sh" --release 2>&1)"; rc_is '㉛ worktree --release → exit 0' 0 "$?" "$out"
gone  '㉛ 釋放後 lock 消失'
out="$(cd "$fx/mainrepo" && LS_LOCK_ALLOW_MAIN=1 bash "$lock_sh" --hold 'LS-0 放行' --max-minutes 1 2>&1)"; rc=$?
rc_is '㉛ LS_LOCK_ALLOW_MAIN=1 主 checkout --hold 放行 → exit 0' 0 "$rc" "$out"
has   '㉛ 放行時 holder worktree＝主 checkout' "$(cat "$SUPABASE_LOCK_DIR/holder" 2>/dev/null)" "worktree=$(cd "$fx/mainrepo" && pwd -P)"
out="$(cd "$fx/mainrepo" && bash "$lock_sh" --release 2>&1)"; rc_is '㉛ 放行的 hold 由同一主 checkout --release → exit 0（--release 不在 LS-184 範圍、不擋）' 0 "$?" "$out"
gone  '㉛ 放行的 hold 釋放後 lock 消失'
# `--` 包裝模式不受此限（LS-184 判斷：命令型 holder 不給任何人 worktree 腿——hold_owner_ok／PreToolUse H3b 只認 cmd=hold:*；CI db job 的
# run.sh 自包 wrapper 就是在主 checkout 跑）——這裡釘住；日後要改成同樣拒絕就改這一組
out="$(cd "$fx/mainrepo" && bash "$lock_sh" -- sh -c 'echo main-run' 2>&1)"; rc=$?
rc_is '㉛ 主 checkout 的 -- 包裝模式照常 exit 0' 0 "$rc" "$out"
has   '㉛ -- 包裝命令執行' "$out" 'main-run'
gone  '㉛ -- 包裝結束後釋放'
rm -rf "$fx"
unset SUPABASE_LOCK_HOLD_TICK

if [ "$fail" -eq 0 ]; then
  echo "✓ supabase-lock 自測通過"
fi
exit "$fail"
