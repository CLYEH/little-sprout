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
# 本質是 `pen-open.sh <root> --force-reload` 的封裝——`--force-reload` 讓 pen-open.sh 略過「目前已經
# 是 active 就直接算成功」的捷徑，一律走清場（安全判定＋kill＋重開）流程，確保讀到的是全新 renderer
# 剛從磁碟讀出的內容，而不是某個殘留 renderer 停在舊時間點的快照。安全判定（check_root_safe，見
# pen-open.sh）對「目標本身」與「目前所有開著的 .pen」一視同仁——任一份可能有未落地的真實變更就整個
# 拒絕清場，fail closed（exit 1，訊息會指出該去哪個 root 先 pen-land）；不會為了讀稿而默默丟掉別人
# 真正未落地的設計工作。
#
# Exit code：與 `pen-open.sh <root> --force-reload` 相同——
#   0＝已強制重新載入且對帳一致，可以安全對 active document 做唯讀查詢
#   1＝判定不安全而拒絕清場，或清場後仍與目標路徑不一致
#   2＝用法錯誤／Pen 沒開／pen CLI 問題／清場失敗需人工介入（fail closed）
#
# 讀完之後：呼叫端（qa／visual-reviewer 等）不需要主動切回別的文件——它們本來就是唯讀查詢，下一位
# 使用者開工前也會自己對自己要用的路徑跑一次 force-reload；ui-designer 這類會實際編輯的 agent 仍照
# 既有規約收工前把 Pen 切回主 checkout（見 pen-open.sh／ui-designer 定義）。
#
# 自測：scripts/ops/pen-read.test.sh（驗證正確轉呼叫 pen-open.sh --force-reload 並如實回傳結果；完整
# 的清場矩陣測試在 pen-open.test.sh，這裡不重複）。
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 1 ]; then
  echo "用法：pen-read.sh <worktree-or-repo-root>" >&2
  exit 2
fi

exec bash "${script_dir}/pen-open.sh" "$1" --force-reload
