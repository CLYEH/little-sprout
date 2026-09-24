#!/bin/bash
# LS-346 範圍 3：驗證 ios-dev.md 記載的「背景 push gate 等待迴圈」（`.claude/agents/ios-dev.md` 的
# 「背景 push gate 等待迴圈限 worktree 範圍」段落）不會因為「另一條同 pattern 的等待迴圈」而卡住。
# LS-358：該段落已由 `scripts/ops/push-gate-wait.sh` 取代（ios-dev.md 收成一條指向腳本的規則），① 改檢查腳本的
# `gate_running()`；②–⑤ 驗的是過濾寫法本身，不變。腳本自己的範圍／sibling／舊迴圈情境另見 push-gate-wait.test.sh。
#
# 背景（LS-346 R2，源自 merge-review R1 M1 否證 R1 版修法）：LS-344 agent 回報迴圈用
# `pgrep -f 'worktrees/LS-<n>/'` 找自己 worktree 下的 xcodebuild／push-gate 行程時會卡住不退出。
# **R1 版**修成 `grep -v -x "$_self"`（排除迴圈自己的 PID），理由是「GNU／Linux `pgrep` 預設不排除
# 祖先行程」——reviewer 在 macOS 上 60 次重現否證這個根因敘述：BSD／macOS 的 `pgrep` 本來就預設排除
# 呼叫者與**所有祖先**（`man pgrep` `-a` 選項說明），R1 版舊寫法在 macOS 從未自我命中過一次。**macOS
# 上真正重現得出來的形態是「同 pattern 的第二條迴圈」**：兩條新寫法迴圈並行（正是 LS-344 回報的
# 「兩個行程各空轉 20 分鐘」形狀，也是 `ios-dev.md` 自己承認會發生的狀態——Bash 工具 timeout 截斷後
# 子行程不會被殺掉，上一輪的迴圈還活著，下一輪又起一條）：對方的外層 shell 是 **sibling**、不是 `$$`
# 也不是祖先，`grep -v -x "$_self"` 完全擋不到，`ps -o command=` 印出的正是對方那條含
# `xcodebuild\|push-gate` 字面的命令列——R1 版修法在 agent 實際工作的 macOS 上是 no-op。
#
# **R2 修法**：在 `ps` 之後先濾掉「命令列本身含 `pgrep -f` 字面」的候選（`grep -v 'pgrep -f'`）——這種
# 候選只可能是某條等待迴圈自己（不論是呼叫者本身還是並行的另一條，因為那段字面正是迴圈自己拿來呼叫
# `pgrep` 用的），真正的 push-gate.sh／xcodebuild 命令列不含這個子字串。這個過濾**與平台無關**、同時
# 擋掉「自我」與「sibling」兩種情形，不需要判斷 PID／祖先關係，③④ 兩個情境在 macOS／Linux 都跑得到
# （不再需要 `$(uname) = Linux` 才能驗證 mutation，這點本身就是對 R1 版「只在 Linux 驗證得到」限制
# 的修正）。
#
# 驗的四件事：① ios-dev.md 記載的迴圈含 `grep -v 'pgrep -f'` 過濾、且未用已淘汰的 bracket 寫法；
# ② 新迴圈在無任何相關行程時 1 輪內判定「真的跑完了」；③ 現場有真正的 xcodebuild／push-gate 行程時
# 仍正確判定「還在跑」（不會被新過濾層誤殺）；④ 現場另有一條同 pattern 的等待迴圈（sibling）時，兩條
# 都能正確判定「真的跑完了」——這正是 M1 修掉的那個情境；⑤ mutation：拿掉 `grep -v 'pgrep -f'` 那層
# 過濾，④ 的兩條 sibling 迴圈至少一條會誤判「還在跑」——證明④的正確判定是這層過濾造成的，不是巧合。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

# shellcheck source=lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"

doc="${root}/scripts/ops/push-gate-wait.sh"
[ -f "$doc" ] || { echo "✗ 找不到 ${doc}" >&2; exit 2; }
doc_text="$(cat "$doc")"

# ---- ① 文件與修法同步 ----
if has "$doc_text" "grep -v 'pgrep -f'"; then
  echo "✓ ① push-gate-wait.sh 的等待判定含 grep -v 'pgrep -f' 過濾（sibling／自我比對修法落地）"
else
  echo "✗ ① push-gate-wait.sh 找不到 grep -v 'pgrep -f' 過濾寫法——腳本與修法不同步" >&2
  fail=1
fi
# 只取「等待判定那段程式自己」的文字窗口（LS-358 起是 push-gate-wait.sh 的 `gate_running() {` 到函式結尾）
# 判斷有沒有用 bracket 寫法——不對整份檔案做無範圍的字面掃描（舊版掃 ios-dev.md 時，同段有一句正常說明
# H4 只認 `[x]codebuild`／`[p]ush-gate` 兩個 bracket target，整份掃描會誤判；範圍限定的做法沿用）。
snippet="$(python3 - "$doc" <<'PY'
import sys
doc = open(sys.argv[1], encoding="utf-8").read()
try:
    start = doc.index("gate_running() {")
    end = doc.index("\n}\n", start) + 2
    print(doc[start:end])
except ValueError:
    pass
PY
)"
if [ -z "$snippet" ]; then
  echo '✗ ① 在 push-gate-wait.sh 找不到 gate_running() 函式本體——無法檢查是否用了 bracket 寫法' >&2
  fail=1
elif has "$snippet" '[x]codebuild' || has "$snippet" '[p]ush-gate'; then
  echo "✗ ① 等待迴圈命令本身仍出現 [x]codebuild／[p]ush-gate bracket 自我迴避寫法——LS-330 i7 已裁定淘汰" >&2
  fail=1
else
  echo "✓ ① 等待迴圈命令本身未使用已淘汰的 [x]codebuild／[p]ush-gate bracket 自我迴避寫法"
fi

# ---- ②③④：無關行程／真行程／sibling 迴圈三種情境（縮短逾時到 3 秒，不跑滿文件裡的 570s）----
# fixed=1：R2 修法（多一層 grep -v 'pgrep -f'）；fixed=0：R1 版修法（$_self PID 排除，供 ⑤ mutation 用）
run_loop() {
  local pattern=$1 fixed=$2
  if [ "$fixed" -eq 1 ]; then
    bash -c "
      _ws=\$SECONDS
      while [ \$((SECONDS - _ws)) -lt 3 ] && pgrep -f '${pattern}' | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -v 'pgrep -f' | grep -q 'xcodebuild\\|push-gate'; do
        sleep 1
      done
      pgrep -f '${pattern}' | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -v 'pgrep -f' | grep -q 'xcodebuild\\|push-gate' && echo STILL || echo DONE
    "
  else
    bash -c "
      _self=\$\$
      _ws=\$SECONDS
      while [ \$((SECONDS - _ws)) -lt 3 ] && pgrep -f '${pattern}' | grep -v -x \"\$_self\" | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -q 'xcodebuild\\|push-gate'; do
        sleep 1
      done
      pgrep -f '${pattern}' | grep -v -x \"\$_self\" | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -q 'xcodebuild\\|push-gate' && echo STILL || echo DONE
    "
  fi
}

# ---- ② 無任何相關行程 → DONE ----
pattern2="worktrees/LS-346-selftest-noop-$$/"
t0=$SECONDS
result2=$(run_loop "$pattern2" 1)
t1=$SECONDS
if [ "$result2" = "DONE" ]; then
  echo "✓ ② 新迴圈在無任何相關行程時判定「真的跑完了」（耗時 $((t1 - t0))s，遠小於 3 秒逾時）"
else
  echo "✗ ② 新迴圈未如預期判定 DONE（實得 ${result2}）" >&2
  fail=1
fi

# ---- ③ 現場有真正的 xcodebuild／push-gate 行程（argv 含 pattern，命令列不含 'pgrep -f'）→ STILL ----
# perl exec 直接把行程換成帶特定 argv 的 sleep：argv[0] 塞進與 pattern／push-gate 字樣相符的字串，
# 讓 ps -o command= 印出來的內容跟真的 push-gate.sh／xcodebuild 命令列同形（含 pattern、含
# 'push-gate'，不含 'pgrep -f'）。
pattern3="worktrees/LS-346-selftest-real-$$/"
perl -e 'exec {"/bin/sleep"} "push-gate-'"${pattern3}"'-fake","30"' &
fake_pid=$!
# 給 fake 行程一點時間真的出現在行程表裡（perl exec 是同步 syscall，通常已足夠，留 0.3s 緩衝保守一點）。
sleep 0.3
t0=$SECONDS
result3=$(run_loop "$pattern3" 1)
t1=$SECONDS
kill "$fake_pid" 2>/dev/null
wait "$fake_pid" 2>/dev/null
if [ "$result3" = "STILL" ]; then
  echo "✓ ③ 現場有真正的 push-gate／xcodebuild 行程時，新迴圈仍正確判定「仍在跑」（未被過濾層誤殺，耗時 $((t1 - t0))s）"
else
  echo "✗ ③ 現場有真正行程時新迴圈未判定 STILL（實得 ${result3}）——過濾層可能連真行程都濾掉了" >&2
  fail=1
fi

# ---- ④ 兩條新寫法迴圈並行（sibling，核心情境：LS-344 事故的形狀）→ 兩條都 DONE ----
# 背景子行程的 stdout 各自導到暫存檔（子 shell 內對變數的賦值不會回寫到父 shell，不能直接
# `result=$(...) &` 再等著讀）。
pattern4="worktrees/LS-346-selftest-sibling-$$/"
t0=$SECONDS
out4a="$(mktemp)"; out4b="$(mktemp)"
run_loop "$pattern4" 1 > "$out4a" &
p4a=$!
run_loop "$pattern4" 1 > "$out4b" &
p4b=$!
wait "$p4a" "$p4b"
result4a="$(cat "$out4a")"; result4b="$(cat "$out4b")"
rm -f "$out4a" "$out4b"
if [ "$result4a" = "DONE" ] && [ "$result4b" = "DONE" ]; then
  echo "✓ ④ 兩條新寫法迴圈並行（sibling，LS-344 事故形狀）皆判定「真的跑完了」（耗時 $((t1 - t0))s）"
else
  echo "✗ ④ sibling 迴圈未如預期雙 DONE（實得 a=${result4a} b=${result4b}）" >&2
  fail=1
fi

# ---- ⑤ mutation：R1 版（$_self PID 排除）在 sibling 情境下必卡死——證明④的正確判定是 R2 那層
#        grep -v 'pgrep -f' 過濾造成的，不是巧合（不需要 uname=Linux，macOS 上 sibling 本來就是
#        真實命中，與 BSD/GNU 祖先排除差異無關）----
pattern5="worktrees/LS-346-selftest-mutant-$$/"
out5a="$(mktemp)"; out5b="$(mktemp)"
t0=$SECONDS
run_loop "$pattern5" 0 > "$out5a" &
p5a=$!
run_loop "$pattern5" 0 > "$out5b" &
p5b=$!
wait "$p5a" "$p5b"
t1=$SECONDS
result5a="$(cat "$out5a")"; result5b="$(cat "$out5b")"
rm -f "$out5a" "$out5b"
if { [ "$result5a" = "STILL" ] || [ "$result5b" = "STILL" ]; } && [ $((t1 - t0)) -ge 3 ]; then
  echo "✓ ⑤ mutant（R1 版 \$_self 排除，拿掉 grep -v 'pgrep -f' 過濾）：sibling 情境下至少一條誤判「仍在跑」、卡到自訂 3 秒逾時（耗時 $((t1 - t0))s，a=${result5a} b=${result5b}）——證明④的正確判定是 R2 過濾造成的，不是巧合"
else
  echo "✗ ⑤ mutant 未如預期翻轉（實得 a=${result5a} b=${result5b}，耗時 $((t1 - t0))s）——R1 版修法在 sibling 情境下應該卡住" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ wait-loop-selfmatch 自測通過"
fi
exit "$fail"
