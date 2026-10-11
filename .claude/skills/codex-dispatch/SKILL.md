---
name: codex-dispatch
description: Orchestrator 經本機 codex:rescue（codex-companion task）派任何視覺票給 Codex 視覺 lead 前必載——LS-484 切換點（LS-482 併入 development＋Q1 探針，2026-10-12）後所有 UI 畫面設計由 Codex 產稿。本檔是派工固定句：票號與 brief 檔位置、提案 .pen 路徑（docs/design-proposals/**）、Pen 切檔／清場與鎖屏探針、companion 命令（--cwd 票 worktree、--write、--effort high、status／result 輪詢）、worker effort 指定句、Codex 凍結稿不自行 commit（Claude commit A／B）、不碰 .claude/**、七欄交接、收據用正典 overflow-scan.js、Notes 畫面級屬性與年齡 NBSP 這類 gate 會驗的稿面規則，以及回收後的 scope 檢查與 visual-reviewer 盲審派法。寫 codex-companion prompt 或續派同一 thread 時逐條自檢；Codex 不可用改派 ui-designer 備援前要先取得使用者同意（改讀 opus-dispatch）。
---

# Codex 視覺票派工寫法（本專案版）

來源：`AGENTS.md`、`.codex/README.md`（LS-482）、GitHub issue #648 回覆 2（Q4 四步）／回覆 3（七欄、盲審）／回覆 6（切換點）、COLLABORATION §1「Codex 視覺 lead」三段、LS-482 Q1 探針（companion 1.0.6、CLI 0.162.1）。契約本體在 `AGENTS.md`（Codex 維護，Claude 側不改）；本檔只寫 orchestrator 這一側要放進 brief 的句子與前後手續。

## 1. 派工前（orchestrator 自己做）

1. **票與 worktree**：一票一 worktree（`.claude/worktrees/LS-<n>`）一分支（`feature/LS-<n>-<slug>`），自 development 切出；記下 base commit。design lane WIP＝1（LS-483：Mac 上 headless Pen 與桌面 Pen 不能並存，`pen` CLI 0.3.4 對 2.18／2.21 格式會讀成空文件）。
2. **brief 檔**：寫 scratchpad `LS-<n>-brief.md`（帶票號，不用通名），用 companion `--prompt-file` 傳；brief 內容照第 3 節固定句。
3. **提案 .pen 路徑**：`docs/design-proposals/<slug>/<name>.pen`（不是 `design/littlesprout.pen`）；新稿由 Codex 建檔，改稿就寫既有提案檔路徑。
4. **Pen 切檔由 orchestrator 代跑**：`bash scripts/ops/pen-open.sh <票 worktree 絕對路徑> --pen <提案檔>`，exit 0 才派。`AGENTS.md` 禁止 Codex 切換、關閉或殺共用的桌面 Pen；設計票期間 Pen 停在票檔，Codex 收工也不切回。
5. **鎖屏規則（LS-480／LS-483）**：螢幕鎖定時 Pen 不重新排版、`Get` bounds 系統性偏移，收據會出假陽性。派工前與每次掃描前跑 `bash scripts/design/pen-bounds-probe.sh --pen <提案檔>`，exit 3（鎖屏或 bounds 偏移）就不派掃描、等解鎖；無人值守時段只派不需要版面量測的工作。

## 2. companion 命令

```bash
node ~/.claude/plugins/cache/openai-codex/codex/<ver>/scripts/codex-companion.mjs task \
  --background --fresh --write --effort high \
  --cwd <票 worktree 絕對路徑> --prompt-file <scratchpad>/LS-<n>-brief.md
```

- `<ver>` 取本機現有最新版（Q1 驗過 1.0.6）；不得修改 plugin cache 注入未支援旗標。
- `--write`＝workspace-write sandbox（不帶就是 read-only，Codex 寫不了匯出與 manifest；Pencil MCP 的寫入不受 filesystem sandbox 約束，README「Permissions are inherited」）。
- `--fresh`：新票一律新 thread；同票下一輪改 `--resume`（續同一 thread），不得接到別票的 thread。
- 派完立刻輪詢：`node … status <job-id> --json`（看 `status`：queued／running／completed／failed／cancelled），completed 後 `node … result <job-id>` 取七欄 handoff；companion 不會主動通知。Bash 單次 ≤10 分鐘前景輪詢，逾時再跑一次。
- 失敗就 fail loud：companion／模型／角色缺失（例如 `unknown agent_type`）照實回報使用者，**不改派 ui-designer**——備援要使用者同意。

## 3. brief 固定句（逐條放進 `LS-<n>-brief.md`）

1. **身分與範圍**：「LS-<n> 視覺票。worktree `<絕對路徑>`，分支 `<branch>`，base `<sha>`。畫面／狀態：<清單>。品牌基準：`<revision-pinned skill 路徑＠commit>`（已接受基準、候選延伸、待原生驗證三者分開）。」
2. **可寫路徑 allowlist**：「只寫 `docs/design-proposals/<slug>/` 下的 `<name>.pen`、`exports/`、`manifest`；不碰 `.claude/**`、`AGENTS.md`、`.codex/**`、Swift、pbxproj、`supabase/`、`design/littlesprout.pen`、任何 harness 檔。」
3. **不自行 commit**：「凍結本輪 .pen、匯出與 manifest（screen id、state、來源路徑、SHA256、provenance）後交回；不 commit、不 push、不開 PR、不改 Linear。設計 commit A 與收據／審查 commit B 由 Claude 提交。」
4. **worker 與 effort**：「明確委派 `sprout_designer`／`sprout_visual_reviewer`／`sprout_delivery_verifier`（gpt-6.1-sol），同時最多三個 worker，不再加一層。spawn worker 時要求 reasoning effort high；Q1 實測子 thread 的 runtime effort 是 low（parent high），若 spawn 參數不支援指定 effort，在 handoff「風險」欄寫明實際值，不得默默接受。」（待辦池 LS-413 `ea000770`：role 檔 effort 欄位待查。）
5. **收據**：「全樹溢出掃描一律用正典 `scripts/design/overflow-scan.js`，對 Claude 提交的 commit A 那份快照跑，收據 `design/evidence/LS-<n>-r<k>-overflow.json`、`head_sha`＝A；不得手造收據或把沒跑的檢查填 0。誰產出哪份證據要記明（Codex 跑不了的由 Claude 跑）。」
6. **gate 會驗的稿面規則**：「Notes 板（頂層 frame 名稱含『實作註記』或『Handoff Notes』）的『畫面級屬性』段每個新畫面一列（板名｜隱藏 Tab Bar｜標題｜釘底動作帶｜失敗文案鍵｜深色特例｜AX3 特例｜iPad 重排/放大｜資料落點），Notes 只引用現行節點 id；年齡字串『N 歲 N 個月』／『N 個月』分隔用 U+00A0（月前 U+2060）。這三條由 `design-notes-check.sh`／`design-identity-header-check.sh` 機械驗，新增提案稿整份都算新增（LS-484）。」
7. **Pen**：「Pen 已由 Claude 切到 `<提案檔>`；開工 `get_app_state` 核對 active 文件＝該路徑，不切換、不關閉、不殺 Pen，收工不切檔。」
8. **七欄交接**：「handoff 用七欄：Ticket（含 task／job／thread id）／已完成（artifact 狀態 ready_for_pitch｜needs_revision｜blocked，不是 Linear 狀態）／已驗證（怎麼驗）／自檢／未完成（每條 open finding 含 informational 與處置）／風險／產出位置；內部審查輪次照實記，不湊輪數。」

## 4. 回收後（orchestrator 自己做）

1. **scope 檢查**：`git -C <worktree> status --porcelain` 只能出現 allowlist 路徑；越界即退回，不替 Codex 收拾。
2. **commit A**：`design(proposal): LS-<n> r<k> <摘要>`（只含 .pen／匯出／manifest）。
3. **掃描**：對 A 跑探針（第 1 節第 5 條）再跑正典腳本（Codex 續派或 orchestrator 自跑）。
4. **visual-reviewer 盲審**：派工單只給 commit A／提案檔路徑、brief、收據，**不附 Codex handoff 的自評與內部 reviewer verdict**（`visual-reviewer.md`「盲審」段）；派法照 `opus-dispatch`。不設最低輪數，有 MAJOR 以上 → ITERATE → 把 findings 轉成下一輪 brief（`--resume`）。
5. **commit B**：收據＋審查記錄（`design(evidence): LS-<n> r<k> …`，不碰 .pen）；本機跑 `design-evidence-check.sh`／`design-notes-check.sh`／`design-identity-header-check.sh <提案檔> --base origin/development` 綠才 push。掃描後稿件再動就重走 A→掃描→審查→B。
6. **結案**：設計 PR 併入 development 後執行 `bash scripts/ops/pen-open.sh <主 checkout> --kill` 清場，先呼叫一次 `mcp__pencil__get_app_state`（懶連線自動連上），失敗才請使用者 `/mcp`（COLLABORATION §6 ④）。
