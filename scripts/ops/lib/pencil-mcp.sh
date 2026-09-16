#!/bin/bash
# scripts/ops/lib/pencil-mcp.sh — Pencil mcp-server 行程判定共用庫（LS-308；LS-309 B 改本 session 判定）
#
# 背景：`pen-status.sh`（探針，A1）與 `pen-open.sh --kill`（清場後列殘留，A3）都要判斷「本 session 的
# mcp-server」與「其餘殘留 mcp-server」——判定邏輯（`pgrep` 抓 `mcp-server` 行程、`ps` 查父行程命令是否為
# 活著的 `claude`，見 pen-status.sh 檔頭沿革的實測）原本只會寫在其中一支腳本，A3 若照抄一份會重複貼、
# 日後改一邊漏一邊（LS-267 R2 M1 同型教訓：規則字面同時抄在多處，改一處漏一處）。兩支腳本各自
# `source` 本檔，共用同一套判定。
#
# **LS-309 B**（LS-96 池項 `bef760fe`）：LS-308 版判定是「pgrep 枚舉出的第一支 mcp-server，其父行程命令含
# claude 者」——這只是巧合湊出「本 session」，不是真的比對身分：多支 mcp-server 各自的父行程都含 claude
# 字面（例如另一個活 session、或殘留的舊 claude 行程）時，選到的是 pgrep 枚舉順序（通常＝pid 由小到大）最先
# 出現的那支，不保證是「呼叫本函式的這個 shell」所屬的 session。改法：先用 `pencil_mcp_own_claude_pid()` 沿
# `$PPID` 鏈往上找到本 session 真正的 claude 主行程 pid，再拿它**精確比對**每支 mcp-server 的父行程 pid（相等
# 才算 own）——不再靠「父行程命令含 claude 字面」這個寬鬆判準去猜。找不到（例如根本不在 Claude Code 底下
# 執行、鏈斷在 pid 0/1、或超過深度上限）才退回 LS-308 的舊判準（第一支父行程命令含 claude 的 mcp-server），
# 並設 `PENCIL_MCP_OWN_INFERRED=1` 標記這是「推定」不是精確比對——呼叫端（pen-status.sh）據此在訊息附註。
#
# 提供：pencil_mcp_probe（無參數）——設四個全域變數：
#   PENCIL_MCP_TOTAL      — mcp-server 行程總數
#   PENCIL_MCP_OWN_PID    — 本 session 的 mcp-server pid（找不到則空字串）
#   PENCIL_MCP_OTHER      — 其餘殘留 mcp-server 行程數（不分是別的活 session 還是死行程孤兒，只算數量）
#   PENCIL_MCP_OWN_INFERRED — 1＝上面的 OWN_PID 是退回舊判準推定出來的（$PPID 鏈找不到 claude 主行程）；
#                             0＝精確比對 $PPID 鏈找到的 claude 主行程 pid 與 mcp-server 父行程 pid（LS-309）
# 可覆寫的環境變數（自測用）：
#   PENCIL_MCP_PROC_RE  — mcp-server pgrep 樣式，預設 `Pen\.app/.*mcp-server-[^ ]* --app desktop`
#   PEN_STATUS_PS_BIN   — `ps` 路徑，預設 `ps`（沿用 pen-status.sh 既有的環境變數名，一支自測夾具通用）
#   PENCIL_MCP_START_PID — `$PPID` 鏈的起點，預設 `$PPID`（自測用；正式呼叫不覆寫）
#
# 自測：scripts/ops/lib/pencil-mcp.test.sh（stub pgrep／ps）。規約見 docs/COLLABORATION.md §7。
PENCIL_MCP_PROC_RE_DEFAULT='Pen\.app/.*mcp-server-[^ ]* --app desktop'

# LS-309：從 PENCIL_MCP_START_PID（預設 $PPID）沿父行程鏈往上找第一個命令含 claude 的行程 pid。找到就印出
# 該 pid、return 0；鏈斷在 pid 0/1、ps 讀不到資料、或超過深度上限（32，防禦性：ps 資料異常成環時不要無限
# 迴圈）都 return 1（呼叫端退回舊判準）。純唯讀（只查詢，不動任何東西）。
pencil_mcp_own_claude_pid() {
  local ps_bin=${PEN_STATUS_PS_BIN:-ps}
  local pid=${PENCIL_MCP_START_PID:-$PPID}
  local cmd depth=0
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$depth" -lt 32 ]; do
    cmd=$("$ps_bin" -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in
      *claude*) printf '%s' "$pid"; return 0 ;;
    esac
    pid=$("$ps_bin" -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    depth=$((depth + 1))
  done
  return 1
}

pencil_mcp_probe() {
  local proc_re=${PENCIL_MCP_PROC_RE:-$PENCIL_MCP_PROC_RE_DEFAULT}
  local ps_bin=${PEN_STATUS_PS_BIN:-ps}
  local mcp_pids ppid parent_cmd m own_claude_pid

  mcp_pids=$(pgrep -f "$proc_re" 2>/dev/null | tr '\n' ' ')
  mcp_pids=${mcp_pids% }
  PENCIL_MCP_TOTAL=0
  PENCIL_MCP_OWN_PID=
  PENCIL_MCP_OTHER=0
  PENCIL_MCP_OWN_INFERRED=0

  own_claude_pid=$(pencil_mcp_own_claude_pid) || own_claude_pid=

  for m in $mcp_pids; do
    PENCIL_MCP_TOTAL=$((PENCIL_MCP_TOTAL + 1))
    ppid=$("$ps_bin" -o ppid= -p "$m" 2>/dev/null | tr -d '[:space:]')
    parent_cmd=
    [ -n "$ppid" ] && parent_cmd=$("$ps_bin" -o command= -p "$ppid" 2>/dev/null)
    if [ -n "$own_claude_pid" ]; then
      # LS-309：找到本 session 的 claude 主行程 pid → 精確比對 mcp-server 的父行程 pid，不再靠 pgrep 枚舉順序推定
      if [ -z "$PENCIL_MCP_OWN_PID" ] && [ "$ppid" = "$own_claude_pid" ]; then
        PENCIL_MCP_OWN_PID=$m
      else
        PENCIL_MCP_OTHER=$((PENCIL_MCP_OTHER + 1))
      fi
    elif [ -z "$PENCIL_MCP_OWN_PID" ]; then
      # LS-308 舊判準（退回）：$PPID 鏈找不到 claude 主行程（不在 Claude Code 底下執行等）→ 第一支父行程命令
      # 含 claude 字面的 mcp-server 當「推定」own
      case "$parent_cmd" in
        *claude*) PENCIL_MCP_OWN_PID=$m; PENCIL_MCP_OWN_INFERRED=1 ;;
        *) PENCIL_MCP_OTHER=$((PENCIL_MCP_OTHER + 1)) ;;
      esac
    else
      PENCIL_MCP_OTHER=$((PENCIL_MCP_OTHER + 1))
    fi
  done
}
