# LS-5 Phase 0-1：建立 Xcode 專案骨架（SwiftUI, iOS 17）＋ SwiftLint

| 欄位 | 值 |
|---|---|
| 狀態 | Done（completed） |
| 優先序 | High |
| 標籤 | — |
| Cycle | — |
| Project | Phase 0 — 開發地基 |
| Milestone | — |
| 估點 | — |
| 建立 | 2026-08-22T05:59:05.383Z |
| 開始 | 2026-08-22T06:51:10.351Z |
| 完成 | 2026-08-22T09:07:46.716Z |
| 建票者 | Chih-Lin Yeh |
| 指派 | Chih-Lin Yeh |
| URL | https://linear.app/little-sprout-app/issue/LS-5/phase-0-1建立-xcode-專案骨架swiftui-ios-17-swiftlint |
| 關係 | related→LS-8, related←LS-267, related←LS-49, related←LS-20, related←LS-16, related←LS-13, related←LS-10, related←LS-12, related←LS-7 |

## 描述

依 docs/PLAN.md Phase 0 第 1 步。建立 universal（iPhone＋iPad）SwiftUI 專案與導航骨架。

## Scope

* Xcode 專案（scheme 名 `LittleSprout`，若不同須同步更新 `scripts/gates/push-gate.sh` 與 `.github/workflows/ci.yml`）
* 導航骨架：iPhone 用 TabView（時間軸／相簿／孩子／設定）、iPad 用 NavigationSplitView，selection 單一來源（enum AppSection）
* SwiftLint 設定檔，repo hooks（commit/push gate）自此對 Swift 檔生效

## 驗收條件

- [ ] 模擬器（iPhone＋iPad 各一）跑出空殼 app，四個區塊可切換
- [ ] `swiftlint --strict` 乾淨
- [ ] push gate 的 `xcodebuild test` 能實際執行（至少一個 placeholder test）

備註：空殼導航骨架屬結構性版面、無視覺設計，經 orchestrator 認定可跳過 Design gate。

## 留言（3）

### 2026-08-22T07:19:30.687Z · Chih-Lin Yeh · `182fab3a`

**Handoff（ios-dev/opus，orchestrator 轉錄摘要）**

已完成：XcodeGen 專案（scheme LittleSprout、iOS 17、universal、shared scheme、project.yml＋.xcodeproj 皆入版控）；AppSection enum 單一來源；compact→TabView／regular→NavigationSplitView 共用 SectionContentView；四個 placeholder view；.swiftlint.yml；測試 target 3 條測試。

已驗證：push gate 實跑 xcodebuild test（iPhone 17 Pro）TEST SUCCEEDED；CI ci job 確認真的跑了測試（runs/32559087293 log 有三條 Test Case passed，非略過分支）；swiftlint --strict 0 violations；模擬器截圖：iPhone 四分頁逐一切換、iPad Pro 11" split view 渲染、iPhone Max 橫向 regular 路徑（/tmp/ls5-screenshots/）。

未完成→**QA gate 檢查項**：iPad sidebar 點擊切換互動未自動驗證（mobile-mcp 的 WebDriverAgent 在 iPad 模擬器全數逾時；simctl 無 tap），QA 在 test branch 補驗。

風險：Bundle ID `com.leoyeh.littlesprout` 為佔位，須與 LS-8 的 App ID 對齊（改 project.yml）；SWIFT_VERSION 明設 5.0，語言模式決策 → LS-12；機器環境變更：brew 裝 xcodegen 2.46.0、下載 iOS 26.5 Simulator runtime 8.52GB（必要——原本 xcodebuild 找不到任何可用 destination）。

產出：PR #5 → development（未 merge，CI 全綠）、branch feature/LS-5-xcode-skeleton（f2cf9b8）。

### 2026-08-22T07:50:37.064Z · Chih-Lin Yeh · `14047c8e`

**Merge gate 通過，已併入 development（PR #5，merge commit b0d9a7d）**

- Review 首輪 REQUEST_CHANGES（1 major＋4 minor）→ major 由 LS-13 落地漂移 gate、三個 minor 修於 6bfb081 → 複驗 **APPROVE**（F2/F4/F5 經 reviewer 獨立重測確認）。
- **記錄更正**（reviewer 要求，取代先前不實敘述）：我先前聲稱「PR #5 CI 已實跑漂移 gate（3m15s run）」是錯的——該 run 的 ci job 無此 step，且 gate 當時從未執行過核心邏輯。正確證據：update-branch 後的 run 32560481798，**ci job step 3「XcodeGen 漂移檢查」success**（log 可見 xcodegen generate 實跑、diff 通過），此為 gate 首次實跑證明。
- 過程中確認的機制：pull_request 的 workflow 定義跟著 head branch 走——harness CI 變更 back-merge 後，既有 open PR 需 `gh pr update-branch` 才吃得到新 gate（已記入 LS-10 待寫進規約）。
- 待 QA gate（promote 到 test 後）：ticket 驗收條件逐條＋iPad sidebar 點擊互動（首輪 review 起的未驗項）。
- Worktree 已移除、feature branch 已清（本地＋遠端）。

### 2026-08-22T09:01:29.823Z · Chih-Lin Yeh · `fbde9126`

**QA gate：PASS＋收尾 gate 完成**

QA（qa/sonnet，test branch 2f63227）：① iPhone 四分頁 mobile-mcp 實點＋accessibility tree 交叉確認 ✓；**iPad sidebar 點擊互動積欠項本輪解除**（WDA 本次正常，四分頁點擊驗證）✓；② swiftlint --strict 0 violations ✓；③ xcodebuild test 5/5 ✓；④ Dynamic Type accessibility-extra-large 四分頁不破版、tab 熱區 98×54pt ✓。證據：/tmp/qa-phase0/。
收尾 gate：dead-code 巡檢零 finding（Swift 符號全有呼叫點、pbxproj 無孤兒引用）；retro 見 LS-16 comment。
待 promote test→main 後進 Done。

