# CLAUDE.md — Little Sprout

私密家庭相簿與日記 iOS app（SwiftUI + Supabase）。本檔只放**每個 session 都必須知道的事**；細節在 index 指向的文件，需要時再讀。

## 最高原則：前饋必有反饋

所有給 agent 的指示都假設可能不被遵守；每條重要規則都必須有機械式 gate（hook／CI）攔截違規。**新增重要規則＝同時新增它的 gate**，否則視為未完成。對照表見 `docs/COLLABORATION.md` §7。

## 誰做什麼（硬規定）

- **Orchestrator（主 session）**：開票、派工、把關 gate；不寫功能程式碼（harness 除外）。
- **所有 UI 畫面設計必須由 ui-designer subagent 用 Pencil MCP 產出 .pen 設計稿**（`design/littlesprout.pen`）；沒有設計稿不得實作新畫面。**設計稿送人核可前必先與 visual-reviewer 完成至少 3 輪對抗迭代**（獵殺 slop；前 2 輪一律退修抬標準，第 3 輪起才可 APPROVE；**≥5 輪不收斂且爭點屬可機械複驗項時，orchestrator 得裁定聚焦輪，不進使用者仲裁**，COLLABORATION §1／§7，LS-68）。**每輪收工必附全樹溢出掃描收據**（`design/evidence/<票號>-r<n>-overflow.json`：兄弟交集／橫列溢出／跨 parent 碰撞／角托錨點／文字遮蔽／板裁切六支掃描（一律用正典腳本 `scripts/design/overflow-scan.js`，`corner_anchor.mismatch`、`text_occlusion.flagged` 與 `board_clip.flagged` 限本票觸碰的板 `boards` 且必為 0；`scan_scope` 標明 boards｜document）、TOTAL_NODES、FLAGGED 分類、HEAD sha、`tree_hash`（整份收據須來自對 head 快照的同一次掃描）；.pen 有變更的 PR 必附收據，CI `design-evidence-check.sh` 驗；Notes 板引用的節點 id 由 `design-notes-check.sh` 驗（死 id 只能用沿革寫法提），LS-68／LS-122／LS-168／LS-185）。每完成一項即落地＋commit＋push，不准累積到最後一次交（.pen 不透明檔案無法事後拆 commit）。
- ios-dev 實作；merge-reviewer 審 PR（race condition／運算效能／平行優化／scope）；qa 在 `test` branch 驗收（UI 票含模擬器視覺驗收）。model 政策見 COLLABORATION §1。
- **Feature 收尾儀式**（QA 過後、Done 之前，缺一不可）：dead-code-sweeper 巡檢該 feature 引入的死碼＋orchestrator 做 lesson learning review（harness 改善、設定優化、工具缺口）＋清理（`bash scripts/ops/cleanup-merged.sh --apply LS-<n>` 移除已併入的 worktree／本機分支，LS-86）＋**④ Pen 清場（設計票限定**：設計 PR 併入 development 後 orchestrator `bash scripts/ops/pen-open.sh <主 checkout> --kill` 並請使用者 `/mcp` 重連 pencil——設計票期間 Pen 一律停在票檔、agent 收工不切回，LS-180），皆記於 ticket comment——是 Done 的前置條件。見 COLLABORATION §6。

## 每個 agent 都要遵守

- 分支流向：`feature|fix/* → development ⇒(FF) test ⇒(FF) main`——晉升一律 `bash scripts/ops/promote.sh <from> <to>`（fast-forward push，不開 PR、不 back-merge），禁手動 push 到 `test`／`main`（push-gate 擋）；`hotfix/*` 與 harness 檔從 `main` 切、PR 回 `main` 後只補一支 back-merge `main`→`development`。保護分支禁直接 commit（hook＋GitHub 都會擋）。
- 一張 ticket＝一個 worktree（`.claude/worktrees/LS-<n>`）＝一條 branch（`feature/LS-<n>-slug`）；禁止跨 worktree 編輯。
- Commit 第一行：`<type>(<scope>): LS-<n> <摘要>`（commit-msg hook 會驗）；禁止 `--no-verify`（PreToolUse hook 擋，LS-88）。
- Handoff 格式：Ticket／已完成／已驗證（怎麼驗）／未完成（**必列 reviewer 全部 informational 的處置**：已修／記入待辦池 LS-96／另票 LS-<m>（限 COLLABORATION §5-b harness 優先序 High 以上）／不修＋理由，一條不能省）／風險／產出位置。
- **Linear 是唯一任務狀態來源**（LS team；Backlog→Spec→Design→Ready→In Progress→In Review→QA→Done）。
- **開票必標 lane**（`lane:harness|backend|design|ui|product`，一票一個）；票間依賴只用 Linear `blockedBy` 關係、不寫成文字。每 lane WIP 上限與巡檢補位規則見 COLLABORATION §5-b。
- **改狀態進 Ready 必帶 `cycle`（建票與更新票皆驗）；建票直接進 In Progress 也必帶 `cycle`，但更新既有票改 In Progress 不驗**（`Backlog`／`Done` 不要求；PreToolUse hook 擋，R1 依實測資料裁定的混合案，LS-79）；每週 Cycle 規劃提案／核可／結束回顧的節奏見 COLLABORATION §5-c。
- Secrets 永不進 repo（pre-commit 會掃）。
- 暫存檔一律 `LS-<n>-<用途>.<ext>`（或 `mktemp -d`）；`gh pr create/edit` 前先 `bash scripts/gates/pr-body-check.sh <body>`（CI 亦驗 PR body 檔頭段含分支票號）。

## Index

- `docs/PLAN.md` — 產品定位、技術架構、資料模型、開發路線圖、上架準備
- `docs/COLLABORATION.md` — 完整協作規約：gates 細節、分支與 worktree 規約、命名與訊息範本、巡檢與 session 連續性（§4-b）、Linear 狀態機、agent model 政策、前饋↔反饋對照表
