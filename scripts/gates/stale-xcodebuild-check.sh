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
# `pid=` 記的行程還活著）——這代表命中的是另一個呼叫合法排隊／持有中的 xcodebuild（simulator-lock.sh
# 自己會序列化，不需要這裡插手），視為非殘留、放行；否則（沒帶鎖目錄、鎖不存在、或鎖的持有者已死）
# 才印每個候選 pid／存活時間／命令列前 80 字，並印出「先確認是否為別的 agent／worktree 正在合法使用，
# 再 kill 該 pid」的提示，exit 2（拒跑）。
# **不自動 kill**——殘留可能是別的 agent 正在跑（同 supabase-lock.sh 對別人持有的鎖不動的精神，貿然 kill
# 會打斷別人的測試，LS-217 就是誤殺的教訓）。找不到殘留、或命中合法持有中的鎖 → 靜默 exit 0。
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

# 鎖仍有效持有中＝合法排隊／執行中的另一次呼叫，交給 simulator-lock.sh 自己序列化，不算殘留。
if [ -n "$lock_dir" ] && [ -f "${lock_dir}/holder" ]; then
  holder_pid=$(sed -n 's/^pid=//p' "${lock_dir}/holder" 2>/dev/null)
  if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
    exit 0
  fi
fi

rows=""
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
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
