#!/usr/bin/env bash
# LS-311：用量快取寫入段（可重複安裝版）——把 Claude Code 餵給 statusline 的 JSON（stdin）裡的
# rate_limits 原子寫到 ~/.claude/usage-cache.json，供 scripts/ops/patrol.sh 的「用量」段讀取
# （週用量 ≥97% 不派新任務、≥99% 停工＋交接，見該檔「用量」段與 docs/COLLABORATION.md §4-b）。
# 失敗靜默——statusline 每次更新都會跑這段，不能因為這段掛掉、卡住或噴錯而拖累 statusline 本身的輸出。
#
# 安裝方式：statusline-command.sh 讀完 stdin 存進 $input 變數之後，加一行（背景執行避免拖慢 statusline
# 回應；本腳本本身也是失敗靜默，不需要檢查它的 exit code）：
#   printf '%s' "$input" | bash <repo>/scripts/ops/usage-cache-snippet.sh &
#
# 不依賴 jq 以外的工具；沒裝 jq、stdin 不是合法 JSON、或裡面沒有 rate_limits 都什麼都不寫、直接 exit 0。
# USAGE_CACHE_FILE 可覆寫輸出路徑（自測用；預設 $HOME/.claude/usage-cache.json，與 patrol.sh 的
# PATROL_USAGE_FILE 預設值同一個檔）。
set -uo pipefail
input=$(cat)
target="${USAGE_CACHE_FILE:-$HOME/.claude/usage-cache.json}"

{
  if command -v jq >/dev/null 2>&1; then
    tmp=$(printf '%s' "$input" | jq -c --arg now "$(date +%s)" '{rate_limits: (.rate_limits // {}), written_at: ($now|tonumber)}' 2>/dev/null)
    if [ -n "$tmp" ]; then
      printf '%s\n' "$tmp" > "${target}.tmp.$$" && mv -f "${target}.tmp.$$" "$target"
    fi
  fi
} 2>/dev/null

exit 0
