#!/bin/bash
# LS-180：Pencil 連線探針——給巡檢（patrol.sh 有 design 分支 worktree 時）與設計票派工前用。三個訊號一行印出：
#   1. 行程：`pgrep -f 'Pen\.app/Contents/MacOS/Pen$'`（同 pen-open.sh 清場用的樣式）。
#   2. 路徑：`pen-open.sh --status`（pen CLI 經 Pen 的 desktop socket 跑 get_app_state；讀不到＝CLI 側連不上或未登入）。
#   3. MCP 探針（**LS-308 改寫**，取代舊版 fd 交集邏輯，見下方沿革）：Claude Code 為每個 session 起一支
#      `<Pen.app>/…/mcp-server-<arch> --app desktop` 子行程（stdio 接 Claude Code）。判「本 session」用
#      `ps -o ppid= -p <mcp-server pid>` 取父行程 pid，再 `ps -o command= -p <ppid>` 讀父行程命令是否含 `claude`
#      （父行程仍活著且是 claude＝這支 mcp-server 屬於目前在跑的 session；父行程已死的殘留 mcp-server 不會落在這裡）；
#      取第一支命中的當「本 session」，其餘 mcp-server 行程數一律算「殘留」（不分是否為別的活 session 或死 session 的
#      孤兒，只當 informational，不影響 exit code）。判定邏輯抽到 `scripts/ops/lib/pencil-mcp.sh`（`pencil_mcp_probe`），
#      與 `pen-open.sh --kill` 清場後列殘留（A3）共用同一套，不重複貼一份（LS-267 R2 M1 同型教訓）。
#      PEN_STATUS_PS_BIN 可換 `ps` 路徑，自測用。
#
#   沿革（LS-180 原始邏輯，2026-09-05 起，**已被 LS-308 撤銷**）：原本假設「Pen 被結束重開後 socket 換了、
#   mcp-server 不會重連」，用 `lsof -F dn` 取 mcp-server 的 unix socket peer 位址與 Pen 行程的 socket 位址做交集，
#   沒交集就判 MCP ✗、且會讓整支腳本 exit 1。**2026-09-16 實測推翻這個假設**（LS-96 池項 `43230092`，P1 事故）：
#   Pen 於 10:16 被 `--kill` 重開、socket 換新後，本 session 的 mcp-server（pid 5536，前一晚 23:17 起）`lsof` 確實
#   只剩 stdio fd（舊邏輯判 ✗）；但直接呼叫一次 `mcp__pencil__get_app_state` 立刻成功，呼叫後 `lsof` 才多出一個
#   unix socket fd——**mcp-server 是懶連線（lazy connect）／斷線後下一次請求會自動重連，不需要使用者 `/mcp`**。
#   舊邏輯把「還沒打過請求、所以 socket 还沒建立」誤判成「斷線需要人工重連」，讓 design lane 空轉了 5 小時。另外
#   同一次實測還看到本機另有 7 支別的 session 殘留 mcp-server（2 支 12 天前的 claude、4 支 codex）——「全部連著才
#   算 ✓」這個舊版判定條件因此永遠不可能成立，本身就是設計缺陷。
#
# 用法：pen-status.sh   （無參數；PEN_STATUS_PS_BIN 可換 ps 路徑，自測用來模擬 ps 輸出）
#       pen-status.sh --path   （LS-211 I-c，來源 LS-96 池項 edbc460c：只印目前開檔絕對路徑，機器
#       可讀，供 patrol.sh「Pen 開錯檔」偵測讀取——不必再自己解析上面那行組合字串的字面格式，改措辭
#       就不會靜默退回舊路徑、fail-open）
# 輸出：一行 `Pencil：行程 ✓（pid N）／✗ · 路徑 <path>／✗（…） · MCP：本 session mcp-server ✓（pid N，…）／
#       本 session 沒有 mcp-server 行程（…）；另有 K 支別 session 的 mcp-server（informational）` 到 stdout
#       （--path：只印路徑一行；讀不到則不印任何東西，exit 1）
# Exit：0＝行程 ✓、路徑讀得到（MCP 訊號自 LS-308 起不影響 exit code——mcp-server 懶連線，是否已連上只有實際打一次
#       請求才知道，缺 mcp-server 行程不代表壞掉，只代表這次還沒打過）；1＝行程 ✗／路徑讀不到；2＝用法錯誤
# 自測：scripts/ops/pen-status.test.sh（stub pgrep／ps／pen，不碰真的 Pen；掛 CI rules job）。
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pencil-mcp.sh
source "${script_dir}/lib/pencil-mcp.sh"
path_only=0
if [ $# -eq 1 ] && [ "$1" = "--path" ]; then
  path_only=1
elif [ $# -ne 0 ]; then
  echo "用法：pen-status.sh [--path]" >&2
  exit 2
fi

if [ "$path_only" -eq 1 ]; then
  pen_pid=$(pgrep -f 'Pen\.app/Contents/MacOS/Pen$' 2>/dev/null | head -1)
  if [ -z "$pen_pid" ]; then
    exit 1
  fi
  path=$(bash "${script_dir}/pen-open.sh" --status 2>/dev/null)
  if [ -z "$path" ]; then
    exit 1
  fi
  printf '%s\n' "$path"
  exit 0
fi

PEN_PROC_RE='Pen\.app/Contents/MacOS/Pen$'
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

# MCP 訊號（LS-308）：不影響 bad／exit code——mcp-server 是懶連線，缺行程或找不到本 session 的那支都只是
# 「還沒打過請求」，不是壞掉；資訊性內容只給 agent 派工前參考。判定邏輯見 lib/pencil-mcp.sh。
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 0 ]; then
  mcp="MCP：本機沒有 Pencil mcp-server 行程（尚未呼叫過 pencil MCP；下一次 mcp__pencil__* 呼叫會自動連上，失敗才 /mcp）"
else
  if [ -n "$PENCIL_MCP_OWN_PID" ]; then
    mcp="MCP：本 session mcp-server ✓（pid ${PENCIL_MCP_OWN_PID}，懶連線，派工前實測一次 get_app_state）"
  else
    mcp="MCP：本 session 沒有 mcp-server 行程（尚未呼叫過 pencil MCP 或父行程已死；下一次 mcp__pencil__* 呼叫會自動連上，失敗才 /mcp）"
  fi
  [ "$PENCIL_MCP_OTHER" -gt 0 ] && mcp="${mcp}；另有 ${PENCIL_MCP_OTHER} 支別 session 的 mcp-server（informational）"
fi

echo "Pencil：${proc} · ${path_txt} · ${mcp}"
exit "$bad"
