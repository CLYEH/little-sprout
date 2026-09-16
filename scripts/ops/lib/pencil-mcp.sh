#!/bin/bash
# scripts/ops/lib/pencil-mcp.sh — Pencil mcp-server 行程判定共用庫（LS-308）
#
# 背景：`pen-status.sh`（探針，A1）與 `pen-open.sh --kill`（清場後列殘留，A3）都要判斷「本 session 的
# mcp-server」與「其餘殘留 mcp-server」——判定邏輯（`pgrep` 抓 `mcp-server` 行程、`ps` 查父行程命令是否為
# 活著的 `claude`，見 pen-status.sh 檔頭沿革的實測）原本只會寫在其中一支腳本，A3 若照抄一份會重複貼、
# 日後改一邊漏一邊（LS-267 R2 M1 同型教訓：規則字面同時抄在多處，改一處漏一處）。兩支腳本各自
# `source` 本檔，共用同一套判定。
#
# 提供：pencil_mcp_probe（無參數）——設三個全域變數：
#   PENCIL_MCP_TOTAL    — mcp-server 行程總數
#   PENCIL_MCP_OWN_PID  — 本 session 的 mcp-server pid（父行程仍活著且命令含 claude；找不到則空字串）
#   PENCIL_MCP_OTHER    — 其餘殘留 mcp-server 行程數（不分是別的活 session 還是死行程孤兒，只算數量）
# 可覆寫的環境變數（自測用）：
#   PENCIL_MCP_PROC_RE  — mcp-server pgrep 樣式，預設 `Pen\.app/.*mcp-server-[^ ]* --app desktop`
#   PEN_STATUS_PS_BIN   — `ps` 路徑，預設 `ps`（沿用 pen-status.sh 既有的環境變數名，一支自測夾具通用）
#
# 自測：scripts/ops/lib/pencil-mcp.test.sh（stub pgrep／ps）。規約見 docs/COLLABORATION.md §7。
PENCIL_MCP_PROC_RE_DEFAULT='Pen\.app/.*mcp-server-[^ ]* --app desktop'

pencil_mcp_probe() {
  local proc_re=${PENCIL_MCP_PROC_RE:-$PENCIL_MCP_PROC_RE_DEFAULT}
  local ps_bin=${PEN_STATUS_PS_BIN:-ps}
  local mcp_pids ppid parent_cmd m

  mcp_pids=$(pgrep -f "$proc_re" 2>/dev/null | tr '\n' ' ')
  mcp_pids=${mcp_pids% }
  PENCIL_MCP_TOTAL=0
  PENCIL_MCP_OWN_PID=
  PENCIL_MCP_OTHER=0
  for m in $mcp_pids; do
    PENCIL_MCP_TOTAL=$((PENCIL_MCP_TOTAL + 1))
    ppid=$("$ps_bin" -o ppid= -p "$m" 2>/dev/null | tr -d '[:space:]')
    parent_cmd=
    [ -n "$ppid" ] && parent_cmd=$("$ps_bin" -o command= -p "$ppid" 2>/dev/null)
    if [ -z "$PENCIL_MCP_OWN_PID" ]; then
      case "$parent_cmd" in
        *claude*) PENCIL_MCP_OWN_PID=$m ;;
        *) PENCIL_MCP_OTHER=$((PENCIL_MCP_OTHER + 1)) ;;
      esac
    else
      PENCIL_MCP_OTHER=$((PENCIL_MCP_OTHER + 1))
    fi
  done
}
