# Tokens（色票／字級／間距／尺寸）

來源：`design/littlesprout.pen` Tokens 板（設計語言 v3.3・褪色相片粉調，LS-46 R3 起；LS-72 補 print-edge 兩列與 print-ink 對比欄）、LS-17 spec 抽出的 `tokens.json`（Asset Catalog Any／Dark 值）、LS-46 R10／R11 與 LS-72 審查 comment 的實測數字。**所有對比值為實測（WCAG 2.1 相對亮度），一律以各自的最不利點計。** 標「待補（需 Pen）」者本檔不猜，下一張動 Tokens 板的票回填。

## ① 色彩 Color

色彩極度稀缺。中性階本身就是粉——每一階 B ≥ G（rose 家族，色相 334–356°），不是米色上加粉紅濾鏡。照片是全 app 唯一不粉的東西。

規則三句（可驗證）：
1. `accent` 是唯一的「識別」飽和色：只有它承載品牌、也只有它能做實心主動作，**每畫面最多一次**。撐住它的是配額，不是色值。
2. `danger` 的彩度與 accent 相同是刻意的（功能色被忽略比被誤認更危險）；深色不宣稱彩度相等，改宣稱色相分離（淺 34.0°／深 30.6°）與角色分離——danger 不參與識別、不做主鍵、永遠不與 accent 在同一畫面同時擔任主要動作。
3. `success` 一個流程只出現一次（06d「申請已送出」的勾勾），好消息說一次就夠。

錯誤永遠同時用形（邊框）與字說明，不靠顏色單獨承載。「還沒做完」不是錯誤：06 的「還要再填 1 個字」與空欄位的行內回話都是 `$text-primary`＋circle-alert，不用 danger——用錯誤色責備一個還沒做完的人，是把提示寫成判決。

### 主表（淺色 light／深色 dark；對比欄為淺／深）

| token | light | dark | 角色 | 實測對比 |
|---|---|---|---|---|
| `bg` | #EDD3D6 | #190E12 | 頁面底色＝窗光漸層的暗端。所有文字對比都以它計 | B−G＝+3／+4（rose） |
| `bg-lit` | #F5E1E3 | #251419 | 窗光漸層的亮端（左上受光處） | 兩端比 1.13／1.07 |
| `surface` | #FBEBEC | #2E1C22 | 紙面：卡片、輸入框、外框鈕內側 | 對 bg 1.22／1.17（浮起） |
| `print-paper`（R4） | #FBEBEC | **#E8D9D4** | 相片白邊／沖印品相紙背景，獨立於 surface，**不隨關燈變黑** | 淺與 surface 同值；深自訂暖米白 |
| `print-ink`（R10） | #2B141C | #2B141C | 紙上的墨（Family Caption 等）：**不掛 theme 的單值 token**，任何模式皆＝淺色 `$text-primary` 值 | 對 print-paper **14.92／12.55** |
| `print-ink-secondary`（R10） | #553040 | #553040 | 紙上的墨（Lab Imprint 等）：不掛 theme 的單值 token，任何模式皆＝淺色 `$text-secondary` 值；Lab Imprint 為裝飾性文字，標 accessibilityHidden | 對 print-paper **9.66／8.13** |
| `surface-2` | #E4C8CD | #3B252D | 凹陷／次級填色。規則：只承載 text-primary 與 text-secondary；也是 in-flight 時非主鍵的「轉暗」色 | ink 11.02／11.45・ink-2 7.14／7.03 |
| `border` | #BC969D | #5E3D47 | 純裝飾髮絲線與分組線。不承載意義，申報豁免 3:1 | 1.86／2.01 |
| `control-line` | #8A6470 | #9B7580 | 有意義的邊界：輸入框、外框鈕、焦點框 | 3.60／4.72（≥3 ✓） |
| `text-primary` | #2B141C | #F6E3E5 | 主文字／墨。褪色相片的暗端＝桑葚墨 | 12.21／15.31 AAA |
| `text-secondary` | #553040 | #D3AEB2 | 次要文字 | 7.91／9.41 AAA |
| `accent` | #8E2447 | **#FCA4B5** | 唯一的「識別」飽和色。每畫面最多一個實心主動作。淺 L* 32.85／C* 46.84／h 6.3°、深 L* 76.43／C* 35.02／h 7.9°（深色 35.02 已是該亮度 sRGB 色域上限的 95.0%） | on-accent 壓它 7.30／9.99 AAA |
| `accent-anchor(D)` | —（角色：無，歷史對照） | #E3A9C4 | 2026-08-24 使用者定案：深色 accent 兩錨點一併鎖定。本檔生產值為上列 #FCA4B5；**#E3A9C4 留作對照錨點，非生產值**（LS-46 R2 覆核：判定無生產角色——「一畫面一實心 accent」與「焦點語彙全稿唯一綁 `$accent`」兩條既有規則讓它沒有合法空位，硬塞角色是為了讓它有事做） | — |
| `accent-soft` | #F6DDE2 | #3A2028 | 淡玫瑰填色：badge、icon 底 | ink 13.41／12.02 AAA |
| `on-accent` | #FBEBEC | #190E12 | 壓在 accent 上的字 | 7.30／9.99 AAA |
| `danger` | #6B1809 | #FFA48F | 錯誤。唯一家族外的色相（磚紅 hue 9 vs accent hue 340） | 8.46／9.85 AAA |
| `success` | #1E4732 | #82C79E | 成功語意，一個流程最多用一次 | 7.44／9.54 AAA |
| `photo-corner` | #C89AA3 | #6E4E59 | 角托紙。裝飾，不承載狀態，申報豁免 3:1 | 2.11／2.22（板上 `WEjnC` 原文；此列量測底是 `$surface`，對 `$bg` 為 1.73／2.60——與同表其他列基準不同，板端待下一張動 Tokens 板的票統一） |
| `corner-fold` | #FBEBEC8C | #F6E3E559 | 角托的摺光。光源一律左上 | 裝飾 |
| `paper-shadow` | #2B141C2E | #00000073 | 紙落在頁面上的影。方向永遠右下（光在左上） | 裝飾 |
| `home-indicator` | #2B141C59 | #F6E3E573 | Home indicator | 系統 |
| `apple-bg` / `apple-fg` | #000000 / #FFFFFF | #FFFFFF / #000000 | Apple 登入鍵。HIG 規範，色值不得改 | 21.00 |
| `google-bg` / `google-fg` | #FFFFFF / #1F1F1F | #131314 / #E3E3E3 | Google 登入鍵。Google 品牌規範，色值不得改 | 16.48／14.47 |
| `google-line` | #747775 | #8E918F | Google 鍵外框（品牌規範）；G 標四色 #4285F4／#EA4335／#FBBC05／#34A853 不得取用為 UI 色 | 4.53／5.83 |
| `on-photo` | #FBEBEC | #FBEBEC | 壓在照片／印相罩上的字。兩個模式同一個值——照片上永遠要淺色 | 7.36／8.71 AAA（板上 `sQsj1` 原文標「印相罩最不利點」，但印相罩 R4 已除役；數字實為深色套 `$photo-dim` 後的最不利點，複算 8.65——標籤過期、數字有效，板端待修） |

### 其他（Asset Catalog 有、板上主表之外；值出自 `tokens.json`）

| token | light | dark | 角色（出自審查 comment） | 實測對比 |
|---|---|---|---|---|
| `mount-pool` → `mount-pool-0` | #B5828D → #B5828D00 | #0D0609 → #0D060900 | 角托染料池 radial 的兩端（見 ② 漸層） | 深色 α≈0.36 時 print-ink-secondary 會掉到 3.47:1——Lab Imprint 必須置中避開暗角 |
| `paper-edge` | #FFF7F8 | #432932 | 沖印紙的 1pt 亮邊（堆疊順序：台紙 → 紙（1pt paper-edge）→ 角托） | 待補（需 Pen） |
| `photo-dim` | #FFFFFF00 | #190E122E | 深色模式照片「少一格光」的罩（相紙不會在晚上一樣亮） | 待補（需 Pen） |
| `disabled-fg` | #9F878C | #716366 | **只給 in-flight**（Button Working）；驗證型 disable 全稿為 0 | 待補（需 Pen） |
| `knob-edge` / `knob-shadow` | #8A6470 / #2B141C4D | #D3AEB2 / #00000073 | 開關把手描邊／影（核准開關已改為固定 Approval Status，token 留存） | 待補（需 Pen） |
| `switch-knob` / `switch-off` | #FFFFFF / #E4C8CD | #190E12 / #3B252D | 同上 | 待補（需 Pen） |

### 已除役（表上只為記錄，不得再引用）

`accent-text`（#74193A／#F4A8B6，R1「accent 當文字」的 AAA 版，07b 改 `$control-line`／`$text-primary` 後零使用點）、`mount-edge`（#EFD7DA／#231318，R3 改四顆染料池後無人用）、`scrim-ink`／`scrim-fade`（印相罩；R4 全 app 不再有系統 chrome 壓在照片上）、`inset-mount`。

## ② 漸層 Gradients——只有兩道，各有出處（R4：三收成二）

規則：**說不出物理出處的漸層不畫。禁止紫藍 hero 漸層、按鈕漸層、為了好看而加的漸層。** 壓在漸層上的文字一律以漸層最不利點量對比。

| 名稱 | 色標 | 出處 | 量測 |
|---|---|---|---|
| 窗光 window-light（radial） | `$bg-lit` 0 → `$bg` 1.0；圓心距左上 55／17pt；橢圓 668×1150pt | 光從左上的窗戶落在攤開的相簿頁上。整個 app 只有這一盞光，所以每一片紙的影子一律往右下。**尺度是實體尺度不是百分比**：同一盞光在 iPhone／iPad 上一樣大，不隨畫布縮放 | 兩端比 1.13（淺）／1.07（深）；全部文字對比以暗端 bg 計 |
| 角托染料池 mount-pool（radial × 角托數，每顆角托一顆） | `$mount-pool` 0 → `$mount-pool-0` 1.0；R＝角托邊長×3（正圓）；opacity＝0.03＋0.50×lit(角座標) | 角托遮住的那個角染料留了下來，顏色最深；每顆池子的深度＝那個角的光強度——同一個 lit() 同時決定背景漸層與四角池子。座標系＝viewport（裝置），靜態稿一律「首屏落點」 | lit(p)＝max(0, 1−hypot((x−55)/668, (y−17)/1150))；地板 0.03（＝「這裡沒有落差」）、幅度 0.50；01 相紙實測 TL/TR/BL/BR .494/.288/.360/.236 |

負規則同時成立：照片不再需要罩，因為照片不再墊在系統元件底下。池只畫在紙層，相片圖層不透明蓋住——冷色照片「幾何上不可能污染」。

## ③ 字級 Typography

完整七級，全走 Dynamic Type（右欄是 AX3 值）。分三組讀：一般文字（display／lead／body）→ 等寬數字（otp／code）→ 狀態與註腳（note／meta）。稿面字型 Noto Sans TC／Courier Prime 是 Pencil 替身；**實作一律系統字型**（保 Dynamic Type），數字用 `.monospacedDigit()`。

| 階 | 預設 | AX3 | 用途（每畫面配額） | 實作 |
|---|---|---|---|---|
| `fs-display` | 34 | 55 | 畫面標題。每畫面 1 個，不重複 | `.largeTitle` / `.bold` |
| `fs-lead` | 22 | 44 | 唯一主卡標題或區塊標題。每畫面最多 1 個 | `.title2` / `.bold` |
| `fs-body` | 17 | 40 | 正文、按鈕標籤、欄位值、清單列。主／次以字重＋色分 | `.body` |
| `fs-otp` | 36 | 52 | OTP 六格數字（等寬）；也是邀請碼輸入格的字級——**八格（4+4）時 AX3 須降 52→42**（`h7EnT` R6 ②，見 motifs.md 邀請碼） | `.system(size:).monospacedDigit()` |
| `fs-code` | 60 | 72（Tokens 板格子 `F7Swz6`；`$fs-code` size=ax3 變數仍是 76——**落後的是變數**：`h7EnT`④「六位 AX3 76 會溢出 8.6，已降 72」。**待補（需 Pen）**＝下一張開 Pen 的票把變數改成板上值） | 邀請碼大字（等寬；**8 位 4+4 分組時 60→52、AX3 ≤52**——`h7EnT` R6 ④，見 motifs.md 邀請碼） | `.system(size:).monospacedDigit()` |
| `fs-note` | 17 | 40 | 使用者**必須讀**的次要文字：錯誤、載入中、輸入指示、核准依據（申請人 email／身分／等待時間）。與 body 同為 17 是刻意的——分兩個 token 是為了讓實作區分角色：note 一定伴隨狀態色或狀態圖示 | `.body`＋狀態色（錯誤用 danger） |
| `fs-meta` | 13 | 33 | 只剩三類（`NHDwj` 原文）：①法務行（登入即表示…）②微標籤（邀請碼／加入申請這種放在 60pt 主體上方的眉標）③設計註記（游標位置）。其餘一律升 note | `.footnote` |
| `fs-imprint` | 12 | 12（固定） | 沖印廠牌壓印 LITTLE SPROUT，字距 3.5；**唯一不吃 Dynamic Type 的一級**——它是那張相紙的一部分，不是 UI。代價：不得承載任何唯一資訊；`.accessibilityHidden(true)` 或併進相片 alt 尾段，二選一不得兩者皆無 | 固定 12pt |
| （設計註記） | 13 | — | 「▸…（設計註記）」斜體：給 ios-dev 看的稿面說明，不是 UI 文字，不要實作 | — |

**13pt 的成員資格（規則，不是慣例）**：13pt 只給「不讀也能完成任務」的內容。任何寫著「還可以用幾次／有效幾天／錯在哪裡／要怎麼改／你是誰」的字一律 ≥17。狀態句（如「正在與 Apple 確認你的身分」）必須 ≥ `fs-note` 17，不得降到 13。

## ④ 間距節奏 Spacing Rhythm

一套節奏，四個鈕：**群內 8**（標籤↔欄位、圖示↔標籤）、**群間 16**（同層項目）、**段落 24**（區塊之間）、**章節 44**（一個畫面的兩個章節之間——每一個畫面都必須出現一次；實建 18/25，碼輸入家族 7 張具名豁免：06／06b／06c／06d＋03 家族 3 張）。輔助兩個：sp-tight 6（詞內光學）、sp-group 12（同一段文字內部）。R3 起 sp-inline 10 已刪（與 8／12 在畫面上不可分辨）。

| token | 值 | AX3 | 用在哪裡 | 備註 |
|---|---|---|---|---|
| `sp-tight` | 6 | 6 | 圖示↔標籤（小）、姓名↔信箱、OTP 格之間、膠囊內 | 最緊，表示「這兩個是一件事」 |
| `sp-label` | 8 | 8 | 標籤→欄位、icon→文字、標題→副標（含字標→tagline） | |
| `sp-group` | 12 | 12 | 群組內元素（按鈕之間、卡片內段落） | |
| `sp-item` | 16 | 16 | 同層級並列項目 | |
| `sp-block` | 24 | 24 | 區塊內部、卡片與其動作 | screen-pad 同值 24 |
| `sp-section` | 44 | 44 | 段落／區塊之間（最大呼吸） | 不隨字級放大，避免 AX3 爆版 |
| `screen-pad` | 24 | 24 | 畫面左右邊距（統一由 wrapper 給） | 子區塊不再自帶左右 padding |
| `screen-pad-lg` | 40 | 40 | iPad 畫面邊距 | |
| `inset-card` | 20 | 20 | 卡片內距 | |
| `corner-out` | 5 | 5 | 角托外擴到台紙上的量。角托是黏在台紙上的紙袋、紙的角插進去——所以它一定壓過紙的邊緣 5pt。堆疊順序固定：台紙 → 紙（1pt paper-edge 亮邊）→ 角托 | 規格值、硬寫（x／y 是 Position，schema 不收變數）。**LS-81 對帳中**：`aw57e` 實測 TL 3pt／BL·BR 10pt 與 5pt 不一致 |
| `print-edge` | 8 | 8 | 沖印品白邊：上／右／左三邊 | 與 print-edge-bottom 現值相同但**刻意不合併**——語意各自獨立（上緣三邊 vs 下緣壓印行） |
| `print-edge-bottom` | 8 | 8 | 沖印品白邊：下緣（壓印行 Imprint Row 所在） | 下緣厚度由壓印行「掙來」：視覺 32＝8＋gap 7＋Imprint Row 17＋8（LS-72 F6） |

**內縮節奏 padding**：ctl-pad-nav 9／ctl-pad-tap 9.5／ctl-pad-md 15.5／ctl-pad-cta 17.5／inset-card 20／screen-pad 24／screen-pad-lg 40。**控件高度一律由 padding 推導，不寫死**——順帶讓 AX 字級自己長高。ctl-pad 的半點值是為了讓列高剛好落在 44／56／60，不是排版節奏。

**具名豁免**：①系統列複製 iOS 規格（pad 0/28、gap 7、icon 18），不吃本節奏也不吃 Dynamic Type；②返回鍵 gap 2（chevron 字形自帶 7pt 內留白）；③數量膠囊 gap 2（「2 位」是一個詞）；④ctl-pad-* 半點值；⑤*Wrap 間距補正外框（pad 4/8/12/16）是 Pencil 單一 gap 的產物，實作直接用 `VStack(spacing:)`，不要照抄。

## ⑤ 尺寸與圓角 Size／Radius

| token | 值 | AX3 | 備註 |
|---|---|---|---|
| `radius-md` | 14 | 14 | 卡片、輸入框 |
| `radius-lg` | 18 | 18 | 大卡／沖印品外框 |
| `radius-full` | 999 | 999 | 膠囊 |
| `icon-sm` | 18 | 32 | 行內小圖示（信任列鎖頭 18） |
| `icon-md` | 22 | 40 | 一般圖示 |
| `icon-lg` | 26 | 48 | 主鈕圖示 |
| `icon-apple` | 24 | 56 | Apple 鍵符號（官方資產） |
| `icon-google` | 20 | 47 | Google G 標（官方資產） |
| `kbd-h` | 336 | — | 系統鍵盤（iPhone 393 直式含建議列），規格值 |
| `kbd-accessory` | 60 | — | 配件條＝主 CTA 的高度本人（ctl-pad-cta 17.5×2＋內容 25） |

Pencil 的 icon `width`／`height` 不收 `$variable`（硬寫，AX3 靠 size 主題軸對照）——這是工具限制，實作端正常綁 token。

## 深色模式的三條物理

1. 紙不會變黑：`$print-paper` 深色是暖米白 #E8D9D4，紙上的墨用單值 token（②⑤ 條）。
2. 照片少一格光：深色照片套 `$photo-dim`（相紙在晚上不會一樣亮；軌 C 實測 ΔL* 9.30）。
3. 同一盞窗光：深色窗光兩端比 1.07、影子方向仍是右下，不換光源。
