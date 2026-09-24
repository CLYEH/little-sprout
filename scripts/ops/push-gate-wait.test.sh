#!/bin/bash
# push-gate-wait.sh 的自測（LS-358）。CI rules job「Ops 腳本自測」step 每個 PR 都跑。
# Incidents: LS-313, LS-315, LS-341
#
# 夾具：mktemp 出一個合成 repo＋`git worktree add` 出 `.claude/worktrees/LS-9001`，worktree 內放一支**假
# push-gate.sh**（依 FAKE_* 環境變數決定睡多久、rc、--confirm 時印快取命中／未命中／無 Swift 變更／紅／沒字樣；
# FAKE_READ_STDIN=1 時先 `cat` 讀完 stdin——stdin 沒關就會卡住）。「在跑」判定用真的 pgrep／ps：假 gate 被
# push-gate-wait.sh 以絕對路徑啟動，命令列天然含 worktree 路徑；干擾行程（前綴相同的別票 LS-90011、並行的另一次
# push-gate-wait 呼叫、照舊 ios-dev.md 手寫的 pgrep 等待迴圈）用 perl exec 換 argv 的 sleep 造出來，命令列與真的同形。
# 每次呼叫包一層 perl alarm 期限（卡住＝SIGALRM 142，不會拖垮整支自測）。
#
# 驗的事：①啟動→跑完 exit 0（log 尾＋rc、下一步 --confirm）②同 tree 再呼叫不重跑 ③tree 變了重跑 ④gate 比
# --max-seconds 久 → exit 3「仍在跑」、再呼叫接續等待且不重複啟動 ⑤gate 紅 → exit 1、下一次呼叫重跑 ⑥--confirm
# 命中 0／未命中 4／無 Swift 0／紅 1／rc 0 卻沒字樣 1（fail closed）／gate 在跑時 3 ⑥b（R2）① 綠但 --confirm 回 4 → 下一次 ① 重暖 ⑦--verify-push 對得上 0、
# 對不上 1 ⑧stdin 沒關時兩條路徑都不卡 ⑨範圍：LS-90011 前綴、sibling 呼叫、舊手寫迴圈都不算「在跑」，本 worktree
# 的 push-gate.sh 才算 ⑩主 checkout／--ticket 不一致／預算過大 → exit 2；--ticket 可從主 checkout 找到 worktree
# ⑪腳本依賴的字樣真的在 push-gate.sh 裡（字樣契約）。
# mutation（sed 改一份副本、同情境重跑，必須翻紅）：M1 拿掉 pattern 尾斜線→⑨LS-90011 被等到；M2 拿掉 push-gate-wait
# 過濾→⑨sibling 被等到；M3 拿掉 pgrep -f 過濾→⑨舊迴圈被等到；M4 脫離子樹不改接 stdout／stderr→④呼叫端被握住管線、
# 等到 gate 跑完；M5 拿掉 --confirm 的 < /dev/null→⑧卡住；M6 拿掉單次等待上限→④不再 exit 3、一路等到 gate 跑完；M7（R2）拿掉 --confirm 回 4 時挪開 log→⑥b 不再重暖。
# 脫離啟動那條的 `< /dev/null` 沒有 mutation：非互動 bash 的 `&` 本來就把 stdin 接到 /dev/null，拿掉明寫的那一段
# 行為不變（實測），⑧ 只驗行為；會卡住的是 --confirm 的前景呼叫（M5）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/push-gate-wait.sh"
real_gate="${root}/scripts/gates/push-gate.sh"
# shellcheck source=../gates/lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
work="$(cd "$work" && pwd -P)"
cleanup() {
  local p
  exec 7>&- 2>/dev/null
  for p in $(pgrep -f "${work}/" 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT

# ---- 合成 repo＋票 worktree＋假 push-gate.sh ----
repo="${work}/repo"
mkdir -p "$repo"
g() { git -C "$repo" "$@"; }
g init -q
g config user.email t@example.com
g config user.name t
g config commit.gpgsign false
mkdir -p "$repo/scripts/gates"
cat > "$repo/scripts/gates/push-gate.sh" <<'EOF'
#!/bin/bash
[ -n "${FAKE_COUNT:-}" ] && echo run >> "$FAKE_COUNT"
if [ "${FAKE_READ_STDIN:-0}" = 1 ]; then cat > /dev/null; fi
if [ "${LS_PUSH_GATE_CACHE_ONLY:-0}" = 1 ]; then
  case "${FAKE_CONFIRM:-hit}" in
    hit) echo "✓ push gate：unit tests 已於 2026-01-01 00:00:00 對同一 tree（x）通過，跳過（快取；LS-306）"; echo "✓ push gate 通過"; exit 0 ;;
    miss) echo "✗ push gate：快取未命中（tree x；LS_PUSH_GATE_CACHE_ONLY=1，不跑 unit tests；LS-358）"; exit 4 ;;
    noswift) echo "✓ push gate：無 Swift 變更，跳過 unit tests（CI 仍跑）"; echo "✓ push gate 通過"; exit 0 ;;
    red) echo "✗ push gate：合併衝突（假）"; exit 1 ;;
    silent) echo "✓ push gate 通過"; exit 0 ;;
  esac
fi
echo "→ push gate：unit tests 開始（假）"
sleep "${FAKE_SLEEP:-1}"
echo "✓ push gate 通過（假）"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$repo/scripts/gates/push-gate.sh"
echo 0 > "$repo/f.txt"
g add -A
g commit -qm init
g worktree add -q "$repo/.claude/worktrees/LS-9001" -b fix/LS-9001-x
wt="$(cd "$repo/.claude/worktrees/LS-9001" && pwd -P)"
w() { git -C "$wt" "$@"; }
bump() { echo "$RANDOM$$" >> "$wt/f.txt"; w add f.txt; w commit -qm "chore: LS-9001 bump"; }

count_file="${work}/count"
: > "$count_file"
export FAKE_COUNT="$count_file"
runs() { wc -l < "$count_file" | tr -d ' '; }

# dl <秒> <cmd…>：在自己的行程群組跑 cmd，期限內沒結束就 SIGKILL 整個群組、exit 142——只殺 cmd 本身不夠：
# 被殺的腳本留下的 $(...) 子 shell／gate 會繼續握著輸出管線，呼叫端的 $(...) 就永遠等不到 EOF。
dl() {
  local s=$1; shift
  perl -e 'my $s = shift; my $pid = fork(); die "fork: $!" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
    $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 142; };
    alarm $s; waitpid($pid, 0);
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);' "$s" "$@"
}
# pgw <腳本> <秒> <args…>：跑一次，設全域 out／rc／took
pgw() {
  local s=$1 secs=$2 t0; shift 2
  t0=$(date +%s)
  out=$(dl "$secs" bash "$s" "$@" < /dev/null 2>&1); rc=$?
  took=$(( $(date +%s) - t0 ))
}
# fake <argv0> <秒>：造一支命令列＝argv0 的行程，印 pid
fake() { perl -e 'exec {"/bin/sleep"} $ARGV[0], $ARGV[1]' "$1" "$2" > /dev/null 2>&1 & echo $!; }
wait_gone() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do pgrep -f "${wt}/scripts/gates/push-gate.sh" > /dev/null || return 0; sleep 0.5; done; }

# ---- ① 啟動→跑完 ----
pgw "$script" 20 --worktree "$wt" --max-seconds 10 --interval 1
if [ "$rc" -eq 0 ] && has "$out" 'rc=0' && has "$out" '--confirm' && has "$out" '已脫離啟動' && [ "$(runs)" = 1 ]; then
  ok "① 首次呼叫：脫離啟動 gate、等它跑完 → exit 0，印 rc=0 與下一步 --confirm（啟動 1 次）"
else
  bad "① 首次呼叫應 exit 0（實得 ${rc}、啟動 $(runs) 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
logf="$(cd "$(w rev-parse --git-common-dir)" && pwd -P)/ls-gate-logs/LS-9001-push-gate.log"
if [ -f "$logf" ] && grep -qx 'push-gate rc=0' "$logf" && grep -q "^# push-gate-wait: tree=$(w rev-parse 'HEAD^{tree}')" "$logf"; then
  ok "① log 在 git-common-dir/ls-gate-logs，首行記 tree、末尾有 push-gate rc=0"
else
  bad "① log 格式不符（${logf}）"
fi

# ---- ② 同 tree 再呼叫：不重跑 ----
pgw "$script" 10 --worktree "$wt" --max-seconds 10 --interval 1
if [ "$rc" -eq 0 ] && [ "$(runs)" = 1 ] && [ "$took" -le 2 ]; then
  ok "② 同 tree 再呼叫：直接回報上一輪結果 exit 0，不重跑（仍 1 次、${took}s）"
else
  bad "② 同 tree 再呼叫應直接 exit 0 不重跑（實得 ${rc}、啟動 $(runs) 次、${took}s）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑩ --ticket 從主 checkout 找 worktree ----
out=$(cd "$repo" && dl 10 bash "$script" --ticket LS-9001 --max-seconds 5 --interval 1 < /dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(runs)" = 1 ]; then
  ok "⑩ --ticket LS-9001 從主 checkout 呼叫：用 git worktree list 找到票 worktree（結果同 ②）"
else
  bad "⑩ --ticket 從主 checkout 呼叫應找到 worktree（實得 ${rc}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ③ tree 變了：重跑 ----
bump
pgw "$script" 20 --worktree "$wt" --max-seconds 10 --interval 1
if [ "$rc" -eq 0 ] && [ "$(runs)" = 2 ] && has "$out" 'tree 已變'; then
  ok "③ tree 變了：重新暖快取（啟動第 2 次）→ exit 0"
else
  bad "③ tree 變了應重跑（實得 ${rc}、啟動 $(runs) 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ④ gate 比單次上限久：exit 3 → 再呼叫接續等待、不重複啟動 ----
scenario_long() {   # $1＝腳本；設 rc4a／took4a／out4a
  bump
  FAKE_SLEEP=6 pgw "$1" 15 --worktree "$wt" --max-seconds 2 --interval 1
  rc4a=$rc; took4a=$took; out4a=$out
}
scenario_long "$script"
if [ "$rc4a" -eq 3 ] && has "$out4a" '仍在跑' && has "$out4a" "--ticket LS-9001" && [ "$took4a" -le 4 ]; then
  ok "④ gate 比 --max-seconds 久：${took4a}s 內 exit 3，印「仍在跑…再呼叫一次」"
else
  bad "④ 應在上限內 exit 3（實得 ${rc4a}、${took4a}s）"; printf '%s\n' "$out4a" | sed 's/^/    /' >&2
fi
before=$(runs)
pgw "$script" 20 --worktree "$wt" --max-seconds 12 --interval 1
if [ "$rc" -eq 0 ] && [ "$(runs)" = "$before" ]; then
  ok "④ 再呼叫：接續等同一輪 gate 跑完 → exit 0，沒有重複啟動（仍 ${before} 次）"
else
  bad "④ 再呼叫應接續等待（實得 ${rc}、啟動 ${before}→$(runs) 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑤ gate 紅：exit 1、下一次呼叫重跑 ----
bump
FAKE_RC=1 pgw "$script" 20 --worktree "$wt" --max-seconds 10 --interval 1
before=$(runs)
if [ "$rc" -eq 1 ] && has "$out" 'rc=1' && [ -f "${logf}.failed" ] && [ ! -f "$logf" ]; then
  ok "⑤ gate 紅：exit 1、印 rc=1，log 改名 .failed（不留成本 tree 的結果）"
else
  bad "⑤ gate 紅應 exit 1 並改名 log（實得 ${rc}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
pgw "$script" 20 --worktree "$wt" --max-seconds 10 --interval 1
if [ "$rc" -eq 0 ] && [ "$(runs)" = $((before + 1)) ]; then
  ok "⑤ 紅之後同 tree 再呼叫＝重跑（啟動 +1）→ 這次綠 exit 0"
else
  bad "⑤ 紅之後再呼叫應重跑（實得 ${rc}、啟動 ${before}→$(runs)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑥ --confirm ----
for c in hit:0:'git push' miss:4:'回到' noswift:0:'git push' red:1:'rc=1' silent:1:'fail closed'; do
  mode=${c%%:*}; rest=${c#*:}; want=${rest%%:*}; needle=${rest#*:}
  FAKE_CONFIRM=$mode pgw "$script" 10 --worktree "$wt" --confirm
  if [ "$rc" -eq "$want" ] && has "$out" "$needle"; then
    ok "⑥ --confirm（${mode}）→ exit ${want}"
  else
    bad "⑥ --confirm（${mode}）應 exit ${want} 且含「${needle}」（實得 ${rc}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
done
bump
FAKE_SLEEP=5 pgw "$script" 10 --worktree "$wt" --max-seconds 1 --interval 1
pgw "$script" 10 --worktree "$wt" --confirm
if [ "$rc" -eq 3 ] && has "$out" '仍在跑'; then
  ok "⑥ gate 還在跑時 --confirm → exit 3（先等它結束）"
else
  bad "⑥ gate 在跑時 --confirm 應 exit 3（實得 ${rc}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
wait_gone

# ---- ⑥b R2（merge-review R1 M1）：① 綠、快取標記卻已不在（24h 過期／被清／NO_CACHE）→ --confirm 回 4 → 下一次 ①
#      必須重新啟動 gate，不能一直回報舊的 rc=0 log（否則照 exit code 走＝① 0 → --confirm 4 → ① 0 … 死循環）----
scenario_stale() {   # $1＝腳本；設 rc6a（①）／rc6b（--confirm miss）／rc6c（再一次 ①）／launched6（第二次 ① 的啟動增量）
  local before
  bump
  pgw "$1" 20 --worktree "$wt" --max-seconds 10 --interval 1; rc6a=$rc
  FAKE_CONFIRM=miss pgw "$1" 10 --worktree "$wt" --confirm; rc6b=$rc
  before=$(runs)
  pgw "$1" 20 --worktree "$wt" --max-seconds 10 --interval 1; rc6c=$rc; out6c=$out
  launched6=$(( $(runs) - before ))
}
scenario_stale "$script"
if [ "$rc6a" -eq 0 ] && [ "$rc6b" -eq 4 ] && [ "$rc6c" -eq 0 ] && [ "$launched6" -eq 1 ] && has "$out6c" '已脫離啟動'; then
  ok "⑥b ① 綠 → --confirm 快取未命中 exit 4 → 下一次 ① 重新啟動 gate（啟動 +1），不再回報舊結果"
else
  bad "⑥b --confirm 回 4 之後 ① 應重新啟動 gate（實得 ①=${rc6a}、confirm=${rc6b}、再 ①=${rc6c}、啟動 +${launched6}）"
  printf '%s\n' "$out6c" | sed 's/^/    /' >&2
fi

# ---- ⑦ --verify-push ----
w update-ref refs/remotes/origin/fix/LS-9001-x HEAD
pgw "$script" 10 --worktree "$wt" --verify-push fix/LS-9001-x
if [ "$rc" -eq 0 ] && has "$out" 'push 成功'; then ok "⑦ --verify-push：origin/<branch> = HEAD → exit 0"; else bad "⑦ 對得上應 exit 0（實得 ${rc}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
bump
pgw "$script" 10 --worktree "$wt" --verify-push fix/LS-9001-x
if [ "$rc" -eq 1 ] && has "$out" 'push 沒成功'; then ok "⑦ --verify-push：HEAD 多一個 commit、origin 沒跟上 → exit 1「push 沒成功」"; else bad "⑦ 對不上應 exit 1（實得 ${rc}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
pgw "$script" 10 --worktree "$wt" --verify-push no-such-branch
if [ "$rc" -eq 1 ]; then ok "⑦ --verify-push：origin 沒有該分支 → exit 1"; else bad "⑦ 無此分支應 exit 1（實得 ${rc}）"; fi

# ---- ⑧ stdin 沒關（FIFO 另一端一直開著）：兩條路徑都不卡 ----
fifo="${work}/stdin.fifo"
mkfifo "$fifo"
exec 7<>"$fifo"
scenario_stdin() {   # $1＝腳本；設 rc8a（預設模式）／rc8b（--confirm）
  local t0
  bump
  t0=$(date +%s)
  out8a=$(FAKE_READ_STDIN=1 dl 8 bash "$1" --worktree "$wt" --max-seconds 5 --interval 1 < "$fifo" 2>&1); rc8a=$?
  out8b=$(FAKE_READ_STDIN=1 FAKE_CONFIRM=hit dl 5 bash "$1" --worktree "$wt" --confirm < "$fifo" 2>&1); rc8b=$?
  took8=$(( $(date +%s) - t0 ))
  for p in $(pgrep -f "${wt}/scripts/gates/push-gate.sh" 2>/dev/null); do kill "$p" 2>/dev/null; done
  wait_gone
}
scenario_stdin "$script"
if [ "$rc8a" -eq 0 ] && [ "$rc8b" -eq 0 ]; then
  ok "⑧ 呼叫端 stdin 是永不 EOF 的 FIFO：預設模式與 --confirm 都照常跑完（exit 0／0，${took8}s）"
else
  bad "⑧ stdin 沒關時應照常跑完（實得預設 ${rc8a}、confirm ${rc8b}）"; printf '%s\n%s\n' "$out8a" "$out8b" | sed 's/^/    /' >&2
fi

# ---- ⑨ 範圍：干擾行程不算「在跑」、本 worktree 的 gate 才算 ----
# 先讓本 tree 有結果（之後的呼叫若沒有被干擾，應該秒回 exit 0）
pgw "$script" 20 --worktree "$wt" --max-seconds 10 --interval 1
scenario_scope() {   # $1＝腳本 $2＝干擾 argv0；設 rc9／took9
  local fp
  fp=$(fake "$2" 30)
  sleep 0.3
  pgw "$1" 8 --worktree "$wt" --max-seconds 2 --interval 1
  rc9=$rc; took9=$took; out9=$out
  kill "$fp" 2>/dev/null
}
other_wt="${repo}/.claude/worktrees/LS-90011"
argv_prefix="bash ${other_wt}/scripts/gates/push-gate.sh"
argv_sibling="bash ${wt}/scripts/ops/push-gate-wait.sh --ticket LS-9001"
argv_legacy="bash -c _ws=\$SECONDS; while pgrep -f '${wt}/' | xargs -I{} ps -o command= -p {} | grep -v 'pgrep -f' | grep -q 'xcodebuild\\|push-gate'; do sleep 20; done"
argv_real="bash ${wt}/scripts/gates/push-gate.sh"
for c in prefix sibling legacy; do
  eval "argv=\$argv_${c}"
  scenario_scope "$script" "$argv"
  if [ "$rc9" -eq 0 ] && [ "$took9" -le 1 ]; then
    ok "⑨ 干擾行程（${c}）不算本 worktree 的 gate：秒回 exit 0（${took9}s）"
  else
    bad "⑨ 干擾行程（${c}）不應被等到（實得 ${rc9}、${took9}s）"; printf '%s\n' "$out9" | sed 's/^/    /' >&2
  fi
done
scenario_scope "$script" "$argv_real"
if [ "$rc9" -eq 3 ]; then
  ok "⑨ 正控制：本 worktree 的 push-gate.sh 在跑 → 等到上限 exit 3"
else
  bad "⑨ 本 worktree 的 gate 在跑應 exit 3（實得 ${rc9}）"; printf '%s\n' "$out9" | sed 's/^/    /' >&2
fi

# ---- ⑩ 參數／環境錯 → exit 2 ----
pgw "$script" 5 --worktree "$repo"
if [ "$rc" -eq 2 ] && has "$out" '不是票 worktree'; then ok "⑩ 主 checkout → exit 2（暖到 main 的 tree 沒用）"; else bad "⑩ 主 checkout 應 exit 2（實得 ${rc}）"; fi
pgw "$script" 5 --worktree "$wt" --ticket LS-9002
if [ "$rc" -eq 2 ] && has "$out" '不一致'; then ok "⑩ --ticket 與 --worktree 不一致 → exit 2"; else bad "⑩ 票號不一致應 exit 2（實得 ${rc}）"; fi
pgw "$script" 5 --worktree "$wt" --max-seconds 560 --interval 20
if [ "$rc" -eq 2 ]; then ok "⑩ --max-seconds＋--interval ≥570 → exit 2"; else bad "⑩ 預算過大應 exit 2（實得 ${rc}）"; fi

# ---- ⑪ 字樣契約：腳本判定依賴的字樣真的在 push-gate.sh 裡 ----
gate_text="$(cat "$real_gate")"
for needle in '跳過（快取' '跳過 unit tests' '快取未命中' 'LS_PUSH_GATE_CACHE_ONLY' '無需完整 gate' '尚未建立 Xcode 專案'; do
  if has "$gate_text" "$needle"; then ok "⑪ push-gate.sh 仍印「${needle}」"; else bad "⑪ push-gate.sh 找不到「${needle}」——push-gate-wait.sh 的判定會失準"; fi
done

# ---- mutations ----
mut="${work}/mut"
mkdir -p "$mut"
mutate() {   # $1＝名稱 $2＝sed 表達式；印副本路徑，sed 沒改到任何東西就 bad
  local f="${mut}/$1/push-gate-wait.sh"
  mkdir -p "${mut}/$1"
  sed "$2" "$script" > "$f"
  if cmp -s "$script" "$f"; then bad "mutation $1：sed 沒改到任何東西（錨點失效）"; fi
  printf '%s' "$f"
}
m=$(mutate M1 's#scope_pattern="${worktree}/"#scope_pattern="${worktree}"#')
scenario_scope "$m" "$argv_prefix"
if [ "$rc9" -eq 3 ]; then ok "M1 拿掉 pattern 尾斜線 → LS-90011 的 gate 被當成本票的、等到上限 exit 3（紅）"; else bad "M1 應翻紅（實得 ${rc9}）"; fi
m=$(mutate M2 "s#grep -v 'push-gate-wait' | ##")
scenario_scope "$m" "$argv_sibling"
if [ "$rc9" -eq 3 ]; then ok "M2 拿掉 push-gate-wait 過濾 → 並行的另一次呼叫被當成 gate、exit 3（紅）"; else bad "M2 應翻紅（實得 ${rc9}）"; fi
m=$(mutate M3 "s#grep -v 'pgrep -f' | ##")
scenario_scope "$m" "$argv_legacy"
if [ "$rc9" -eq 3 ]; then ok "M3 拿掉 pgrep -f 過濾 → 舊手寫等待迴圈被當成 gate、exit 3（紅）"; else bad "M3 應翻紅（實得 ${rc9}）"; fi
m=$(mutate M4 's#& ) < /dev/null > /dev/null 2>&1#\& ) < /dev/null#')
scenario_long "$m"
if [ "$rc4a" -ne 3 ] || [ "$took4a" -ge 5 ]; then ok "M4 脫離子樹不改接 stdout／stderr → 背景子 shell 握著呼叫端管線，呼叫端要等 gate 跑完（${took4a}s、exit ${rc4a}，紅）"; else bad "M4 應翻紅（實得 ${rc4a}、${took4a}s）"; fi
m=$(mutate M5 's#bash "$gate" < /dev/null 2>&1#bash "$gate" 2>\&1#')
scenario_stdin "$m"
if [ "$rc8b" -ne 0 ]; then ok "M5 拿掉 --confirm 的 < /dev/null → 卡在讀 stdin、被期限中止（實得 ${rc8b}，紅）"; else bad "M5 應翻紅（實得 ${rc8b}）"; fi
m=$(mutate M6 '/MUTATION-BUDGET-START/,/MUTATION-BUDGET-END/d')
scenario_long "$m"
if [ "$rc4a" -ne 3 ] && [ "$took4a" -ge 5 ]; then ok "M6 拿掉單次等待上限 → 不再 exit 3，一路等 gate 跑完（${took4a}s、exit ${rc4a}，紅）"; else bad "M6 應翻紅（實得 ${rc4a}、${took4a}s）"; fi
m=$(mutate M7 '/mv -f "$log" "${log}.stale"/d')
scenario_stale "$m"
if [ "$launched6" -eq 0 ]; then ok "M7 拿掉 --confirm 回 4 時挪開 log → 下一次 ① 仍回報舊 rc=0、不重暖（啟動 +0，紅）"; else bad "M7 應翻紅（實得啟動 +${launched6}）"; fi
wait_gone

if [ "$fail" -eq 0 ]; then
  echo "✓ push-gate-wait 自測通過（${n} 組，含 7 個 mutation）"
fi
exit "$fail"
