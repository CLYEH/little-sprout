#!/bin/bash
# LS-180：Pencil 連線探針——給巡檢（patrol.sh 有 design 分支 worktree 時）與設計票派工前用。三個訊號一行印出：
#   1. 行程：`pgrep -f 'Pen\.app/Contents/MacOS/Pen$'`（同 pen-open.sh 清場用的樣式）。
#   2. 路徑：`pen-open.sh --status`（pen CLI 經 Pen 的 desktop socket 跑 get_app_state；讀不到＝CLI 側連不上或未登入）。
#   3. MCP 探針：Claude Code 為每個 session 起一支 `<Pen.app>/…/mcp-server-<arch> --app desktop` 子行程（stdio 接
#      Claude Code），它再以 unix socket 連 Pen 的 `~/.pencil/socket/pencil-desktop.sock`。Pen 被結束重開後 socket 換了、
#      mcp-server 不會重連——lsof 看它只剩 fd 0/1/2（stdio），沒有任何 fd 的 peer 位址落在 Pen 行程持有的 unix socket
#      位址集合裡。本探針用 `lsof -F dn` 取兩邊位址做交集：mcp-server 的 `n->0x<peer>` ∈ Pen 的 `d0x<addr>` ⇒ 連著。
#      沒有 mcp-server 行程＝本機沒有任何 session 連著 pencil（✗）；缺 lsof／讀不到 Pen 的 socket＝不可測（不判 ✗）。
#      多支 mcp-server（多個 session）時全部連著才 ✓，部分斷線也標 ✗（從 shell 分不出哪支是本 session 的）。
#      實測依據（2026-09-05，LS-177 VR R2 斷線現場，唯讀觀察）：Pen pid 3185 `lsof -nP -a -U -p 3185 -F dn` 有
#      `d0x1b7c…`＋`n/Users/…/.pencil/socket/pencil-desktop.sock` 與一條 `d0x15a8…`＋`n->0x134e…` 的已接受連線；斷線的
#      mcp-server pid 24097 只有 f0／f1／f2 三個 stdio fd、peer 皆不在 Pen 的位址集合。連線正常時的樣本本票沒有
#      （硬限制不得重連／重開 Pen），交集邏輯以 stub 自測；若實機連線正常時仍印 ✗，方向是誤報斷線（fail loud），
#      不會把斷線判成 ✓——第一次重連後請對照一次，格式不符改本檔的 sed 樣式即可。
#
# 用法：pen-status.sh   （無參數；PEN_STATUS_LSOF_BIN 可換 lsof 路徑，自測用來模擬缺 lsof）
# 輸出：一行 `Pencil：行程 ✓（pid N）／✗ · 路徑 <path>／✗（…） · MCP 探針 ✓／✗／不可測（…）` 到 stdout
# Exit：0＝行程 ✓、路徑讀得到、MCP ✓ 或不可測；1＝任一 ✗（斷線／Pen 沒開／路徑讀不到）；2＝用法錯誤
# 自測：scripts/ops/pen-status.test.sh（stub pgrep／lsof／pen，不碰真的 Pen；掛 CI rules job）。
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -ne 0 ]; then
  echo "用法：pen-status.sh（無參數）" >&2
  exit 2
fi

PEN_PROC_RE='Pen\.app/Contents/MacOS/Pen$'
MCP_PROC_RE='Pen\.app/.*mcp-server-[^ ]* --app desktop'
LSOF_BIN=${PEN_STATUS_LSOF_BIN:-lsof}
bad=0

pen_pid=$(pgrep -f "$PEN_PROC_RE" 2>/dev/null | head -1)
if [ -n "$pen_pid" ]; then
  proc="行程 ✓（pid ${pen_pid}）"
else
  proc="行程 ✗（Pen 沒開）"; bad=1
fi

if [ -n "$pen_pid" ]; then
  path=$(bash "${script_dir}/pen-open.sh" --status 2>/dev/null)
  if [ -n "$path" ]; then
    path_txt="路徑 ${path}"
  else
    path_txt="路徑 ✗（pen CLI 讀不到 active 文件——CLI 未登入／desktop socket 連不上）"; bad=1
  fi
else
  path_txt="路徑 —（Pen 沒開，不查）"
fi

lsof_unix() { "$LSOF_BIN" -nP -a -U -p "$1" -F dn 2>/dev/null; }
mcp_pids=$(pgrep -f "$MCP_PROC_RE" 2>/dev/null | tr '\n' ' ')
mcp_pids=${mcp_pids% }
if [ -z "$mcp_pids" ]; then
  mcp="MCP 探針 ✗（沒有 Pencil mcp-server 行程——本機沒有任何 Claude Code session 連著 pencil；在 Claude Code 執行 /mcp 重連 pencil）"; bad=1
elif ! command -v "$LSOF_BIN" >/dev/null 2>&1; then
  mcp="MCP 探針 不可測（無 lsof；mcp-server 行程 pid ${mcp_pids} 存活，連線狀態未知）"
elif [ -z "$pen_pid" ]; then
  mcp="MCP 探針 ✗（mcp-server 行程 pid ${mcp_pids} 存活但 Pen 沒開——必然斷線；Pen 開好後在 Claude Code 執行 /mcp 重連 pencil）"; bad=1
else
  pen_addrs=$(lsof_unix "$pen_pid" | sed -n 's/^d//p')
  if [ -z "$pen_addrs" ]; then
    mcp="MCP 探針 不可測（lsof 讀不到 Pen pid ${pen_pid} 的 unix socket；mcp-server pid ${mcp_pids} 存活，連線狀態未知）"
  else
    total=0; connected=0
    for m in $mcp_pids; do
      total=$((total + 1))
      peers=$(lsof_unix "$m" | sed -n 's/^n->//p')
      hit=0
      for p in $peers; do
        case $'\n'"${pen_addrs}"$'\n' in
          *$'\n'"${p}"$'\n'*) hit=1; break ;;
        esac
      done
      [ "$hit" -eq 1 ] && connected=$((connected + 1))
    done
    if [ "$connected" -eq "$total" ]; then
      mcp="MCP 探針 ✓（mcp-server ${total} 支皆有 unix socket 連到 Pen pid ${pen_pid}）"
    elif [ "$connected" -gt 0 ]; then
      mcp="MCP 探針 ✗（mcp-server ${total} 支、僅 ${connected} 支連到 Pen——其餘斷線：若是本 session 的，在 Claude Code 執行 /mcp 重連 pencil）"; bad=1
    else
      mcp="MCP 探針 ✗（mcp-server ${total} 支皆無 Pen socket 連線——Pen 曾被結束重開、mcp-server 不會自己重連；在 Claude Code 執行 /mcp 重連 pencil）"; bad=1
    fi
  fi
fi

echo "Pencil：${proc} · ${path_txt} · ${mcp}"
exit "$bad"
