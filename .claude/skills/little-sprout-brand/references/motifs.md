# 母題與構圖規則（相簿紙語言）

跨畫面的識別靠三件實體物：①相片角托 ②沖印白邊 ③角托染料池。三者是同一條規則的三個面：**角托決定哪裡有池，白邊決定那是不是一張可以拿起來的紙。** 出處：Tokens 板 ⑥、LS-46 R3–R11 審查 comment、LS-72。

## 沖印品 Print（白邊＋壓印行）

- 結構（由外而內）：台紙（`$bg`＋窗光）→ 紙（`$print-paper`，1pt `$paper-edge` 亮邊，`$paper-shadow` 右下影）→ 照片（Photo Wrap，`clip:true`）→ 壓印行 Imprint Row → 角托（最上層，壓過紙緣 5pt）。
- 白邊 padding 一律綁 `$print-edge`／`$print-edge-bottom`（`["$print-edge","$print-edge","$print-edge-bottom","$print-edge"]`），**不是** `$sp-label`（LS-72 F8 改掉 12 張）。四邊解析 8/8/8/8；下緣視覺 32＝8＋gap 7＋Imprint Row 17＋8，厚度由壓印那行字掙來，不要當成 padding 去調。這是**壓印小字型**（單一 caption，一行 17pt）的公式。
- **caption 型印品**（LS-119 R3）：當壓印行改成承載較長內容的單一文字（例如「情境句 · 年齡／張數」合併成一行、可能自然換行到 2–3 行），Imprint Row 不再固定 17，改為該文字 `fit_content` 的實際高度（實測單行 25、雙行 ~50、AX3 三行 ~116）。下緣視覺厚度公式改寫為 **8＋gap 7＋Imprint Row(fit_content)＋8**——「掙來」的仍是那行字，只是字本身長度可變，不是固定一行。角托 y／x 因此必須隨印品實測高度／寬度重算（見「角托一律壓過紙緣」條與 entry-conditions／LS-119 Handoff Notes 的核對表），**不能沿用舊的固定 211/324 座標**。
- Print 一律 `fit_content`，**板高跟著內容走，不從板高倒推 Print 高**（R9-B：倒推出的 63.9 白邊沒有主人；R10 修正後八張 Print 全部閉合 230.1／iPad 582）。
- 照片出血：Hero Photo 刻意大於 `clip:true` 容器，靠 frame 裁出構圖（01 家族 345×190.1 的窗、Hero 本體 345×515 y−84）。這類 partially clipped 是設計意圖，計入已知溢出白名單（R11 51／LS-72 後 50，見 SKILL.md 數字速查）。
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

### 紙面基底可以借給非照片元件，角托不行（LS-111 R6 起；R8 改為「紙本身就是選中訊號」）

零角托不等於「不能用紙」。`$print-paper`＋白邊／陰影語彙可以借給**非照片、非邀請碼的持久性設定列**，只要那個元件不是「會過期的東西」——但**不加角托**：角托的稀缺性只留給①段的家人照片，借去給設定列會稀釋規則本身。判準：這個元件是「你會再點開看一次的收藏」還是「你設定一次就忘記的清單」？前者才有資格談角托，後者只能借紙面基底與紙緣亮邊／落影。

**R6 的做法**（容器本身是一張大紙、選中列疊 theme-aware 底色）**在深色模式失敗了**：把 `$accent-soft`（theme-aware）疊在 `$print-paper`（不掛 theme）上，深色模式兩者對比只剩 10.8:1 的暗色塊，選中列反而讀起來像背景、不像紙（LS-111 R7-B2）。**R8 改正**：不要整個容器共用一張紙，改成**每一列各自可能是一張紙**——

- 選中列＝一張獨立的 `$print-paper`（`$paper-edge` 1pt 描邊＋`$paper-shadow` outer shadow，`$radius-lg` 圓角），像一張從清單裡被拿起來的沖印品；文字用「紙上墨」`$print-ink`／`$print-ink-secondary`（不掛 theme——躺在紙上的字本來就不該跟著 theme 反轉）。
- 未選中列＝完全透明，直接躺在容器背後的 `$bg`（theme-aware）上——它**不是紙**，所以文字要用 `$text-primary`／`$text-secondary`（theme-aware），不能沿用 print-ink：深色模式下 `$bg` 很暗，若還用不掛 theme 的 print-ink（恆暗），對比只剩 1.1:1，等於「因為套了紙的規則，反而在沒有紙的地方看不見字」。
- 兩種底色各自的字一定要用各自對應的 token 家族——「裸紙用 print-ink、沒有紙的地方用 text-primary」是同一個容器裡兩種背景各自的正確配色，不是不一致。判斷準則很簡單：這個子區塊此刻是不是一張真的紙（有 `$print-paper` fill）？是才用 print-ink。
- 列之間不再用分隔線，改用 `$sp-label`（8）的 gap——選中的那張紙自己的邊緣就是分界，不需要额外一條線。

這個版本同時解決了「角色列自己的記憶點」問題：紙不再只是背景色，而是一個會從清單裡浮起來的實體物件，遮住 logo 依然認得出。

## 釘底動作帶 Action Bar（LS-111 R6 起，全 app 版式慣例——**n=2，已轉正**）

R7 掃過全部 393 寬、非 A11y/Stress 的螢幕板：27 張有實心 accent，其中 20 張其他板剛好 852、內容不溢出，只有 07 家族 5 張用到本慣例——當時沒有第二個畫面真的套用過它。**第二次套用＝LS-119 日記編輯器家族 6 板**（12/12b/12c/12 深色/12-iPad/A11y-12）：6/6 板結構一致（`Bar Hairline` `$border` 1pt＋`Bar Button Wrap` padding 16/24）、CTA 底緣→板底 6/6 板皆 50pt（含 `peiRC` 錯誤列讓 Action Bar 從 93 長到 159 仍守 50），慣例本身在跨畫面／跨狀態下證明可轉正，本行「暫定」拿掉。

畫面若有**貫穿全狀態的單一主 CTA**（`$accent` 實心，每畫面限一次）且**內容量會隨狀態變動**（載入中／已產生／AX3 等），主 CTA 改用「釘底動作帶」，不要讓 CTA 座標由上方內容累加決定。

- **結構**：畫面根 frame 維持 Chrome → 內容區 → Home Indicator Area 三段，中間插入第四段 **Action Bar**（內容區之後、Home Indicator Area 之前）：Action Bar＝1pt `$border` 頂部 hairline（純裝飾分組線，與全稿其他 18 條 1pt 分隔線同一 token；**不要用 `$control-line`**——那個 token 保留給輸入框／外框鈕等有意義的邊界，R7-M1 曾誤用又被同批 commit 自己的 Q2 改動打臉）＋ Button Wrap（padding `[$sp-item, $screen-pad, $sp-item, $screen-pad]`＝16/24/16/24，fill `$surface`）包住主 CTA。原本與 CTA 同框的次要文案中，**真正必須在按下 CTA 前讀到的那一行**（例如到期日／名額這類「有效幾天／還可以用幾次」的數字，brand 規則 6 要求 ≥17 且要讀得到）跟著搬進 Button Wrap、疊在 CTA 之上（`$fs-note`／`$text-secondary`，與 CTA 間距 `$sp-label` 8）——這樣它永遠在首屏內，不受內容區長度影響；語意與別處重複的次要條款（例如已在畫面標題／副標講過的政策句）直接精簡或刪除，不要因為「反正有地方放」就把兩句都留著讓首屏被摺線吃掉。
- **安全區**：Action Bar 不吸收 home indicator 安全區，Home Indicator Area（34pt）仍是獨立的最後一段。CTA 底緣到裝置實體底緣＝ Button Wrap padding-bottom（16）＋ Home Indicator Area（34）＝**50pt 定值**，與內容區長度無關——這是本慣例要保證的不變式，換掉哪一段內容都不该改變這個數字。
- **與捲動內容的關係**：內容區維持可捲動；Action Bar 對應實作端 `.safeAreaInset(edge:.bottom)` 釘在 ScrollView 外，不要把 CTA 塞進 ScrollView 內容裡。
- **不適用**：內容恆定、不隨狀態變動的一次性表單（06 碼輸入家族既有的 Upper／Footer flex-spacer 慣例——單一 fixed-height 畫面＋`height:fill_container` spacer 把 Footer 頂到底）不需要改用本慣例，兩者是因應不同前提的兩套解法。
- **不適用（LS-119 R3 新增例外）：Tab-root 畫面**（iPhone TabView 的四個分頁本身，例如時間軸首頁）。這類畫面底部已有一顆全 app 共用、絕對定位的浮動膠囊 `cmp/Tab Bar`（361×64，x16，y＝板高−98）；若再疊一條釘底 Action Bar，Tab Bar 的 y 必須跟著上移，但其他分頁沒有這段新增內容，Tab Bar 位置會隨分頁不同而跳動——這比單一畫面內的版面穩定更根本（跨分頁，不是跨狀態）。這類畫面的單一主要動作改放**導覽列／Header Row 具名按鈕**（見下「時間軸建立入口」條），不套用本慣例。
- **Pencil 實作陷阱**：root frame 與內容區 frame 的 `height` 常是硬寫數字（不是 `fit_content`），改動子內容後必須手動重算並更新這兩層的 `height`，否則 `clip:true` 會靜默裁掉超出宣告高度的 Action Bar／Home Indicator Area 而毫無報錯。

### 時間軸建立入口：導覽列按鈕（LS-119 R3，取代 FAB）

- 時間軸首頁的建立動作用 `cmp/Create Entry Button`（前身 `cmp/FAB`，同一元件 id 就地改造）：pill 形、`fill:$accent`、padding `[$ctl-pad-tap, $sp-item]`＝44pt 高（padding 推導，非硬寫）、icon-sm＋`fs-body` label（「＋ 新增回憶」），放進 Header Row（與畫面標題同列，`justifyContent:space_between`），**不用絕對定位**。
- 這是本規則唯一目前已知需要放棄「釘底動作帶」慣例的畫面類型（見上「不適用：Tab-root 畫面」），理由是浮動／釘底元素都無法在不影響 Tab Bar 全域位置的前提下與 Tab Bar 共存；把入口收進固定版面的 Header Row，結構上保證它不會疊到任何捲動中的卡片內容。
- 空狀態（無內容時）的引導文案應指向這顆按鈕實際所在的位置（「點上方的『新增回憶』…」），不要寫死方向詞而不對照實際座標——文案與版面必須同步更新。

## 日期章 Day Divider（LS-119 R3 新增，跨畫面 signature）

- `cmp/Day Divider`：一枚微旋轉（預設 −4°）的圖章，`$print-paper` 底、`$print-ink-secondary` 墨、`fit_content` 尺寸（padding `[$sp-tight,$sp-label]`）。在 Feed 中用作**日期分組標頭**（同一天的卡片跟著它，組間 `$sp-section` 44、標頭到首卡 `$sp-label` 8）；在日記詳情頁放大（`fontSize` 覆寫至 `$fs-lead` 22）用作**畫面錨點**——同一枚章在兩種尺度出現是同一個元件的兩個 instance，不是兩個平行語彙。
- **Ghost（重影）**：模擬二次蓋章的視覺，做法是 `Copy` 主 Stamp 本身（不是另建一個獨立尺寸的框），疊在後方，位移固定 `(-3, +3)`、旋轉差固定 `3°`，`opacity` 套在整個 Ghost frame（不是只淡文字）——這樣深色模式下才有紙底一起淡出，不會變成「純文字漂在暗背景上」。**Ghost 的文字內容必須手動同步主 Stamp 的內容**（兩者是各自獨立的 `fit_content` 節點，靠相同內容才會算出相同尺寸），新增或修改 Day Divider 實例時務必兩處一起改。
- 角托三段規則不因此新增第四段：日期章不裱照片、零角托、零染料池，屬於「借紙面基底給非照片元件」的既有規則（見上「紙面基底可以借給非照片元件」），不是角托文法的延伸。

## 相簿卡疊紙 Stack Sheet（LS-119 R3，區分「一張照片」與「一疊照片」）

- `cmp/Card Album` 在 Photo Print 下緣新增兩條 4pt 薄片（`fill:$print-paper`＋`stroke:$paper-shadow`），暗示這張紙底下還有更多張，取代早期誤用 `$photo-corner`（角托色）畫底線的做法——**底下那疊紙用紙的顏色，不是角托的顏色**，借用角托色會稀釋角托規則本身（同「紙面基底」條的道理）。
- 位置避開角托涵蓋區：`x=21` 起、寬＝印品寬−42（兩端各留 21pt 淨空，正好是角托 26pt 涵蓋區扣掉 5pt corner-out 出血後的淨寬）；`y`＝印品高與印品高+7，隨每個 instance 的實測印品高分別覆寫（同角托 y 的工具限制與核對紀律，見 entry-conditions／LS-119 Handoff Notes）。

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

- **定案（使用者 2026-08-25 裁決，LS-89）：6 碼、3+3 分組、32 字元表** `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`（排除易混的 0／O／1／I，Crockford 式；稿上 `h7EnT`【R2】另排 Q／L 的 30 字元集未採用，字母表以後端為準）＝ 6 × 5 bit ＝ **30 bit**。安全前提是**核准必開**（固定文案、無開關）：30 bit 只在「加入須管理者核准」下成立，若日後開放直進則升 8 碼。
- **後端已對齊（LS-90，2026-08-25 併入 main 並部署）**：`create_invite` 現為 **6 碼／30 bit**（`supabase/migrations/20260825070627_invite_code_6.sql`；`supabase/tests/80_join_approval.sql` 釘死 `{6}`；既有 8 碼邀請一律失效，舊碼 → LS011、從未存在 → LS010）。
- 輸入 **3+3 分組**（人傳人念／聽／打）與 OTP **六等格**（系統自動填、iOS 原生語彙）不同是刻意的（`FLYU5`）。
- **已擱置備案：八格應變規格**（稿上 `h7EnT`【R6】原文要點；只在日後升 8 碼時啟用，**不是現行**，收錄是為了不必再開一輪設計）：
  - ① 格寬：卡片內寬 305（345 − 2×`$inset-card` 20）。六格＝(305 − 5×8)/6＝44.17（gap `$sp-label` 8）；八格改 4+4 分組：格間 gap 降到 `$sp-tight` 6（6 道）＋中間一道分組間隙 `$sp-item` 16，格寬＝(305 − 6×6 − 16)/8＝31.63。分組間隙是版面元素不是格線，AX 下不放大。
  - ② 字級：`fs-otp` 36 不動（Courier Prime 數字前進寬 ≈0.6em＝21.6，格內扣 2pt 邊框剩 27.6）；AX3 由 52 降到 42（52 會爆：31.2 > 27.6；42＝25.2）。這是八格唯一需要改的 token 值。
  - ③ `fs-code`（07／07b 顯示用大字；寬＝n×(0.6·fs＋4)＋16）：60 在八位時 336 > 內寬 305；八位時降到 52（297.6，餘 7.4），AX3 亦 ≤52。（六位時 AX3 76 溢出 8.6 已降 72，見 tokens.md `fs-code` 待補。）
  - ③-1【LS-107 對帳，2026-08-31】稿面「300 ≤ 305 卡寬所以 AX3 72pt 放得下」是用 Pencil 的 `$font-num`＝Courier Prime 替身字量的；實作用系統等寬字（`.monospaced`），前進寬不同，且 `minimumScaleFactor` 會即時 clamp。LS-107 PR #177 R1/R2 實測：iPhone 寬字母六碼（如 WMZWGB）在**預設字級**就已縮到約 53–55pt，AX3 與預設收斂到同一個由卡片內寬（305pt）決定的下限——**AX3 對寬碼完全沒有放大效果**，`fs-code` 60/72 兩檔在寬碼情境都拿不到。這是版面寬度決定的物理下限，不是實作 bug；本規則承認這個下限存在，不強行加寬卡片或改直排（那會牽動 07/07b 兩板既有沖印品版式），如需要更高下限需另開一輪版式設計。
  - ④ **單一 tap target 是前提，不是附註**（六格亦同）：「一個隱形輸入框＋N 個顯示格」，整列是單一 tap target（高 72 ≥44）；實作不得把每格做成獨立按鈕。
  - ⑤ 切換成本：「一個 cellCount＋兩個 AX3 字級值」，六格與八格共用同一張卡、同一個 72 高、同一條錯誤態文法；真正要重畫的只有 07／07b 的顯示碼與分享文案裡的示例字串。
- 06 主稿只留一行 `fs-meta` 摘要「送出後要等管理者核准」，完整三行「接下來會發生什麼」預告表在 06d 等待頁；核准必開（固定文案，不畫開關）。
- 邀請碼卡零角托、零染料池（會過期的東西不是收藏品）。

## 壓測板是母題的一部分

每個母題主張都要有壓測板才算成立：AX3（01／06／07）、超長家庭名（Stress-05）、空欄位、冷白日光燈與夜間閃光照片（F16 `tNqvY`／`Rtq1m`）。沒有壓測板的主張只是修辭。
