# CLAUDE.md — Little Sprout 協作規約

產品與技術規劃見 `docs/PLAN.md`。本檔定義開發協作的角色、分支、gate 與訊息規約，**所有 agent（含 subagent）都必須遵守**。

## 1. 角色與分工

- **Orchestrator（主 session）**：拆解任務、在 Linear 開票與推動狀態、指派 subagent、把關每一個 gate。原則上不直接寫功能程式碼（harness 與小型修補除外）。
- **ui-designer subagent**：**所有 UI 畫面設計必須由這個專門的 subagent 透過 Pencil MCP（.pen 設計檔）完成**。禁止在沒有 .pen 設計稿的情況下直接手寫新畫面的 SwiftUI 版面。設計檔：`design/littlesprout.pen`。
- **ios-dev subagent**：功能實作。一張 ticket＝一個 worktree＝一條 branch。
- **merge-reviewer subagent**：merge gate 的 code review（四維度，見 §4）。
- **qa subagent**：在 `test` branch 上依驗收條件驗收。

## 2. 分支模型

| Branch | 用途 | 規則 |
|---|---|---|
| `main` | 正式站（App Store / TestFlight 發佈來源） | 禁止直接 commit；只接受來自 `test` 的 PR 或 `hotfix/*` |
| `test` | 測試站；qa subagent 在此驗收 | 禁止直接 commit；只接受來自 `development` 的 PR |
| `development` | 開發整合 | 禁止直接 commit；只接受來自工作分支的 PR |
| `feature/*` `fix/*` `hotfix/*` | 工作分支 | 一律在 worktree 中作業；`hotfix/*` 從 `main` 切出 |

流向：`feature/* → development → test → main`。development→test 由 orchestrator 批次 promote；test→main 即 release（打 tag `vX.Y.Z`）。

**Worktree 規約（平行分工）**：
- 位置 `.claude/worktrees/LS-<n>`（已 gitignore）。一張 ticket 一個 worktree 一條 branch。
- 多張 ticket 平行時各自 worktree，**禁止跨 worktree 編輯檔案**；合併完成後移除 worktree。
- 首次 clone 後執行 `git config core.hooksPath .githooks` 啟用 gate hooks（worktree 共用同一份 config，不必重設）。

## 3. 命名與訊息規約

**Branch**：`feature/LS-123-short-slug`、`fix/LS-124-short-slug`、`hotfix/LS-125-short-slug`（slug 英文小寫連字號）。

**Commit message**（Conventional Commits + Linear ID）：
```
<type>(<scope>): LS-<n> <一句話摘要>

<why：為什麼這樣改，而不只是改了什麼>

Fixes LS-<n>        ← 此 commit 完結該票時才加（Linear 自動連動）
```
type ∈ `feat|fix|chore|docs|refactor|test|perf|design`；scope 可省略。禁止 `--no-verify` 繞過 hooks。

**PR message**：依 `.github/pull_request_template.md`（ticket、變更摘要、驗證方式、風險、UI 截圖）。

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
| **Design gate** | ticket 含 UI 時，開發前 | ui-designer 完成 .pen 畫面並經 orchestrator（重大畫面：使用者本人）核可 | ui-designer |
| **Commit gate** | pre-commit hook | 禁止直接 commit 保護分支；staged Swift 檔過 SwiftLint | 自動（`scripts/gates/commit-gate.sh`） |
| **Push gate** | pre-push hook | unit tests（xcodebuild test）＋全 repo SwiftLint／格式 | 自動（`scripts/gates/push-gate.sh`） |
| **Merge gate** | 每個 PR | CI 綠燈（build＋test＋lint）＋ merge-reviewer 四維度審查：**race condition、運算效能、平行優化、scope** | CI + merge-reviewer |
| **QA gate** | 併入 test 之後 | qa subagent 逐條驗證 ticket 驗收條件＋回歸冒煙（登入／時間軸／上傳／留言）＋RLS 冒煙 | qa |

Merge gate 有任一 blocker/major finding → REQUEST_CHANGES，不得合併。gate 工具缺失（如有 Swift 檔但 SwiftLint 未裝）→ 直接 fail，不得靜默跳過。

## 5. Linear（協作狀態機）

- Workspace/team key：`LS`。**Linear 是唯一的任務狀態來源**；每個狀態的離開就是一個 gate，由 orchestrator 執行轉換並在 ticket 留 comment 記錄 gate 證據。
- MCP 設定在專案 `.mcp.json`（`https://mcp.linear.app/mcp`）；session 重啟後用 `/mcp` 完成 OAuth。**未授權前不得改用其他系統替代開票**。

| 狀態 | 離開條件（gate） |
|---|---|
| Backlog | 被排入優先，值得寫規格 |
| Spec | ticket 具備**可驗證的驗收條件**與明確 scope |
| Design | design gate 過（純後端票可跳過此狀態） |
| Ready | worktree＋branch 已建、指派給 agent |
| In Progress | push gate 過、PR 開出 |
| In Review | merge gate 過、併入 development |
| QA | QA gate 過（在 test branch） |
| Done | 已併入 main（隨 release） |
| Canceled | 記錄取消原因 |

## 6. 補充規定

- **Hotfix**：`hotfix/*` 從 `main` 切出、PR 回 `main`（CI＋review 照跑、QA 走快速通道），合併後**必須 back-merge 到 `test` 與 `development`**。
- **Release**：test→main 合併後打 tag `vX.Y.Z`（semver），TestFlight 上傳由 orchestrator 執行並在對應 ticket 記錄 build 號。
- **DB migration gate**：`supabase/migrations` 的變更必附 RLS 測試；**破壞性 migration（DROP、縮欄、改型）需使用者本人核可**，agent 不得自行合併。
- **Secrets**：金鑰一律不進 repo。Client 端用 gitignored 的 `Secrets.xcconfig`；CI 用 GitHub Secrets；`service_role` key 永不出現在 client 或 repo。
- **回滾**：正式站問題以 revert PR 處理；保護分支禁止 force-push。
- **Checkpoint**：每張 ticket 完成，orchestrator 把 handoff 訊息留在 Linear ticket comment，讓狀態可還原、可交接。
- **模擬器驗不了的項目**（推播、Sign in with Apple 完整流程）：QA 標註「需實機驗證」，不得記為 PASS。
- **CI 成本**：macOS runner 計費倍率高；CI 只在 PR 與保護分支 push 時觸發，勿加無謂矩陣。
