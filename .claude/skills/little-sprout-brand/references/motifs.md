# 母題與構圖規則（相簿紙語言）

跨畫面的識別靠三件實體物：①相片角托 ②沖印白邊 ③角托染料池。三者是同一條規則的三個面：**角托決定哪裡有池，白邊決定那是不是一張可以拿起來的紙。** 出處：Tokens 板 ⑥、LS-46 R3–R11 審查 comment、LS-72。

## 沖印品 Print（白邊＋壓印行）

- 結構（由外而內）：台紙（`$bg`＋窗光）→ 紙（`$print-paper`，1pt `$paper-edge` 亮邊，`$paper-shadow` 右下影）→ 照片（Photo Wrap，`clip:true`）→ 壓印行 Imprint Row → 角托（最上層，壓過紙緣 5pt）。
- 白邊 padding 一律綁 `$print-edge`／`$print-edge-bottom`（`["$print-edge","$print-edge","$print-edge-bottom","$print-edge"]`），**不是** `$sp-label`（LS-72 F8 改掉 12 張）。四邊解析 8/8/8/8；下緣視覺 32＝8＋gap 7＋Imprint Row 17＋8，厚度由壓印那行字掙來，不要當成 padding 去調。
- Print 一律 `fit_content`，**板高跟著內容走，不從板高倒推 Print 高**（R9-B：倒推出的 63.9 白邊沒有主人；R10 修正後八張 Print 全部閉合 230.1／iPad 582）。
- 照片出血：Hero Photo 刻意大於 `clip:true` 容器，靠 frame 裁出構圖（01 家族 345×190.1 的窗、Hero 本體 345×515 y−84）。這類 partially clipped 是設計意圖，計入已知 51 項白名單。
- 壓印行內容：歡迎家族＝「LITTLE SPROUT」（置中、fs-imprint）；建立家庭＝家庭名 Family Caption（`$print-ink`，超長以 `.lineLimit(1).truncationMode(.tail)` 真截斷）；空欄位態＝單一空白 `" "`（保住 Imprint Row 32pt 行高、卡高 175 不塌縮，**不可整列隱藏**）。
- 空白沖印品（`H0KHI` 同構）用來填 02／02b／05／05b 的大片空洞——延續母題，不是裝飾。

## 角托三段規則（R4 起有文法）

| 段 | 角托 | 誰 |
|---|---|---|
| ① 四角托＝這是一張沖印品 | 4 | 使用者會收藏、會再看第二次的東西。全 app 只有**家人的照片**：01／01b／01c／01-iPad／04／04-iPad／A11y-04／07a 範例沖印品 |
| ② 兩對角托＝同一張紙縮到 ≤60pt | 2 對角 | App icon 實機尺寸；對角保留「被裱住」的剪影，且對角正好是窗光最強與最弱的兩端 |
| ③ 零角托＝不是沖印品 | 0 | 一次性表單、橫幅、設定列、印在卡片上的照片。**邀請碼卡／邀請碼輸入卡**：會過期、有次數上限、用完就作廢——會過期的東西不是收藏品。撤角托時連四顆染料池一起撤：沒有角托的紙沒有池 |

- 角托一律壓過紙緣 `corner-out` 5pt（iPhone／iPad／深色紙條接縫皆守；01 家族 corner y＝print y−5）。**LS-81 對帳中**：`aw57e` 實測 TL 3pt／BL·BR 10pt 與 5pt 慣例不一致，以 LS-81 結論為準。
- 角托是四方位變體（TL／TR／BL／BR），**禁用 flipX／flipY**（Pencil 渲染錯位）。摺光 `$corner-fold` 光源一律左上。
- 深色紙條（01c）：上兩顆角托壓在紙條與相紙接縫上，把兩張紙釘成一個物件。

## 染料池 mount-pool

- 每顆角托一顆，R＝角托邊長×3，opacity＝0.03＋0.50×lit(角座標)；lit 以 viewport 座標算（窗光在 55,17，橢圓 668×1150）。池深＝那個角的光強度——規則自己執行自己。
- 池畫在紙層、不覆蓋照片本體；冷色照片（F16 壓測）幾何上不可能被污染。地板 0.03（等於「這裡沒有落差」）；0.08 在 iPad 上會變一層假的均勻粉霧。
- Lab Imprint 置中是為了避開池的暗角（深色 α≈0.36 時 print-ink-secondary 掉到 3.47:1）。

## 一畫面一顆實心主鈕

- `$accent` 實心每畫面最多一次（全稿掃描 solid=1／ink=0）。歡迎頁 0 次實心 accent——Apple 鍵是黑、Google 是白、Email 是外框。
- 其餘按鈕：外框鈕 `$surface`＋`$control-line`＋`$text-primary`；in-flight 時非主鍵轉 `$surface-2`（換 token，不用 opacity）。
- 07b 兩筆核准同權重（都外框），不誘導長輩按最醒目的那顆。
- 06 家族 Upper／Footer 用 flex spacer（`height:fill_container` 置於 Upper 末尾、Body 不用 `space_between`），把「改用貼上邀請連結」永遠釘在拇指區；不許魔術數 spacer（232／100）。

## 章節斷點 44 與畫面高度

- 每畫面必須出現一次 `$sp-section` 44（真 gap 或 padding 皆可）；實建 18/25，**碼輸入家族 7 張具名豁免**（06／06b／06c／06d＋03 家族 3 張），Tokens 板 `JkWvW` 與 Handoff `t4ZGwX` 兩處措辭一致。
- 畫面宣告高＝內容高（slack ≤0.4；iPhone 852、01 AX3 1073、06 AX3 1297）。虛構留白（R7 `DW9PE` 767pt spacer）與底部死空間（R9 57.55）都是缺陷。
- Print Stage 三個值各自組成要照抄（見 entry-conditions ⑤）：01／01b 292、01c 424.6、AX3 296。

## Legal／Status 槽 38pt

- 01／01b／01c 共用固定高度插槽 38（`Legal / Status Slot`）：01 放法務行（`fs-meta` 13，連結墨色＋底線），01b 放狀態句「正在與 Apple 確認你的身分，請稍候。」（`fs-note` 17／600，節點名 `Signing Status`）——**取代非併存**。
- AX3 法務行會折行成 64pt，**不套 38 槽**；SwiftUI 用 `AttributedString`／`Link`＋`ViewThatFits`，勿照抄 .pen 的四段排列。
- 狀態句不得降到 13pt（13pt 成員資格規則）。

## 狀態切換不搬動版面

- 01→01b 只准差三件事：Apple 鍵換 in-flight（loader-circle＋「登入中…」）、Google／Email 轉 `$surface-2`、法務行換狀態行（同一插槽）。印品幾何、字標、tagline、信任列、按鈕座標一律不動——兩板逐像素差異必須全部落在 pt 589 以下的四條帶內。
- 5.25pt 的相片縮、12.4 的節奏 gap 都算缺陷；「因為變小就過」不成立。

## 錯誤文法四層（`k2Mw4`，全稿統一）

1. 輸入元件邊框 → `$danger` 2pt（欄位框或全部六格 OTP）。
2. 錯誤行：circle-alert 18pt danger＋訊息 `fs-note` danger 600，緊貼輸入下方。
3. 後續動作：主 CTA 維持 accent 實心＋次要文字 `$text-secondary` fs-note。
4. 政策行：純 `fs-note` `$text-secondary`（時限行用 `$text-primary`），無 icon／色／框。

語氣＝D 的對話視角（先講發生什麼，再講怎麼辦）、C 的句長。OTP 輸錯保留輸入＋計次（「還可以再試 N 次」），不清空；「請家人重新產生」這類 app 做不到的假 CTA 不畫。

## 邀請碼

- **位數以後端契約為準：8 位、32 字元字母表** `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`（只排易混的 0／1／I／O，Crockford 式；保留 Q／L）＝ 8 × 5 bit ＝ **40 bit**。`create_invite` 已上線（`supabase/migrations/20260823010000_join_approval.sql`），`supabase/tests/80_join_approval.sql` 以 `^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$` 釘死——**不是** 6 位。
- **6 位方案已擱置（31 bit 不足）**：6 位英數上限 36^6 ≈ 31 bit，稿上 `h7EnT`【R2】自己算過「若需維持 40 bit，6 位英數不可能達成」；R2 提的 30 字元集（另排 Q／L）× 6 位更只有 29.4 bit。被擱置的是「6 位」這個位數；排除易混字元的原則後端採用了。
- **與 LS-46 定案的偏差（明寫，不掩）**：使用者 2026-08-23／08-25 的定案文字是「邀請碼 6 碼」，稿上 06 家族至今仍是 6 格 3+3（設計早於後端定案的既有落差）。本 skill 裁定：**後端 40-bit 為準，設計以下列八格應變規格為現行**；任何邀請碼畫面票實作前必須先把 06 家族轉八格。此偏差由 orchestrator 回報使用者確認；若使用者維持 6 碼，改的是後端契約與測試（另票），不是把本段改回 6 位。
- **八格應變規格**（稿上 `h7EnT`【R6】原文要點；改稿與實作照抄，不必再開一輪設計）：
  - ① 格寬：卡片內寬 305（345 − 2×`$inset-card` 20）。六格＝(305 − 5×8)/6＝44.17（gap `$sp-label` 8）；八格改 **4+4 分組**：格間 gap 降到 `$sp-tight` 6（6 道）＋中間一道分組間隙 `$sp-item` 16，格寬＝(305 − 6×6 − 16)/8＝**31.63**。分組間隙是版面元素不是格線，AX 下不放大。
  - ② 字級：`fs-otp` 36 不動（Courier Prime 數字前進寬 ≈0.6em＝21.6，格內扣 2pt 邊框剩 27.6，左右各餘 3.0）；**AX3 由 52 降到 42**（52 會爆：31.2 > 27.6；42＝25.2，左右各餘 1.2）。這是八格唯一需要改的 token 值。
  - ③ `fs-code`（07／07b 顯示用大字；寬＝n×(0.6·fs＋4)＋16，letterSpacing 4）：60 在八位時 336 > 內寬 305、無安全邊界；**八位時降到 52**（297.6，餘 7.4），AX3 亦 ≤52。（六位時 AX3 76 溢出 8.6 已降 72，見 tokens.md `fs-code` 待補。）
  - ④ **單一 tap target 是前提，不是附註**：六格與八格都是「一個隱形輸入框＋N 個顯示格」，整列是單一 tap target（高 72 ≥44）；31.63pt 的格子本來就構不成 44pt 命中目標，實作不得把每格做成獨立按鈕。
  - ⑤ 切換成本：「一個 cellCount＋兩個 AX3 字級值」，六格與八格共用同一張卡、同一個 72 高、同一條錯誤態文法；真正要重畫的只有 07／07b 的顯示碼與分享文案裡的示例字串（現稿 6 位「K7M 2FD」要換成 8 位示例）。
- 邀請碼輸入**分組**（人傳人念／聽／打）與 OTP **六等格**（系統自動填、iOS 原生語彙）不同是刻意的（`FLYU5`）；OTP 維持六格，不隨邀請碼位數變。
- 06 主稿只留一行 `fs-meta` 摘要「送出後要等管理者核准」，完整三行「接下來會發生什麼」預告表在 06d 等待頁；核准必開（固定文案，不畫開關）。
- 邀請碼卡零角托、零染料池（會過期的東西不是收藏品）。

## 壓測板是母題的一部分

每個母題主張都要有壓測板才算成立：AX3（01／06／07）、超長家庭名（Stress-05）、空欄位、冷白日光燈與夜間閃光照片（F16 `tNqvY`／`Rtq1m`）。沒有壓測板的主張只是修辭。
