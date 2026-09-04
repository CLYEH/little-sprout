#!/bin/bash
# LS-91：Pen app 開檔路徑機械對帳。
#
# 背景（LS-81／LS-91 comment A 實測，pen CLI 0.3.4；**LS-117 更新**——舊結論已過期，見下）：pen CLI 連線模式
# 的 `--in <file>` 在「不帶 --in 的後續呼叫」上不生效——`pen interactive --app desktop --in <file>` 確實會讓
# **那一次**呼叫的 get_app_state 回報 `<file>`，但這只是該次 CLI 連線的 session-local 覆寫，不影響 app 真正的
# active document／不影響其後不帶 --in 的呼叫（含 Pencil MCP）——不是真正的切檔手段。唯一機械可行的切檔方法
# 仍是 `open -a Pen <path>`。**LS-117**：Pencil MCP `execute`（及 `browser`）工具現行 schema 已把 `filePath`
# 列為**必要參數**（`required: ["filePath"]`）——LS-81／LS-91 comment A 當時「execute 的 filePath 參數無效」
# 的結論已過期，該參數確實會被拿來比對目前 Pen 已知的文件。**LS-118 撤回並修正 LS-117 當時「不必先搶下
# active document」這個過度樂觀的結論**：本票用合成 fixture 實測（見 `pen-read.sh` 與 handoff）確認
# `filePath` 只在目標路徑剛好命中 Pen**目前某個 renderer 記得的文件**時才「命中」，且命中時服務的是那個
# renderer 記憶體裡的快照——不會因為磁碟檔案之後被 git（checkout／merge／pull）更新而自動變新，重新
# `open -a Pen` 想搶回 active 也不會讓既有 renderer 重新讀取磁碟（唯一會重新讀取磁碟的是全新 renderer，
# 只有清場重開才生得出來）；目標路徑若從未被任何 renderer 開過，`execute` 甚至不會報錯或建立新文件，而是
# **默默**改服務目前 active document 的內容——沒有任何錯誤或警告訊號可以區分「讀到目標檔」與「讀到別的
# 文件」。因此 filePath 對唯讀查詢**不能取代**先把目標檔案變成 active document 這一步；`pen-read.sh`
# （封裝本腳本的 `--force-reload`）是供 QA／視覺審查安全讀稿用的入口。本腳本：`open -a Pen` 切檔 →
# 輪詢（總預算 ≤15s）用 `pen interactive --app desktop` 跑 `get_app_state()` 讀目前 active canvas editor 路徑 →
# 與目標路徑比對；不一致時嘗試自動清場後重試一次（R2，見下）。
#
# 用法：
#   pen-open.sh <worktree-or-repo-root> [--no-quit|--force-reload|--kill]
#                                                       把 Pen 切到 <root>/design/littlesprout.pen 並輪詢對帳；
#                                                       不一致時預設嘗試自動清場重試，`--no-quit` 關掉這步
#                                                       （只對帳、不清場，等同 R2 之前的行為）。**LS-118／LS-180**：
#                                                       `--force-reload` 不信任「路徑已一致」——既有 renderer 仍可能
#                                                       停在上次讀到磁碟的時間點；LS-180 起改為**先比 tree_hash**：
#                                                       磁碟 design_tree_hash.py vs Pencil 端 execute 回讀，相符即
#                                                       exit 0、不殺行程（Pencil MCP 連線保留）；不相符且安全判定
#                                                       通過才清場重開並印「需重連」；讀不到 Pencil 端雜湊則印期望
#                                                       值、exit 3 交 agent 複算（見下方 LS-180 段）。`pen-read.sh`
#                                                       即為此模式的唯讀封裝，供 QA／視覺審查讀稿用。
#                                                       `--kill`＝舊 `--force-reload` 語意：不比雜湊，一律安全判定＋
#                                                       kill＋重開——只給 orchestrator 明示清場用（LS-180）。
#   pen-open.sh --status                               不 open，只輪詢一次目前路徑並印到 stdout（供巡檢／派工前
#                                                       對帳用；不比對，比對交給呼叫端——見 §4-b）
#
# Exit code：
#   0＝（open 模式）路徑已一致（含自動清場重試後一致；`--force-reload` 為「一致且 tree_hash 相符」或「清場重開後
#      一致」；`--kill` 一律經過清場才算數）；（--status）成功讀到路徑並印出
#   1＝（open 模式限定）輪詢逾時仍與目標路徑不一致（含清場後仍不一致，或判定不安全而未清場）
#   2＝Pen 沒開／pen CLI 未登入／連線失敗／用法錯誤／清場失敗需人工介入（fail closed；--status 讀不到路徑也是這個）
#   3＝（--force-reload 限定，LS-180）路徑已一致但 Pencil 端 tree_hash 讀不到——未清場、MCP 連線保留；stdout 印期望值
#      `tree_hash=<磁碟值>`，呼叫的 agent 自己用 mcp__pencil__execute 跑 SCAN_HASH_ONLY 比對（見 LS-180 段第 3 點）
#
# R2／R3（自動清場，使用者核可 2026-08-25）：目標路徑已在背景視窗開著時，`open -a Pen` 不會奪回 active（見
# 下方「已知坑」）。輪詢逾時仍不一致 → **`kill` 殺的是 Pen 主行程＝全部視窗一起結束**，所以安全判定必須涵蓋
# 「目前所有開著的 .pen」，不能只驗目前 active 那一份（R2 版本只驗了 active 那份就漏了：目標路徑本身必定也
# 開在另一個背景視窗，否則一開始就不會走到這裡——那份從未被驗過就被 kill，R3 merge-reviewer 抓到）。做法：
# 用 `ps -Ao command | grep 'Pen Helper' | grep -oE 'file://.../design/littlesprout\.pen'` 唯讀枚舉目前所有
# renderer 行程命令列帶的檔案路徑（每個開著的文件是獨立的 renderer 行程），聯集上目前 active 路徑與目標路徑、
# 去重 → 每一個候選路徑各自推回 worktree 根、各自跑 `pen-land.sh <root> --dry-run`（不帶 --allow-unchanged，
# 藉此把它預設的「結構無差異」拒絕當成「沒有未落地變更」的安全信號來解讀）→ **全部**都安全才嘗試
# `osascript -e 'tell application "Pen" to quit'`（優雅退出，給 4 秒）→ 還在就 `kill -TERM`（不用 SIGKILL）→
# 總計等程序消失 ≤10 秒 → 重新 `open -a Pen` 並再跑一輪輪詢。任一份不安全／無法確認就完全不清場，印出提示
# 「先 pen-land <root>」，exit 1。`--no-quit` 關掉整段自動清場，只做原本的對帳。
#
# LS-117（三個相關缺陷，同批修）：
#   1. placeholder autosave 漂移擋切檔——主 checkout 每次被切走都會在 Pen 記憶體／backup 累積一個純
#      `placeholder`（pen-dev skill 定義的「工作中」UI 態旗標，見 ui-designer 收工前開關）屬性變更的漂移，
#      節點總數與 id 集合不變、且該檔對 git 全程 clean（漂移只在 Pen 記憶體，未進 git）。這類差異在
#      `pen-land.sh --dry-run` 眼中曾被當成「有結構差異」直接判定不安全，即使沒有任何實質內容被捨棄，
#      每次都要人工 SIGKILL 才能繼續派下一張設計票。修法：`pen-land.sh` 的 python 結構 diff 新增一個
#      「僅白名單屬性差異」判定（見該檔），`check_root_safe()` 認得這個訊號，**加驗** `git status --porcelain`
#      對該 root 的 `design/littlesprout.pen` 全程 clean（防止「landed 檔本身其實也被直接改過內容」這種
#      情況被誤放行）才視為安全。
#   2. Pen 無回應時無強制路徑——`osascript` quit 彈「儲存變更？」對話框回 `-128 User canceled`、`SIGTERM`
#      也無反應時，舊版本無路可走、只能印「需人工介入」然後 exit 2。修法：既然清場前已對**全部**候選 root
#      跑過 `check_root_safe()` 確認安全，`SIGTERM` 逾時後改為**在送出 SIGKILL 前重新對全部候選 root 跑一次
#      `check_root_safe()`**（防止等待期間 Pen 又寫入新的實質變更——TOCTOU 視窗雖短但存在）；重新確認仍安全
#      才 `kill -KILL`，並印一行稽核訊息（捨棄了哪些候選路徑、為何判定安全）；重新確認發現任一候選有實質
#      結構差異（非純白名單屬性）就**拒絕** SIGKILL，印「拒絕強殺」、exit 2，需人工介入——與 R1-R3 一貫的
#      「安全才動作」原則一致，只是把「安全」的定義從「零差異」放寬到「零差異或僅白名單屬性差異＋git-clean」。
#   3. `check_root_safe()` 誤判——查無 backup（`pen-land.sh` 印「找不到 backup」、exit 2）代表 Pen 從未開過
#      這個路徑、不可能有未落地的變更，是**安全**訊號，舊版本卻把它跟其他 exit 2（讀不到 backup mtime 等
#      真正無法確認的情況）混在一起當「不安全」。修法：`check_root_safe()` 認得這個特定訊息，直接判定安全。
#
# LS-118（`--force-reload`，補一個既有邏輯沒涵蓋到的缺口）：本腳本原本的成功判定只看「目前 active 路徑
# 是否等於目標路徑」，一致就立刻 exit 0，不管這個「一致」是這次呼叫剛清場重開才達成的，還是目標路徑本來就
# 已經是 active（例如它從未被切走過，或另一個 agent 前一刻才切過去）。本票合成 fixture 實測發現：一個
# 已經在跑的 renderer，即使之後又被重新 `open -a Pen` 同一路徑重新奪回 active，服務的內容仍是它自己那次
# 讀取磁碟當下的舊快照——不會因為磁碟檔案在那之後被 git 改過而自動變新（`execute` 的 `filePath` 命中同一個
# renderer 時也是同樣的舊快照，見上方 LS-118 段）。換句話說，舊版「一致即成功」的判定對「目標路徑本來就是
# active，但那個 renderer 已經讀過一次舊磁碟內容」這種情況會誤判成功——QA／視覺審查如果照著這個「已一致」
# 的訊號去讀稿，讀到的可能是別的 commit 的內容而不自知。`--force-reload` 的修法：一旦帶了這個旗標，
# 「目前已經一致」不再視為終點，而是無條件併入下面既有的自動清場流程（安全判定＋kill＋重開）——複用同一套
# `check_root_safe()`／候選枚舉／SIGTERM→SIGKILL escalation，不重寫一份新邏輯；清場後重新 `open -a Pen`
# 生出的全新 renderer 才保證這次是真的從磁碟讀出目前內容。若安全判定認為目前開著的任一份 .pen 可能有未落地
# 的真實變更，仍然 fail closed（exit 1，印出該去哪個 root 先 `pen-land.sh`），不會為了保證新鮮度而默默丟掉
# 別人真正的未落地設計工作。`pen-read.sh` 就是這個模式的唯讀封裝，供 reviewer／QA 安全讀取指定 worktree 的
# 設計稿；自測見 pen-open.test.sh 的 `--force-reload` 案例與 `pen-read.test.sh`。（**LS-180 修訂**：上文「無條件併入
# 清場流程」已改為「先比 tree_hash、相符不清場」，保留為沿革；現行語意見下方 LS-180 段。）
#
# LS-176（LS-96 池項 56eeaee0）：候選路徑在磁碟上已不存在（Pen 仍記得已被 cleanup-merged.sh 移掉的 worktree）
# 視為可安全捨棄——見 check_root_safe() 的訊號 d。舊版判「不存在→無法確認安全」拒絕清場，每張後續設計票的
# pen-read.sh 都被擋（LS-152／LS-163 清理後各發生一次）。
#
# LS-180（來源 LS-177 VR R2 `b017cbd1`；LS-96 池項 bed3ca3e 同族）：`--force-reload` 一律清場＝Pen 主行程被結束，
# **Pencil MCP 連線隨之中斷且 Claude Code session 內不會重連**（`mcp__pencil__*` 全部不可用，直到使用者手動 `/mcp`
# 重連）——「照指示切檔」與「照指示重掃／截圖」互斥。本票把 `--force-reload` 改成**先驗新鮮度、相符不殺**：
#   1. 切檔＋輪詢路徑一致後，磁碟 `scripts/gates/design_tree_hash.py <want>` 算 tree_hash，再用 `pen interactive --app
#      desktop` 餵 `execute({ input: <scripts/design/overflow-scan.js 全文，前置一行 SCAN_HASH_ONLY = true> })` 讀回
#      Pencil 端同一演算法印出的 `SUMMARY-HASH … tree_hash=…`（read_pen_hash()；每次看門狗 PEN_OPEN_HASH_TIMEOUT 秒、
#      最多 PEN_OPEN_HASH_ATTEMPTS 次）。**兩邊相符＝renderer 記憶體內容等於磁碟**（LS-118 要防的是 renderer 停在舊
#      磁碟快照；同一份 canon＋FNV-1a 64 全樹雜湊相符即等價證明），exit 0、不清場、MCP 連線保留。
#   2. 讀回的值與磁碟不同（renderer 真的停在舊快照、或記憶體有未落地編輯）→ 才走既有清場流程（候選枚舉＋
#      check_root_safe＋osascript→TERM→KILL＋重開）；未落地的真實編輯仍 fail closed exit 1，與 LS-118 相同。
#   3. 讀不到 Pencil 端雜湊（CLI 逾時／Pencil `InternalError: interrupted`——9000 節點級的稿單次 execute 走訪全樹會
#      機率性中斷，LS-177 R1／R2 實測；或 CLI 輸出格式改了）→ **不殺、不猜**：stdout 印期望值 `tree_hash=<磁碟值>` 與
#      複算指引，exit 3——由呼叫的 agent 用 mcp__pencil__execute 自己跑 SCAN_HASH_ONLY（大稿可分段累加，VR 既有作法）
#      比對；相符即可讀稿，不符回報 orchestrator 決定是否 `--kill`。這就是「印出待 agent 複算的期望值＋exit 碼」的
#      替代設計：Pencil 端唯一的 shell 途徑是同一支 execute，它在大稿上不保證成功，所以只能當快路徑、不能當唯一路徑。
#   4. 只要清場流程真的結束了 Pen 主行程，stdout 必印「⚠ Pencil MCP 需重連：請在 Claude Code 執行 /mcp 重連 pencil」
#      ——不論之後重開成功與否（agent 定義要求把這行帶回 handoff）；預設模式路徑不一致時的自動清場（R2）同樣印。
#   5. `--kill`：舊 `--force-reload` 語意（不比雜湊、一律安全判定＋kill＋重開），只給 orchestrator 明示清場用
#      （例：確定 renderer 壞掉、或要一次關掉累積的背景視窗）；與 `--force-reload`／`--no-quit` 互斥。
#   實機限制：本票開發期間 Pencil MCP 正斷線等使用者重連、Pen 開著 LS-177 的稿，硬限制不得對活的 Pen 跑本腳本——
#   read_pen_hash() 的 CLI 路徑只以 stub 自測（pen-open.test.sh ⑮），實跑格式（REPL 是否接受 JSON 字串字面值的
#   execute 參數、SUMMARY-HASH 行是否原樣印出）待 orchestrator 在重連後對 LS-177 worktree 跑一次 `--force-reload`
#   核對；失敗方向是 exit 3（不殺），不會誤放行、也不會誤殺。
#   已知盲區：`open -a Pen <want>` 對「已在背景視窗開著」的路徑不會奪回 active（下方已知坑），那條路徑仍只能清場——
#   本票的不殺路徑只救「目標已是 active」的情況（設計輪 designer↔VR 同一份稿交替最常見）。LS-180 裁決因此把規約
#   改成「設計票期間 Pen 停在票檔、ui-designer／VR 收工都不切回主 checkout」（ui-designer.md 步驟 5、COLLABORATION
#   §2／§6 ④），讓不殺路徑成為常態；票結案由 orchestrator 用 `--kill` 清場一次並請使用者重連。
#
# macOS 沒有 coreutils timeout：每次 pen interactive 呼叫用背景程序＋背景 sleep 到期就 kill 的看門狗模式
# （同 scripts/ops/patrol.sh 的 fetch_with_timeout；此處用 stdin/stdout 重導向而非管線，$! 才是 pen 程序本身的
# PID，kill 不會留下管線另一端的孤兒程序）。
#
# 自測：scripts/ops/pen-open.test.sh（stub `open`／`pen`／`pgrep`／`osascript`／`kill`；掛 CI `rules` job）。
#
# 已知坑（R1 I6）：本腳本與真實 pen CLI 唯一的耦合點是 poll_once() 那行 grep 樣式——
# 「Currently active canvas editor: `…`」，這是 pen CLI **0.3.4** 的輸出格式，沒有更穩定的結構化介面
# 可查（get_app_state() 回的是給人看的一段 message 文字，不是 JSON）。CLI 若改了這行的措辭，自測仍會綠
# （stub 複製的是同一個假設），但實跑會讀不到路徑、fail closed 成 exit 2——方向安全，不會誤放行，只是要
# 靠實機才驗得出來（見 handoff／本檔 git log 的實機復驗紀錄）。升級 pen CLI 後應重新用 `pen interactive
# --app desktop` 手動跑一次 `get_app_state()` 確認這行格式沒變。
#
# 已知坑（本票實測）：這台機器的 bash 3.2 在 LC_CTYPE=UTF-8 下，裸 `$var` 緊接全形標點（如「」／：）會把該標點的
# UTF-8 位元組也吃進變數名稱，觸發 `set -u` 的 unbound variable（例："$want」" 炸成「want�: unbound variable」）。
# 一律用 `${var}` 明確收尾；本檔與訊息字串中所有變數皆已改寫，新增訊息比照。
#
# 已知坑（本票實測，重要；R2／R3 起由自動清場處理）：`open -a Pen <path>` 只在該路徑**尚未在別的背景視窗開著**時
# 可靠——這台機器累積了 5 個過去票留下的背景 renderer（LS-17-impl／LS-72／LS-81／LS-91／主 checkout 各一），
# 對其中任一已開著的路徑重新 `open -a Pen` 並輪詢 30 秒（遠超本腳本預設的 15s）仍讀不到切換；get_app_state
# 回報的是「上次真正被切到的那個」，不會因為再 open 同一路徑而重新奪回 active。**唯一驗證有效的復原手段**：
# 確認目前所有開著的 .pen 皆無未落地變更後（R3：不只驗 active 那份，見上方 R2／R3 段）
# `kill -TERM <Pen 主行程 pid>` 乾淨結束，再 `open -a Pen <目標路徑>`
# 重開——全新行程對「當下沒有背景視窗」的路徑立即可切（本票 R1 階段實測：`osascript ... to quit` 在這個 session
# 的沙盒環境裡對 Pen 沒有效果，行程仍在——研判是 Automation 權限被擋，同一 session 內 `tell application
# "System Events"` 也讀不到 Pen 的視窗清單，同一種症狀；`kill -TERM <pid>` 由 PID 直接送訊號則確實有效、乾淨
# 結束後全部視窗的 backup 皆完整無損。R2 因此兩者都做：先試 osascript（環境允許時是更禮貌的退出方式），
# 短暫等待後一律補 `kill -TERM` 兜底，不依賴 osascript 一定成功）。
set -uo pipefail

usage() {
  echo "用法：pen-open.sh <worktree-or-repo-root> [--no-quit|--force-reload|--kill]｜pen-open.sh --status" >&2
}

PEN_BIN=${PEN_BIN:-pen}
POLL_TIMEOUT=${PEN_OPEN_TIMEOUT:-15}
ATTEMPT_TIMEOUT=${PEN_OPEN_ATTEMPT_TIMEOUT:-8}
POLL_INTERVAL=${PEN_OPEN_POLL_INTERVAL:-2}
QUIT_TIMEOUT=${PEN_OPEN_QUIT_TIMEOUT:-10}
QUIT_GRACE=${PEN_OPEN_QUIT_GRACE:-4}
# LS-180：Pencil 端 tree_hash 回讀（execute 全樹走訪）——單次看門狗與重試次數；9000 節點級的稿一次走訪要數十秒。
HASH_TIMEOUT=${PEN_OPEN_HASH_TIMEOUT:-60}
HASH_ATTEMPTS=${PEN_OPEN_HASH_ATTEMPTS:-2}
for v in "$POLL_TIMEOUT" "$ATTEMPT_TIMEOUT" "$POLL_INTERVAL" "$QUIT_TIMEOUT" "$QUIT_GRACE" "$HASH_TIMEOUT" "$HASH_ATTEMPTS"; do
  case "$v" in
    ''|*[!0-9]*) echo "✗ pen-open：PEN_OPEN_TIMEOUT／PEN_OPEN_ATTEMPT_TIMEOUT／PEN_OPEN_POLL_INTERVAL／PEN_OPEN_QUIT_TIMEOUT／PEN_OPEN_QUIT_GRACE／PEN_OPEN_HASH_TIMEOUT 須為整數秒、PEN_OPEN_HASH_ATTEMPTS 須為整數次數（得到「${v}」）" >&2; exit 2 ;;
  esac
done
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage
  exit 2
fi

mode=open
target=$1
no_quit=0
force_reload=0
kill_mode=0
if [ "$1" = "--status" ]; then
  if [ $# -ne 1 ]; then
    usage
    exit 2
  fi
  mode=status
  target=""
elif [ $# -eq 2 ]; then
  if [ "$2" = "--no-quit" ]; then
    no_quit=1
  elif [ "$2" = "--force-reload" ]; then
    force_reload=1
  elif [ "$2" = "--kill" ]; then
    kill_mode=1
  else
    usage
    exit 2
  fi
fi

command -v "$PEN_BIN" >/dev/null 2>&1 || {
  echo "✗ pen-open：找不到 pen CLI（PATH 上沒有「${PEN_BIN}」）" >&2
  exit 2
}

# 單次嘗試：跑 `pen interactive --app desktop` 餵 get_app_state()，印出擷取到的 active canvas editor 路徑
# （擷取不到印空字串）。用暫存檔而非 $(...) 直接包住整個背景管線，避免管線孤兒程序（見檔頭）。
poll_once() {
  local tmp in
  tmp=$(mktemp "${TMPDIR:-/tmp}/pen-open-out.XXXXXX") || return 1
  in=$(mktemp "${TMPDIR:-/tmp}/pen-open-in.XXXXXX") || { rm -f "$tmp"; return 1; }
  printf 'get_app_state()\nexit()\n' > "$in"
  "$PEN_BIN" interactive --app desktop < "$in" > "$tmp" 2>&1 &
  local ppid=$!
  ( sleep "$ATTEMPT_TIMEOUT"; kill "$ppid" 2>/dev/null ) >/dev/null 2>&1 &
  local wpid=$!
  wait "$ppid" 2>/dev/null
  kill "$wpid" 2>/dev/null
  rm -f "$in"
  grep -o 'Currently active canvas editor: `[^`]*`' "$tmp" 2>/dev/null \
    | sed -E 's/^Currently active canvas editor: `//; s/`$//' | head -1
  rm -f "$tmp"
}

# LS-180：向 Pencil 端回讀目前 active document 的 tree_hash——把正典腳本 scripts/design/overflow-scan.js 全文（前置
# `SCAN_HASH_ONLY = true;`）JSON 編碼成 JS 字串字面值，經 `pen interactive --app desktop` 的 `execute({ input })` 送進
# Pencil 跑同一份 canon＋FNV-1a 64 走訪，擷取它 Print 的 `SUMMARY-HASH total_nodes=… tree_hash=<16 hex>`。stdout 印
# 16 碼 hex；逾時／中斷／輸出無 SUMMARY-HASH 就印空字串（重試 HASH_ATTEMPTS 次後放棄），呼叫端據此走 exit 3 路徑。
# 看門狗／暫存檔／背景程序模式同 poll_once()。純唯讀（Get 走訪），不動文件。
read_pen_hash() {
  local snippet in tmp attempt h ppid wpid
  snippet=$(python3 - "${script_root}/scripts/design/overflow-scan.js" <<'PY'
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
print("execute({ input: " + json.dumps("SCAN_HASH_ONLY = true;\n" + src, ensure_ascii=True) + " })")
PY
  ) || { echo "  Pencil 端 tree_hash：無法組出 execute 片段（python3／overflow-scan.js 缺？）" >&2; return 0; }
  attempt=0
  while [ "$attempt" -lt "$HASH_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    tmp=$(mktemp "${TMPDIR:-/tmp}/pen-open-hash-out.XXXXXX") || return 0
    in=$(mktemp "${TMPDIR:-/tmp}/pen-open-hash-in.XXXXXX") || { rm -f "$tmp"; return 0; }
    printf '%s\nexit()\n' "$snippet" > "$in"
    "$PEN_BIN" interactive --app desktop < "$in" > "$tmp" 2>&1 &
    ppid=$!
    ( sleep "$HASH_TIMEOUT"; kill "$ppid" 2>/dev/null ) >/dev/null 2>&1 &
    wpid=$!
    wait "$ppid" 2>/dev/null
    kill "$wpid" 2>/dev/null
    h=$(grep -oE 'SUMMARY-HASH total_nodes=[0-9]+ tree_hash=[0-9a-f]{16}' "$tmp" 2>/dev/null | sed -E 's/.*tree_hash=//' | head -1)
    rm -f "$in" "$tmp"
    if [ -n "$h" ]; then
      printf '%s\n' "$h"
      return 0
    fi
    echo "  Pencil 端 tree_hash 第 ${attempt}/${HASH_ATTEMPTS} 次回讀失敗（${HASH_TIMEOUT}s 內無 SUMMARY-HASH 輸出：逾時／InternalError: interrupted／CLI 格式變了）" >&2
  done
  return 0
}

if [ "$mode" = status ]; then
  path=$(poll_once)
  if [ -z "$path" ]; then
    echo "✗ pen-open --status：讀不到 Pen 目前文件路徑（app 沒開／pen CLI 未登入／連線失敗，fail closed）" >&2
    exit 2
  fi
  echo "$path"
  exit 0
fi

root=$(cd "$target" 2>/dev/null && pwd -P) || {
  echo "✗ pen-open：找不到目錄「${target}」" >&2
  exit 2
}
want="${root}/design/littlesprout.pen"
[ -f "$want" ] || {
  echo "✗ pen-open：找不到「${want}」" >&2
  exit 2
}

# 輪詢到 $want 一致就 echo 訊息並回傳 0；逾時回傳 1（不一致，$LAST_SEEN 非空）或 2（讀不到路徑，$LAST_SEEN 空）。
# 用全域變數 LAST_SEEN 而非 local 回傳值，好讓呼叫端（清場後重試）也讀得到最後看到的路徑。
poll_until_match() {
  local deadline
  deadline=$((SECONDS + POLL_TIMEOUT))
  LAST_SEEN=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    path=$(poll_once)
    if [ -n "$path" ]; then
      LAST_SEEN=$path
      if [ "$path" = "$want" ]; then
        return 0
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] && sleep "$POLL_INTERVAL"
  done
  [ -n "$LAST_SEEN" ] && return 1
  return 2
}

open -a Pen "$want" >/dev/null 2>&1
poll_until_match
poll_rc=$?
if [ "$poll_rc" -eq 0 ] && [ "$force_reload" -ne 1 ] && [ "$kill_mode" -ne 1 ]; then
  echo "✓ pen-open：Pen 目前文件＝${want}"
  exit 0
fi
if [ "$poll_rc" -eq 2 ]; then
  echo "✗ pen-open：${POLL_TIMEOUT}s 內讀不到 Pen 文件路徑（app 沒開／pen CLI 未登入／連線失敗，fail closed）" >&2
  exit 2
fi

if [ "$poll_rc" -eq 0 ] && [ "$kill_mode" -eq 1 ]; then
  echo "  --kill：目前文件已是「${want}」，依 orchestrator 明示不比對 tree_hash、強制清場重開（LS-180）" >&2
elif [ "$poll_rc" -eq 0 ]; then
  # LS-118：--force-reload 且已經一致——不信任這個「一致」，既有 renderer 可能是停在舊磁碟內容的殘留行程。
  # LS-180：先比 tree_hash——磁碟 design_tree_hash.py vs Pencil 端 execute 回讀；相符即證明 renderer 內容＝磁碟，
  # 不清場（Pencil MCP 連線保留）；讀不到就印期望值 exit 3 交 agent 複算；只有真的不相符才併入下面的清場流程。
  disk_hash=$(python3 "${script_root}/scripts/gates/design_tree_hash.py" "$want" 2>/dev/null) || disk_hash=""
  case "$disk_hash" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *)
      echo "✗ pen-open：--force-reload 算不出磁碟 tree_hash（scripts/gates/design_tree_hash.py 對「${want}」失敗——.pen 壞掉或 python3 缺？fail closed）" >&2
      exit 2
      ;;
  esac
  echo "  --force-reload：目前文件已是「${want}」；磁碟 tree_hash=${disk_hash}，向 Pencil 端回讀比對新鮮度（LS-180：相符不清場）……" >&2
  pen_hash=$(read_pen_hash)
  if [ -n "$pen_hash" ] && [ "$pen_hash" = "$disk_hash" ]; then
    echo "✓ pen-open：Pen 目前文件＝${want}；tree_hash=${disk_hash} 與磁碟一致（renderer 內容＝磁碟，未清場、Pencil MCP 連線保留，LS-180）"
    exit 0
  fi
  if [ -z "$pen_hash" ]; then
    echo "⚠ pen-open：路徑已一致（${want}）但 Pencil 端 tree_hash 讀不到——未清場、Pencil MCP 連線保留；新鮮度待 agent 複算：用 mcp__pencil__execute 跑 scripts/design/overflow-scan.js（第一行加 SCAN_HASH_ONLY = true；大稿可分段累加），期望值 tree_hash=${disk_hash}；相符即可讀稿，不符回報 orchestrator 以 pen-open.sh <root> --kill 清場（之後需在 Claude Code 執行 /mcp 重連 pencil）（LS-180，exit 3）"
    exit 3
  fi
  echo "  --force-reload：tree_hash 不一致——磁碟 ${disk_hash}、Pencil 端 ${pen_hash}（renderer 停在舊快照或有未落地編輯，LS-118）——走清場重開" >&2
else
  echo "✗ pen-open：路徑不一致——目標「${want}」，Pen 目前「${LAST_SEEN}」" >&2
fi

if [ "$no_quit" -eq 1 ]; then
  echo "  （--no-quit：不嘗試清場，僅回報）" >&2
  exit 1
fi

# ---- R2 自動清場（R3 F1 修正：`kill` 殺的是 Pen 主行程＝全部視窗一起結束，必須驗過「全部目前開著的
# .pen」才能 quit，只驗 LAST_SEEN 那一份不夠——$want 本身必定也開在另一個背景視窗，否則一開始就不會走到
# 這裡）----
suffix="/design/littlesprout.pen"

# 列出目前所有 Pen renderer 行程命令列裡帶的 design/littlesprout.pen file:// URI（唯讀查詢，R3 實測可行：
# 每個開著的文件各自是一個獨立的 `Pen Helper (Renderer)` 行程，`--init-params` 帶著它的 fileURI）。
list_open_pen_paths() {
  ps -Ao command 2>/dev/null | grep 'Pen Helper' | grep -oE 'file://[^"]*/design/littlesprout\.pen' | sed 's#^file://##'
}

# check_root_safe <root>：用 pen-land.sh --dry-run 判斷這個 root 是否「沒有未落地的變更、或只有可安全捨棄的
# UI 態漂移」。回傳 0＝安全，1＝不安全或無法判定（fail closed）；印診斷到 stderr。三種安全訊號（LS-117）：
#   a. rc=1＋「本輪零變更或 autosave 還沒追上」——backup 與落地檔結構完全相同。
#   b. rc=2＋「找不到 backup」——Pen 從未開過這個路徑，不可能有未落地變更（defect 3：這是安全訊號，不是
#      「無法確認」）。
#   c. rc=0＋「僅偵測到白名單屬性」（見 pen-land.sh）——節點總數／id 集合不變，只有 placeholder 這類 UI 態
#      屬性有差異；**額外要求**目標檔對 git 全程 clean（`git status --porcelain` 該路徑無輸出）才視為安全
#      （defect 1：防止落地檔本身其實也被直接改過內容、只是恰好也帶了 placeholder 差異的邊界情況被誤放行）。
#   d. （LS-176，LS-96 池項 56eeaee0）`<root>/design/littlesprout.pen` 在磁碟上已不存在——Pen 記得的是被
#      cleanup-merged.sh 移掉的 worktree 路徑，落地目標都沒了，那份 renderer 記憶體裡的東西本來就無處可落地：
#      「無檔即無未落地變更可失」，視為可安全捨棄並印「舊路徑不存在，視為已捨棄：<path>」。舊版把它與
#      「無法確認」混在一起判不安全，LS-152／LS-163 worktree 清理後每張後續設計票的 pen-read.sh 都被擋、
#      renderer 讀現稿的新鮮度保證失效。路徑存在的 root 仍照 a–c／mtime 方向判定，dirty 照舊擋。
check_root_safe() {
  local root=$1 out rc
  if [ ! -e "${root}${suffix}" ]; then
    echo "  舊路徑不存在，視為已捨棄：${root}${suffix}" >&2
    return 0
  fi
  out=$(bash "${script_root}/scripts/ops/pen-land.sh" "$root" --dry-run 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF '本輪零變更或 autosave 還沒追上'; then
    echo "  「${root}」安全：本輪零變更（backup 與落地檔結構相同）" >&2
    return 0
  fi
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到 backup'; then
    echo "  「${root}」安全：查無 Pen backup（從未編輯過這個路徑）" >&2
    return 0
  fi
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '僅偵測到白名單屬性'; then
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && [ -z "$(git -C "$root" status --porcelain -- design/littlesprout.pen 2>/dev/null)" ]; then
      echo "  「${root}」安全：僅偵測到白名單（placeholder）UI 態差異，節點總數不變，且 design/littlesprout.pen 對 git 全程 clean——視為可安全捨棄的 autosave 漂移" >&2
      return 0
    fi
    echo "  「${root}」僅偵測到白名單屬性差異，但 design/littlesprout.pen 不是 git-clean（或無法確認是否為 git 倉庫）——不視為安全，需人工確認" >&2
  fi
  # LS-118 R1 F2（merge-review）：mtime 方向訊號——落地檔比 backup 新，代表 backup 是陳舊快取（本票要治的
  # 場景：QA git pull 後 Pen 那份 renderer／autosave 還停在舊版），不是「有真實未落地編輯」。這種情況下
  # 捨棄 backup、強制重新載入是安全的；**絕不能**指示跑 pen-land.sh——那會用這份陳舊快照覆蓋較新的落地檔
  # （R1 reviewer fixture 實證：2 節點落地檔被改寫成 1 節點 backup 版還印「✓ 已落地」）。仍要求 git-clean
  # （同 rule c 的理由：防止落地檔本身其實也被直接改過內容的邊界情況被誤放行）；不 clean 或無法確認就不
  # 提前 return，落到下面的通用訊息（其中已把「陳舊快取」列為優先假設）。
  if printf '%s' "$out" | grep -qF '落地檔 mtime 晚於 backup'; then
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && [ -z "$(git -C "$root" status --porcelain -- design/littlesprout.pen 2>/dev/null)" ]; then
      echo "  「${root}」安全：backup mtime 早於落地檔——落地檔在 Pen 上次 autosave 之後被更新（例如 git checkout／merge／pull），backup 是陳舊快取而非未落地的新編輯，且落地檔對 git 全程 clean——視為安全，不要跑 pen-land.sh（會用舊快照覆蓋較新的落地檔），直接強制重新載入即可" >&2
      return 0
    fi
    echo "  「${root}」backup mtime 早於落地檔（疑似陳舊快取），但落地檔對 git 不是 clean（或無法確認是否為 git 倉庫）——不視為安全，需人工確認方向" >&2
  fi
  echo "  「${root}」有結構差異，方向不明——**最常見成因是 Pen 快取陳舊**（backup 落後落地檔，例如 git pull／merge 之後 Pen 那份 renderer 還沒追上；此時不該跑 pen-land.sh，會用舊快照覆蓋較新的落地檔），也可能是真有未落地編輯（backup 領先落地檔，此時才該跑 bash scripts/ops/pen-land.sh ${root}）——人工核對 mtime／內容方向後再動作，不要預設跑 pen-land.sh" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  return 1
}

# 候選清單＝目前 active 文件（LAST_SEEN）＋目標文件（want，必定也開在某個背景視窗，否則不會走到這裡）＋
# ps 命令列枚舉到的全部開著的 .pen，去重（每個候選路徑對應唯一 root，去重路徑＝去重 root）。
candidates=$(
  {
    printf '%s\n' "$LAST_SEEN"
    printf '%s\n' "$want"
    list_open_pen_paths
  } | grep -v '^$' | sort -u
)
echo "  目前偵測到開著的 .pen 文件：" >&2
printf '%s\n' "$candidates" | sed 's/^/    /' >&2

# check_all_candidates_safe：對 $candidates 逐一 check_root_safe，全部安全才回傳 0——初次判定與（LS-117）
# SIGKILL 前重新確認共用同一份邏輯，避免兩處判定漂移。
check_all_candidates_safe() {
  local p root ok
  ok=1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      */design/littlesprout.pen) root=${p%$suffix} ;;
      *)
        echo "  「${p}」不是預期的 .../design/littlesprout.pen 形狀——無法安全判定，視為不安全" >&2
        ok=0
        continue
        ;;
    esac
    check_root_safe "$root" || ok=0
  done <<PATHS
$candidates
PATHS
  [ "$ok" -eq 1 ]
}

if ! check_all_candidates_safe; then
  echo "✗ pen-open：目前開著的 .pen 中至少一份可能有未落地變更（或無法確認安全）——不自動 quit，見上方訊息，逐一 pen-land 後再試" >&2
  exit 1
fi
echo "  已確認全部開著的 .pen 皆無未落地變更（或僅屬可安全捨棄的 UI 態漂移，見上方逐一判定），嘗試安全結束 Pen 並重開……" >&2

pen_pid=$(pgrep -f 'Pen\.app/Contents/MacOS/Pen$' 2>/dev/null | head -1)
pen_restarted=0
if [ -z "$pen_pid" ]; then
  if [ "$force_reload" -eq 1 ] || [ "$kill_mode" -eq 1 ]; then
    # LS-118 R1 F1（merge-review）：走到清場的 --force-reload（雜湊不符）與 --kill 的存在理由都是「exit 0 ⇒ 換成
    # 全新 renderer 剛讀過磁碟」。pgrep 找不到主行程時無從確認接下來的 open -a Pen 是重開了全新行程還是只是
    # 重新聚焦既有行程（樣式不符／改名／pgrep 缺失都可能讓 pgrep 撲空，但 Pen 其實還在跑）——不能假裝清場過，
    # fail closed。預設模式維持原行為：它的成功語意本來就只有「路徑一致」，不含「保證全新 renderer」。
    echo "✗ pen-open：--force-reload／--kill 但找不到 Pen 主行程（pgrep 沒有結果）——無法確認接下來會是全新 renderer 還是既有行程被重新聚焦，不繼續（fail closed）" >&2
    exit 2
  fi
  echo "  找不到 Pen 主行程（pgrep 沒有結果）——跳過清場步驟，直接嘗試重開" >&2
else
  osascript -e 'tell application "Pen" to quit' >/dev/null 2>&1
  quit_start=$SECONDS
  quit_deadline=$((quit_start + QUIT_TIMEOUT))
  term_sent=0
  while [ "$SECONDS" -lt "$quit_deadline" ] && kill -0 "$pen_pid" 2>/dev/null; do
    if [ "$term_sent" -eq 0 ] && [ "$SECONDS" -ge $((quit_start + QUIT_GRACE)) ]; then
      kill -TERM "$pen_pid" 2>/dev/null
      term_sent=1
    fi
    sleep 1
  done
  if kill -0 "$pen_pid" 2>/dev/null; then
    # LS-117 defect 2：優雅退出／SIGTERM 都無反應時，過去無路可走。既然清場前已對全部候選 root 判定過安全，
    # 這裡不是「沒有把關就強殺」——而是在 SIGKILL 前**重新確認**（防等待期間又生變更的 TOCTOU 窗口），
    # 重新確認仍安全才印稽核行並 escalate；發現任一候選轉為不安全就拒絕，不強殺。
    echo "  Pen（pid ${pen_pid}）優雅退出／SIGTERM 後 ${QUIT_TIMEOUT}s 內仍未結束——SIGKILL 前重新確認全部候選 .pen 仍安全……" >&2
    if ! check_all_candidates_safe; then
      echo "✗ pen-open：SIGKILL 前重新確認發現有實質結構差異——拒絕強殺，需人工介入（pid ${pen_pid} 仍存活）" >&2
      exit 2
    fi
    echo "  稽核：重新確認全部候選 .pen 仍安全（零變更／查無 backup／僅白名單 UI 態漂移＋git-clean，見上方逐一判定），SIGKILL pid=${pen_pid}，捨棄對象：" >&2
    printf '%s\n' "$candidates" | sed 's/^/    /' >&2
    kill -KILL "$pen_pid" 2>/dev/null
    kill_deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$kill_deadline" ] && kill -0 "$pen_pid" 2>/dev/null; do
      sleep 1
    done
    if kill -0 "$pen_pid" 2>/dev/null; then
      echo "✗ pen-open：Pen（pid ${pen_pid}）SIGKILL 後仍存活——需人工介入" >&2
      exit 2
    fi
  fi
  pen_restarted=1
fi

# LS-180：Pen 主行程一旦結束，Claude Code 這個 session 的 Pencil MCP 就斷了且不會自己重連——不論下面重開成功與否
# 都要讓呼叫者看到這行（agent 定義要求把它帶回 handoff；orchestrator 據此請使用者 /mcp 重連再派下一輪）。
reconnect_notice() {
  [ "$pen_restarted" -eq 1 ] || return 0
  echo "⚠ Pencil MCP 需重連：請在 Claude Code 執行 /mcp 重連 pencil（Pen 主行程 pid ${pen_pid} 已結束重開，本 session 的 mcp__pencil__* 不會自動重連——agent 收到這行必須在 handoff 回報「需重連」，LS-180）"
}

open -a Pen "$want" >/dev/null 2>&1
poll_until_match
poll_rc=$?
if [ "$poll_rc" -eq 0 ]; then
  echo "✓ pen-open：清場後 Pen 目前文件＝${want}"
  reconnect_notice
  exit 0
elif [ "$poll_rc" -eq 1 ]; then
  echo "✗ pen-open：清場後仍路徑不一致——目標「${want}」，Pen 目前「${LAST_SEEN}」" >&2
  reconnect_notice
  exit 1
else
  echo "✗ pen-open：清場後 ${POLL_TIMEOUT}s 內讀不到 Pen 文件路徑" >&2
  reconnect_notice
  exit 2
fi
