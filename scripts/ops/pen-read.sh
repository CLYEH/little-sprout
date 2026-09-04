#!/bin/bash
# LS-118：唯讀讀稿前必先「強制重新載入」目標 worktree 的 design/littlesprout.pen 為 Pen 的 active
# document，才能安全地用 Pencil MCP 的 execute／get_app_state 唯讀查詢它——見本票調查結論
# （docs/COLLABORATION.md §7「Pencil MCP filePath」列、scripts/ops/pen-open.sh 檔頭 LS-118 段）：
# `execute` 的 `filePath` 參數只在目標路徑剛好是 Pen 目前某個 renderer 記得的文件時才「命中」，且
# 命中時服務的是那個 renderer 記憶體裡的快照——不會因為磁碟檔案之後被 git（checkout／merge／pull）
# 更新而自動變新；目標路徑若從未被任何 renderer 開過，`execute` 甚至不會報錯，而是**默默**改服務
# 目前 active document 的內容。本票合成 fixture 實測三種情況——從未開過、開過但磁碟已在背景被改過、
# 以及重新 `open -a Pen` 想搶回 active 但沒有先清場——filePath 讀到的都不是目標路徑當下的磁碟內容，
# 且沒有任何錯誤或警告訊號可以區分「讀到目標檔」與「讀到別的文件」。唯一可靠的解法：先把目標檔案
# 強制重新載入（必要時清場重開 Pen，讓全新 renderer 從磁碟讀取當下內容）成為 active document，讀者
# 再對這份 active document 做唯讀查詢（get_app_state／execute 不帶會寫入的操作）。
#
# 用法：pen-read.sh <worktree-or-repo-root>
#
# 本質是 `pen-open.sh <root> --force-reload` 的封裝——`--force-reload` 讓 pen-open.sh 不信任「目前已經
# 是 active」這個訊號。**LS-180 起**（來源 LS-177 VR R2：一律清場＝殺 Pen 主行程＝Pencil MCP 在 Claude Code
# session 內斷線不重連，「照指示切檔」與「照指示重掃」互斥）：路徑一致後先比 tree_hash——磁碟
# `design_tree_hash.py` vs Pencil 端經 `pen interactive` execute 回讀的同一演算法值——相符即證明 renderer
# 內容＝磁碟，exit 0、**不殺行程、Pencil MCP 連線保留**；只有真的不相符才走清場（安全判定＋kill＋重開）
# 並印「⚠ Pencil MCP 需重連：請在 Claude Code 執行 /mcp 重連 pencil」；讀不到 Pencil 端雜湊則不殺、印期望值、
# exit 3 交呼叫的 agent 自己用 mcp__pencil__execute 複算（細節見 pen-open.sh 檔頭 LS-180 段）。安全判定
# （check_root_safe，見 pen-open.sh）對「目標本身」與「目前所有開著的 .pen」一視同仁——任一份可能有未落地
# 的真實變更就整個拒絕清場，fail closed（exit 1，訊息會指出該去哪個 root 先 pen-land）；不會為了讀稿而默默
# 丟掉別人真正未落地的設計工作。要無條件清場請 orchestrator 明示用 `pen-open.sh <root> --kill`（本腳本不提供）。
#
# Exit code：與 `pen-open.sh <root> --force-reload` 相同——
#   0＝路徑一致且 tree_hash 相符（未清場），或清場重開後一致（stdout 會多一行「需重連」——帶回 handoff）；
#      皆可安全對 active document 做唯讀查詢
#   1＝判定不安全而拒絕清場，或清場後仍與目標路徑不一致
#   2＝用法錯誤／Pen 沒開／pen CLI 問題／磁碟 .pen 算不出雜湊／清場失敗需人工介入（fail closed）
#   3＝路徑一致但 Pencil 端雜湊讀不到（大稿 execute 中斷／逾時）——未清場；stdout 印「期望值 tree_hash=<磁碟值>」，
#      呼叫端用 mcp__pencil__execute 跑 overflow-scan.js（SCAN_HASH_ONLY = true，可分段）比對：相符即可讀稿，
#      不符回報 orchestrator（由其決定 --kill），不得自行清場
#
# 讀完之後：呼叫端（qa／visual-reviewer 等）不需要主動切回別的文件——它們本來就是唯讀查詢，下一位
# 使用者開工前也會自己對自己要用的路徑跑一次 force-reload；ui-designer 這類會實際編輯的 agent 仍照
# 既有規約收工前把 Pen 切回主 checkout（見 pen-open.sh／ui-designer 定義）。
#
# 自測：scripts/ops/pen-read.test.sh（驗證正確轉呼叫 pen-open.sh --force-reload 並如實回傳結果：雜湊相符不殺／
# 不符才清場＋印需重連／讀不到 exit 3；完整的清場矩陣測試在 pen-open.test.sh，這裡不重複）。
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 1 ]; then
  echo "用法：pen-read.sh <worktree-or-repo-root>" >&2
  exit 2
fi

exec bash "${script_dir}/pen-open.sh" "$1" --force-reload
