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
- 位置 `.claude/worktrees/LS-<n>`（已 gitignore）。一張 ticket 一個 worktree 一條 branch。
- 多張 ticket 平行時各自 worktree，**禁止跨 worktree 編輯檔案**；合併完成後移除 worktree。
- 首次 clone 後執行 `git config core.hooksPath .githooks` 啟用 gate hooks（worktree 共用同一份 config，不必重設）。

**Harness 變更例外**：協作規約與 harness 檔（`CLAUDE.md`、`docs/COLLABORATION.md`、`.claude/agents/`、`scripts/gates/`、`.githooks/`、`.github/`、`.mcp.json`）不走 feature→QA 全流程，比照 hotfix：從 `main` 切 `hotfix/LS-<n>-*` branch、PR 回 `main`（CI 照跑），合併後 back-merge 到 `test` 與 `development`——這些檔案必須在所有分支即時一致。

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

**PR message**：依 `.github/pull_request_template.md`（ticket、變更摘要、驗證方式、風險、UI 截圖）。含新畫面的 PR 必須在 body 寫 `Design: <.pen frame 名>`（CI 會驗）。

**Handoff 訊息**（subagent 完成或交接時，一律用此格式）：
```
Ticket：LS-<n>
已完成：（逐項）
已驗證：（怎麼驗的：測試名稱／指令輸出／截圖）
未完成／剩餘：
風險與已知問題：
產出位置：branch／PR／.pen frame 名稱
```

## 4. Gates（每關都要有證據，fail loud）

| Gate | 時點 | 內容 | 執行者 |
|---|---|---|---|
| **Design gate** | ticket 含 UI 時，開發前 | ① ui-designer 完成 .pen 畫面 → ② **visual-reviewer 對抗審查×ui-designer 修改，至少完整迭代 3 輪**（前 2 輪一律 ITERATE 抬標準；第 3 輪起才可 APPROVE，未達標續迭）→ ③ design-landing-check 綠燈（`--expect-nodes` 對畫布，輸出貼 ticket）→ ④ orchestrator（重大畫面：使用者本人）核可 | ui-designer + visual-reviewer |
| **Commit gate** | pre-commit hook | 禁止直接 commit 保護分支；branch 命名格式；secrets 掃描；staged Swift 檔過 SwiftLint | 自動（`scripts/gates/commit-gate.sh`） |
| **Commit-msg gate** | commit-msg hook | commit message 第一行格式（type + LS-n） | 自動（`scripts/gates/commit-msg-gate.sh`） |
| **Push gate** | pre-push hook | unit tests（xcodebuild test，動態選模擬器）＋全 repo SwiftLint | 自動（`scripts/gates/push-gate.sh`） |
| **Merge gate** | 每個 PR | CI 綠燈（rules＋lint＋build/test）＋ merge-reviewer 四維度審查：**race condition、運算效能、平行優化、scope** | CI + merge-reviewer |
| **QA gate** | 併入 test 之後 | qa subagent 逐條驗證 ticket 驗收條件＋回歸冒煙（登入／時間軸／上傳／留言）＋RLS 冒煙＋**視覺驗收**（UI 票：模擬器渲染截圖比對 .pen 設計稿） | qa |
| **收尾 gate** | QA 過後、Done 之前 | ① dead-code-sweeper 巡檢 feature 引入的死碼（findings 開 fix 票或併入下票）② orchestrator 的 **lesson learning review**：gate 攔截／漏接、返工原因、harness 與設定改善項（開票）、工具缺口、model 政策調整。兩者記於 ticket comment，缺一不得進 Done | dead-code-sweeper + orchestrator |

Merge gate 有任一 blocker/major finding → REQUEST_CHANGES，不得合併。gate 工具缺失（如有 Swift 檔但 SwiftLint 未裝）→ 直接 fail，不得靜默跳過。

## 5. Linear（協作狀態機）

- Team key：`LS`（workspace `little-sprout-app`）。**Linear 是唯一的任務狀態來源**；每個狀態的離開就是一個 gate，由 orchestrator 執行轉換並在 ticket 留 comment 記錄 gate 證據。
- MCP 設定在專案 `.mcp.json`；linear 走 OAuth（session 重啟後用 `/mcp` 完成），其餘皆 stdio＋.env 注入。
- **MCP 必要環境變數**：repo 根 `.env`（gitignored）須含 `FIGMA_PERSONAL_ACCESS_TOKEN`（figma MCP，LS-42）與 `SUPABASE_ACCESS_TOKEN`（supabase MCP，LS-43）——啟動時注入、缺失即啟動失敗 fail loud。`.env` 的值一律只認 key 名、不讀取。
- **開票結構**：Project＝epic；Milestone＝feature 群（同一 epic 底下相關的一批 issue）；Issue＝story，必須帶可驗證的驗收條件（同 §1 的 Spec 狀態離開條件）；Sub-issue＝task，**只有在單一 story 需要多個 agent 接力完成**（例如設計→實作→審查分屬不同派工、無法一個 agent 一次做完）時才拆，拆分依據與各 task 的範圍寫在該 story 的 ticket scope 裡，不預先拆。

| 狀態 | 離開條件（gate） |
|---|---|
| Backlog | 被排入優先，值得寫規格 |
| Spec | ticket 具備**可驗證的驗收條件**與明確 scope |
| Design | design gate 過（純後端票可跳過此狀態） |
| Ready | worktree＋branch 已建、指派給 agent |
| In Progress | push gate 過、PR 開出 |
| In Review | merge gate 過、併入 development |
| QA | QA gate 過（在 test branch）**且收尾 gate 完成**（dead-code 巡檢＋retro 記錄在案） |
| Done | 已併入 main（隨 release） |
| Canceled | 記錄取消原因 |

## 6. 補充規定

- **Hotfix**：`hotfix/*` 從 `main` 切出、PR 回 `main`（CI＋review 照跑、QA 走快速通道），合併後**必須 back-merge 到 `test` 與 `development`**。
- **Release**：test→main 合併後打 tag `vX.Y.Z`（semver），TestFlight 上傳由 orchestrator 執行並在對應 ticket 記錄 build 號。
- **DB migration gate**：`supabase/migrations` 的變更必附 RLS 測試（CI 強制）；**破壞性 migration（DROP、縮欄、改型）需使用者本人核可**——核可方式：使用者本人在 PR body 加上 `DESTRUCTIVE-APPROVED`，**標記須獨佔一行**（允許前後空白；同行不得有其他字，粗體／反引號包起也不算。反過來，gate 只看 raw body 的行：藏在多行 HTML 註解 `<!-- … -->` 或 fenced code block 內的獨佔行仍會放行，rendered body 看不見——標記不保證肉眼可見，審查請看 raw body——LS-45），agent 不得代寫。加標記後 CI 不會自動重跑（`pull_request` 觸發不含 `edited`），需 close/reopen 或再 push（LS-37 實測）。
- **Secrets**：金鑰一律不進 repo。Client 端用 gitignored 的 `Secrets.xcconfig`；CI 用 GitHub Secrets；`service_role` key 永不出現在 client 或 repo。
- **回滾**：正式站問題以 revert PR 處理（GitHub Revert 按鈕產生的 `revert-*` head 在 CI 方向矩陣中對三條保護分支皆合法）；保護分支禁止 force-push。
- **雲端資料庫只透過 migration 變更**：schema／policy 變更一律走 `supabase/migrations`＋PR，**禁止用 Supabase MCP 或 dashboard 直接改正式專案**。機械面：`.mcp.json` 的 supabase MCP 以 `--read-only --project-ref` 鎖唯讀與專案（LS-43 起走 PAT/stdio，PAT 存 .env），需要寫入時由使用者本人臨時解鎖。**注意：PAT 是帳號層級、具完整寫入權的 Management API 憑證，唯讀鎖只在本機 client 端生效，且 Management API 路徑繞過 RLS——`.env` 的保管等級＝正式站的保管等級**。`project_ref` 視為公開資訊（本來就會出現在 app 的 API URL）。
- **API 變更紀律（LS-41）**：契約的真身＝migrations＋錯誤碼＋RLS 行為，`docs/API.md` 是 iOS 端唯一可消費的契約文件——變更 RPC 簽章／表／錯誤碼／回傳形狀必須與 migration **同一 PR** 更新 API.md（gate：`api-contract-check`——本機 push-gate 文字解析 best-effort、CI `--catalog` 查活 DB 為權威；錯誤碼表與 `RETURNS TABLE` 欄位尚無機械涵蓋，靠 merge-reviewer）。**UI 上線前可自由改**：某 RPC 尚無出貨的 iOS 呼叫端時，改簽章或語意不需相容層，doc＋tests 同 PR 動即可。**UI 首次上線後傾向 additive-only**：該 RPC 已有出貨 client 之後，變更以「新增」為原則（新參數帶 default、新語意開 `_v2`），不破壞既有簽章；確有必要的破壞性變更須在 PR body 以 `BREAKING:` 段落寫明受影響的 app 版本與遷移路徑，並在 API.md 該條目加相容性註記。「已上線」的判定依據＝API.md **§4 逐支 RPC 條目**標記 `shipped: <app 版本>`（**不得寫進 §9 機械對帳區塊**，那裡是逐行精確比對）；標記自 LS-25 TestFlight 起維護（補齊全部 RPC 的 `shipped:` 是 LS-25 的驗收條件之一），**fail-safe（逐條保守）**：LS-25 完成後，§4 條目**未標** `shipped:` 者一律視為已上線，確定未出貨者須顯式寫 `shipped: none`（漏標倒向「多做相容層」而非無聲放行；此形狀可機械化：檢查每個 §4 條目底下皆有 `shipped:` 行）；LS-25 之前全部 RPC 視為上線前。**此三條（additive-only／`BREAKING:` 段落／`shipped:` 標記）目前無機械 gate**——`BREAKING:` 不同於 `DESTRUCTIVE-APPROVED`，不受任何腳本檢查，靠 merge-reviewer 與 orchestrator 人工把關；已於 §7 對照表登記為 ⚠️ 人工。
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
| PR 只能開向合法 base | CI `rules` job：base/head 方向矩陣（`revert-*` 合法） | ✅ |
| secrets 不進 repo | pre-commit＋CI 共用 `scan-secrets.sh`（private key／JWT／sb_secret／DB 連線字串／各家 token；pattern 自身免疫寫法，無路徑盲區）＋.gitignore；同一行含 `gate:allow-example` 標記可放行文件裡刻意寫的示範連線字串（逐行生效，救不到別行的真金鑰——LS-10） | ✅ hook＋CI |
| migration 必附 RLS 測試 | CI `rules` job：`supabase/migrations` 變更必須伴隨 `supabase/tests` 變更（僅驗「有動」，LS-10 起限定 feature|fix|hotfix head 執行——promote／back-merge 的內容已在來源 feature PR 驗過）＋ CI `db` job：`supabase db start` → `supabase db reset` → 實跑 `supabase/tests/run.sh`（RLS 隔離／owner 不變量／trigger／併發／RLS plan 效能），任一測試檔失敗即紅（LS-11） | ✅（CI 實際執行 run.sh） |
| 破壞性 migration 需本人核可 | CI 偵測 DROP／TRUNCATE／DISABLE RLS 等關鍵字（機械，LS-10 起限定 feature|fix|hotfix head 執行——promote PR body 不會自動携帶來源 PR 的 `DESTRUCTIVE-APPROVED` 標記，內容已在來源 feature PR 驗過；LS-34 起比對前剝除 `--` 註解，註解提及關鍵字不誤判；已知限制：`/* */` 塊註解仍會誤觸，且 `--` 出現在字串字面值／引號識別子內時其後同行的關鍵字會漏掉——實務上 migration 一行一句，且本 gate 本就 ⚠️混合）；`DESTRUCTIVE-APPROVED` 寫在 PR body，LS-45 起**整行錨定**（`scripts/gates/destructive-approval-check.sh`：`^[[:space:]]*DESTRUCTIVE-APPROVED[[:space:]]*$`，散文提及／〈〉括起／同行前綴或尾隨文字皆不放行；CI 每個 PR 跑 `.test.sh` 負向樣本防退化——原純子字串比對曾被「等待使用者蓋 …」誤放行，PR #55 run 32626369903；已知限制：逐行比對不做跨行狀態機，多行 HTML 註解 `<!-- … -->` 或 fenced code block 內的獨佔行仍會放行而 rendered body 看不見，與上述 `/* */` 塊註解限制同類——審查看 raw body）；已知限制：**agent 技術上仍寫得進去**——核可真實性靠規約禁止＋orchestrator 把關 | ⚠️ 混合 |
| 安裝 extension／新 schema 函式必須顯式 grant | `supabase/tests/60_default_privileges.sql` 逐支列舉 schema `private` 的每一支函式＋對任意新 schema 建探針函式，證明 `harden_default_privileges.sql` 的全域 default privileges 收斂對任何新函式一律套用，不管它從哪個 schema／哪個 extension 冒出來；忘記替需要對外的 RPC 補 `grant execute` 只會讓該 RPC 直接呼叫失敗（fail loud、功能面立刻可見），不是安全外洩——真正的安全風險（忘記收斂）已由全域 revoke 機械保證（LS-10，來源 PR #17 review F2） | ✅（fail loud 設計） |
| 新畫面必有 .pen 設計稿 | CI 掃 diff 新增行的 View 宣告＋驗 body `Design:` 欄（換行式 conformance 掃不到，LS-10 起限定 feature|fix|hotfix head 執行——promote／back-merge 的內容已在來源 feature PR 驗過，PR body 標記也不會隨 promote 携帶）；設計稿真偽由 orchestrator 核 | ⚠️ 混合 |
| 設計稿須過 visual-reviewer 對抗審查（≥3 輪迭代）才送人核 | 掛在 Design 狀態出口：ticket 須有**三輪以上輪次標記的審查記錄**＋末輪 APPROVE，orchestrator 轉換狀態時逐輪清點 | ⚠️ 人工（狀態機承載） |
| ui-designer 必先載入 frontend-design skill | 無機械 gate——skill 載入發生在 subagent 內部；handoff checklist 有「skill 影響了哪些取捨」欄（載入失敗須明說），orchestrator 驗 handoff 兜底（LS-32） | ⚠️ 人工 |
| .pen 設計稿必須真實落地（Pencil 無 save 工具，編輯只在 app 記憶體） | `scripts/gates/design-landing-check.sh`：0 bytes／壞 JSON／空結構即紅，`--expect-nodes` 驗與畫布一致；**commit-gate 對 staged .pen 自動觸發＋CI rules job 對 diff 內 .pen 兜底**（皆無 N——「落地比記憶體舊」的深度驗證靠收工程序步驟 2/4，PR review 驗 handoff 輸出）（LS-26） | ✅ hook＋CI（深度驗證⚠️程序） |
| MCP 必要 env 變數必須存在（FIGMA_PERSONAL_ACCESS_TOKEN、SUPABASE_ACCESS_TOKEN） | `.mcp.json` 的 `${VAR:?}` 展開——缺失／空值時 server 啟動即炸，`/mcp` 可見（LS-42） | ✅（fail loud 設計） |
| project.yml ↔ .xcodeproj 同步（XcodeGen 雙來源） | CI：重跑 `xcodegen generate` 後 `git add -A -- LittleSprout.xcodeproj && git diff --cached --exit-code`（涵蓋 xcodegen 產生的全新 untracked 檔，LS-10 補上原本只比對已追蹤檔案的盲區；生成物 byte-identical，不 flaky；雙向漂移皆攔） | ✅ |
| 雲端 DB 不得繞過 migration 直改 | supabase MCP 以 `--read-only` 旗標鎖唯讀（機械，LS-43 起 PAT/stdio）；dashboard 路徑靠規約 | ⚠️ 混合 |
| API 變更必同步 `docs/API.md` | `scripts/gates/api-contract-check.sh`：CI `db` job（`supabase db reset` 之後、`run.sh` 之前）以套用完 migrations 的活資料庫 `pg_catalog` 為權威來源比對 `docs/API.md` §9 的 `API-CONTRACT:RPC`／`API-CONTRACT:TABLES` 區塊，RPC 簽章或表清單任一邊多、任一邊少（含幽靈項）都紅；本機 push-gate 另跑純文字解析 migrations 的 best-effort 版本（不需活資料庫，已知限制見 `scripts/gates/api_contract_check.py` 檔頭）；兩者的負向樣本見 `scripts/gates/api-contract-check.test.sh`（掛在 CI `rules` job）。**未涵蓋面**：只對帳 RPC 簽章與表清單本身，不含錯誤碼全表是否窮盡、`RETURNS TABLE` 的欄位形狀、逐欄 grant／RLS 語意是否寫對——這些仍靠人工覆核與 PR review 兜底（LS-41，PR #58 review） | ⚠️ 混合 |
| harness 檔 back-merge 到 test／development | 無機械 gate——orchestrator 在 LS ticket 驗收條件中列入並人工確認 | ⚠️ 人工 |
| scope 不越界、worktree 隔離 | 無法全機械化——merge-reviewer 的 scope 維度人工兜底 | ⚠️ 人工 |
| QA 不得把跳過寫成 PASS | 無法機械化——orchestrator 驗 handoff 證據（截圖／輸出）兜底 | ⚠️ 人工 |
| feature 收尾必經 dead-code 巡檢＋retro | 掛在狀態機：兩者的 ticket comment 是進 Done 的前置條件，orchestrator 執行狀態轉換時把關 | ⚠️ 人工（狀態機承載） |
| API 上線後 additive-only／`BREAKING:` 段落／`shipped:` 標記（§6，LS-41） | 無機械 gate——merge-reviewer 與 orchestrator 人工把關；`shipped:` 逐條存在性可機械化（待補） | ⚠️ 人工 |
