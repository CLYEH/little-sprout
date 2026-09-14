# LS-7 Phase 0-3：XCTest＋CI 紅綠驗證

| 欄位 | 值 |
|---|---|
| 狀態 | Done（completed） |
| 優先序 | High |
| 標籤 | — |
| Cycle | — |
| Project | Phase 0 — 開發地基 |
| Milestone | — |
| 估點 | — |
| 建立 | 2026-08-22T05:59:58.804Z |
| 開始 | 2026-08-22T07:51:24.071Z |
| 完成 | 2026-08-22T09:07:55.744Z |
| 建票者 | Chih-Lin Yeh |
| 指派 | Chih-Lin Yeh |
| URL | https://linear.app/little-sprout-app/issue/LS-7/phase-0-3xctestci-紅綠驗證 |
| 關係 | related→LS-13, related→LS-5, related←LS-86, related←LS-16 |

## 描述

依 docs/PLAN.md Phase 0 第 3 步。CI（`.github/workflows/ci.yml`）已就緒但從未被真測試驗證過——綠燈本身不能證明 CI 真的在跑測試。

## 驗收條件

- [ ] 先推一個**刻意失敗**的測試（RLS 或 unit）讓 CI 變紅（附紅燈 run 連結）
- [ ] 修掉後 CI 變綠（附綠燈 run 連結）
- [ ] PR 觸發的 CI 包含 build＋test＋SwiftLint 三者

依賴：[LIT-5](https://linear.app/little-sprout-app/issue/LIT-5/phase-0-1建立-xcode-專案骨架swiftui-ios-17-swiftlint)（要有 Xcode 專案與測試 target 才能驗）。

## 留言（2）

### 2026-08-22T08:13:02.102Z · Chih-Lin Yeh · `821cb9a5`

**Handoff（ios-dev/sonnet，orchestrator 轉錄摘要）**

三項驗收全達成，全部 step 層級證據（PR #9）：
1. 綠燈基底：新增 AppSectionUniquenessTests（title/symbol 無重複，補了原本缺的意圖測試），run 32560908650 三 job 綠。
2. 紅燈：Contents API 直推失敗測試（模擬繞過本機 hook）→ run 32561176693 ci job Build & Test fail，失敗 case `testDeliberatelyFailsForCIRedGreenVerification`（4 ≠ 99）。**額外收穫**：第一次 API 推送漏同步 project.pbxproj，被 XcodeGen 漂移 gate 先攔（run 32561072873）——LS-13 gate 的首次真實攔截。
3. 綠燈：本機刪除失敗測試走正常 push gate → run 32561503946 全綠，job/step 清單證明 CI 含 build＋test（ci）＋SwiftLint（lint）＋規約檢查（rules 四 step）。

CI 紅綠驗證的結論：**CI 真的在跑測試、真的會因失敗變紅**，Phase 0-3 的核心疑慮解除。PR #9 未 merge，待 merge gate。

### 2026-08-22T09:01:36.979Z · Chih-Lin Yeh · `5d81b90d`

**QA gate：PASS＋收尾 gate 完成**

QA：AppSectionUniquenessTests 於 test branch 存在且實際執行（5 測試含其 2 條）✓；紅綠證據沿用 merge gate 記錄（run 32561176693 紅／32561503946 綠）。
收尾 gate：dead-code 巡檢確認紅燈鷹架（DeliberateFailureTests＋pbxproj 4 行引用）已在 4953786 完整移除，全庫 grep 零命中。retro 見 LS-16。
待 promote test→main 後進 Done。

