#!/bin/bash
# 殘留 xcodebuild 防護（LS-236，來源 LS-96 池項 `4de3e796`）：push-gate.sh／detect-simulator.sh 在對某台
# 模擬器 UDID 開跑 xcodebuild 之前，用這支腳本確認沒有殘留的 xcodebuild 行程還在跑同一顆 UDID。
#
# 背景：Bash 工具 timeout 上限 600000（10 分鐘）截斷後，被包住的 xcodebuild 不會被殺掉，只是這一輪呼叫
# 看不到它的輸出——行程本身留著繼續跑、繼續佔用那台模擬器。LS-166 R2 push gate 期間發現並殺掉一個這樣的
# 殘留 xcodebuild，它正靜默污染測試（模擬器爭用）；同型 LS-217 R4 agent 誤殺了自己剛背景化的 tap-target
# 行程（殺錯對象）。LS-215 的 background-bash-guard 只擋顯式 `run_in_background:true` 與「背景化再等」的
# 命令文字慣用形狀，工具 timeout 截斷後的自動背景化不在偵測範圍——這支腳本補的正是這個缺口。
#
# 用法：bash stale-xcodebuild-check.sh <UDID> [<simulator-lock.sh 的 --dir 鎖目錄>]
# 行為：`pgrep -f "xcodebuild .*<UDID>"` 找同一顆 UDID 的殘留 xcodebuild 行程（`-destination` 帶的 UDID
# 字面會落在同一行命令列裡，`.*` 涵蓋中間的其他參數；`xcodebuild` 後面要求一個空白——本腳本自己的檔名
# `stale-xcodebuild-check.sh` 也含 `xcodebuild` 子字串，若不要求後面接空白，兩個並行呼叫（例如兩個
# worktree 同時退回共用 UDID）的 `pgrep -f` 會把「對方那次呼叫本腳本的命令列」誤判成殘留 xcodebuild——
# `bash …/stale-xcodebuild-check.sh <UDID>` 這行本身同時含 `xcodebuild`（在檔名裡）與 UDID 字面，實測
# 重現於 push-gate.test.sh ⑧ 的併發情境）。找到候選後，若帶了第二個參數（呼叫端即將用來包住
# 這次 xcodebuild 呼叫的 simulator-lock.sh 鎖目錄）且該鎖**目前有效持有中**（`<lock>/holder` 存在且
# `pid=` 記的行程還活著）——**逐一**核對每個候選 pid 是否是那個 holder 本身、或落在它的父子鏈之下
# （`ps -o ppid=` 往上追，撞到 holder pid 才算；LS-236 R2 merge-review F4：舊版只要 holder 活著就整批
#放行，沒核對候選 pid 跟這把鎖有沒有關係——A 合法持鎖跑 xcodebuild 時，若剛好還有一個上一輪 Bash
# timeout 截斷、沒被任何鎖保護的殘留 xcodebuild 也在同一顆共用 UDID 上跑，會被「鎖有效持有中」整段
# 誤放行，B 排隊拿到鎖後跟那個殘留同時打同一台模擬器，正是本票要擋的形狀）——是 holder 子孫的候選視為
# 合法排隊／執行中，跳過；其餘（不帶鎖目錄、鎖不存在、鎖的持有者已死、或候選跟 holder 無關）才印每個
# 候選 pid／存活時間／命令列前 80 字，並印出「先確認是否為別的 agent／worktree 正在合法使用，再 kill
# 該 pid」的提示，exit 2（拒跑）。
# **不自動 kill**——殘留可能是別的 agent 正在跑（同 supabase-lock.sh 對別人持有的鎖不動的精神，貿然 kill
# 會打斷別人的測試，LS-217 就是誤殺的教訓）。找不到殘留、或候選皆為合法持鎖行程的子孫 → 靜默 exit 0。
#
# 逃生口：PUSH_GATE_ALLOW_STALE_XCODEBUILD=1（已確認殘留是自己這次故意保留，或已用其他方式驗證安全）。
#
# 自測：scripts/gates/stale-xcodebuild-check.test.sh（fixture 化 pgrep／ps，正負樣本＋mutation）；
# push-gate.sh／detect-simulator.sh 各自的自測另外驗接線本身。
set -uo pipefail

udid="${1:-}"
lock_dir="${2:-}"
if [ -z "$udid" ]; then
  echo "✗ stale-xcodebuild-check：用法：stale-xcodebuild-check.sh <UDID> [<lock 目錄>]" >&2
  exit 2
fi

if [ "${PUSH_GATE_ALLOW_STALE_XCODEBUILD:-0}" = 1 ]; then
  echo "→ stale-xcodebuild-check：PUSH_GATE_ALLOW_STALE_XCODEBUILD=1，略過殘留 xcodebuild 檢查（${udid}）" >&2
  exit 0
fi

pids=$(pgrep -f "xcodebuild .*${udid}" 2>/dev/null || true)
[ -n "$pids" ] || exit 0

# 鎖仍有效持有中＝合法排隊／執行中的另一次呼叫；holder_pid 非空代表下面逐一核對候選是否為其子孫（F4）。
holder_pid=
if [ -n "$lock_dir" ] && [ -f "${lock_dir}/holder" ]; then
  h=$(sed -n 's/^pid=//p' "${lock_dir}/holder" 2>/dev/null)
  if [ -n "$h" ] && kill -0 "$h" 2>/dev/null; then
    holder_pid=$h
  fi
fi

# is_holder_descendant <candidate pid>：候選是 holder 本身或其父子鏈下的子孫則回傳 0（合法、不算殘留）。
# 用 `ps -o ppid=` 往上追（上限 30 層防禦無限迴圈；行程樹深度正常遠小於此），追到 holder_pid 即命中；
# 追不到 ppid（行程已死／查不到）就停止並判定不是子孫。
is_holder_descendant() {
  [ -n "$holder_pid" ] || return 1
  local p=$1 ppid hops=0
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$hops" -lt 30 ]; do
    [ "$p" = "$holder_pid" ] && return 0
    ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')
    [ -n "$ppid" ] || return 1
    p=$ppid
    hops=$((hops + 1))
  done
  return 1
}

rows=""
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  is_holder_descendant "$pid" && continue
  row=$(ps -o pid=,etime=,command= -p "$pid" 2>/dev/null) || continue
  [ -n "$row" ] || continue
  # 防禦性二次過濾（belt-and-suspenders，同上方 pgrep 樣式收窄的理由）：命令列若是呼叫本腳本自己
  # （檔名含 xcodebuild 子字串），一律不算數。
  case "$row" in *stale-xcodebuild-check*) continue ;; esac
  pid_col=$(printf '%s' "$row" | awk '{print $1}')
  etime_col=$(printf '%s' "$row" | awk '{print $2}')
  # command 欄可能含空白，取第三欄之後全部原文，再截前 80 字
  cmd_col=$(printf '%s' "$row" | awk '{ $1=""; $2=""; sub(/^  */, ""); print }')
  cmd_trunc=$(printf '%s' "$cmd_col" | cut -c1-80)
  rows="${rows}  pid=${pid_col} etime=${etime_col} cmd=${cmd_trunc}"$'\n'
done <<PIDS
$pids
PIDS

[ -n "$rows" ] || exit 0

echo "⚠ 殘留 xcodebuild（pid／etime／命令前 80 字）：" >&2
printf '%s' "$rows" >&2
echo "  同一顆模擬器（${udid}）上有其他 xcodebuild 行程還在跑——可能是別的 agent／worktree 正在合法使用，也可能是 Bash 工具 timeout（600000）截斷後留下的殘留（LS-166／LS-217）。確認後若確定是殘留，kill <pid> 再重跑；PUSH_GATE_ALLOW_STALE_XCODEBUILD=1 可略過此檢查。" >&2
exit 2
