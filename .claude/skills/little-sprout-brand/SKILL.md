---
name: little-sprout-brand
description: Little Sprout（萌芽日記）設計語言定案——LS-46 十一輪對抗審查後使用者核可的 tokens（色票含深色錨點與實測對比、字級跳階、間距 8/16/24/44）、蠟筆字標與品牌規則、沖印品母題（白邊／角托／染料池）、長輩硬約束、專案版 slop 禁例、實作票進場條件 12 項。ui-designer 與 visual-reviewer 開工必載。任何要畫、審、或對照設計稿實作 Little Sprout 畫面的工作（新畫面、改版面、design token、mockup、.pen 視覺審查、SwiftUI 對照 design/littlesprout.pen）都先讀這份，即使只是「調個顏色」「加一顆按鈕」——本專案的顏色與按鈕都有規則。
---

# Little Sprout 設計語言（定案版）

定案來源：`design/littlesprout.pen`（LS-46 R11 APPROVE，HEAD `651a9ff`，2654 節點；LS-72 補 Tokens 板實測值後現況 **2676 節點**——基線隨最新 landing 更新，見 COLLABORATION §7 design-landing 列）。本 skill 是它的文字鏡像——**稿與本檔衝突時以稿為準，並回頭修本檔**。

## 靈魂（一句話）

> 照片是一件被印出來、被角托黏在相簿台紙上的實體沖印品；UI 是它躺著的那張台紙。整個 app 只有一條「褪色相紙的染料階」（青染料先死、老照片偏洋紅）、只有一盞窗光。

由此推出的三個記憶點（reviewer 自己寫得出、不是設計者宣稱）：①白邊＋壓印小字＋四角托＋染料池的沖印品母題；②「紙不會變黑」——紙上的墨不隨深色模式反轉，是可掃描的 token 規則；③「不因驗證未通過而 disable」在版面留下痕跡（即時回話列、空欄位卡不塌縮）。

## 何時讀哪份

| 你在做什麼 | 讀 |
|---|---|
| 取色、字級、間距、圓角、icon 尺寸、對比數字 | `references/tokens.md` |
| 字標「萌芽日記」、LITTLE SPROUT 小字、App icon、深色紙條 | `references/wordmark-brand.md` |
| 排一張新畫面、放一張照片、決定要不要角托／白邊／主鈕 | `references/motifs.md` |
| 長輩可用性（對比、點擊、Dynamic Type、a11y） | `references/elder-constraints.md` |
| 視覺審查、自我檢查「這是不是 slop」 | `references/slop-forbidden.md` |
| 實作票開工前檢查 | `references/entry-conditions.md`（LS-46 comment `ba6dbabb` 12 項原文） |

## 十條不可協商（各 reference 的濃縮）

1. **一畫面一顆實心主鈕**：`$accent` 是唯一的「識別」飽和色，每畫面最多一次實心；danger 不做主鍵、success 一流程一次、連結一律墨色＋底線。
2. **紙不會變黑**：`$print-paper` 深淺兩模式都是淺色（#FBEBEC／#E8D9D4）；紙上文字一律 `$print-ink` #2B141C／`$print-ink-secondary` #553040——**不掛 theme 的單值 token**，Asset Catalog 的 Any／Dark 填同值。
3. **沖印品白邊 8/8/8/8**（`$print-edge`＝`$print-edge-bottom`＝8，兩 token 同值但刻意不合併），下緣視覺厚度 32＝8＋7＋Imprint Row 17，由壓印那行字「掙來」，不是 padding 調出來的。
4. **角托三段規則**：四角托＝這是一張沖印品（只有家人的照片）；兩對角托＝同一張紙縮到 ≤60pt（App icon）；零角托＝不是沖印品（表單、邀請碼卡——會過期的東西不是收藏品）。角托一律壓過紙緣 `corner-out` 5pt。
5. **間距只有一套節奏**：8／16／24／44（群內／群間／段落／章節）＋輔助 6／12；每畫面必須出現一次 44 章節斷點（碼輸入家族 7 張具名豁免）。任何不在節奏上的數字都要有主人（具名豁免），沒有主人的是「倒推餘數」＝缺陷。
6. **字級七級跳階**：display 34／lead 22／body 17／note 17／meta 13／otp 36／code 60，全走 Dynamic Type；唯一例外 `fs-imprint` 12（印在紙上的字不長大）。**13pt 只給「不讀也能完成任務」的內容**；寫著「還可以用幾次／有效幾天／錯在哪／要怎麼改／你是誰」的字一律 ≥17。
7. **長輩硬約束**：文字對比 ≥4.5:1（內文目標 7:1 AAA）、點擊 ≥44pt、每張重要畫面必附 AX3 壓力板、字標與圖片帶 a11y metadata、icon 一律帶文字標籤、不用進階手勢。
8. **驗證型 disable＝0**：按鈕只在 in-flight 才 disable；「還沒做完」用 `$text-primary`＋circle-alert 的即時回話列，不用 danger 責備使用者。錯誤同時用形（邊框）與字說明，不靠顏色單獨承載；語氣先講發生什麼、再講怎麼辦。
9. **漸層只有兩道**（窗光、角托染料池），各有物理出處；說不出出處的漸層不畫，按鈕零漸層，禁紫藍 hero。壓在漸層上的字以最不利點量對比。
10. **狀態切換不搬動版面**：同一畫面的不同狀態（01→01b、空欄位→有值）只准差該狀態該有的東西；印品幾何、字標、按鈕座標一律不動；空狀態的卡片高度不塌縮。

## 數字速查

- 深色 accent 錨點：生產值 **#FCA4B5**；**#E3A9C4** 只是 D 軌歷史對照，無生產角色。
- 字標：蠟筆四字等大「萌芽日記」，B 版式——**標題列 190pt**（iPhone，高 90.6）／247pt（iPad，1.3×）；tagline `$fs-body` 17 `$text-secondary`，字標→tagline `$sp-label` 8。深色（01c）字標＋tagline 坐在與相片同寬 361 的 `$print-paper` 紙條上（高 136.6）。
- 「LITTLE SPROUT」小字：`fs-imprint` 12／字距 3.5／`$print-ink-secondary`／**只在歡迎頁家族相片白邊、水平置中**，其他 UI 不得出現英文名。
- App icon＝**photo-stack**（三張扇疊照片；`design/app-icon-photo-stack.png` 1024）。「芽」字 icon 概念已被使用者否決。
- 實測對比（WCAG 2.1，淺／深）：print-ink on print-paper **14.92／12.55**；print-ink-secondary **9.66／8.13**；text-primary on bg 12.21／15.31；text-secondary 7.91／9.41；on-accent 7.30／9.99。
- Legal／Status 槽 **38pt** 固定高（01／01b／01c 共用；AX3 折行 64 不套槽）。
- 邀請碼：**6 碼、32 字元表（排除 0／O／1／I）、30 bit、3+3 分組、核准必開**（使用者 2026-08-25 裁決 LS-89；後端 LS-90 對齊中——現行部署仍 8 碼／40 bit，**LS-90 併入前設計稿不得改 8 格**）。八格應變規格（`fs-otp` AX3 52→42、`fs-code` 60→52、單一 tap target）是已擱置備案，見 `references/motifs.md` 邀請碼。
- 已知溢出白名單：R11 基線 51 項（出血 13／角托 34／`mXQJh` 1／AX3 法務 3）是設計意圖；**LS-72 後現況 nodes 2676／FLAGGED 50**（−1 LS-72 自述不可歸因、未獨立複驗）。自動化版面檢查以**最新 landing 的實測值**為白名單基線（基線隨最新 landing 更新，見 COLLABORATION §7 design-landing 列），不要寫死 51。

## 不包含（另有出處）

- Pencil MCP 的工具限制與繞法（`Insert()` 只建空殼、`height` 丟 `$variable`、`flipX` 錯位…）→ agent 定義（LS-44）。
- 設計流程規則（≥3 輪迭代、聚焦輪、換軌後重跑驗收集、收工程序）→ `docs/COLLABORATION.md` §4 與 agent 定義（LS-68）。

## 使用方式與更新

- ui-designer：開工載入後，設計每個取捨都對照「十條」；handoff「skill 影響了哪些取捨」欄要寫得出本檔哪一條左右了決定。
- visual-reviewer：通用 slop 十條之外，逐條對照 `references/slop-forbidden.md`；每條 finding 註明違反本檔哪一條或哪個數字。
- ios-dev：實作前先清 `references/entry-conditions.md` 12 項；token 名稱與值以 `references/tokens.md` 為準，節點 id 一律以合併時 HEAD 重新解析。
- 動了 Tokens 板或母題規則的設計票，**同一 PR 更新本 skill**——這裡標「待補（需 Pen）」的值，就是下一張設計票該回填的。
