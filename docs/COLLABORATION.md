# COLLABORATION.md — Little Sprout 完整協作規約

本檔是 `CLAUDE.md` 的完整版參考：gates 細節、Linear 狀態機、命名與訊息範本、agent model 政策、前饋↔反饋對照表。產品與技術規劃見 `docs/PLAN.md`。

## 0. 最高原則：前饋必有反饋

所有寫給 agent 的指示（CLAUDE.md、agent 定義、派工 prompt）都**假設可能不被遵守**。每一條重要規則都必須有對應的**機械式反饋 gate**（hook、CI、腳本）攔截違規；做不到機械攔截的，由 orchestrator／merge-reviewer 人工兜底，並在 §7 對照表誠實標示。**新增重要規則時必須同時新增它的 gate，否則視為未完成。**

## 1. 角色與分工

- **Orchestrator（主 session）**：拆解任務、在 Linear 開票與推動狀態、指派 subagent、把關每一個 gate。原則上不直接寫功能程式碼（harness 與小型修補除外）。
- **ui-designer subagent**：**所有 UI 畫面設計必須由這個專門的 subagent 透過 Pencil MCP（.pen 設計檔）完成**。禁止在沒有 .pen 設計稿的情況下直接手寫新畫面的 SwiftUI 版面。設計檔：`design/littlesprout.pen`。
- **ios-dev subagent**：功能實作。一張 ticket＝一個 worktree＝一條 branch。
- **merge-reviewer subagent**：merge gate 的 code review（四維度，見 §4）。
- **qa subagent**：在 `test` branch 上依驗收條件驗收，UI 票必做視覺驗收（模擬器實際渲染，優先用 mobile-mcp，備援 `xcrun simctl` 截圖）。
- **dead-code-sweeper subagent**：feature 收尾時巡檢該 feature 引入的死碼與殘留物（只報告不刪改）。
- **visual-reviewer subagent**：對抗性視覺審查。**任何設計稿在送 orchestrator／使用者核可之前必須先過它**——以極嚴視覺標準獵殺 AI slop 與模板感，預設 ITERATE（退修；verdict 詞彙唯一：ITERATE／APPROVE），設計須自證三個記憶點才能通過。只審查不動檔。

**Agent model 政策**（agent 定義檔的 `model:` 為預設；orchestrator 派工時得以 Agent 工具的 `model` 參數覆寫升級）：

| Agent | 預設 | 升級到 opus 的時機（orchestrator 手動判斷） |
|---|---|---|
| ui-designer | sonnet | 建立全新設計語言／資訊架構大改版時 |
| ios-dev | sonnet | 併發或架構性的票（背景上傳佇列、導航骨架、RLS 設計）、同一票 sonnet 兩次未過 gate、hotfix |
| merge-reviewer | opus | 預設即最高——review 是安全網；純文件 diff 可降 sonnet |
| qa | sonnet | 驗收含併發時序或安全（RLS）判斷時 |
| dead-code-sweeper | sonnet | 大型 feature 批次或跨模組重構後的巡檢 |
| visual-reviewer | opus | 預設即最高——視覺判斷是對抗審查的核心能力 |

降級同理：機械性小任務（批次改名、跑腳本回報）可用 haiku。升降級都要在派工訊息中註明理由。

**審查類 agent 的 Linear 權限**（LS-60）：merge-reviewer 與 dead-code-sweeper 具 Linear 讀票（`get_issue`／`list_comments`）權，merge-reviewer 另具 `save_comment` 寫回權；兩者皆**無** `save_issue`（不得改狀態或票文）。審查依據以票文為準，不得只憑 commit／PR body 推斷。

## 2. 分支模型

| Branch | 用途 | 規則 |
|---|---|---|
| `main` | 正式站（App Store / TestFlight 發佈來源） | 禁止直接 commit；只接受來自 `test` 的 PR 或 `hotfix/*`／harness 分支 |
| `test` | 測試站；qa subagent 在此驗收 | 禁止直接 commit；只接受來自 `development` 的 PR（或 main back-merge） |
| `development` | 開發整合 | 禁止直接 commit；只接受來自工作分支的 PR（或 main back-merge） |
| `feature/*` `fix/*` `hotfix/*` | 工作分支 | 一律在 worktree 中作業；`hotfix/*` 從 `main` 切出 |

流向：`feature/* → development → test → main`。development→test 由 orchestrator 批次 promote；test→main 即 release（打 tag `vX.Y.Z`）。

**GitHub 端強制**（三條保護分支皆已設定）：必須走 PR、required status checks `ci`＋`lint`＋`rules`＋`db`、enforce_admins（admin 也不能繞）、禁 force-push 與刪除。

**Worktree 規約（平行分工）**：
- 位置 `.claude/worktrees/LS-<n>`（已 gitignore）。一張 ticket 一個 worktree 一條 branch（gate：`branch-ticket-check`，工作分支自 merge-base 以來的 commit 票號必須等於分支票號；刻意夾帶他票以 commit body＋PR body 各一行 `Bundles: LS-<m>` 宣告——LS-50，§7）。
- 多張 ticket 平行時各自 worktree，**禁止跨 worktree 編輯檔案**；合併完成後移除 worktree。
- 首次 clone 後執行 `git config core.hooksPath .githooks` 啟用 gate hooks（worktree 共用同一份 config，不必重設）。

**Harness 變更例外**：協作規約與 harness 檔（`CLAUDE.md`、`docs/COLLABORATION.md`、`.claude/agents/`、`.claude/settings.json`、`scripts/gates/`、`scripts/ops/`、`.githooks/`、`.github/`、`.mcp.json`）不走 feature→QA 全流程，比照 hotfix：從 `main` 切 `hotfix/LS-<n>-*` branch、PR 回 `main`（CI 照跑），合併後 back-merge 到 `test` 與 `development`——這些檔案必須在所有分支即時一致。

**harness PR 併入 `main` 後，先 pull 主 checkout 再派 agent（LS-71）**：agent 定義（`.claude/agents/`）、`CLAUDE.md`、專案層 `.claude/settings.json` 與 gate 腳本都是從**主 checkout**（repo 根目錄，不是 worktree）讀的——harness PR 併了但主 checkout 沒 `git pull --ff-only origin main`，接下來派出的每個 agent 都在用舊規約。SessionStart hook 會在 session 開頭偵測主 checkout 落後 `origin/main` 並提示（§4-b）；session 中途併入的靠 orchestrator 在 merge 後立刻 pull（§7）。**並行 harness PR 的合併順序**：兩張 harness 票同時在飛時幾乎必撞 `docs/COLLABORATION.md` §7 對照表尾與 `.github/workflows/ci.yml` 的自測 step——先併者不動，**後併者負責 `git merge origin/main` 解衝突再 push**（PR 頁 CONFLICTING 不會跑 CI，`merge-conflict-check` 只驗 push 當下，§7）。

**本地合併版 back-merge 的分支命名（LS-56 補記）**：GitHub 偶爾把 `main`→`development`／`test` 的 back-merge PR 誤判 CONFLICTING（本地 `git merge-tree` 零衝突——LS-54 PR #71 實測）。此時改在本地把 `main` merge 進目標分支的臨時分支再開 PR，該分支**必須命名 `hotfix/LS-<n>-backmerge-<target>`**（例：`hotfix/LS-54-backmerge-development`）。**本變通只適用 `<target>=development`**：方向矩陣 `base=test` 只收 `development|main|revert-*`，`hotfix/*` 開向 `test` 會被擋死；`test` 端若誤判 CONFLICTING，改 close／reopen 該 PR 或重推一個 head=`main` 的 PR，不放寬矩陣。命名成 `back-merge/*` 會被擋：CI 由 `rules` job 方向矩陣擋（PR #73 被擋、#74 改名後通過）、本機由 `commit-gate.sh` 的 branch 命名 regex 擋，不必另開規則。

**harness back-merge 後，open PR 要手動 update-branch（LS-10 補記）**：GitHub 的 `pull_request` workflow 定義是跟著該 PR 的 **head** 分支當下內容跑，base 分支被 back-merge 進新的 gate／CI 定義後不會自動反映到既有 open PR 上——那些 PR 的 head 沒有拿到新 commit，仍在用 merge 前的 workflow 版本檢查自己。這不是理論風險：LS-5 的 PR 在 harness back-merge 前後兩次 CI run（`32560313234` → `32560481798`）就是實測到同一份 head 內容因為 base 端 workflow 版本不同而跑出不同結果。做法：**orchestrator 每次執行 harness back-merge 到 `test`／`development` 後，必須對這兩條分支上所有還開著的 PR 執行 `gh pr update-branch`**，把 back-merge 後的最新 commit 併進各 PR 的 head，讓它們吃到新 gate 再繼續走 review／CI。無機械 gate（GitHub 不會替你做這件事）；由 orchestrator 人工執行並在對應 ticket 記錄。

## 3. 命名與訊息規約

**Branch**：`feature/LS-123-short-slug`、`fix/LS-124-short-slug`、`hotfix/LS-125-short-slug`（slug 英文小寫連字號；pre-commit hook 會驗格式）。

**Commit message**（Conventional Commits + Linear ID；commit-msg hook 會驗第一行）：
```
<type>(<scope>): LS-<n> <一句話摘要>

<why：為什麼這樣改，而不只是改了什麼>

Fixes LS-<n>        ← 此 commit 完結該票時才加（Linear 自動連動）
```
type ∈ `feat|fix|chore|docs|refactor|test|perf|design`；scope 可省略。禁止 `--no-verify` 繞過 hooks（本機繞過者仍會被 CI required check 擋在 merge 前）。

**PR message**：依 `.github/pull_request_template.md`（ticket、變更摘要、驗證方式、風險、UI 截圖）。**檔頭段必須含本票 `LS-<n>`**（檔頭段＝從檔頭到第一個內容段落結束；開頭空白行與 `#` 標題行一併納入——模板的「## Ticket／空行／LS-<n>」與「Ticket: LS-<n> …」皆可）；`gh pr create/edit --body-file <f>` 之前先 `bash scripts/gates/pr-body-check.sh <f>` 斷言（票號取自當前分支），CI `rules` job 以 head 分支票號再驗（LS-63）。**紅了之後修 body 不會讓 CI 自動重跑**（`pull_request` 觸發不含 `edited`，`gh run rerun` 也重放舊 body）——close/reopen PR 或再 push 一個 commit（同 §6 DESTRUCTIVE-APPROVED 標記的坑，LS-37 實測）。含新畫面的 PR 必須在 body 寫 `Design: <.pen frame 名>`（CI 會驗）。

**暫存檔（scratchpad）**：agent 的暫存檔（PR body、handoff 草稿、取證輸出…）檔名一律 `LS-<n>-<用途>.<ext>`，或放進 `mktemp -d` 子目錄；禁止 `pr-body.md` 這類無票號通名——平行 agent 共用同一個 scratchpad 目錄會互相覆寫（2026-08-24 LS-53／LS-56 撞檔，LS-56 的 body 被 `gh pr edit` 貼上 PR #78，LS-63）。檔名本身無機械 gate，靠上列 PR body 檢查攔它要防的結果。

**派工 prompt 固定五條（LS-71）**——orchestrator 派任何會寫檔／開 PR 的 agent 都貼進 prompt（general-purpose agent 不讀本檔，只有 prompt 到得了）：
1. 暫存檔一律 `LS-<n>-<用途>.<ext>` 或 `mktemp -d`（上段；LS-63 事故）。
2. `gh pr create/edit --body-file <f>` 前先 `bash scripts/gates/pr-body-check.sh <f>`（CI 亦驗檔頭段含分支票號）。
3. `.test.sh` 失敗分支用 `${name}`，不寫 `"$name（"`（bash 3.2 會炸，LS-59）。
4. 分段落地：長工作每完成一項就落地＋commit（.pen 存檔、程式 commit-gate 過就 commit），不准累積到最後一次交——LS-46 R8 第一次派工 4.5 小時無存檔。
5. handoff「未完成／剩餘」欄必列 reviewer 每一條 informational 的處置（已修／另票 LS-<m>／不修＋理由），一條不能省（CLAUDE.md「每個 agent 都要遵守」）。

**Handoff 訊息**（subagent 完成或交接時，一律用此格式）：
```
Ticket：LS-<n>
已完成：（逐項）
已驗證：（怎麼驗的：測試名稱／指令輸出／截圖）
未完成／剩餘：（reviewer 全部 informational 的處置逐條列：已修／另票 LS-<m>／不修＋理由）
風險與已知問題：
產出位置：branch／PR／.pen frame 名稱
```

## 4. Gates（每關都要有證據，fail loud）

| Gate | 時點 | 內容 | 執行者 |
|---|---|---|---|
| **Design gate** | ticket 含 UI 時，開發前 | ① ui-designer 完成 .pen 畫面 → ② **visual-reviewer 對抗審查×ui-designer 修改，至少完整迭代 3 輪**（前 2 輪一律 ITERATE 抬標準；第 3 輪起才可 APPROVE，未達標續迭）→ ③ design-landing-check 綠燈（`--expect-nodes` 對畫布，輸出貼 ticket）→ ④ orchestrator（重大畫面：使用者本人）核可 | ui-designer + visual-reviewer |
| **Commit gate** | pre-commit hook | 禁止直接 commit 保護分支；branch 命名格式；secrets 掃描；已追蹤檔不得命中 .gitignore（`tracked-ignored-check`，LS-51）；審查取證路徑不得 staged（`evidence-path-check`，LS-61）；staged .pen 落地檢查（`design-landing-check`，LS-26）；staged Swift 檔過 SwiftLint | 自動（`scripts/gates/commit-gate.sh`） |
| **Commit-msg gate** | commit-msg hook | commit message 第一行格式（type + LS-n） | 自動（`scripts/gates/commit-msg-gate.sh`） |
| **Push gate** | pre-push hook | 全 repo SwiftLint；unit tests（xcodebuild test，動態選模擬器，序列執行；SPM 解析在 hook 環境會因 git 匯出的 `GIT_DIR` 炸掉——push-gate 開頭先 `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX`（LS-73，根因）；原「瞬斷隔 10 秒重試」保留為保險（LS-56））；API 契約對帳（`api-contract-check` 文字模式，有 `supabase/migrations` 才跑，LS-41）；錯誤碼三方對帳（`error-codes-check`：API.md §5 ↔ LSErrorCode ↔ migrations errcode，無條件跑，LS-54／LS-56）；migration 版本號撞號（`migration-version-check --target origin/<target>`：本分支 tree 內版本號重複、或本分支版本號已在 target 當前 tip 但檔名不同即擋——LS-57／LS-66 同取 `20260825030000`，LS-70）；migration 分級（`migration-breaking-check --base`：BREAKING 且本分支未動 `docs/API.md` 即擋；PR body 標記只有 CI 驗得到，這裡印提醒——LS-53）；分支起點乾淨度（`branch-ticket-check --base`：自 merge-base 以來的非 merge commit 票號≠分支票號即擋，刻意夾帶以 commit body 獨佔一行 `Bundles: LS-<m>` 宣告、PR body 同步宣告由 CI 驗——LS-50）；合併衝突預檢（`merge-conflict-check --target origin/<target>`：本機 ref 落後遠端即擋要求 fetch，`git merge-tree --write-tree` 有衝突即擋並指示 `git merge origin/<target>`——LS-50） | 自動（`scripts/gates/push-gate.sh`） |
| **Merge gate** | 每個 PR | CI 綠燈（rules＋lint＋build/test）＋ merge-reviewer 四維度審查：**race condition、運算效能、平行優化、scope** | CI + merge-reviewer |
| **QA gate** | 併入 test 之後 | qa subagent 逐條驗證 ticket 驗收條件＋回歸冒煙（登入／時間軸／上傳／留言）＋RLS 冒煙＋**視覺驗收**（UI 票：模擬器渲染截圖比對 .pen 設計稿） | qa |
| **收尾 gate** | QA 過後、Done 之前 | ① dead-code-sweeper 巡檢 feature 引入的死碼（findings 開 fix 票或併入下票）② orchestrator 的 **lesson learning review**：gate 攔截／漏接、返工原因、harness 與設定改善項（開票）、工具缺口、model 政策調整。兩者記於 ticket comment，缺一不得進 Done | dead-code-sweeper + orchestrator |

Merge gate 有任一 blocker/major finding → REQUEST_CHANGES，不得合併。gate 工具缺失（如有 Swift 檔但 SwiftLint 未裝）→ 直接 fail，不得靜默跳過。

## 4-b. Orchestrator 巡檢與 session 連續性（LS-71）

巡檢要抓的是「**無依賴卻沒人動**」的項——PR 開著沒人審／審過沒人併、分支領先 remote 沒 push（agent 等自己的背景 push 不醒）、worktree 有變更卻長時間沒 commit（設計 agent 4.5h 無存檔）、Ready 沒人接、QA 票 test 分支沒含、lane 有空位卻沒補票（§5-b，LS-75）。這些不會自己好、也沒有人會通知，靠 orchestrator 定期巡（2026-08-25 三種停滯的來源）。

**工具**：`bash scripts/ops/patrol.sh [stale_minutes] [--brief|--json] [--no-fetch] [--no-pr] [--repo <path>]`——只讀不寫（唯一寫入是 `git fetch origin`），列 open PR（mergeState／review／幾分鐘沒更新）、三分支落後數、主 checkout 是否落後 `origin/main`、每個 worktree 的 local vs remote／未 push／dirty 停滯、Supabase lock 持有者（`scripts/ops/supabase-lock.sh --status` 讀 holder 檔，LS-70）；`--brief` 只印表頭＋異常行（hook 用；lock 持有中另印一行），`--json` 給程式讀；時間一律 epoch（`git log --format=%ct`、gh 內建 jq 的 `fromdateiso8601`），macOS／GNU 都能跑；`git fetch` 掛看門狗（`PATROL_FETCH_TIMEOUT`，預設 10s——黑洞位址的 TCP 逾時實測 75s，會把 hook 的 30s 撐爆），逾時或失敗印警告、退回本機 ref 續巡；gh 未裝或失敗只標「略過」不炸。自測 `scripts/ops/patrol.test.sh`（合成 repo，掛 CI `rules` job）。Linear 那一半要用 MCP `list_issues` 對照，腳本只印提醒；**lane 補位**（§5-b）同屬 Linear 那一半——`patrol.sh` 無 Linear token，由 orchestrator 依下方 cron 模板用 MCP 執行。

**三種停滯型態**（腳本判定規則；stale＝參數分鐘數，預設 45）：
1. **PR 停滯**：CONFLICTING／UNSTABLE／BEHIND／CHANGES_REQUESTED 立即標；CLEAN 且 reviewDecision＝APPROVED 立即標「可併」；其餘 CLEAN／BLOCKED 超過 stale 沒更新標 ⏳（草稿不標）。
2. **分支停滯**：有 commit 但分支從未 push；領先 remote 且最後 commit 超過 stale（push gate 卡）；落後 remote（別處 push 過）；已 push、無 open PR、最後 commit 超過 stale。
3. **工作區停滯**：有未提交變更（不含 untracked）且最後改動超過 stale；worktree 建好超過 stale 仍 0 commit 無變更（尚未開工）；分支已併入 base（自 merge-base 0 commit、但分支 reflog 有過 commit）而 worktree 未移除（§2：合併完成後移除 worktree）。「最後 commit 幾分鐘前」只在分支自 merge-base 後有 commit 時才看——新 worktree 的 HEAD 就是 base commit，拿它的時間會把剛建好的 worktree 誤判成停滯（scratchpad 原型的 bug）；0 commit 時看 dirty 檔 mtime 與 worktree 的 `.git` 檔 mtime。

**Session 連續性**（新 session 不靠記憶檔就能接手）：
- **SessionStart hook**（專案層 `.claude/settings.json`，入版控 → `scripts/ops/session-start.sh`，timeout 30s）：startup／resume／clear／compact 後跑 `patrol.sh --brief`，把巡檢摘要＋兩條指示注入 context——①主 checkout 落後 `origin/main` 時先 `git pull --ff-only origin main` 再派工（§2）；②本 session 尚未建巡檢 cron 就立即建（下方模板）。fail-soft：patrol 炸掉／repo 找不到仍輸出合法 JSON、exit 0，錯誤寫在 context 裡，不擋 session。與使用者層的 SessionStart hook 並存不覆蓋；改 `settings.json` 後 settings watcher 要 `/hooks` 或重啟才載入。驗法：`echo '{}' | bash scripts/ops/session-start.sh | jq -e '.hookSpecificOutput.additionalContext'`。
- **巡檢 cron**（`CronCreate`，`*/26 * * * *`；session-only、7 天到期，所以每個新 session 都由 hook 提醒重建）——prompt 模板（hook 引用的就是這段）：

  > 跑 `bash scripts/ops/patrol.sh 40`＋linear `list_issues`（Ready／In Progress／In Review／QA），只處理無依賴卻沒人動的項：CLEAN 且已 APPROVE 的 PR → 併；CLEAN 無 review → 派 merge-reviewer；分支領先 remote >40 分鐘 → 催／重派；Ready 無人接 → 派工；In Progress >60 分鐘無 commit 且無 dirty → 查勤；QA 但 test 未含 → 晉升。再做 lane 補位（§5-b）：`list_issue_labels` 取五個 `lane:*`；`list_issues` 各查 state Backlog／In Progress／In Review（fields labels、priority、createdAt）——每 lane 在飛＝In Progress＋In Review 張數，候補＝該 lane Backlog 中非 `lane:product`、priority 最高（同 priority 取 createdAt 最早）者，候補以 `get_issue`（includeRelations）查 blockedBy 全 Done 才算依賴已解，且候補票文須具備可驗證驗收條件與 scope（Spec 出口）——依賴未解、或缺驗收條件（在狀態表標「待 Spec」）皆看下一張，不改 Ready；印 lane 狀態表（每 lane：上限／在飛／候補），並列「無 lane 標籤的 open 票」；在飛＜上限且有候補 → `save_issue` state Ready → 立即派工（Ready 不停留）。有動作記一行，全正常回『巡檢：無異常』

- 巡檢有動作時在對應 ticket 留 comment（§6 Checkpoint 同理），讓下一個 session 看得到誰在等什麼。

## 5. Linear（協作狀態機）

- Team key：`LS`（workspace `little-sprout-app`）。**Linear 是唯一的任務狀態來源**；每個狀態的離開就是一個 gate，由 orchestrator 執行轉換並在 ticket 留 comment 記錄 gate 證據。
- MCP 設定在專案 `.mcp.json`；linear 走 OAuth（session 重啟後用 `/mcp` 完成），其餘皆 stdio＋.env 注入。
- **MCP 必要環境變數**：repo 根 `.env`（gitignored）須含 `FIGMA_PERSONAL_ACCESS_TOKEN`（figma MCP，LS-42）與 `SUPABASE_ACCESS_TOKEN`（supabase MCP，LS-43）——啟動時注入、缺失即啟動失敗 fail loud。`.env` 的值一律只認 key 名、不讀取。
- **開票結構**：Project＝epic；Milestone＝feature 群（同一 epic 底下相關的一批 issue）；Issue＝story，必須帶可驗證的驗收條件（同 §1 的 Spec 狀態離開條件）；Sub-issue＝task，**只有在單一 story 需要多個 agent 接力完成**（例如設計→實作→審查分屬不同派工、無法一個 agent 一次做完）時才拆，拆分依據與各 task 的範圍寫在該 story 的 ticket scope 裡，不預先拆。

| 狀態 | 離開條件（gate） |
|---|---|
| Backlog | 被排入優先，值得寫規格；或由 §5-b lane 補位規則直接改 Ready（限票文已具驗收條件者） |
| Spec | ticket 具備**可驗證的驗收條件**與明確 scope |
| Design | design gate 過（純後端票可跳過此狀態） |
| Ready | worktree＋branch 已建、指派給 agent |
| In Progress | push gate 過、PR 開出 |
| In Review | merge gate 過、併入 development |
| QA | QA gate 過（在 test branch）**且收尾 gate 完成**（dead-code 巡檢＋retro 記錄在案） |
| Done | 已併入 main（隨 release） |
| Canceled | 記錄取消原因 |

## 5-b. Lane 與 WIP 上限／Backlog→Ready 機械規則（LS-75）

使用者 2026-08-25 決議：WIP 上限寫進規約、巡檢每輪多做一步「lane 補位」、票間依賴只用 Linear 關係。規則全在 Linear 側，repo 內無 gate（§7 標 ⚠️ 巡檢承載）。

- **Lane**＝Linear label，五個：`lane:harness`、`lane:backend`、`lane:design`、`lane:ui`、`lane:product`（需使用者決策的規格題，不派工）。**每張票必帶一個 lane 標籤，開票即標**（orchestrator 開票的必填項；`save_issue` 的 `labels`）。
- **WIP 上限**（同 lane 狀態 **In Progress＋In Review** 的票數；Ready 不停留、QA 不計）：

| Lane | 上限 |
|---|---|
| `lane:harness` | 1 |
| `lane:backend` | 2 → **3**（lock 落地後：`scripts/ops/supabase-lock.sh` 隨 LS-70 於 2026-08-25 併入 main 起生效） |
| `lane:design` | 1（Pencil 單一實例） |
| `lane:ui` | ＝已核可設計稿對應的畫面群數（目前 LS-46 → 1；LS-67 核可後 +1） |
| `lane:product` | 不派工，無上限 |

- **依賴只用 Linear `blockedBy` 關係**（`save_issue` 的 `blockedBy`），**不用文字**；「依賴已解」＝所有 blockedBy 皆 Done。
- **Backlog→Ready 機械規則**——觸發時點：巡檢每輪（§4-b cron），以及任一票進 In Review／Done 時。對每個 lane：若 In Progress＋In Review ＜ 上限 → 取該 lane Backlog 中 **priority 最高、blockedBy 全 Done、且不需使用者決策（非 `lane:product`）** 的票 → 改 Ready → **立即派工（Ready 不停留）**；同 priority 取 createdAt 最早。補位跳過 Spec／Design 兩格但不免除其離開條件：候補票文須已有可驗證驗收條件與 scope（Spec 出口），缺者不算候補、在 lane 狀態表標「待 Spec」；`lane:ui` 的 Design 出口由上限定義承載（沒核可稿就沒空位）。
- **例外**：`lane:design` 與 `lane:ui` 共用 Pen 時，ui 票的「設計稿讀取階段」期間 design lane 視為滿。
- **巡檢輸出**多一段「**lane 狀態表**」（每 lane：上限／在飛／候補票）＋「**無 lane 標籤的 open 票**」清單（盲區提醒：沒標 lane 的票不會被補位）。
- **機械面**：`scripts/ops/patrol.sh` 無 Linear token，lane 步驟由 orchestrator 用 MCP 執行（`list_issue_labels`＋`list_issues`＋`get_issue`＋`save_issue`，步驟寫在 §4-b cron 模板）；CI／pre-push 不驗。

## 6. 補充規定

- **Hotfix**：`hotfix/*` 從 `main` 切出、PR 回 `main`（CI＋review 照跑、QA 走快速通道），合併後**必須 back-merge 到 `test` 與 `development`**。
- **Release**：test→main 合併後打 tag `vX.Y.Z`（semver），TestFlight 上傳由 orchestrator 執行並在對應 ticket 記錄 build 號。
- **DB migration gate**：`supabase/migrations` 的變更必附 RLS 測試（CI 強制）；**破壞性 migration（DROP、縮欄、改型）需使用者本人核可**——核可方式：使用者本人在 PR body 加上 `DESTRUCTIVE-APPROVED`，**標記須獨佔一行**（允許前後空白；同行不得有其他字，粗體／反引號包起也不算。反過來，gate 只看 raw body 的行：藏在多行 HTML 註解 `<!-- … -->` 或 fenced code block 內的獨佔行仍會放行，rendered body 看不見——標記不保證肉眼可見，審查請看 raw body——LS-45），agent 不得代寫。加標記後 CI 不會自動重跑（`pull_request` 觸發不含 `edited`），需 close/reopen 或再 push（LS-37 實測；§3 的 PR body 票號檢查 LS-63 同坑）。**分級自 LS-53 起由 `scripts/gates/migration-breaking-check.sh` 做 statement 級判定**（單一 pass 剝 `--`／`/* */` 註解後以 `;` 切句，多行敘述、單一字面值的 `execute '…'` 動態 SQL 也認得；`||` 串接拆開多字關鍵字認不得——已知限制，靠 merge-reviewer；規則表在檔頭）：**DESTRUCTIVE**（任何 DROP／TRUNCATE／DISABLE RLS／ALTER COLUMN TYPE，不留物件型別白名單讓人換寫法）→ 上述本人核可；**BREAKING**（ALTER POLICY 不分收緊放寬、CREATE POLICY … AS RESTRICTIVE、REVOKE 收回 public／anon 以外角色、CREATE [OR REPLACE] FUNCTION／DROP FUNCTION 既有名稱、RENAME、SET SCHEMA）→ PR body 須有 **`BREAKING:` 段落**：`BREAKING:` 在行首、同一行寫受影響呼叫端／app 版本／遷移路徑摘要（`scripts/gates/breaking-section-check.sh` 行錨定；粗體／列點／引用前綴、只有標頭下一行才寫內容皆不算；細節可在下方列點），**且 `docs/API.md` 須在同 PR 有變更**（契約文件跟著改；既有 RPC 只改本體也算——在該條目補一行行為差異）。兩級以檔內所有命中取聯集，同一句也可同時命中兩級（LS-37 invites：DROP POLICY＋REVOKE authenticated ＝ 兩者都要；DROP FUNCTION 既有 RPC ＝ 兩者都要）。只從 public／anon 收回的 REVOKE 是新函式上鎖慣例、ALTER DEFAULT PRIVILEGES 只影響未來物件，皆不算。
- **Secrets**：金鑰一律不進 repo。Client 端用 gitignored 的 `Secrets.xcconfig`；CI 用 GitHub Secrets；`service_role` key 永不出現在 client 或 repo。
- **回滾**：正式站問題以 revert PR 處理（GitHub Revert 按鈕產生的 `revert-*` head 在 CI 方向矩陣中對三條保護分支皆合法）；保護分支禁止 force-push。
- **本機 Supabase 容器序列化（LS-70）**：本機 `supabase db reset`／`bash supabase/tests/run.sh`（及任何會動同一容器的指令）一律經 `bash scripts/ops/supabase-lock.sh -- <命令>`——所有 worktree 共用同一個容器（同 `project_id`／port），裸跑互踩（LS-57／LS-66：rc=137、"container is not running"、migration 忽有忽無）。lock＝`/tmp/supabase-lock-<project_id>` 目錄（`mkdir` 原子性，macOS 無 flock），holder 檔記 pid／worktree／branch／cmd／時間；等待逾時 15 分鐘 fail loud（exit 124）；持有者 pid 不存在自動回收；`run.sh` 未在 lock 內會自己經 lock 重跑；巡檢 `patrol.sh` 印持有者。等待逾時先看持有者是否還在跑，**不得 `rm -rf` 別人的 lock**。**migration 版本號**取 `date -u +%Y%m%d%H%M%S` 當下時間、不手填整點；push-gate 4b／CI Migration rules 以 `migration-version-check` 擋本分支內重複與「與目標分支同版本、不同檔名」的撞號。隔離方案（每 worktree 各自 `project_id`／port 的容器）另票評估。
- **雲端資料庫只透過 migration 變更**：schema／policy 變更一律走 `supabase/migrations`＋PR，**禁止用 Supabase MCP 或 dashboard 直接改正式專案**。機械面：`.mcp.json` 的 supabase MCP 以 `--read-only --project-ref` 鎖唯讀與專案（LS-43 起走 PAT/stdio，PAT 存 .env），需要寫入時由使用者本人臨時解鎖。**注意：PAT 是帳號層級、具完整寫入權的 Management API 憑證，唯讀鎖只在本機 client 端生效，且 Management API 路徑繞過 RLS——`.env` 的保管等級＝正式站的保管等級**。`project_ref` 視為公開資訊（本來就會出現在 app 的 API URL）。
- **正式站 `supabase db push` 每次需使用者當次授權（LS-71）**：對正式專案執行 `supabase db push`（及任何會改雲端 schema／資料的 CLI 指令）每一次都要使用者本人**當次**口頭授權——不得沿用上一次的授權、不得寫進 permissions allow 清單、不得由 agent 代跑。auto-mode 的分類器會擋這類指令：被擋就停下回報使用者，**不改寫指令繞過**（拆 pipe、包進腳本、換工具都算繞）。schema 內容本身仍走上列「雲端資料庫只透過 migration 變更」（migration＋PR＋CI）；這條管的是「按下部署」那一步。
- **API 變更紀律（LS-41）**：契約的真身＝migrations＋錯誤碼＋RLS 行為，`docs/API.md` 是 iOS 端唯一可消費的契約文件——變更 RPC 簽章／表／錯誤碼／回傳形狀必須與 migration **同一 PR** 更新 API.md（gate：`api-contract-check`——本機 push-gate 文字解析 best-effort、CI `--catalog` 查活 DB 為權威；錯誤碼表 ↔ Swift `LSErrorCode` 的集合一致自 LS-54 起由 `error-codes-check` 對帳，但 migration 內 raise 的碼 ↔ 錯誤碼表、與 `RETURNS TABLE` 欄位仍無機械涵蓋，靠 merge-reviewer）。**UI 上線前可自由改**：某 RPC 尚無出貨的 iOS 呼叫端時，改簽章或語意不需相容層，doc＋tests 同 PR 動即可。**UI 首次上線後傾向 additive-only**：該 RPC 已有出貨 client 之後，變更以「新增」為原則（新參數帶 default、新語意開 `_v2`），不破壞既有簽章；確有必要的破壞性變更須在 PR body 以 `BREAKING:` 段落寫明受影響的 app 版本與遷移路徑，並在 API.md 該條目加相容性註記。「已上線」的判定依據＝API.md **§4 逐支 RPC 條目**標記 `shipped: <app 版本>`（**不得寫進 §9 機械對帳區塊**，那裡是逐行精確比對）；標記自 LS-25 TestFlight 起維護（補齊全部 RPC 的 `shipped:` 是 LS-25 的驗收條件之一），**fail-safe（逐條保守）**：LS-25 完成後，§4 條目**未標** `shipped:` 者一律視為已上線，確定未出貨者須顯式寫 `shipped: none`（漏標倒向「多做相容層」而非無聲放行；此形狀可機械化：檢查每個 §4 條目底下皆有 `shipped:` 行）；LS-25 之前全部 RPC 視為上線前。**此三條的機械涵蓋（LS-53 起）**：migration 被 `migration-breaking-check` 判 BREAKING 時，CI 驗 `BREAKING:` 行錨定段落＋`docs/API.md` 同 PR 變更（見上方 DB migration gate 條）；additive-only 本身、`shipped:` 標記、以及不經 migration 的破壞性變更（只改 API.md 語意、Swift 端）仍靠 merge-reviewer 與 orchestrator 人工把關；§7 對照表分列。
- **Checkpoint**：每張 ticket 完成，orchestrator 把 handoff 訊息留在 Linear ticket comment，讓狀態可還原、可交接。
- **Feature 收尾儀式**：「feature」的粒度由 orchestrator 判斷並記錄——單張 feature 票，或同批 promote 的票群共用一次。① dead-code-sweeper 巡檢（範圍＝該 feature 的累積 diff）；② orchestrator retro（lesson learning review）——固定檢視：各 gate 的攔截／漏接記錄、review 輪數與返工原因、agent 派工與 model 選擇是否恰當、需要補的工具或 MCP、規約與 gate script 的改善項。改善項一律開票（harness 票走 hotfix 流程），不留口頭。純 harness 票可免 dead-code 巡檢，retro 照做（輕量版）。
- **模擬器驗不了的項目**（推播、Sign in with Apple 完整流程）：QA 標註「需實機驗證」，不得記為 PASS。
- **CI 成本**：public repo 的 Actions 免費，但仍只在 PR 與保護分支 push 觸發，勿加無謂矩陣。

## 7. 前饋↔反饋對照表（§0 的落地清單）

hook 隨分支內容走（舊分支可能沒有新 hook）、且可被 `--no-verify` 繞過，所以**本機 hook 只是快速回饋，CI `rules` job 才是強制層**——凡標「hook＋CI」者兩層皆有。

| 前饋規則 | 機械反饋 gate | 狀態 |
|---|---|---|
| 保護分支禁直接 commit | pre-commit hook＋GitHub branch protection（enforce_admins） | ✅ |
| 測試／lint 過了才能合併 | pre-push hook＋CI required checks（`ci`＋`lint`） | ✅ |
| commit message 格式 | commit-msg hook＋CI 逐筆驗工作分支 PR 的 commit（merge/revert/fixup 豁免；`git log base..HEAD --not origin/main origin/development origin/test` 排除已存在於任一保護分支的歷史 commit，避免未來保護分支上出現的不合規歷史 commit，經由 back-merge／跨分支 merge 帶進 feature 分支後被永久誤擋——LS-10） | ✅ hook＋CI |
| branch 命名格式 | pre-commit hook＋CI（同一條 regex） | ✅ hook＋CI |
| 一張 ticket＝一條 branch：工作分支不得夾帶他票 commit（起點乾淨度） | push-gate 第 6 步＋CI `rules` job 共用 `scripts/gates/branch-ticket-check.sh`：自 merge-base（hotfix→origin/main、其餘→origin/development；CI 用 origin/$BASE）以來的非 merge commit，subject 第一個 `LS-<n>` 必須等於分支名票號，異票號／無票號即紅並列出 commit；已在任一保護分支上的 commit 排除（`--not origin/main origin/development origin/test`，同 LS-10——把保護分支 merge 回來解衝突不算夾帶）；找不到 base ref 直接紅。逃生口：任一 commit body **獨佔一行** `Bundles: LS-<m>[, LS-<k>]`（行錨定：散文提及／粗體／列點／同行尾隨文字不算，理由寫下一行）涵蓋全部異票號才放行並印出宣告，CI 再驗 PR body 有同樣獨佔一行的宣告（逃生口使用在 PR 可見）；自測 `branch-ticket-check.test.sh`（19 組）掛 CI `rules` job（LS-50）。盲區：只看 subject 第一個票號；`Bundles:` 宣告是否合理、夾帶的 commit 該不該一起交靠 merge-reviewer scope 維度；跨 worktree 編輯本身仍無機械 gate | ✅ hook＋CI |
| push 前分支須可與目標分支無衝突合併（PR 開了 CI 才跑得起來） | push-gate 第 7 步 `scripts/gates/merge-conflict-check.sh --target origin/<target>`（方向矩陣同上）：先 `git ls-remote` 對遠端 sha，本機 origin/<target> 落後即紅要求 fetch（拿過期 ref 比是假綠——PR #77 的分支落後 27 commit）；再 `git merge-tree --write-tree --name-only` 模擬合併，有衝突即紅並列出檔案、指示 `git merge origin/<target>`；找不到 ref／連不到遠端／git <2.38 皆 fail closed；自測 `merge-conflict-check.test.sh`（9 組，file:// 裸 repo 當遠端）掛 CI `rules` job（LS-50）。**CI 無法承載**：GitHub 對不可合併的 PR 不觸發 pull_request workflow——這正是本規則要堵的盲區本身，required checks 也等不到結果；`--no-verify` 繞過後只剩 orchestrator 讀 `gh pr view --json mergeStateStatus`。只驗 push 當下：push 後目標分支再前進造成的新衝突不在此 gate（PR 頁會顯示 CONFLICTING，但 CI 同樣不會跑） | ✅ hook（CI 無法承載；push 後的衝突⚠️人工） |
| 暫存檔名帶票號（`LS-<n>-<用途>.<ext>`／`mktemp -d`）、PR body 檔頭段含本票票號 | `scripts/gates/pr-body-check.sh [--branch] <body-file>`：agent 在 `gh pr create/edit` 前對 body 檔呼叫（票號取自當前分支）＋CI `rules` job 對 `github.event.pull_request.body` 以 head 分支票號再驗（限 feature\|fix\|hotfix head，同 LS-10／LS-50——promote／back-merge 沒有本票）。檔頭段＝從檔頭到第一個內容段落結束，開頭空白行與 `#` 標題行一併納入（模板「## Ticket／空行／LS-<n>」、「Ticket: LS-<n>」、「## Ticket／LS-<n>」三種實際形狀皆同一段）；`LS-<n>` 整字比對（`LS-630` 不滿足 `LS-63`）、CRLF 認得；空 body／模板未填／票號只在後段／檔頭段是他票皆紅，他票時點名票號提示疑似貼錯；非工作分支、缺檔 exit 2（fail closed）；自測 `pr-body-check.test.sh`（22 組）掛 CI `rules` job（LS-63）。**紅了之後修 body 不會讓 CI 自動重跑**（`pull_request` 觸發不含 `edited`，`gh run rerun` 也重放舊 body）——需 close/reopen PR 或再 push 一個 commit，失敗輸出會提示（同 §6 DESTRUCTIVE-APPROVED 的坑，LS-37 實測）。盲區：暫存檔名本身在 repo 外無機械 gate（靠規約，這裡攔的是它要防的結果）；檔頭段之後貼錯內容（第二段起是別票的 body）看不出來，靠 merge-reviewer scope 維度；逐行比對不做跨行狀態機——HTML 註解 `<!-- LS-<n> -->` 內的票號也算檔頭段內容，rendered body 看不見仍放行（與 LS-45 DESTRUCTIVE-APPROVED 同型，審查看 raw body；反向：以 HTML 註解開頭的 body 會把註解當內容段落，本 repo 模板不是這形狀） | ✅ CI（agent 本機同腳本；檔名⚠️規約） |
| PR 只能開向合法 base | CI `rules` job：base/head 方向矩陣（`revert-*` 合法） | ✅ |
| secrets 不進 repo | pre-commit＋CI 共用 `scan-secrets.sh`（private key／JWT／sb_secret／DB 連線字串／各家 token；pattern 自身免疫寫法，無路徑盲區）＋.gitignore；同一行含 `gate:allow-example` 標記可放行文件裡刻意寫的示範連線字串（逐行生效，救不到別行的真金鑰——LS-10） | ✅ hook＋CI |
| 設計畫布執行產物不入版控（`design-canvas*/` 的 `_shotcheck.html`／`shots/`／measured·verified·shots·selftest.json／打包 html） | 根 `.gitignore` 統一規則（三軌同一份，各軌自己的 .gitignore 只是子集）＋pre-commit／CI 共用 `tracked-ignored-check.sh`：index 內任一已追蹤檔命中 repo 內 .gitignore 即紅——ignore 規則管不到規則落地前就已追蹤、或 `git add -f` 硬加的檔（三軌的 `_shotcheck.html` 正是），須 `git rm --cached`；含子目錄否定行偵測——index 內任一 `design-canvas*/.gitignore` 有 `!` 開頭的行即紅（子目錄否定會讓根規則失效、且檔案從此不再 ignored、第一檢查看不見；各軌只准收窄，放寬只准改根 .gitignore——PR #79 R1 F1）；只認 repo 內 .gitignore、不吃本機 `core.excludesFile`／`.git/info/exclude`，避免「我機器紅、CI 綠」；自測 `tracked-ignored-check.test.sh` 每個 PR 都跑（LS-51）。盲區：**未追蹤**的審查取證目錄（如 `ls46r7-review/`）沒有命名慣例可 ignore，靠 merge-reviewer scope 維度（LS-61 起固定位置 `.claude/evidence/` 已 ignore、staged 進來的散落路徑由 `evidence-path-check` 擋，見下列） | ✅ hook＋CI（未追蹤取證目錄⚠️人工） |
| migration 必附 RLS 測試 | CI `rules` job：`supabase/migrations` 變更必須伴隨 `supabase/tests` 變更（僅驗「有動」，LS-10 起限定 feature|fix|hotfix head 執行——promote／back-merge 的內容已在來源 feature PR 驗過）＋ CI `db` job：`supabase db start` → `supabase db reset` → 實跑 `supabase/tests/run.sh`（RLS 隔離／owner 不變量／trigger／併發／RLS plan 效能），任一測試檔失敗即紅（LS-11）；EXPLAIN 證據（`supabase/tests/evidence/`）以 `upload-artifact` 留存，`retention-days: 90` 顯式寫死、不押環境預設（LS-54 D2／LS-56 F3） | ✅（CI 實際執行 run.sh） |
| 破壞性 migration 需本人核可 | CI `rules` job 以 `scripts/gates/migration-breaking-check.sh --base` 對 migrations 新增行做 **statement 級**分級（LS-53：單一 pass 剝 `--` 與 `/* */` 註解後以 `;` 切句，多行敘述、單一字面值的 `execute '…'` 動態 SQL 也認得；任何 DROP／TRUNCATE／DISABLE RLS／ALTER COLUMN TYPE ＝ DESTRUCTIVE，不留物件型別白名單讓人換寫法——舊版逐行關鍵字 grep 命中 DROP POLICY 卻放過同義的 ALTER POLICY … (false)／REVOKE，PR #60 review F7；LS-10 起限定 feature|fix|hotfix head 執行——promote PR body 不會自動携帶來源 PR 的 `DESTRUCTIVE-APPROVED` 標記，內容已在來源 feature PR 驗過）；`DESTRUCTIVE-APPROVED` 寫在 PR body，LS-45 起**整行錨定**（`scripts/gates/destructive-approval-check.sh`：`^[[:space:]]*DESTRUCTIVE-APPROVED[[:space:]]*$`，散文提及／〈〉括起／同行前綴或尾隨文字皆不放行——原純子字串比對曾被「等待使用者蓋 …」誤放行，PR #55 run 32626369903）；兩支腳本的負向樣本 `.test.sh` 掛 CI `rules` job 防退化；push-gate 對同一分級只印提醒（PR body 尚不存在）。已知限制：字串字面值內的關鍵字也算（刻意——動態 SQL 是最自然的繞法；COMMENT ON 說明文字請改寫）；`||` 串接拆開的多字關鍵字（`'alter ' || 'policy'`）認不得（漏報方向，靠 merge-reviewer）；欄名就叫 `type` 的 ALTER COLUMN（`alter column type set default …`）會誤報 D4；`--`／`/*` 出現在字串字面值內時其後內容會被當註解剝掉；PR body 逐行比對不做跨行狀態機，多行 HTML 註解 `<!-- … -->` 或 fenced code block 內的獨佔行仍會放行而 rendered body 看不見——審查看 raw body；**agent 技術上仍寫得進去**——核可真實性靠規約禁止＋orchestrator 把關 | ⚠️ 混合 |
| 呼叫端破壞性 migration（BREAKING）須 `BREAKING:` 段落＋`docs/API.md` 同 PR 更新 | 同上分級腳本的 BREAKING 級（ALTER POLICY 不分收緊放寬／CREATE POLICY … AS RESTRICTIVE／REVOKE 收回 public、anon 以外角色／CREATE [OR REPLACE] FUNCTION／DROP FUNCTION 既有名稱——`--base` 自 base 的 migrations 取既有清單（base 無 migrations 時清單為空＝全視為新函式）；stdin／檔案模式未給 `--known-functions` 才一律視為既有（fail closed）／RENAME／SET SCHEMA；只從 public、anon 收回與 ALTER DEFAULT PRIVILEGES 不算）：CI `rules` job 驗 PR body 的 `BREAKING:` 行錨定段落（`scripts/gates/breaking-section-check.sh`：行首＋同行摘要，粗體／列點／引用前綴不算）＋ `git diff --name-only base...HEAD -- docs/API.md` 非空；push-gate 對本分支相對 base（hotfix→origin/main、其餘→origin/development）做同一分級，BREAKING 且未動 API.md 即擋、PR body 部分印提醒；負向樣本 `migration-breaking-check.test.sh`（含 `--base` 模式）＋`breaking-section-check.test.sh` 掛 CI `rules` job（LS-53）。**未涵蓋面**：段落內容是否屬實靠 merge-reviewer；既有函式只改本體也判 BREAKING（over-approximate，寧可多寫一行說明） | ✅ hook＋CI（hook 只驗 API.md 半邊；段落標記僅 CI 驗得到） |
| 本機 Supabase 容器序列化：`supabase db reset`／`run.sh` 必經 `scripts/ops/supabase-lock.sh`（§6，LS-70） | `scripts/ops/supabase-lock.sh`：`mkdir` 原子 lock 目錄（`/tmp/supabase-lock-<project_id>`，跨 worktree／clone 共用），holder 檔記 pid／worktree／branch／cmd／started；等待逾時 15 分鐘 exit 124 fail loud；持有者 pid 不存在（`ps -p`）或建好 30s 仍無 holder 即自動回收（先 mv 到 tomb 再核對，不誤殺剛重取的鎖）；重入看 holder pid 是否本程序祖先（殘留 `SUPABASE_LOCK_HELD` 繞不過）。`supabase/tests/run.sh` 開頭未在 lock 內即經 lock 重跑自己（機械）；`supabase db reset` 只能靠 agent 定義（ios-dev／qa／merge-reviewer／dead-code-sweeper）照規約包——CLI 本身沒有 hook 可攔。巡檢 `patrol.sh` 印「Supabase lock」持有者（human／`--json` 欄位 `supabase_lock`；`--brief` 只在持有中印）。自測 `supabase-lock.test.sh`（合成 lock 目錄：互斥／exit code／逾時／死鎖回收與不誤殺剛建的鎖／重入／TERM 釋放／run.sh 自動經 lock）掛 CI `rules` job。盲區：裸跑 `supabase db reset` 無機械攔截；持有者被 SIGKILL 而子命令仍在跑會被當死鎖回收；pid 重用會等到逾時 | ⚠️ 規約承載（run.sh 機械、reset 靠 agent 定義；巡檢顯示持有者） |
| migration 版本號不得撞號（本分支內唯一、不與目標分支既有版本同號異名；§6，LS-70） | push-gate 4b：`scripts/gates/migration-version-check.sh --target origin/<target>`（hotfix→main、其餘→development）比 tree（`git ls-tree`，未 commit 不算）——檔名不符 `<數字>_<名稱>.sql`、本分支內同版本兩檔、本分支版本在 target 當前 tip 存在但檔名不同皆 exit 1；缺 ref exit 2 不靜默跳過；CI `rules` job Migration rules step 對 `origin/$BASE` 再驗（伺服器端兜底）；自測 `migration-version-check.test.sh`（含 LS-57／LS-66 形狀：切出後 base 先併進同號）掛 CI `rules` job。盲區：兩張 open PR 互相撞號、都還沒併時彼此看不見（只對 target tip 比）——先併的綠、後併的要等 CI 重跑才紅，而 CI 不會因 base 前進自動重跑（靠 branch protection 的「須跟上 base」或併前巡檢） | ✅ hook＋CI（自測掛 CI） |
| 安裝 extension／新 schema 函式必須顯式 grant | `supabase/tests/60_default_privileges.sql` 逐支列舉 schema `private` 的每一支函式＋對任意新 schema 建探針函式，證明 `harden_default_privileges.sql` 的全域 default privileges 收斂對任何新函式一律套用，不管它從哪個 schema／哪個 extension 冒出來；忘記替需要對外的 RPC 補 `grant execute` 只會讓該 RPC 直接呼叫失敗（fail loud、功能面立刻可見），不是安全外洩——真正的安全風險（忘記收斂）已由全域 revoke 機械保證（LS-10，來源 PR #17 review F2） | ✅（fail loud 設計） |
| 新畫面必有 .pen 設計稿 | CI 掃 diff 新增行的 View 宣告＋驗 body `Design:` 欄（換行式 conformance 掃不到，LS-10 起限定 feature|fix|hotfix head 執行——promote／back-merge 的內容已在來源 feature PR 驗過，PR body 標記也不會隨 promote 携帶）；設計稿真偽由 orchestrator 核 | ⚠️ 混合 |
| 設計稿須過 visual-reviewer 對抗審查（≥3 輪迭代）才送人核 | 掛在 Design 狀態出口：ticket 須有**三輪以上輪次標記的審查記錄**＋末輪 APPROVE，orchestrator 轉換狀態時逐輪清點 | ⚠️ 人工（狀態機承載） |
| ui-designer 必先載入 frontend-design skill | 無機械 gate——skill 載入發生在 subagent 內部；handoff checklist 有「skill 影響了哪些取捨」欄（載入失敗須明說），orchestrator 驗 handoff 兜底（LS-32） | ⚠️ 人工 |
| .pen 設計稿必須真實落地（Pencil 無 save 工具，編輯只在 app 記憶體） | `scripts/gates/design-landing-check.sh`：0 bytes／壞 JSON／空結構即紅，`--expect-nodes` 驗與畫布一致；**commit-gate 對 staged .pen 自動觸發＋CI rules job 對 diff 內 .pen 兜底**（皆無 N——「落地比記憶體舊」的深度驗證靠收工程序步驟 2/4，PR review 驗 handoff 輸出）（LS-26） | ✅ hook＋CI（深度驗證⚠️程序） |
| MCP 必要 env 變數必須存在（FIGMA_PERSONAL_ACCESS_TOKEN、SUPABASE_ACCESS_TOKEN） | `.mcp.json` 的 `${VAR:?}` 展開——缺失／空值時 server 啟動即炸，`/mcp` 可見（LS-42） | ✅（fail loud 設計） |
| project.yml ↔ .xcodeproj 同步（XcodeGen 雙來源） | CI：重跑 `xcodegen generate` 後 `git add -A -- LittleSprout.xcodeproj && git diff --cached --exit-code`（涵蓋 xcodegen 產生的全新 untracked 檔，LS-10 補上原本只比對已追蹤檔案的盲區；生成物 byte-identical，不 flaky；雙向漂移皆攔） | ✅ |
| 雲端 DB 不得繞過 migration 直改 | supabase MCP 以 `--read-only` 旗標鎖唯讀（機械，LS-43 起 PAT/stdio）；dashboard 路徑靠規約 | ⚠️ 混合 |
| API 變更必同步 `docs/API.md` | `scripts/gates/api-contract-check.sh`：CI `db` job（`supabase db reset` 之後、`run.sh` 之前）以套用完 migrations 的活資料庫 `pg_catalog` 為權威來源比對 `docs/API.md` §9 的 `API-CONTRACT:RPC`／`API-CONTRACT:TABLES` 區塊，RPC 簽章或表清單任一邊多、任一邊少（含幽靈項）都紅；本機 push-gate 另跑純文字解析 migrations 的 best-effort 版本（不需活資料庫，已知限制見 `scripts/gates/api_contract_check.py` 檔頭）；兩者的負向樣本見 `scripts/gates/api-contract-check.test.sh`（掛在 CI `rules` job）。**未涵蓋面**：只對帳 RPC 簽章與表清單本身，不含錯誤碼全表是否窮盡、`RETURNS TABLE` 的欄位形狀、逐欄 grant／RLS 語意是否寫對——這些仍靠人工覆核與 PR review 兜底（LS-41，PR #58 review） | ⚠️ 混合 |
| 錯誤碼全表（API.md §5）↔ Swift `LSErrorCode` ↔ migrations `errcode` 三方逐碼一致 | `scripts/gates/error-codes-check.sh`：抽 §5 表格列**首欄**（`awk -F'|'` 第 2 欄、錨定開頭 `` `LSnnn` ``，碼後可接括號註記）的集合、`AppError.swift` 行首錨定的 `case <名稱> = "LSnnn"` rawValue 集合、`supabase/migrations/*.sql` 剝 `--` 註解後的 `errcode = 'LSnnn'` 集合，三方兩兩雙向比對，任一邊多即紅（API.md 有、Swift 無會在 `AppError.map` 落 `.server`——PR #60 併入後 LS020-022 曾是這個狀態而 CI 全綠；Swift 有、API.md 無＝幽靈碼；migrations 有、API.md 無＝後端會丟但文件沒寫；API.md 有、migrations 無＝後端從不丟）；任一側抽到空集合也紅；§5 表內出現沒有首欄列的 `LSnnn`（首欄少反引號、一格兩碼、說明欄引用未定義碼）fail loud，說明欄引用**已有列**的碼允許（LS-55 的 LS016 列形狀）；註解掉的 `// case x = "LSnnn"` 不算存在、**整行**註解裡的 `"LSnnn"` 不算幽靈碼（LS-56 F1／F2，PR #69 review）。掛 push-gate＋CI `rules` job，正負對照樣本 `error-codes-check.test.sh`（19 組，LS-54／LS-56）。**未涵蓋面**：四層歸類是否正確靠 `AppErrorTests` 的列舉測試；case 行的**行尾**註解（`case x = "LS001" // 參考 "LS099"`）裡的碼仍會被抓成幽靈碼（假紅）；Swift 多行 `/* */` 塊註解內縮排的 case 行、migrations 的 `/* */` 塊註解仍會被算進去；migrations 腳對 append-only 歷史取**聯集**——後續 migration 以 `create or replace` 拿掉某個 raise 後，舊 migration 仍含該碼、三方仍綠（假綠方向）；反之要把該碼從 §5／Swift 拿掉時會紅，屆時再補退役清單機制（fail loud，不靜默） | ✅ hook＋CI |
| 單元測試序列執行（`MockURLProtocol` 全域 handler 不可平行） | `project.yml` scheme 明寫 `parallelizable: false`＋CI／push-gate 的 `xcodebuild test` 帶 `-parallel-testing-enabled NO`（LS-54 N8）；XcodeGen 漂移 gate 保證 scheme 設定不被 GUI 改掉 | ✅ |
| harness 檔 back-merge 到 test／development | 無機械 gate——orchestrator 在 LS ticket 驗收條件中列入並人工確認；本地合併版 back-merge 分支須命名 `hotfix/LS-<n>-backmerge-<target>`、只適用 `<target>=development`（`test` 端誤判改 close／reopen 或重推 head=`main`，§2）；命名成 `back-merge/*` 時 CI 由方向矩陣擋、本機由 `commit-gate.sh` 命名 regex 擋（LS-56 補記） | ⚠️ 人工（命名部分機械） |
| scope 不越界、worktree 隔離 | 「分支不得夾帶他票 commit」自 LS-50 起機械（上列 `branch-ticket-check`）；跨 worktree 編輯與 scope 本身無法全機械化——merge-reviewer 的 scope 維度人工兜底 | ⚠️ 人工（夾帶他票 commit 部分機械） |
| QA 不得把跳過寫成 PASS | 無法機械化——orchestrator 驗 handoff 證據（截圖／輸出）兜底 | ⚠️ 人工 |
| feature 收尾必經 dead-code 巡檢＋retro | 掛在狀態機：兩者的 ticket comment 是進 Done 的前置條件，orchestrator 執行狀態轉換時把關 | ⚠️ 人工（狀態機承載） |
| API 上線後 additive-only／`BREAKING:` 段落／`shipped:` 標記（§6，LS-41） | `BREAKING:` 段落：經 migration 觸發者自 LS-53 起機械驗（上列）；不經 migration 的破壞性變更（只改 API.md 語意、Swift 端）與 additive-only 本身無機械 gate——merge-reviewer 與 orchestrator 人工把關；`shipped:` 逐條存在性可機械化（待補） | ⚠️ 混合 |
| 審查取證（截圖／匯出／掃描輸出）不入版控，固定落在 `.claude/evidence/<票號>/<輪次>/`（worktree 相對；ui-designer `r<n>/`、visual-reviewer `r<n>-review/`、qa `qa<n>/`） | 根 `.gitignore` ignore `.claude/evidence/`（`git add -f` 硬加由 `tracked-ignored-check` 擋）＋pre-commit `scripts/gates/evidence-path-check.sh`（commit-gate 第 4 步）：staged 路徑（index，`git diff --cached --name-only -z --diff-filter=d`：NUL 分隔讀取，含 `"`／`\`／換行的檔名不會因 `--name-only` 加引號而漏掉——PR #94 R1 I1；新增／修改／rename 目的地，不含刪除——清掉歷史誤入版控的取證要放行）任一目錄層以 `review` 開頭或含 `-review`（`review*`／`*-review*`；不是 `*review*`——那會誤擋 Xcode 預設的 `Preview Content/`，orchestrator 裁決收窄）、或以 `ls<數字>` 開頭，或 `*.png` 不在 `design/`／`LittleSprout/Assets.xcassets/`／`LittleSprout/Preview Content/`（Xcode 模板的 `Preview Assets.xcassets`）／`docs/img/` 白名單即紅並列出檔案與解法（白名單原為整個 `docs/`——repo 最常寫的目錄、放行不 fail loud，R1 M1 收窄成 `docs/img/`；`Assets*` 會吃掉 `AssetsFake/`，R1 I4 改精確目錄名）；所有比對 `shopt -s nocasematch` 大小寫不敏感（`LS46r9/`、`Review-shots/`、`.PNG` 皆擋，白名單亦然——macOS 檔案系統本就不分大小寫，R1 I3）；目錄名規則不看白名單（`docs/img/` 底下也不准有 `*-review/`），檔名層不算（`visual-reviewer.md`、`ls46-notes.md` 放行）；帶路徑參數時目錄不存在或 `git diff` 失敗一律 exit 2 fail closed（R1 I2）；自測 `evidence-path-check.test.sh`（24 組）掛 CI `rules` job（LS-61）。盲區：只看 index——**未追蹤**的取證目錄不管（歷史散落的 `ls46r7-review/`、`ls46r8/`、`ls46r8-review/` 留在 LS-46 worktree 不搬），`git status` 乾淨靠三支 agent 的存放指示；目錄規則只認歷史形狀（`ls<n>`、`review*`／`*-review*`）——新慣例的輪次目錄名 `r<n>/`／`qa<n>/` 或其他名字（`screens/`）誤落在 worktree 根時只剩 png 規則擋得住，非 png 的掃描輸出會漏（R1 I5，靠 merge-reviewer scope）；白名單外的新資產路徑（如未來的 `LittleSprout/Resources/`、第二個 `.xcassets`）要改腳本白名單（fail loud，不會靜默放行）；CI 只跑自測、不對 PR diff 重跑，`--no-verify` 繞過後無伺服器端兜底（`--base` 模式另票，R1 I10） | ✅ hook（CI 自測；未追蹤取證⚠️人工） |
| 新 session 開頭必巡檢（open PR／分支領先 remote／dirty 停滯／尚未開工／主 checkout 落後 `origin/main`，§4-b） | 專案層 `.claude/settings.json` SessionStart hook → `scripts/ops/session-start.sh`：跑 `patrol.sh --brief`，摘要＋指示注入 `hookSpecificOutput.additionalContext`；fail-soft（patrol 炸掉／repo 找不到仍輸出合法 JSON、exit 0，錯誤寫在 context 裡，不擋 session）；`scripts/ops/patrol.test.sh` 用合成 repo（file:// 裸 origin＋七個 worktree）驗各停滯型態判定的正負樣本、`--json` 合法、gh 不可用不炸、hook 輸出合法 JSON 且 settings.json 有掛上，掛 CI `rules` job（LS-71）。盲區：hook 只在 startup／resume／clear／compact 觸發，session 中途靠 cron；settings 改了要 `/hooks` 或重啟才載入；fetch 逾時（看門狗 10s）退回本機 ref——`origin/*` 可能過期，摘要有標警告但判定仍以過期 ref 為準；Linear 那一半（Ready 無人接／QA 但 test 未含）靠 orchestrator 用 MCP 對照 | ✅ hook（CI 自測） |
| 每個 session 要有巡檢 cron（`*/26 * * * *`，§4-b） | 同上 hook 每次注入「尚未建就立即 CronCreate」——cron 建了沒有無法從 hook 端驗（CronCreate 是 session 內工具、7 天到期），靠 orchestrator 照做 | ⚠️ 提示非強制 |
| 每張票必標 `lane:*`、依賴只用 blockedBy、每 lane WIP 上限、Backlog→Ready 補位（§5-b，LS-75） | 無 repo 側 gate——規則全在 Linear 側：`patrol.sh` 無 Linear token，CI／pre-push 不驗。巡檢 cron 每輪由 orchestrator 用 MCP（`list_issue_labels`＋`list_issues`＋`get_issue`）算每 lane 在飛數與候補、印 lane 狀態表、`save_issue` 改 Ready 並派工；票進 In Review／Done 時再算一次。盲區：**忘了標 lane 的票不會被補位**——巡檢輸出列「無 lane 標籤的 open 票」提醒，補標仍靠人；寫在文字裡的依賴（沒建 blockedBy）看不見，會被當「依賴已解」提前補位；上限是人維護的常數（backend 2→3、ui 隨設計核可數），規約改了 cron prompt 沒跟上就失準；cron 本身有沒有建也無法從 hook 端驗（上列） | ⚠️ 巡檢承載 |
| harness PR 併入 main 後先 pull 主 checkout 再派工（§2） | 同上 hook：主 checkout 落後 `origin/main` 即在 context 提示先 `git pull --ff-only origin main`；session 中途併入的靠 cron 的 patrol 輸出＋orchestrator 自律 | ⚠️ 混合（session 開頭機械、中途人工） |
| 正式站 `supabase db push` 每次需使用者當次授權（§6） | auto-mode 分類器擋雲端寫入指令（Claude Code 層、非 repo 內 gate；被擋就停下回報）；「不改寫指令繞過」靠規約 | ⚠️ 混合 |
| handoff「未完成／剩餘」欄必列 reviewer 全部 informational 的處置（CLAUDE.md；派工 prompt 五條之五，§3） | 無機械 gate——orchestrator 驗 handoff 時逐條對照 merge-reviewer 輸出，缺一退回 | ⚠️ 人工 |
