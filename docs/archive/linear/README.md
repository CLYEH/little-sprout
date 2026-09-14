# Linear 封存票索引（team LS）

匯出時間：2026-09-15T00:55:09+0800；條件：completed／canceled 早於 2026-09-13T16:00:00Z；每票一檔 `LS-<n>.md`（描述＋全部留言）。

| 票 | 狀態 | 完成 | Lane／標籤 | 標題 |
|---|---|---|---|---|
| [LS-1](LS-1.md) | Canceled | 2026-08-22 |  | Get familiar with Linear |
| [LS-2](LS-2.md) | Canceled | 2026-08-22 |  | Connect your tools |
| [LS-3](LS-3.md) | Canceled | 2026-08-22 |  | Import your data |
| [LS-4](LS-4.md) | Canceled | 2026-08-22 |  | Set up your teams |
| [LS-5](LS-5.md) | Done | 2026-08-22 |  | Phase 0-1：建立 Xcode 專案骨架（SwiftUI, iOS 17）＋ SwiftLint |
| [LS-6](LS-6.md) | Done | 2026-08-22 |  | Phase 0-2：Supabase 專案＋schema migration＋RLS policies |
| [LS-7](LS-7.md) | Done | 2026-08-22 |  | Phase 0-3：XCTest＋CI 紅綠驗證 |
| [LS-9](LS-9.md) | Done | 2026-08-22 |  | Harness：前饋反饋 gates、agent model 政策、QA 視覺驗收、規約重構 |
| [LS-10](LS-10.md) | Done | 2026-08-22 |  | Gate 強化：secrets 誤判逃生口＋commit 驗證範圍排除保護分支歷史 |
| [LS-11](LS-11.md) | Done | 2026-08-22 |  | Harness：CI 機械執行 RLS 測試（migration gate 補強） |
| [LS-12](LS-12.md) | Done | 2026-08-22 |  | 決策：Swift 語言模式（5 vs 6 strict concurrency） |
| [LS-13](LS-13.md) | Done | 2026-08-22 |  | Harness：XcodeGen 漂移 gate（project.yml ↔ .xcodeproj 同步檢查） |
| [LS-14](LS-14.md) | Done | 2026-08-22 |  | 部署 schema 到雲端 Supabase＋default privileges 覆核（\ddp） |
| [LS-15](LS-15.md) | Done | 2026-08-22 |  | DB 硬化：rls_auto_enable 收權＋sequences/functions default privileges |
| [LS-16](LS-16.md) | Done | 2026-08-22 |  | Harness：feature 收尾儀式——dead-code-sweeper agent＋lesson learning review |
| [LS-17](LS-17.md) | Done | 2026-08-25 | lane:ui | Story：Sign in with Apple＋Email OTP 登入 |
| [LS-18](LS-18.md) | Done | 2026-08-31 | lane:ui | Story：建立家庭與邀請加入 |
| [LS-19](LS-19.md) | Done | 2026-09-04 | lane:ui | Story：孩子檔案 CRUD 與年齡標記 |
| [LS-26](LS-26.md) | Done | 2026-08-23 |  | Harness：ui-designer 設計稿落地 gate（Pencil 無 save 工具） |
| [LS-27](LS-27.md) | Done | 2026-08-25 |  | Harness：visual-reviewer——設計稿對抗性視覺審查 gate |
| [LS-28](LS-28.md) | Done | 2026-08-25 |  | Harness：設計方向更新（暖色主導）＋visual-reviewer 邊界條款 |
| [LS-29](LS-29.md) | Done | 2026-08-25 |  | Harness：ui-designer 必載 frontend-design skill |
| [LS-30](LS-30.md) | Done | 2026-08-25 | lane:harness | Harness：little-sprout-brand 專案 skill（設計語言定案後） |
| [LS-31](LS-31.md) | Done | 2026-08-25 | lane:design | 實驗：/design canvas 管線 vs .pen——同 brief 三輪對抗比較 |
| [LS-32](LS-32.md) | Done | 2026-08-22 |  | Harness 維護批次：agent 定義小修×4（PR #33 review minors） |
| [LS-33](LS-33.md) | Done | 2026-08-22 |  | Task：LS-18 後端——邀請、加入申請與審核的 schema＋RPC＋RLS |
| [LS-34](LS-34.md) | Done | 2026-08-22 |  | Harness：run.sh 全形括號在 bash 3.2 的 unbound variable bug ×3 |
| [LS-35](LS-35.md) | Done | 2026-08-23 |  | Harness：visual-reviewer verdict 詞彙統一（REQUEST_CHANGES vs ITERATE） |
| [LS-36](LS-36.md) | Done | 2026-08-24 |  | DB：補 11 個既有外鍵的反向索引（65_ 列舉檢查掃出） |
| [LS-37](LS-37.md) | Done | 2026-08-24 |  | DB 安全強化：invites_insert policy 收斂——唯一寫入路徑改 create_invite RPC |
| [LS-38](LS-38.md) | Done | 2026-08-25 | lane:design | 實驗第二輪：軌 C (.pen) × 軌 D (canvas)——粉色調＋漸層，各 ≥5 輪對抗 |
| [LS-39](LS-39.md) | Done | 2026-08-31 | lane:ui | Auth：Google 登入（Supabase provider＋iOS 整合） |
| [LS-40](LS-40.md) | Done | 2026-08-24 |  | Task：LS-20 後端——Storage bucket／RLS policy／路徑規約 |
| [LS-41](LS-41.md) | Done | 2026-08-24 |  | API 契約成品化：docs/API.md＋doc↔schema 對帳 gate |
| [LS-42](LS-42.md) | Done | 2026-08-25 | lane:harness | Harness：Figma 整合（secrets pattern＋唯讀 MCP＋官方 kit 參考資產） |
| [LS-43](LS-43.md) | Done | 2026-08-25 | lane:harness | Harness：supabase MCP 改 PAT（stdio）——OAuth 動態註冊過期不再影響 |
| [LS-44](LS-44.md) | Done | 2026-09-01 | size:M, lane:harness | Harness：ui-designer/visual-reviewer 定義更新批次（Pencil 缺陷清單×4＋收工程序內容證明） |
| [LS-45](LS-45.md) | Done | 2026-08-24 |  | Harness：破壞性核可標記改整行錨定（子字串比對可被無意提及滿足） |
| [LS-46](LS-46.md) | Done | 2026-08-25 |  | 設計定稿合併：C 基準＋使用者指定調整 → design/littlesprout.pen |
| [LS-47](LS-47.md) | Done | 2026-08-25 |  | 寶貝 profile：建立家庭後可新增多個寶貝（建立/管理/切換） |
| [LS-48](LS-48.md) | Done | 2026-08-25 |  | Task：LS-21 後端——diaries schema 補全／時間軸查詢 RPC／RLS＋測試 |
| [LS-49](LS-49.md) | Done | 2026-08-24 |  | iOS 基礎層：Supabase SDK 整合＋環境設定＋Auth session 服務（無 UI） |
| [LS-50](LS-50.md) | Done | 2026-08-24 |  | Harness：分支起點乾淨度 gate——feature 分支不得夾帶其他票號的 commit |
| [LS-51](LS-51.md) | Done | 2026-08-24 |  | chore：設計畫布執行產物入版控規則統一（_shotcheck.html 等，A/B/D 三軌） |
| [LS-52](LS-52.md) | Done | 2026-08-25 |  | DB 安全：albums_update／comments_update owner 分支不限欄位——owner 可改寫他人相簿標題與留言內文 |
| [LS-53](LS-53.md) | Done | 2026-08-24 |  | Harness：破壞性偵測器盲區——ALTER POLICY …(false) 與 REVOKE 未納入關鍵字/語意判定 |
| [LS-54](LS-54.md) | Done | 2026-08-24 |  | Harness 小修批次：api-contract-check N1-N5＋approve_join 註解矛盾（PR #58 R2 minors） |
| [LS-55](LS-55.md) | Done | 2026-08-24 |  | iOS 基礎層收尾 minors（PR #63 R2 N1-N9）：initialSession 離線抹 nil、快取非同步測試、LS999 測試、死碼 userFacingMessage |
| [LS-56](LS-56.md) | Done | 2026-08-24 |  | Harness：error-codes-check 抽取規則硬化（註解掉的 case／表格首欄格式）＋artifact retention-days（PR #69 R1 minors） |
| [LS-57](LS-57.md) | Done | 2026-08-25 | lane:backend | 產品決策：owner 軟刪的內容可被作者直接還原（diaries/albums/comments 系統性）——是否記錄 deleted_by 並禁止作者清除他人設下的 deleted_at |
| [LS-58](LS-58.md) | Done | 2026-08-25 |  | Task：LS-22 後端——comments／reactions 寫入 RPC、feed 整合、device_tokens 推播基礎＋RLS 測試 |
| [LS-59](LS-59.md) | Done | 2026-09-01 | size:S, lane:harness | Harness：既有三支 gate .test.sh 在 macOS bash 3.2 下 ✗ 分支變數名吸入多位元組會炸 |
| [LS-60](LS-60.md) | Done | 2026-08-24 |  | Harness：merge-reviewer／dead-code-sweeper 缺 Linear 工具，讀不到票文也寫不了 comment |
| [LS-61](LS-61.md) | Done | 2026-08-25 |  | Harness：審查取證目錄（截圖／掃描輸出）定固定位置＋ignore 規則，改 agent 存放指示 |
| [LS-62](LS-62.md) | Done | 2026-08-25 | lane:backend | iOS 測試：N1 離線快取測試改為計數 stub 呼叫次數，去除對 SDK 重試常數的寫死依賴 |
| [LS-63](LS-63.md) | Done | 2026-08-25 |  | Harness：scratchpad 暫存檔名必帶票號（平行 agent 撞檔導致 PR body 誤貼） |
| [LS-64](LS-64.md) | Done | 2026-08-25 | lane:backend | LS-58 收尾小修：API.md §2 引用對齊＋private.record_notification_event 授權邊界測試 |
| [LS-65](LS-65.md) | Done | 2026-09-01 | size:S, lane:harness | Harness：push-gate 便宜檢查（契約對帳／錯誤碼／分級／票號／衝突預檢）前移到 xcodebuild 之前 |
| [LS-66](LS-66.md) | Done | 2026-08-25 | lane:backend | Task：LS-47 後端——children 多寶貝 CRUD RPC、軟刪 30 天可還原、角色矩陣＋測試 |
| [LS-67](LS-67.md) | Done | 2026-08-31 | lane:design | 設計：多寶貝 profile 三畫面（建檔／管理／切換）— ui-designer→visual-reviewer ≥3 輪 |
| [LS-68](LS-68.md) | Done | 2026-09-01 | size:M, lane:harness | Harness：設計流程規則機械化——聚焦輪條款、收工溢出掃描必跑、分段落地、掃描收據 gate |
| [LS-69](LS-69.md) | Done | 2026-09-01 | size:S, lane:harness | Harness：evidence-path-check 加 --base 模式讓 CI 對 PR diff 重跑（目前 CI 只跑自測） |
| [LS-70](LS-70.md) | Done | 2026-08-25 | lane:harness | Harness：並行後端票搶同一個本機 Supabase 容器（db reset 互踩）— 隔離或序列化 |
| [LS-71](LS-71.md) | Done | 2026-08-25 |  | Harness：session 連續性——SessionStart hook 跑巡檢＋提醒建 cron、patrol.sh 進 repo、本 session 慣例寫進規約與 agent 定義 |
| [LS-72](LS-72.md) | Done | 2026-08-25 | lane:design | 設計 chore：LS-46 R10/R11 informational F6–F8（print-edge token 合併、Tokens 表補對比欄、其餘 12 個沖印品換 token） |
| [LS-73](LS-73.md) | Done | 2026-08-25 |  | Harness：push-gate 在 hook 環境下 SPM 解析必炸——xcodebuild 前清掉 GIT_DIR／GIT_WORK_TREE／GIT_INDEX_FILE |
| [LS-74](LS-74.md) | Done | 2026-09-01 | size:M, lane:harness | Harness：design/ 大檔與 .pen 逐輪快照的體積策略（git-lfs 或設計 PR squash） |
| [LS-75](LS-75.md) | Done | 2026-08-25 | lane:harness | Harness：Lane WIP 上限＋Backlog→Ready 機械規則（巡檢每輪補位；票文 lane 標籤＋blockedBy 關係） |
| [LS-76](LS-76.md) | Done | 2026-08-31 | size:S, lane:harness | Harness：push-gate 對「無 Swift／專案檔變更」的 PR 跳過 xcodebuild test（純文件 harness PR 也吃模擬器 flake） |
| [LS-77](LS-77.md) | Done | 2026-09-01 | size:M, lane:harness | Harness：開票結構 gate——open 票必有 project；Phase 票必有 milestone；Task 必有 parent（巡檢列出＋Spec guard 擋） |
| [LS-79](LS-79.md) | Done | 2026-09-01 | size:M, lane:harness | Harness：Cycle（Sprint）機制——每週規劃一次核可、lane 補位只取當前 cycle、hook 擋無 cycle 的派工、巡檢對帳 cycle 外 active 票 |
| [LS-80](LS-80.md) | Done | 2026-08-31 | size:S, lane:harness | Harness：已併入 base 的 migration 檔不可變 gate——pre-push＋CI 對 base 上既有 `supabase/migrations/*` 的修改／改名／刪除即擋 |
| [LS-81](LS-81.md) | Done | 2026-08-25 | lane:design | 設計 chore：`aw57e` 角托壓紙緣量與 Tokens 板「5pt」慣例不一致（LS-72 visual-reviewer 範圍外觀察） |
| [LS-82](LS-82.md) | Done | 2026-08-25 | lane:ui | AuthStore 訂閱 authStateChanges（SDK 端登出/撤銷要立刻反映到 root routing） |
| [LS-83](LS-83.md) | Done | 2026-08-25 | size:S, lane:harness | Harness：detect-simulator 以機型名選 destination，多 worktree 併發 xcodebuild test 打同一台模擬器 → runner 崩潰；改 UDID＋每 worktree 專屬模擬器或串行 lock |
| [LS-84](LS-84.md) | Done | 2026-08-25 | lane:backend | DB 測試：60_ §2 private 函式授權檢查改通掃＋例外名單（手寫列舉漏 enforce_child_not_deleted／enforce_children_family_immutable）＋87_ §8 anon 半段斷言形狀 |
| [LS-85](LS-85.md) | Done | 2026-08-25 | lane:harness | Harness：晉升改 fast-forward push（promote.sh）＋取消 back-merge——GitHub 保護改「狀態檢查＋限制推送者」、CI 加 push 觸發、push-gate FF 檢查、巡檢分支漂移偵測 |
| [LS-86](LS-86.md) | Done | 2026-09-01 | size:S, lane:harness | Harness：結案清理機制——GitHub 併入即刪 head 分支、Done 收尾必移除 worktree／本機分支、cleanup-merged.sh＋巡檢偵測殘留 |
| [LS-87](LS-87.md) | Done | 2026-08-25 | lane:harness | Harness：審查與 QA 裁決機械化——merge-reviewer APPROVE 與 QA PASS 以 commit status 綁 SHA 並列為 required check；push-gate 對分支刪除早退；SessionStart 驗 hooksPath |
| [LS-88](LS-88.md) | Done | 2026-08-25 | size:M, lane:harness | Harness：Claude Code hooks 集（縮減版）——三支 fail-closed PreToolUse hook：禁 --no-verify／force push、禁讀 .env value、db reset 必經 supabase-lock |
| [LS-89](LS-89.md) | Done | 2026-08-25 | lane:product | 產品決策：邀請碼長度——定案 6 碼（LS-46）vs 後端已上線 8 碼／40-bit（LS-33）衝突，擇一 |
| [LS-90](LS-90.md) | Done | 2026-08-25 | lane:backend | Task：LS-18 後端——邀請碼改 6 碼（32 字元表、30 bit；LS-89 裁決 A）：create_invite／驗證正則／測試／API.md |
| [LS-91](LS-91.md) | Done | 2026-08-25 | size:M, lane:harness | Harness：Pen 開檔路徑對帳＋機械落地——pen-open.sh（open -a 切檔＋對帳）／pen-land.sh（autosave 結構 diff → 落地 → landing gate），根治 Pencil 單一文件與多 worktree 衝突 |
| [LS-92](LS-92.md) | Done | 2026-08-25 | lane:ui | Story 文案小修：OTP 畫面「還可以再試 0 次」矛盾句（LS-17 I-2）＋429／rate-limit 冷卻文案歸位（I-3） |
| [LS-93](LS-93.md) | Done | 2026-09-01 | size:S, lane:harness | Harness：本機 Supabase Auth 自訂 OTP 信件模板，讓 Inbucket 直接顯示 6 位驗證碼（QA 不必走 Admin API） |
| [LS-94](LS-94.md) | Done | 2026-08-25 | size:S, lane:harness | Harness：agent-tools-check 補釘 qa 的 mcp__pencil__execute＋ios-dev 規則列；visual-reviewer.md 引用不存在的 export_nodes 校正；§7 盲區欄記 qa 持 execute 可寫 .pen（LS-87 R3 I1–I3） |
| [LS-95](LS-95.md) | Done | 2026-09-01 | size:L, lane:harness | Harness：≥44pt 點擊目標機械 gate——UI 票 QA 前以 accessibility frame 量測所有 Button／tappable 元件，<44pt 即 FAIL（LS-17 QA1 兩顆按鈕漏網＋#148 R1 I4） |
| [LS-97](LS-97.md) | Canceled | 2026-08-25 | lane:product | Phase 1：Google 登入的雲端前置——在 Google Cloud Console 建 OAuth client，把 client ID／secret 填進 Supabase Auth Google provider（使用者本人操作） |
| [LS-98](LS-98.md) | Done | 2026-08-26 | lane:ui | iPad 歡迎頁視覺還原——`MountPoolOpacity.iPad` 染料池參數接上 `WelcomeView.regularLayout`（01-iPad 稿面；LS-17 sweeper F1） |
| [LS-99](LS-99.md) | Done | 2026-08-25 | lane:product | Phase 1：正式站 Auth 寄信——自訂 SMTP（Resend／Postmark／SES 擇一）＋提高 email 寄送上限＋OTP 信件模板含 6 碼＋寄件網域 SPF/DKIM（Supabase 內建 SMTP 全專案 2 封／小時，開放註冊前必做） |
| [LS-100](LS-100.md) | Done | 2026-08-25 | size:S, lane:harness | Harness：模擬器用完必關——ios-dev／qa 任務結束 `simctl shutdown`、push-gate 測完關專屬機、巡檢列出 Booted 模擬器並印關閉指令（使用者 2026-08-25 桌面堆滿模擬器） |
| [LS-101](LS-101.md) | Done | 2026-08-25 | lane:ui | 歡迎頁修正：三顆登入鈕間距一致、Apple 鈕圓角對齊、Google「G」改官方標誌、按鈕字級字型一致、封面照片補上（使用者 2026-08-25 demo 回饋） |
| [LS-102](LS-102.md) | Done | 2026-08-25 | size:S, lane:harness | Harness：本機 demo 指令入 repo——scripts/ops/demo-refresh.sh（FF 到指定 ref 重建裝進 demo 模擬器）＋demo-otp.sh（Admin API 取 OTP），README 加「本機 demo」段 |
| [LS-103](LS-103.md) | Done | 2026-08-31 | size:M, lane:harness | Harness：patrol.sh 用 LINEAR_API_KEY 直接打 Linear GraphQL——把巡檢的 Linear 半段（狀態對照、cycle 對帳、lane 補位候補、開票結構 (a)–(e)）機械化，orchestrator 只處理輸出的動作清單 |
| [LS-104](LS-104.md) | Done | 2026-08-31 | size:S, lane:harness | Harness：pretool.sh 誤擋精修——只在命令列位置比對（heredoc／引號字串／echo 內容排除），保留歧義即 deny；LS-88 生效後 orchestrator 連續 3 條命令因文字提到規則字面被擋 |
| [LS-105](LS-105.md) | Done | 2026-08-25 | lane:ui | AX3 下數字鍵盤遮住 OTP 畫面的「確認登入」鈕（鍵盤不隨 Dynamic Type 縮放）——加鍵盤避讓／可捲動（LS-92 QA1 新發現） |
| [LS-106](LS-106.md) | Done | 2026-08-26 | size:S, lane:harness | Harness：push-gate 對齊 CI——xcodegen 漂移檢查前移＋Xcode／Swift 版本比對（#165 同一 PR 兩次本機綠、CI 紅） |
| [LS-107](LS-107.md) | Done | 2026-08-31 | lane:ui | Task：LS-18 iOS（A）——首次進入三岔路＋建立家庭（05）＋邀請家人（07）：Owner 路徑 |
| [LS-108](LS-108.md) | Done | 2026-08-31 | lane:ui | Task：LS-18 iOS（B）——輸入邀請碼（06）＋等待核准（06d）＋deep link＋Owner 審核清單：加入路徑 |
| [LS-109](LS-109.md) | Done | 2026-08-31 | lane:ui | OTP／Email 畫面 AX3 鍵盤開啟時內容底部雙倍留白（contentMargins 與系統鍵盤 inset 疊加；LS-105 QA1 4(d) 實測 245–330pt） |
| [LS-110](LS-110.md) | Done | 2026-08-31 | lane:backend | Task：LS-18 後端——`profiles` 列自動建立（auth.users insert trigger＋回填），登入路徑不再依賴 client upsert（LS-107 發現：repo 無任何登入路徑 upsert profiles） |
| [LS-111](LS-111.md) | Done | 2026-08-31 | lane:design | 設計 chore：07 邀請家人——角色選擇列（一般成員／只能看）白話說明＋選中態（LS-46 定稿只有單一產生鈕；LS-107 以既有 token 暫拼） |
| [LS-112](LS-112.md) | Done | 2026-08-31 | lane:ui | Auth：登入頁三鈕語言統一——宣告 app 主語系 zh-Hant，讓 Apple 官方鈕顯示中文 |
| [LS-113](LS-113.md) | Done | 2026-08-31 | lane:ui | Task：LS-47 iOS——多寶貝 profile 三畫面實作（建檔／管理／切換），依 LS-67 核可稿 |
| [LS-114](LS-114.md) | Done | 2026-09-01 | lane:design | 設計 chore：`cmp/Approval Status`（`PXPcH`）AX3 錯位 196pt——alignItems center 缺陷，與 LS-111 R2-F2 同型（既有元件，R2 裁決三定另票） |
| [LS-115](LS-115.md) | Done | 2026-08-31 | size:S, lane:harness | Harness：CI Xcode 對齊本機 26.6——ci.yml macOS jobs 改 runs-on macos-26＋.xcode-version 改 26.6（取代「本機裝 16.4」方案） |
| [LS-116](LS-116.md) | Done | 2026-08-31 | size:S, lane:harness | Harness：patrol_linear.py LANE_LIMITS lane:ui 1→2——LS-67 核可觸發的手動同步（R1 informational 預告；獨立小票不塞 LS-103） |
| [LS-117](LS-117.md) | Done | 2026-08-31 | size:M, lane:harness | Harness：pen-open.sh 精修——主 checkout placeholder autosave 漂移擋切檔＋Pen 無回應時無強制路徑（本 session ≥2 次手動 SIGKILL） |
| [LS-118](LS-118.md) | Done | 2026-09-01 | size:M, lane:harness | Harness：Pencil MCP execute filePath 回傳陳舊版本（目標檔非 active doc 時吐 Pen 快取的舊版，非指定路徑內容）——阻塞設計票視覺 QA |
| [LS-119](LS-119.md) | Done | 2026-09-02 | lane:design | 設計:日記編輯器＋時間軸卡片流(LS-21 畫面群)— ui-designer→visual-reviewer ≥3 輪 |
| [LS-120](LS-120.md) | Done | 2026-09-03 | lane:design | 設計 chore：cmp/Tab Bar AX3 適應（單一形態規則） |
| [LS-121](LS-121.md) | Done | 2026-09-02 | lane:backend | Task：LS-21 後端——日記／相簿多寶貝標記（diary_children／album_children 連結表、RPC 改陣列、時間軸篩選、軟刪守門） |
| [LS-122](LS-122.md) | Done | 2026-09-02 | size:M, lane:harness | Harness：設計收工溢出掃描補三個結構性盲區——resolveInstances 深入、跨 parent 絕對座標碰撞、角托錨點核對（LS-119 R5 兩 BLOCKER 皆既有兩支掃描抓不到） |
| [LS-123](LS-123.md) | Done | 2026-09-02 | size:S, lane:harness | Harness：破壞性 migration 核可標記改認 PR comment（使用者本人留言獨佔行），body 覆寫不再洗掉核可 |
| [LS-124](LS-124.md) | Canceled | 2026-09-03 | lane:design | 設計 chore：全稿角托錨點以 LS-122 正典腳本複驗——確認並清除跨 parent 真碰撞（A11y/04 AX3 Corner × Card Text 等候選） |
| [LS-125](LS-125.md) | Done | 2026-09-02 | lane:ui | Task：LS-21 iOS——日記編輯器（照片佇列拖曳排序／多選移除／20 張上限／影片格／多寶貝標記），依 LS-119 核可稿 |
| [LS-126](LS-126.md) | Done | 2026-09-02 | lane:ui | Task：LS-21 iOS——時間軸＋日記詳情（卡片流／Day Divider／瀑布流照片牆／影片觸發態／多寶貝 caption），依 LS-119 核可稿 |
| [LS-127](LS-127.md) | Done | 2026-09-02 | size:S, lane:harness | Harness：design-evidence-check 在 CI merge ref 上誤把 base 側 .pen 變更算成本 PR（boards 漏列假紅＋合併 commit 被當最後一次 .pen commit） |
| [LS-128](LS-128.md) | Done | 2026-09-02 | lane:backend | Task：LS-20 後端——media 縮圖欄與上傳端縮圖（列表只載縮圖，PLAN §7 egress 防線） |
| [LS-129](LS-129.md) | Done | 2026-09-03 | lane:ui | Task：LS-20 iOS——上傳端縮圖（MediaUploadService 同步產生並上傳 thumb，寫入 thumb_path／尺寸） |
| [LS-130](LS-130.md) | Done | 2026-09-03 | lane:ui | Task：LS-20 iOS——列表／詳情改讀 thumb_path（NULL 退回原圖；全尺寸只在放大／播放時簽） |
| [LS-132](LS-132.md) | Done | 2026-09-12 | lane:product | 法務內容：隱私權政策與使用條款正式文本（繁中；含 UGC 零容忍條款；同步公開網址供 App Store） |
| [LS-133](LS-133.md) | Done | 2026-09-05 | lane:design | 設計：法務文件 in-app 檢視畫面（歡迎頁《使用條款》《隱私權政策》改開 app 內視窗，不跳網站） |
| [LS-134](LS-134.md) | Done | 2026-09-03 | lane:backend | Task：LS-20 後端——media.duration_seconds（影片時長欄，上傳端寫入；列表徽章不再依賴全尺寸簽名） |
| [LS-135](LS-135.md) | Done | 2026-09-03 | lane:ui | Task：LS-20 iOS——影片時長徽章改讀 media.duration_seconds（上傳端寫入；列表不再對影片簽全尺寸） |
| [LS-136](LS-136.md) | Done | 2026-09-03 | lane:ui | Task：LS-120 iOS——Tab Bar 全字級純 icon 實作（選中態紙片＋墨線、icon 26／32、AX3 48、VoiceOver selected、Large Content Viewer、tab-root 標題契約⑬） |
| [LS-137](LS-137.md) | Done | 2026-09-03 | size:S, lane:harness | Harness：CI 點擊目標 gate 路徑過濾漏掉 Features/、DesignSystem/ 之外的 SwiftUI View（LS-136 全票 UI 測試在 CI 跳過＝綠） |
| [LS-138](LS-138.md) | Done | 2026-09-03 | lane:ui, Bug | iOS：Release 組態編譯失敗（41 error，#Preview 引用 DEBUG-only mock）——無法 Archive／TestFlight |
| [LS-139](LS-139.md) | Done | 2026-09-03 | size:S, lane:harness | Harness：CI 加 Release 組態編譯 gate（xcodebuild -configuration Release build）——Release 紅＝PR 紅 |
| [LS-140](LS-140.md) | Done | 2026-09-03 | size:S, lane:harness | Harness：handoff 申報可驗證 gate——「記入 LS-96」必附 comment id、「已修」必附 SHA＋行號，pr-body-check 本機驗＋CI 反查 |
| [LS-141](LS-141.md) | Done | 2026-09-03 | size:S, lane:harness | Harness：cleanup-merged.sh 對 gitignored 產物（Config/Secrets.xcconfig、supabase/.temp/、supabase/tests/evidence/）不再略過——dirty 判定只看 tracked／untracked-non-ignored |
| [LS-142](LS-142.md) | Done | 2026-09-05 | lane:design, hold:user | 設計：相簿頁＋相簿詳情＋上傳佇列（LS-20 畫面群）——ui-designer／visual-reviewer ≥3 輪 |
| [LS-143](LS-143.md) | Done | 2026-09-03 | lane:backend | Task：LS-24 後端——刪除帳號 RPC（唯一 Owner 須先轉移；成員內容軟刪；併發無死鎖） |
| [LS-144](LS-144.md) | Done | 2026-09-03 | size:S, lane:harness | Harness：巡檢加「開票責任」機械提醒——lane 在飛 0 且無可派候補時，動作清單印「→ 開票」並列來源（story 拆票／LS-96 P1 升票） |
| [LS-145](LS-145.md) | Done | 2026-09-04 | lane:ui | Phase 2-2：PrivacyInfo.xcprivacy（required-reason API）＋Info.plist 用途字串（相簿／相機／推播）＋出口合規旗標 ITSAppUsesNonExemptEncryption=false |
| [LS-146](LS-146.md) | Done | 2026-09-12 | lane:backend | Phase 2-3：審核用 demo 帳號＋示範家庭資料（正式站種子：孩子檔案／照片／日記／留言、長期有效邀請碼、Email OTP 備援） |
| [LS-149](LS-149.md) | Done | 2026-09-03 | lane:backend | Task：LS-23 後端——檢舉／封鎖／Owner 移除內容 RPC（content_reports／blocked_users 寫入路徑、封鎖過濾納入時間軸與留言、額度 LS002 對帳） |
| [LS-150](LS-150.md) | Done | 2026-09-03 | lane:ui | Task：LS-136 寶貝 tab icon 由 figure.and.child.holdinghands 換 stroller.fill（使用者 0903 核可；AppSection 單點改＋a11y label 不變） |
| [LS-151](LS-151.md) | Done | 2026-09-04 | lane:backend | Task：LS-24 後端——Edge Function delete-account（service_role 刪 auth.users；RPC 後立即呼叫；deletion_requested_at 非 NULL 時 RLS 拒寫） |
| [LS-152](LS-152.md) | Done | 2026-09-05 | lane:design | 設計：設定與成員管理畫面群——刪除帳號流程（LS-24）、封鎖／檢舉入口（LS-23）、顯示名稱與頭像、退出家庭、Owner 移除成員、刪除單筆內容操作表 |
| [LS-153](LS-153.md) | Done | 2026-09-06 | lane:backend | Task：後端——軟刪與刪除帳號後 30 天自動永久清除排程（pg_cron／排程 Edge Function：DB 列硬刪＋Storage 物件刪除＋額度對帳） |
| [LS-154](LS-154.md) | Done | 2026-09-04 | size:S, lane:harness | Harness：擋 agent 寫入主 checkout——PreToolUse hook 對 Write／Edit 路徑與 Bash 重導／cp／tee 目標在 repo 根但不在 .claude/worktrees 下的呼叫拒絕（LS-96 f22f0645 P1 升票） |
| [LS-155](LS-155.md) | Done | 2026-09-04 | size:S, lane:backend | Task：LS-24 後端——刪帳號時一併軟刪該使用者上傳的 media（含日記附帶），30 天後由 purge 連同 Storage 清除；隱私政策 §8／API.md 同步 |
| [LS-156](LS-156.md) | Done | 2026-09-04 | size:S, lane:ui | Fix：Email 登入欄位 trim 前後空白——貼上帶空白／換行的 email 目前撞 GoTrue 泛用 400 而非格式提示 |
| [LS-157](LS-157.md) | Done | 2026-09-04 | size:S, lane:harness | Harness：XS 池項同批——main-checkout-guard 三項（GIT_* 全剝修 fail-open／帶引號前綴與 env -i／nice 穿透／「即將建立的 worktree」誤擋）＋pre-commit 衝突標記 gate＋dead-code-sweeper 白名單補 save_comment |
| [LS-158](LS-158.md) | Done | 2026-09-04 | size:M, lane:harness | Harness：QA 端到端驅動不依賴 mobile-mcp——LittleSproutUITests 加 QA e2e 情境測試（launchEnvironment 指定登入 OTP 自本機 Mailpit 取碼／固定 fixture 發佈／時間軸瀏覽），QA 以 -only-testing 驅動並接 Storage log |
| [LS-159](LS-159.md) | Done | 2026-09-04 | size:S, lane:harness | Harness：supabase-lock.sh 加「QA 持有」模式——`--hold <label> [--max-minutes N]`／`--release`，互動式 UI 驗收期間其他 worktree 的 db reset 排隊等待而非洗掉 QA session；qa 定義與派工模板同步 |
| [LS-160](LS-160.md) | Done | 2026-09-04 | size:S, lane:ui | 測試／修正：AppSection SF Symbol 可用性測試改驗「引入版本 ≤ deployment target」（iOS 17 裝置空白圖示風險）＋iPad 寶貝空狀態圖示對齊 stroller.fill＋UITests sentinel 引用 AppSection 常數 |
| [LS-162](LS-162.md) | Done | 2026-09-04 | size:S, lane:backend | Task：LS-146 正式站種子前置——review-demo-seed.sh 支援 --owner-email／--member-email 覆寫（真實可收信信箱，OTP 方案 C）＋review-notes.md 登入方式改寫為方案 C（信箱密碼只放 App Store Connect 備註、不進 repo） |
| [LS-163](LS-163.md) | Done | 2026-09-05 | size:S, lane:design | 設計：歡迎頁「以帳號密碼登入」小字連結（三顆登入鈕下方，非大按鈕）＋帳號密碼登入畫面（審核帳號用，方案 B）——ui-designer／visual-reviewer ≥3 輪 |
| [LS-164](LS-164.md) | Done | 2026-09-05 | size:S, lane:ui | Task：LS-17 iOS——帳號密碼登入（審核帳號用，方案 B）：歡迎頁小字連結＋密碼登入畫面＋`AuthService.signInWithPassword`＋錯誤映射＋隱私政策登入方式一句 |
| [LS-165](LS-165.md) | Done | 2026-09-05 | size:M, lane:ui | Task：LS-20 iOS——相簿 tab 首頁（相簿卡片列表／扇影厚度分級／空狀態／新增相簿）依 LS-142 稿實作，含深色、AX3、iPad 兩欄 |
| [LS-166](LS-166.md) | Done | 2026-09-12 | size:M, lane:ui | Task：LS-20 iOS——相簿詳情（瀑布流照片牆／加入照片入口／寶貝標記／改名與刪除相簿）依 LS-142 稿實作，含深色、AX3、iPad、34 張壓測 |
| [LS-167](LS-167.md) | Done | 2026-09-05 | size:M, lane:ui | Task：LS-20 iOS——上傳佇列 sheet（沒有成功／正在進行／已完成三群、LS002 容量已滿列最前、重試與背景續傳、固定 detent）依 LS-142 稿實作，含深色、AX3 |
| [LS-168](LS-168.md) | Done | 2026-09-04 | size:M, lane:harness | Harness：design-evidence gate 補強三項——Notes 板節點 id 存在性檢查（設計稿五度「Notes 落後改稿」）＋收據新鮮度雜湊（拼接收據 gate 盲）＋overflow-scan 第五支「文字遮蔽掃描」（Label × Action Bar／Value × Tab Bar） |
| [LS-169](LS-169.md) | Done | 2026-09-04 | size:M, lane:ui | Task：LS-19 iOS——寶貝大頭照上傳（PhotosPicker→方形縮圖→Storage `{family_id}/avatars/{child_id}.jpg`→`avatar_url`）＋有圖顯示圖／無圖顯示縮寫＋年齡標記邊界單元測試（閏月／未滿月／生日當天） |
| [LS-170](LS-170.md) | Done | 2026-09-04 | size:S, lane:harness | Harness：ios-dev／reviewer 互動式本機驗證（模擬器對本機 Supabase 容器）必須先 `supabase-lock.sh --hold`——LS-169 E2E 被他票 db reset 打斷四次；agent 定義＋派工模板＋agent-tools-check 規則 |
| [LS-171](LS-171.md) | Done | 2026-09-04 | size:S, lane:harness | Hotfix：LS-168 `tree_hash` Pencil 端與 js／py 不一致——Pencil `Get` 把 `geometry` 省略成 `"..."`，design-evidence gate 對含 path 節點的稿一律 fail-closed（擋住所有設計票收據） |
| [LS-172](LS-172.md) | Done | 2026-09-04 | size:M, lane:backend | Task：LS-22 後端——推播發送 Edge Function `push-dispatch`（消化 `notification_events` 待送列：彙總文案、對象判定含封鎖、device_tokens 失效清理、APNs provider 介面＋本機 stub；APNs 金鑰待 LS-8 才部署正式站） |
| [LS-173](LS-173.md) | Done | 2026-09-04 | size:S, lane:ui | 測試補強：LS-169 頭像上傳 R2／R3 新行為的單元測試（cache-busting 時間戳、Storage 403→`.rejected` 映射、簽名 URL 批次世代守門、`AvatarPickerLoader` 取消／世代）＋`docs/API.md` §6 一句更正 |
| [LS-174](LS-174.md) | Done | 2026-09-04 | size:S, lane:ui | Fix：儲存寶貝頭像後回到寶貝管理列表不即時刷新（要切一次 tab 才顯示新圖）——ChildrenStore 更新後列表重繪／簽名 URL 重取 |
| [LS-175](LS-175.md) | Done | 2026-09-04 | size:S, lane:backend | Task：LS-22 後端——`media` 新增彙總通知事件（批次上傳 50 張＝一則「爸爸新增了 50 張照片」）：AFTER INSERT statement-level trigger 進 `notification_events`（kind `album`／`media`，5 分鐘視窗），與 push-dispatch 文案矩陣對齊 |
| [LS-176](LS-176.md) | Done | 2026-09-04 | size:S, lane:harness | Harness：pen-open／pen-read 對「Pen 記得的舊 worktree 路徑已不存在」視為可安全捨棄（設計票新鮮度保證恢復）＋ cleanup-merged 連刪該票專屬模擬器與 DerivedData（磁碟水位） |
| [LS-177](LS-177.md) | Done | 2026-09-06 | size:M, lane:design | 設計：留言、愛心互動列與留言 sheet（LS-22 畫面群）＋推播通知權限提示與設定頁「推播通知」列——ui-designer／visual-reviewer ≥3 輪 |
| [LS-178](LS-178.md) | Canceled | 2026-09-04 | size:S, lane:ui | Chore：LS-19 iOS——`CreateChildAvatarFieldUITests` 裸 `isHittable` 斷言 flaky（無 wait／存在性前置）→ 改 `waitForExistence`＋hittable 輪詢，並掃同檔同型斷言 |
| [LS-179](LS-179.md) | Done | 2026-09-05 | size:M, lane:backend | Task：LS-23 後端——營運防線：使用者／家庭停權旗標（`profiles.suspended_at`／`families.suspended_at`：RLS＋RPC 全面拒絕、client 錯誤碼）＋註冊開關（`app_settings.registrations_open`：建立家庭／加入家庭前檢查）——PLAN §10-A(3)／§10-B，Dashboard 改欄位即生效、不改程式碼 |
| [LS-180](LS-180.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：`pen-open.sh --force-reload` 以 SIGKILL 清場會讓 Pencil MCP 斷線且 session 內不重連——VR 切檔後五支掃描／截圖全部不可用；改為不殺行程的可信切檔（切檔＋磁碟 tree_hash 新鮮度驗證），殺行程只做最後手段並印重連指引；巡檢／派工前偵測 Pencil 連線 |
| [LS-181](LS-181.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：`migration-breaking-check` 加 `ALTER TYPE … ADD VALUE` 規則——enum 加值時自動列出消費端（EF 型別守衛／iOS enum／API.md 矩陣）並要求 PR body 逐一確認，防「不認得的 kind 整批靜默丟失」再發生（LS-175 R1-i1） |
| [LS-182](LS-182.md) | Done | 2026-09-05 | size:S, lane:backend | Chore：LS-22 後端——推播／通知／停權測試與文件債清理（LS-96 池項六條：Stub 410 注入入口、claim race 耗時斷言、`ls172_*_capture` 殘表清理、push-dispatch 行轉換搬進 handler.ts＋測試、`delete_my_account` 情況 2 對停權者回歸案、API.md／105 檔頭三處一行修） |
| [LS-183](LS-183.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：PreToolUse 擋繞過 `supabase-lock.sh` 的本機容器操作——`docker exec` 進 `supabase_*` 容器、`psql`／連線字串打 54322、`supabase functions serve`／`supabase db query`（非 `--linked`）未經 lock 包裝或非持有者一律 deny（LS-96 `e381f653` 第 1 項） |
| [LS-184](LS-184.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：lock 持有安全補強——`supabase-lock.sh --hold` 在主 checkout（`git-dir`＝`git-common-dir`）直接拒絕（exit 2）＋`supabase stop`／`start` 納入 H3b＋qa／ios-dev 派工模板固定 `cd <worktree> && --hold` 同鏈（LS-96 `8fcc81c5`／`b4cb1e29`） |
| [LS-185](LS-185.md) | Done | 2026-09-05 | size:M, lane:harness | Harness：`overflow-scan.js` 第六支 `board_clip`（後代 AABB 超出有 clip 的 root frame 被裁切）＋收據 `scan_scope: boards\|document` 欄位＋`cross_parent_collision` 先過濾候選再配對（大稿 Pencil interrupted 緩解）——LS-96 `83392d32` 剩餘半段／`83694378`／`32754383` |
| [LS-186](LS-186.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：gate 精修兩項——`pr-body-check.sh --verify`「已修」行 SHA 候選只認 git object（Linear comment id 形狀不再被當 SHA 反查，LS-185 兩次紅 CI）＋CI `db` job `supabase db reset` 對 54322 port 綁定 flake 加一次重試（LS-184 run 33934840343）——LS-96 `29b413bb` p1／`305a9279` |
| [LS-187](LS-187.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：巡檢「專屬模擬器」段改為「票已 Done／Canceled 或 worktree 已不存在的 `LS-<n>-*` 一律 ⚠＋動作清單 `→ cleanup-merged.sh --apply LS-<n>`（不再只看 >7 天未用）」＋列 Xcode 預設機台數／磁碟；使用者 2026-09-05 指出 4 台 Done 票殘機巡檢沒抓 |
| [LS-188](LS-188.md) | Done | 2026-09-05 | size:M, lane:ui | Task：LS-152 iOS——設定頁 root（個人／家庭／內容與安全／法律／帳號五區）＋儲存空間頁（09／09b 已滿）依 LS-152 稿實作，含深色、AX3、iPad；家庭區塊列文字垂直置中（使用者 0905 意見） |
| [LS-189](LS-189.md) | Done | 2026-09-06 | size:M, lane:ui | Task：LS-23 iOS——內容操作表（日記／照片／留言「⋯」或長按：檢舉／封鎖此成員／Owner 移除內容）＋檢舉原因與已送出＋封鎖確認＋封鎖名單（解除）＋Owner 檢舉收件匣 依 LS-152 稿實作，含 AX3 |
| [LS-190](LS-190.md) | Done | 2026-09-06 | size:S, lane:ui | Task：LS-23 iOS——EULA 同意頁（首次登入／版本更新時，零容忍條款摘要，08）＋刪除單筆內容確認（日記 10／留言 10b，沿 LS-142 15c 語彙）依 LS-152 稿實作，含 AX3 |
| [LS-191](LS-191.md) | Done | 2026-09-05 | size:S, lane:ui | Task：LS-133 iOS——法務文件 in-app 檢視 sheet（《使用條款》《隱私權政策》：bundled markdown 渲染、Footer 釘底關閉、版本／生效日期讀檔頭、iPad 置中卡片 520）依 LS-133 稿實作，歡迎頁與設定頁連結改開 sheet |
| [LS-192](LS-192.md) | Done | 2026-09-06 | size:M, lane:ui | Task：LS-152 iOS——編輯顯示名稱與頭像（02）＋家庭成員管理（03／03-AX3／03-iPad、03b 移除成員確認、03c 轉移 Owner 確認）＋退出家庭（03d／03e 需先轉移 Owner）依 LS-152 稿實作 |
| [LS-193](LS-193.md) | Done | 2026-09-06 | size:M, lane:ui | Task：LS-24 iOS——刪除帳號流程（04a 一般成員／04b 唯一 Owner 需轉移／04d 唯一成員警告／04e 最終確認／04f 進行中／04g 完成／04h 失敗，含 AX3、深色）依 LS-152 稿實作，接 `delete_my_account` 與 LS-151 EF |
| [LS-194](LS-194.md) | Done | 2026-09-05 | size:S, lane:design | 設計 chore：使用者 0905 核可意見兩項——LS-152 `01 設定` 家庭區塊列文字垂直置中＋LS-163 `P1 帳號密碼登入` AX3 大字級跑版修正；修完 VR 聚焦複驗一輪＋收據即通過（不再送核可） |
| [LS-195](LS-195.md) | Done | 2026-09-05 | size:S, lane:backend | Task：LS-23 後端——檢舉事件推播只發給家庭 Owner（`notification_recipients` 對 kind='report' 只取 `family_members.role='owner'`；DB 測試釘住；notification_events 讀取面同步只給 owner） |
| [LS-196](LS-196.md) | Done | 2026-09-06 | size:S, lane:backend | Task：後端——Edge Function 改用新式 secret key 驗證與 admin client（purge-storage／push-dispatch／delete-account：`apikey` 比對 `SUPABASE_SECRET_KEYS`、admin client 改吃 secret key、`verify_jwt=false`）；pg_cron 改送 `apikey`——修正正式站 purge-storage 401（LS-153 i4 阻塞） |
| [LS-197](LS-197.md) | Done | 2026-09-05 | size:S, lane:backend | Task：LS-23 後端——EULA 同意紀錄（`app_settings.eula_version` 當前版本＋`profiles.eula_accepted_version／eula_accepted_at`＋`accept_eula(p_version)` RPC；欄位只准經 RPC 寫；DB 測試）——LS-190 iOS EULA 同意頁的後端前置 |
| [LS-198](LS-198.md) | Done | 2026-09-05 | size:S, lane:harness | Harness chore：LS-96 池項清倉五件——「收據 N 支」殘句統一指回 `overflow-scan.js` 檔頭（7 處）＋`pr-body-check.sh` 格式模式對純數字 SHA 候選印警告與 deny 訊息補句＋`patrol.sh` du 快取原子寫入／`--json` `sim_linear_note`／`ticket_has_worktree` memo＋`motifs.md` 角托規則對齊稿面＋`docs/API.md` §6／§10 pg_net 範本補 `timeout_milliseconds` |
| [LS-199](LS-199.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：push-gate `xcodebuild test` 看門狗——逾時（預設 25 分）與「test runner hasn't connected」／宿主 crash 偵測即中止、印 crash report 路徑與 xcresult session log 尾、釋放 simulator-lock 並 shutdown 專屬機；LS-197 R2 push 卡 28 分人工 kill |
| [LS-200](LS-200.md) | Done | 2026-09-05 | size:S, lane:backend | Task：LS-20 後端——相簿摘要 view `album_summaries`（security invoker；`visible_media_count`＋`latest_thumb_path` 只算 RLS 可見的 media；含 `cover` 解析）供相簿 tab 列表一趟讀取，取代 client 端 `album_media(count)` 連結列口徑 |
| [LS-201](LS-201.md) | Done | 2026-09-06 | size:M, lane:design | 設計 chore：全稿舊債清倉——root 板重疊 17 對重新落位（80pt 板距）＋`board_clip` document 332 筆／26 板與 `text_occlusion` 9 筆歸零（Body 補 clip 視窗或內容移入）＋多寶貝署名 AX3 行尾「·」孤符裁決；收據 `scan_scope: document` 三支 flagged 為 0 為驗收 |
| [LS-202](LS-202.md) | Done | 2026-09-05 | size:S, lane:harness | Harness：設計 gate 精修三項——`overflow-scan.js` `corner_anchor` 改以 `ref → cmp/Photo Corner` 判準（不再靠 `Corner TL/…` 名稱；`Mount TL/BR` 盲區）＋六支皆輸出 per-scan `scope` 與 `document_count`＋`design-notes-check.sh` 新增「署名年齡片語必 NBSP」機械檢查；三支 python gate 不留 `__pycache__` |
| [LS-203](LS-203.md) | Done | 2026-09-12 | size:S, lane:ui | Task：LS-20 iOS——相簿 tab 列表改讀 `album_summaries` view（`visible_media_count`／`latest_thumb_path`／`latest_storage_path`／`cover_thumb_path`／`cover_storage_path`），拿掉 PostgREST 內嵌 aggregate 與連結列計數口徑；`AlbumsContentAssembler` 退路改用 view 欄位 |
| [LS-204](LS-204.md) | Done | 2026-09-05 | size:S, lane:backend | Chore：後端測試與文件債清理（LS-96 池項四條：`107_album_summaries.sql` §6 效能斷言與措辭、`run.sh` evidence 檔頭 SubPlan 判準、107／50 共用 51200 列 fixture、`106_eula_consent.sql` 場景 6 還原值改讀暫存表） |
| [LS-205](LS-205.md) | Done | 2026-09-05 | size:M, lane:harness | Harness：模擬器 runtime 與 CI 對齊——`detect-simulator.sh` 建專屬機時選 CI 同版 runtime（`.ios-runtime` 釘住）、push-gate／CI／巡檢印出 runtime 版本並標不一致；順修 push-gate 看門狗三項（info-1～3）、`api-contract-check.sh` 納入 view（relkind v）、evidence-check 檔頭數字 |
| [LS-206](LS-206.md) | Done | 2026-09-05 | size:S, lane:backend | Task：LS-24 後端——家庭成員管理守門：唯一 Owner 且家庭仍有其他成員時不得退出（`family_members` BEFORE DELETE trigger，新錯誤碼 LS0xx，DETAIL 帶需先轉移提示）＋`transfer_ownership(p_family_id, p_to_user_id)` RPC 原子轉移（升對方、降自己同一交易；LS0xx 守門）＋DB 測試＋API.md §3／§4 |
| [LS-207](LS-207.md) | Done | 2026-09-05 | size:M, lane:harness | Harness：CI 韌性與設計 gate 盲點修補——`pr-body-check` Linear 反查加重試且 `rules` 自測步驟不依賴它、`overflow-scan.js` 角托 ref 判準改從未展開快照取對照表（`ref_hits` 哨兵）、`tap-target-check.sh` 摘要列出同輪其他紅測試、`supabase-lock.sh` 排隊可見化、COLLABORATION §7 runtime 列訂正 |
| [LS-208](LS-208.md) | Done | 2026-09-12 | size:M, lane:design, hold:user | 設計 chore：小債清倉 2——末張卡完全隱藏裝飾件 17 筆裁決、`HLXo3` `fZ3KF` 實例年齡片語 NBSP＋`cmp/Card Diary` Multi Caption 補「·」、Auth 連結 in-flight 暗化與空欄位提示 icon 語彙、深色板壓印小字 WCAG 對比量測、Notes 署名計數訂正；收據 `scan_scope: document` 六支 0 為驗收 |
| [LS-209](LS-209.md) | Done | 2026-09-06 | size:M, lane:harness | Harness：實作票 agent 防線與 push 韌性——ios-dev tools 白名單移除 `mcp__pencil__*`／禁派 fork＋patrol「Pen 開錯檔（實作票）」⚠、pre-push hook 期間 SSH keepalive（`core.sshCommand`）、CI 加 iPad 機型 job 跑 `*IPadTests`、handoff mutation 必附原文釘句、`agent-tools-check` 提示尾巴、`unused_import` 清理與規則；順修 LS-205 n1～n4／LS-207 N2～N6 |
| [LS-210](LS-210.md) | Done | 2026-09-06 | size:S, lane:ui | Task：LS-133 iOS——設定頁「法律」區兩列改開 `LegalDocumentSheet`（目前仍 `Link` 到外部 `littlesprout.app/legal/*`；LS-191 範圍 2 殘留）＋UITest 釘住設定頁入口 |
| [LS-211](LS-211.md) | Done | 2026-09-06 | size:M, lane:harness | Harness：handoff 可驗證第二波——qa／reviewer handoff 逐項對應派工單＋引用測試名須存在（grep gate）、`pr-body-check` 本機無 key 對池項候選行印 ⚠＋rerun 模板先看失敗 step、`privacy_manifest_check.py` 驗枚舉值合法性、LS-209 informational I-a／I-b／I-c 順修、24 個未用 import 清理（逐檔 build 驗） |
| [LS-212](LS-212.md) | Done | 2026-09-06 | size:M, lane:backend | Task：LS-20 後端／上傳管線——影片暫存檔與孤兒 media 清理補完（上傳失敗／中斷／App 重啟後的本機暫存、`media` 列存在但 Storage 物件缺或反向）＋EXIF 直拍照片 `media.width/height` 與 `thumb_width/height` 方向一致（依 LS-96 `d8634a08`／`66770dd0` 原文） |
| [LS-213](LS-213.md) | Done | 2026-09-06 | size:M, lane:backend | Task：LS-20 後端——孤兒媒體清理排程補完：(a) Storage 有物件但無 `media` 列（`purge_expired()` 不掃，LS-96 `996220e9`）＋(b) `media` 列存在、`deleted_at IS NULL`、從未被 `diary_media`／`album_media` 引用且超過寬限期（LS-96 `c2050d43`）→ 軟刪／入 purge 佇列＋DB 測試 |
| [LS-214](LS-214.md) | Done | 2026-09-06 | size:S, lane:ui | Fix：`TimelineStoreTests.test_refresh_secondCallWithDifferentChildID_winsOverStaleInFlightCall` 在 development c87e7b3 CI 隨機紅（LS-190 R3 m5 把 `AsyncGate` 改佇列＋第二次呼叫包 `Task` 後的時序 flake）——修測試的同步點使其決定性，並對 `EULAStoreTests` 同名 helper 複查 |
| [LS-215](LS-215.md) | Done | 2026-09-12 | size:S, lane:harness | Harness：PreToolUse 擋 ios-dev／qa 的背景 Bash（`run_in_background:true` 直接 deny）＋Monitor／背景 push 慣用形狀偵測——「不使用背景 Bash」規約落地後仍三起（LS-210 push、LS-190 R2 tap-target、LS-193 push-gate），改機械 gate |
| [LS-216](LS-216.md) | Done | 2026-09-12 | size:M, lane:ui | Task：LS-22 iOS——時間軸卡片互動列（愛心 Like Toggle＋Count Zone＋留言鈕）與按讚名單 sheet——依 LS-177 稿 `IgqGF`／`VZ0wV`／`Qzz3r`／`GZ3pb`（深色／AX3；三種卡片共用同一實作） |
| [LS-217](LS-217.md) | Done | 2026-09-12 | size:M, lane:ui | Task：LS-22 iOS——推播權限前置說明頁＋系統授權＋`register_device_token`＋設定頁「推播通知」列與權限狀態同步——依 LS-177 稿 `j7WwV`／`ckgMp`／`KyxGc`／`y7KAW`／`y66AzT`（`FeqWk` 系統對話框不實作；實機 APNs 待 LS-8） |
| [LS-218](LS-218.md) | Done | 2026-09-12 | size:M, lane:ui | Task：LS-22 iOS——留言 sheet（清單／輸入列／空狀態／錯誤態 網路＋LS026／骨架載入／Owner 移除操作表→既有二次確認；iPad 置中卡片）——依 LS-177 稿 `FiBvh`／`f10d1D`／`SHbqU`／`dHSyh`／`TnxXE`／`wY7f8`／`DUyg3` |
| [LS-219](LS-219.md) | Done | 2026-09-06 | size:S, lane:backend | Task：LS-22 後端——`push-dispatch` 通知文案依 LS-189 定案矩陣改字（`supabase/functions/push-dispatch/handler.ts:266-269` 附近）＋deno 測試同步——LS-189 handoff 未完成第 4 項（0905 補註「handler 改字另開 XS」） |
| [LS-220](LS-220.md) | Done | 2026-09-06 | size:S, lane:harness | Harness：`qa-e2e.sh` QADriver 支援 LS-190 EULA 同意 gate（登入後落在「使用條款更新」→ 點「我已閱讀並同意」再判時間軸／三岔路）＋COLLABORATION §4-b「登入後 30 秒未到落點」排障順序——解除 login／publish／browse 三情境全紅、LS-190／212 真後端 QA 阻塞 |
| [LS-221](LS-221.md) | Done | 2026-09-06 | size:S, lane:ui | Task：LS-18 iOS——`FamilyStoreJoinRequestsTests.test_requestJoin_whileSubmitting_ignoresDuplicateCall` flake（輪詢到 `.submitting` 時 stub handler 尚未被排程，`("0") != ("1")`）——改用 `AsyncGate.waitForWaiters` 同步（沿 LS-214 修法） |
| [LS-222](LS-222.md) | Done | 2026-09-06 | size:S, lane:backend | Task：LS-20 後端——`purge-storage` 孤兒掃描後續：TS／SQL 媒體路徑規則單一來源（`is_media_object_path()` 為準）＋`purge_storage_queue_enqueue_orphans` 丟棄計數回報＋`orphan_scan_cursor` 每家庭前綴分段寫回——LS-213 merge-review R2 N3／N2 收口 |
| [LS-223](LS-223.md) | Done | 2026-09-06 | size:S, lane:backend | Task：LS-20 後端——`purge-storage` 孤兒掃描收口：候選預算扣除不合法路徑（F2）、不合法路徑改計數＋樣本回報（F1）、舊 RPC `purge_storage_queue_enqueue_orphans` 標 deprecated（F3）、API.md §6 過期敘述訂正（cron 已接線／舊 vault 已刪）——LS-222 R1 F1–F3＋LS-153 sweeper 收口 |
| [LS-224](LS-224.md) | Done | 2026-09-12 | size:S, lane:backend | Task：LS-20 後端——正式站 advisors 健檢收口：4 支 `private.*` 函式補 `set search_path = ''`（function_search_path_mutable WARN）、3 張 RLS-no-policy 表（`private.purge_runs`／`notification_events`／`purge_storage_queue`）以測試釘住「刻意只給 service_role」、26 支 SECURITY DEFINER RPC 的 authenticated grant 白名單對照 API.md、Leaked Password Protection 開啟（Auth 設定） |
| [LS-225](LS-225.md) | Done | 2026-09-12 | size:S, lane:backend | Task：LS-23 後端——封鎖過濾補 reactions：`get_reaction_counts()` 與 `reactions_select` policy 加 `blocked_pairs` 述詞（A 封鎖 B 後 B 的愛心不計入計數、不出現在按讚名單；解除即恢復）＋SQL 測試——LS-149 遺漏，LS-216 merge-review R1 i1 |
| [LS-226](LS-226.md) | Done | 2026-09-12 | size:M, lane:harness | Harness：`scripts/design/overflow-scan.js` 對萬節點級 .pen 的三支 O(n²) 掃描與 tree-hash 自帶分批＋跨批配對＋加總、收據每支掃描附結果雜湊並由 `design-evidence-check.sh` 驗、`scan_note` 必填（LS-208 r5 分段手寫收據首例，merge-review R2 `e1e5157f`） |
| [LS-227](LS-227.md) | Done | 2026-09-12 | size:S, lane:backend | Task：LS-20 後端——DESTRUCTIVE：移除 deprecated `public.purge_storage_queue_enqueue_orphans(text, uuid, text[])` v1（LS-222 起零生產呼叫端，由 `_v2` 取代）＋對應 `109_` 自測與 API.md §3／§9 條目（需使用者 DESTRUCTIVE-APPROVED comment） |
| [LS-228](LS-228.md) | Done | 2026-09-12 | size:S, lane:harness | Harness：`scripts/gates/handoff-evidence-check.sh` 證據錨點白名單補 `.ts`／`.sql`／`.md` 路徑（`supabase/functions`、`supabase/migrations`、`supabase/tests`、`docs`）——backend／sweeper handoff 一日三次誤報（LS-96 `acb4e2df`） |
| [LS-229](LS-229.md) | Done | 2026-09-12 | size:S, lane:ui | Task：LS-23 iOS——`ContentActionsAX3UITests.testReportReasonSheet_ax3_allReasonsReachableAndSubmitWorks` 在 test `c5f07b9` CI 隨機紅（等「正在新增照片」StaticText 10s 逾時；delta 純 SQL、同 SHA PR run 綠）——改決定性同步點（沿 LS-214／221 修法） |
| [LS-230](LS-230.md) | Done | 2026-09-12 | size:S, lane:ui | Task：LS-22 iOS——`InteractionRowUITests.testDiaryCardIdentifier_stillFindableAndNavigates` CI 隨機紅兩起（LS-216 R3 PR run＋09-12 development push run 34668565895）——`InteractionRowUITests.swift:186` tap 後立即 `XCTAssertFalse(exists)` 無等待，改決定性同步點（merge-review R4 `4be70111` m3） |
| [LS-231](LS-231.md) | Done | 2026-09-12 | size:S, lane:harness | Harness：CI `ci`／`ci-ipad` job 在 `xcodebuild test` 失敗時上傳 `.xcresult`（`if: failure()`，保留 3 天）＋`tap-target-check.sh` 摘要印失敗測試的 assertion 行＋§4-b 補「ci 紅先下載 xcresult 看失敗行」——今日 LS-230 flake 四次 rerun 皆只靠推論裁決（LS-96 `bdf9eeae`） |
| [LS-232](LS-232.md) | Done | 2026-09-12 | size:S, lane:harness | Harness：「新增登入後全屏 gate 的票必更新 QADriver」機械化——`RootView` 全屏 gate 清單 vs `QADriver` 落點處理清單對照 gate（CI `rules`＋push gate），漏一個即紅；兩起事故：LS-190 EULA（→LS-220）、LS-217 推播前置頁（QA R1 FAIL `e4863482`） |
| [LS-233](LS-233.md) | Done | 2026-09-12 | size:S, lane:harness | Harness：`patrol.sh` PR 段 BLOCKED 分流——讀 check bucket 分「CI 跑中 N 分」／「check 全綠仍 BLOCKED＝缺必要 status → §2 貼 promote: no content diff 或派 review」／「check 紅 <名> → rerun 或修」，取代籠統「無動作（CI 沒回報？）」（09-12 兩起誤判：#365 CI 跑中被當停滯、#366 五綠仍卡 20 分） |
| [LS-234](LS-234.md) | Done | 2026-09-13 | size:M, lane:design | 設計：App Store 截圖版型——iPhone 6.9"（1320×2868）與 iPad 13"（2064×2752）各 5 張（時間軸／日記詳情／相簿／寶貝／邀請加入）：裝置框＋品牌標語＋截圖槽；標語文案定稿；匯出規格 Notes（LS-147 前置） |
| [LS-235](LS-235.md) | Done | 2026-09-12 | size:S, lane:backend | Task：LS-20 後端——`purge-storage` EF 讀 `purge_storage_queue` 加重試／退避（09-11 一次 Gateway Timeout 即整輪 500）＋正式站排程健康度腳本改看 `net._http_response` 實際 HTTP 狀態（`cron.job_run_details` 經 pg_net 永遠 succeeded） |
| [LS-236](LS-236.md) | Done | 2026-09-12 | size:S, lane:harness | Harness：殘留 `xcodebuild` 防護（Bash timeout 截斷自動背景化，push-gate／detect-simulator 開跑前偵測同 UDID 殘留行程）＋agent 定義「xcodebuild 前景 timeout 600000、分段」＋`pen-open.sh --kill` 清場後 `.pen` 寫回主 checkout 自動還原＋COLLABORATION／agent 定義過期敘述清倉（池 `4de3e796`／`797c7149`／`188ae73b`／`51bd1635`／`bab56145`／`5d6e51b6`(1)／`588c483f`／`49457773`(1)(3)／`4bbd2960`(2)／`1ae89cbd`） |
| [LS-237](LS-237.md) | Done | 2026-09-13 | size:M, lane:ui | iOS chore：小債清倉 3（無需設計稿）——上傳批次 `sortOrder` 同號＋相簿詳情離開再進不刷新（池 `4fafaa19`）、不支援格式靜默略過＋詳情永遠 ProgressView（`1aa74165`）、互動列競窗內按讚計數（`37be169f`(1)）、留言送出清空草稿／關閉中途計數不同步（`d17bed11` i3／i4）、`StubTimelineAPIClient` 按讚名單零覆蓋補測（`d4bde273`）、UITests 假綠斷言同步點（`08cad41e`(1)(2)）、Albums 過期 doc comment（`ca7ab3c3`／`0975ec67`(1)(2)） |
| [LS-238](LS-238.md) | Done | 2026-09-13 | size:M, lane:harness | Harness：規約文件去敘事化——`docs/COLLABORATION.md`（172 處「事故／教訓／R<n> F<n>」、80 處「不再／改為／已廢止」）與 `.claude/agents/ui-designer.md`（12 處）改成「規則＋一行理由＋LS 指標」，一檔一 PR、`agent-tools-check`／`brand-skill-check` 釘住字句重驗（prompt-audit 0912 F8） |
| [LS-239](LS-239.md) | Done | 2026-09-13 | size:S, lane:harness | Harness：orchestrator context 減量三項（使用者 09-13 裁決）——①巡檢 cron 模板改由 subagent 跑 `patrol.sh` 只回傳動作清單／⚠ 旗標／「無異常」；②「orchestrator 不直接讀大檔（>4 KB／tasks output／handoff／comment 串）一律派 Explore 回結論」規則＋§7 記「暫無 gate」；③SessionStart hook 與 §4-b「先 CronList 確認再 CronCreate，已有不重建」（同步 `patrol-mechanism.md`） |
| [LS-240](LS-240.md) | Done | 2026-09-12 | size:S, lane:backend | Task：LS-146 後端——`review-demo-seed.sh` Storage 上傳段加暫時性錯誤重試（curl 56／5xx／逾時，3 次退避）＋`--storage-only` 續傳（DB 已是本輪資料時只補缺的物件）＋`psql` 偵測補 `/opt/homebrew/opt/libpq/bin`（池 `3f23757a`） |
| [LS-241](LS-241.md) | Done | 2026-09-13 | size:S, lane:ui | Task：LS-22 iOS——日記詳情頁留言區改接互動列＋留言 sheet（移除 LS-126 占位「留言功能即將推出」） |
| [LS-244](LS-244.md) | Done | 2026-09-13 | size:S, lane:backend | Task：LS-20 後端——正式站 Storage 部署驗證腳本 `scripts/ops/prod-storage-verify.sh`（PLAN §5 三條「本機測不到、`db push` 綠燈不能取代」清單機械化：`storage.prefixes` RLS／`owner`＋`owner_id` 填值／`storage.buckets` policy 數＝0；唯讀、比照 `prod-purge-health.sh`） |
| [LS-245](LS-245.md) | Done | 2026-09-13 | size:S, lane:ui | iOS chore：小債清倉 4（無需設計稿）——`InteractionRow` iPad 窄寬留言計數截字（池 `5824399c`）、詳情頁三個 sheet 來源收斂為單一 `sheet(item:)`（`7f77856c`）、`SettingsViewIPadTests` 第三支舊同步寫法（`2c4bfc80`）、`StubCommentAPIClient.setSetCommentDeletedHandler` 無呼叫（`38a3c74b`）、TapTargetGate 兩處 stale 註解 |
| [LS-254](LS-254.md) | Done | 2026-09-13 | size:S, lane:harness | Harness：worker agent 的研究 fork 越權執行——`subagent_type: fork` 繼承父 agent 全文脈絡（含派工單）後平行執行整項任務（LS-234 R7 同一 .pen／branch 雙寫），本 session 第 3 次；PreToolUse hook 對 subagent 內的 `Agent` 呼叫限制 fork／規定研究用 Explore＋agent 定義補規則 |
