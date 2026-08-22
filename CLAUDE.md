# CLAUDE.md — Little Sprout

私密家庭相簿與日記 iOS app（SwiftUI + Supabase）。本檔只放**每個 session 都必須知道的事**；細節在 index 指向的文件，需要時再讀。

## 最高原則：前饋必有反饋

所有給 agent 的指示都假設可能不被遵守；每條重要規則都必須有機械式 gate（hook／CI）攔截違規。**新增重要規則＝同時新增它的 gate**，否則視為未完成。對照表見 `docs/COLLABORATION.md` §7。

## 誰做什麼（硬規定）

- **Orchestrator（主 session）**：開票、派工、把關 gate；不寫功能程式碼（harness 除外）。
- **所有 UI 畫面設計必須由 ui-designer subagent 用 Pencil MCP 產出 .pen 設計稿**（`design/littlesprout.pen`）；沒有設計稿不得實作新畫面。
- ios-dev 實作；merge-reviewer 審 PR（race condition／運算效能／平行優化／scope）；qa 在 `test` branch 驗收（UI 票含模擬器視覺驗收）。model 政策見 COLLABORATION §1。
- **Feature 收尾儀式**（QA 過後、Done 之前，缺一不可）：dead-code-sweeper 巡檢該 feature 引入的死碼＋orchestrator 做 lesson learning review（harness 改善、設定優化、工具缺口），兩者皆記於 ticket comment——是 Done 的前置條件。見 COLLABORATION §6。

## 每個 agent 都要遵守

- 分支流向：`feature|fix/* → development → test → main`；`hotfix/*` 與 harness 檔從 `main` 切、PR 回 `main` 後 back-merge。保護分支禁直接 commit（hook＋GitHub 都會擋）。
- 一張 ticket＝一個 worktree（`.claude/worktrees/LS-<n>`）＝一條 branch（`feature/LS-<n>-slug`）；禁止跨 worktree 編輯。
- Commit 第一行：`<type>(<scope>): LS-<n> <摘要>`（commit-msg hook 會驗）；禁止 `--no-verify`。
- Handoff 格式：Ticket／已完成／已驗證（怎麼驗）／未完成／風險／產出位置。
- **Linear 是唯一任務狀態來源**（LS team；Backlog→Spec→Design→Ready→In Progress→In Review→QA→Done）。
- Secrets 永不進 repo（pre-commit 會掃）。

## Index

- `docs/PLAN.md` — 產品定位、技術架構、資料模型、開發路線圖、上架準備
- `docs/COLLABORATION.md` — 完整協作規約：gates 細節、分支與 worktree 規約、命名與訊息範本、Linear 狀態機、agent model 政策、前饋↔反饋對照表
