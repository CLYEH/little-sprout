# LS-9 Harness：前饋反饋 gates、agent model 政策、QA 視覺驗收、規約重構

| 欄位 | 值 |
|---|---|
| 狀態 | Done（completed） |
| 優先序 | High |
| 標籤 | — |
| Cycle | — |
| Project | Harness 與協作基建 |
| Milestone | — |
| 估點 | — |
| 建立 | 2026-08-22T06:16:06.243Z |
| 開始 | 2026-08-22T06:16:06.287Z |
| 完成 | 2026-08-22T06:51:06.685Z |
| 建票者 | Chih-Lin Yeh |
| 指派 | — |
| URL | https://linear.app/little-sprout-app/issue/LS-9/harness前饋反饋-gatesagent-model-政策qa-視覺驗收規約重構 |
| 關係 | related←LS-170, related←LS-16, related←LS-10 |

## 描述

落實最高原則「前饋必有反饋」：所有給 agent 的規則都要有機械 gate 攔截。

## Scope

* commit-msg hook（格式驗證）、branch 命名檢查、secrets 掃描（pre-commit）
* CI `rules` job：PR 方向矩陣、migration 必附 RLS 測試、破壞性 migration 攔截、design gate 機械面（新增 SwiftUI View 須填 `Design:`）
* agent model 政策（ui-designer/ios-dev/qa: sonnet、merge-reviewer: opus）＋升級規則
* qa 視覺驗收（mobile-mcp，備援 simctl 截圖）；`.mcp.json` 加 mobile-mcp
* CLAUDE.md 瘦身為 session 必讀＋index；完整規約移 `docs/COLLABORATION.md`
* push gate／CI 模擬器 destination 改動態偵測

## 驗收條件

- [X] 紅燈驗證：壞格式 commit message 被 commit-msg gate 擋下（本機實測）
- [X] 紅燈驗證：secrets pattern 誤判文件敘述已修正（改抓金鑰素材而非關鍵字）
- [X] PR 過 CI（rules＋lint＋ci 三個 job）併入 main
- [X] back-merge 到 test 與 development（PR #2／#3）

產出：branch `hotfix/LS-9-harness-feedback-gates`

## 留言（1）

### 2026-08-22T06:51:03.385Z · Chih-Lin Yeh · `1ae7466e`

**Handoff（orchestrator）**

Ticket：LS-9
已完成：commit-msg／branch 命名／secrets hooks、CI rules job（方向矩陣、migration 規約、design gate、commit/branch/secrets 伺服器端兜底）、agent model 政策、qa 視覺驗收（mobile-mcp@1.0.2）、CLAUDE.md 瘦身＋docs/COLLABORATION.md（含 §0 最高原則與 §7 對照表）、supabase MCP（read_only）、模擬器動態偵測。
已驗證：本機紅綠測試（壞格式 commit 被擋、secrets 四類攔截／文件敘述放行、純刪除 commit 放行）；CI 三 job 於 f9fb03e 全綠（run 32557878154）；merge-reviewer（opus）兩輪審查——首輪 REQUEST_CHANGES（6 major 全修＋複驗發現的 B1 已修），終輪 **APPROVE**。
未完成／剩餘：reviewer 兩個非阻擋觀察 → LS-10（Backlog）。
風險與已知問題：§7 標 ⚠️ 的人工兜底項（破壞性核可真實性、back-merge 確認、QA 證據）。
產出位置：PR #1（merged to main）、back-merge PR #2（test）／#3（development）皆已合併，三分支 harness 一致。

