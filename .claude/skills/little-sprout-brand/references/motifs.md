# 母題與構圖規則（相簿紙語言）

跨畫面的識別靠三件實體物：①相片角托 ②沖印白邊 ③角托染料池。三者是同一條規則的三個面：**角托決定哪裡有池，白邊決定那是不是一張可以拿起來的紙。** 出處：Tokens 板 ⑥、LS-46 R3–R11 審查 comment、LS-72。

## 沖印品 Print（白邊＋壓印行）

- 結構（由外而內）：台紙（`$bg`＋窗光）→ 紙（`$print-paper`，1pt `$paper-edge` 亮邊，`$paper-shadow` 右下影）→ 照片（Photo Wrap，`clip:true`）→ 壓印行 Imprint Row → 角托（最上層，壓過紙緣 5pt）。
- 白邊 padding 一律綁 `$print-edge`／`$print-edge-bottom`（`["$print-edge","$print-edge","$print-edge-bottom","$print-edge"]`），**不是** `$sp-label`（LS-72 F8 改掉 12 張）。四邊解析 8/8/8/8；下緣視覺 32＝8＋gap 7＋Imprint Row 17＋8，厚度由壓印那行字掙來，不要當成 padding 去調。這是**壓印小字型**（單一 caption，一行 17pt）的公式。
- **caption 型印品**（LS-119 R3）：當壓印行改成承載較長內容的單一文字（例如「情境句 · 年齡／張數」合併成一行、可能自然換行到 2–3 行），Imprint Row 不再固定 17，改為該文字 `fit_content` 的實際高度（實測單行 25、雙行 ~50、AX3 三行 ~116）。下緣視覺厚度公式改寫為 **8＋gap 7＋Imprint Row(fit_content)＋8**——「掙來」的仍是那行字，只是字本身長度可變，不是固定一行。角托 y／x 因此必須隨印品實測高度／寬度重算（見「角托一律壓過紙緣」條與 entry-conditions／LS-119 Handoff Notes 的核對表），**不能沿用舊的固定 211/324 座標**。
- **空白 caption 型印品（格狀照片牆專用，LS-119 R6）**：多張小尺寸印品排成格狀牆時（見下「20 張上限」），若每格 Imprint Row 只填單一空白字元（既有「空欄位態」慣例），空白字元仍會照字級走 Dynamic Type（預設 25pt、AX3 58pt），導致 AX3 每格憑空多出一大塊空白且角托 y 要跟著兩套數字跑（R5 的 BL-1 就是這樣算錯的：假設 Imprint Row＝17 的字面值，但空白字元的真實渲染高是 25/58，全部對不上）。**格狀牆改用第三種公式**：整條 Imprint Row 拿掉，下緣改固定 `padding-bottom: 32`（承接同一個「下緣視覺厚度 32」數字，但這次是**寫死的 padding，不是任何一行字撐出來的**——因為這裡本來就沒有要顯示的壓印文字，不需要用文字把厚度「掙」出來）。好處：①預設密度與 AX3 每格幾何完全相同（不再有兩套角托 y）②角托 y 永遠＝`8+wrapH+32-21`，只跟該格的照片高度 `wrapH` 有關，不受任何文字內容影響。這個公式**只適用於「格子小、caption 本來就留空」的格狀牆**；只要哪一格開始要顯示真實文字（例如之後要在格狀牆加逐格 caption），必須改回上一條「caption 型印品」的 `fit_content` 公式，不能繼續套固定 32。
- Print 一律 `fit_content`，**板高跟著內容走，不從板高倒推 Print 高**（R9-B：倒推出的 63.9 白邊沒有主人；R10 修正後八張 Print 全部閉合 230.1／iPad 582）。
- 照片出血：Hero Photo 刻意大於 `clip:true` 容器，靠 frame 裁出構圖（01 家族 345×190.1 的窗、Hero 本體 345×515 y−84）。這類 partially clipped 是設計意圖，計入已知溢出白名單（R11 51／LS-72 後 50，見 SKILL.md 數字速查）。
- 壓印行內容：歡迎家族＝「LITTLE SPROUT」（置中、fs-imprint）；建立家庭＝家庭名 Family Caption（`$print-ink`，超長以 `.lineLimit(1).truncationMode(.tail)` 真截斷）；空欄位態＝單一空白 `" "`（保住 Imprint Row 32pt 行高、卡高 175 不塌縮，**不可整列隱藏**）。
- 空白沖印品（`H0KHI` 同構）用來填 02／02b／05／05b 的大片空洞——延續母題，不是裝飾。

## 瀑布流（masonry）詳情頁照片牆（LS-119 R10 起）

- 日記詳情頁照片牆不是固定格狀，是瀑布流：每張照片依原始序等比縮放到欄寬（保持自然比例，不裁切），逐張放進目前累計高度較矮的欄（相等放左欄）；欄底不對齊是預期結果，不補空白格。欄內／欄間 gap 皆 16，corner-out 5pt 出血規則不變，角托依每格實際高度重算。
- 欄數：iPhone 一律 2 欄；iPad 依可用寬度 W 套門檻「欄寬 ≥164.5pt」，取符合門檻的最大欄數。**門檻 164.5 的依據（R11，取代 R10 沒有主人的 140）**：164.5＝iPhone 既有 2 欄的 colW 本身，推導＝iPhone 2 欄 wrapW 148.5（本稿 R6 起沿用、經 R6–R10 視覺審查的 iPhone 2 欄沖印品照片寬；日後做長輩可讀性實測再回填實測值）＋Print Cell 左右各 8pt 內距＝148.5+16=164.5——低於這個欄寬，wrapW 會比這個沿用值更窄，判定不利閱讀。這個門檻管的是「照片本身多窄還算得上一張沖印品」，跟 8/16/24/44 版面留白節奏是兩件事，不要往節奏數字上硬湊。
- 現稿 iPad 兩塊詳情左欄（`MjRcr`、`KjDsM`）實測 W=360，套用門檻後皆為 2 欄（3 欄僅 109.33pt<164.5，不合格）——`KjDsM` 因此由早期版本的 3 欄改為 2 欄，是門檻規則的直接結果，非另行裁決。
- 詳細版面規格與 SwiftUI 實作指引見 `design/littlesprout.pen` 的 detail-notes 板（`g41UR`）R10／R11 段。

## 角托三段規則（R4 起有文法）

| 段 | 角托 | 誰 |
|---|---|---|
| ① 四角托＝這是一張沖印品 | 4 | 使用者會收藏、會再看第二次的東西。全 app 只有**家人的照片**：01／01b／01c／01-iPad／04／04-iPad／A11y-04／07a 範例沖印品。現稿（main）四顆共 175 處（`Print Cell`×134、`Print Stage`×16、`Photo Print`×10…），維持現狀 |
| ② 對角兩顆＝App icon、`cmp/Profile Print`＋LS-177 起新畫的沖印品 | 2 對角 | App icon 實機尺寸（≤60pt，四顆會糊成一圈邊）；**`cmp/Profile Print`（`OePXK`）現稿就是對角兩顆**（`/Print/Mount TL` `R1lbwf`／`/Print/Mount BR` `S4O4r8` → `cmp/Photo Corner` `GEBcf`；main 上唯一非 App icon 的既有例）；**LS-177 起新畫的沖印品用對角兩顆**（例：Hero Print `zzXNT` 200×155、Empty Print `K1yE6j` 120×120；LS-177 VR R3 MN-2）。既有四顆（`Print Cell` 等 175 處）維持現狀，是否統一另票對帳（LS-96 `a442c747` 角托實況池項）。對角保留「被裱住」的剪影，且對角正好是窗光最強與最弱的兩端。`cmp/Card Diary` 是零角托（③），不是本段的例 |
| ③ 零角托＝不是沖印品 | 0 | 一次性表單、橫幅、設定列、印在卡片上的照片。**邀請碼卡／邀請碼輸入卡**：會過期、有次數上限、用完就作廢——會過期的東西不是收藏品。撤角托時連四顆染料池一起撤：沒有角托的紙沒有池 |

- 角托一律壓過紙緣 `corner-out` 5pt（iPhone／iPad／深色紙條接縫皆守；01 家族 corner y＝print y−5）。**LS-81 對帳中**：`aw57e` 實測 TL 3pt／BL·BR 10pt 與 5pt 慣例不一致，以 LS-81 結論為準。
- **多張印品並排時（格狀照片牆），格間 gap 必須 > corner-out×2＝10pt**（LS-119 R6，BL-2）：相鄰兩格的角托各自出血 5pt，gap 若 ≤10 兩顆角托會直接重疊、連成一整片，讀不出「這是好幾張各自獨立的印品」。目前用 `$sp-block` 16（節奏內最接近的一級，10pt 淨空），不要為了省一級節奏改用 `$sp-item` 12（只有 2pt 淨空，仍偏緊）。
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

R7 掃過全部 393 寬、非 A11y/Stress 的螢幕板：27 張有實心 accent，其中 20 張其他板剛好 852、內容不溢出，只有 07 家族 5 張用到本慣例——當時沒有第二個畫面真的套用過它。**第二次套用＝LS-119 日記編輯器家族**：R4 時為 6 板（12/12b/12c/12 深色/12-iPad/A11y-12），6/6 板結構一致（`Bar Hairline` `$border` 1pt＋`Bar Button Wrap` padding 16/24）、CTA 底緣→板底 6/6 板皆 50pt（含 `peiRC` 錯誤列讓 Action Bar 從 93 長到 159 仍守 50），慣例本身在跨畫面／跨狀態下證明可轉正，「暫定」拿掉。**R5（2026-09-02）新增 5 板**（12d 多選態、12e 拖曳中、A11y-12e、12f 已達上限、12g 影片超長）同套結構——**目前全家族 11 板皆用本慣例，11/11 板 50pt 不變式成立**（沿用同一批 execute 腳本量測，未逐板另建腳本）。R4-d 指出的「motifs.md 板數過期」在 R5 一併回填為目前正確值，不留過期數字。

畫面若有**貫穿全狀態的單一主 CTA**（`$accent` 實心，每畫面限一次）且**內容量會隨狀態變動**（載入中／已產生／AX3 等），主 CTA 改用「釘底動作帶」，不要讓 CTA 座標由上方內容累加決定。

- **結構**：畫面根 frame 維持 Chrome → 內容區 → Home Indicator Area 三段，中間插入第四段 **Action Bar**（內容區之後、Home Indicator Area 之前）：Action Bar＝1pt `$border` 頂部 hairline（純裝飾分組線，與全稿其他 18 條 1pt 分隔線同一 token；**不要用 `$control-line`**——那個 token 保留給輸入框／外框鈕等有意義的邊界，R7-M1 曾誤用又被同批 commit 自己的 Q2 改動打臉）＋ Button Wrap（padding `[$sp-item, $screen-pad, $sp-item, $screen-pad]`＝16/24/16/24，fill `$surface`）包住主 CTA。原本與 CTA 同框的次要文案中，**真正必須在按下 CTA 前讀到的那一行**（例如到期日／名額這類「有效幾天／還可以用幾次」的數字，brand 規則 6 要求 ≥17 且要讀得到）跟著搬進 Button Wrap、疊在 CTA 之上（`$fs-note`／`$text-secondary`，與 CTA 間距 `$sp-label` 8）——這樣它永遠在首屏內，不受內容區長度影響；語意與別處重複的次要條款（例如已在畫面標題／副標講過的政策句）直接精簡或刪除，不要因為「反正有地方放」就把兩句都留著讓首屏被摺線吃掉。
- **安全區**：Action Bar 不吸收 home indicator 安全區，Home Indicator Area（34pt）仍是獨立的最後一段。CTA 底緣到裝置實體底緣＝ Button Wrap padding-bottom（16）＋ Home Indicator Area（34）＝**50pt 定值**，與內容區長度無關——這是本慣例要保證的不變式，換掉哪一段內容都不该改變這個數字。
- **與捲動內容的關係**：內容區維持可捲動；Action Bar 對應實作端 `.safeAreaInset(edge:.bottom)` 釘在 ScrollView 外，不要把 CTA 塞進 ScrollView 內容裡。
- **不適用**：內容恆定、不隨狀態變動的一次性表單（06 碼輸入家族既有的 Upper／Footer flex-spacer 慣例——單一 fixed-height 畫面＋`height:fill_container` spacer 把 Footer 頂到底）不需要改用本慣例，兩者是因應不同前提的兩套解法。
- **不適用（LS-119 R3 新增例外）：Tab-root 畫面**（iPhone TabView 的四個分頁本身，例如時間軸首頁）。這類畫面底部已有一顆全 app 共用、絕對定位的浮動膠囊 `cmp/Tab Bar`（361×64，x16，y＝板高−98）；若再疊一條釘底 Action Bar，Tab Bar 的 y 必須跟著上移，但其他分頁沒有這段新增內容，Tab Bar 位置會隨分頁不同而跳動——這比單一畫面內的版面穩定更根本（跨分頁，不是跨狀態）。這類畫面的單一主要動作改放**導覽列／Header Row 具名按鈕**（見下「時間軸建立入口」條），不套用本慣例。
- **Pencil 實作陷阱**：root frame 與內容區 frame 的 `height` 常是硬寫數字（不是 `fit_content`），改動子內容後必須手動重算並更新這兩層的 `height`，否則 `clip:true` 會靜默裁掉超出宣告高度的 Action Bar／Home Indicator Area 而毫無報錯。

### 時間軸建立入口：導覽列按鈕（LS-119 R3，取代 FAB）

- 時間軸首頁的建立動作用 `cmp/Create Entry Button`（新建 reusable `zy3Ps`；LS-47 四板內嵌 FAB frame 未動，同步另記 LS-96）：pill 形、`fill:$accent`、padding `[$ctl-pad-tap, $sp-item]`＝44pt 高（padding 推導，非硬寫）、icon-sm＋`fs-body` label（「＋ 新增回憶」），放進 Header Row（與畫面標題同列，`justifyContent:space_between`），**不用絕對定位**。
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

## Tab Bar 全字級純 icon（LS-120，R4 修訂——取代 R1／R2／R3 描述）

`cmp/Tab Bar` 全字級（含預設，不只 AX）純 icon，不掛文字——取代 R 前「icon＋fs-meta 文字」兩層結構；文字標籤路徑靠**兩條**（非單靠長按，見下「非手勢替代路徑」）承載，是 `elder-constraints.md`「icon 一律帶文字標籤」的第二條明文例外。四顆 icon：時間軸＝gallery-vertical（單一直立矩形＋橫線＝一條持續往下捲動的 feed）、相簿＝**images**（兩張交疊相框＝一疊隨時可翻開的收藏，呼應 app icon photo-stack 的疊放照片意象；R1 曾改 layout-grid，因與 iOS 相片 app「田字＝所有照片、疊起＝相簿」的平台先驗相反且讓 Tab Bar 上找不到一張「照片」，R2 review MJ-2 判定失敗，改回）、寶貝＝baby、設定＝settings——差異軸「一條流 vs 一疊收藏」，四種剪影零文字仍可辨。

- **選中態＝四個維度同時變化，非只換色**：①背景透明→`$surface` **圓角方形**實心＋outer shadow（`$radius-md` 14，R3 MN-6 由 `$radius-full` 改——更貼近「一張紙」母題，且四向淨空一致：直徑 44/60 的圓內接方形邊長 31.1/42.4 小於 icon 32/48，會讓方形 icon 四角頂到圓邊；改方形後 `$sp-tight` 6 四向淨空都成立）＋1.5pt `$control-line` 描邊（R3 MN-8 由 1pt 加粗，未選中描邊同色 `$surface-2`＝無框，膠囊本體維持 1pt 不動）②icon 由 `$icon-tab-md` 放大到 `$icon-tab-lg`③色由 `$text-secondary` 轉 `$text-primary`。**量測**（WCAG 2.1 相對亮度，非形容詞）：`$control-line` 對 `$surface-2`＝淺 **3.249:1**／深 **3.527:1**（兩主題同向皆 ≥3:1，R2 review 逐像素複驗屬實）；R1 只靠明度分離時是淺 1.354:1／深 1.140:1（深色比軌道更暗、方向反轉），這正是為什麼「形狀＋對比要強」不能只是斷言，必須附測量法與數字。
- **尺寸**：`$icon-tab-md`（unselected，26／AX3 40）、`$icon-tab-lg`（selected，32／AX3 48）——比一般 `$icon-md`/`$icon-lg` 大一階，理由：導覽用的圖示不是「一般圖示」，拿掉文字後空間要還給 icon（**注意**：`$icon-tab-md` 與 `$icon-lg` 預設值剛好都是 26，AX3 才分開 40 vs 48，稿面上一個字面 26 分不出是哪個 token——Tab Bar 內的 26 一律讀作 `$icon-tab-md`）。indicator padding 固定 `$sp-tight`（6，不隨 AX3 放大，見 tokens.md ④）。選中 Indicator＝icon+12：預設 32+12=**44**（恰為觸控下限，膠囊本身即合格目標）、AX3 48+12=**60**。外層膠囊：預設 361×64、AX3 361×88——**這兩個尺寸是固定值，不隨畫面內容量變動**（見下「板高不變」段）。
- **y 位移（公式固定，R4 起不再有例外；R9 訂正「只有兩個 y 值」的過窄講法）**：Tab-root 板的膠囊 y 一律由公式 **`y = 板高 − 34（底部安全邊界）− 膠囊高`** 導出，不因畫面內容量、狀態（有內容/深色/下拉中/空狀態）而變動——**公式是唯一不變量，y／板高的具體數字不是**。目前全 app 有三組（板高, 膠囊高, y）：預設 `(852, 64, 754)`（多數 Tab-root 板）／AX3 `(1500, 88, 1378)`（`lKoZG`／`HLXo3`）／AX3 `(1272, 88, 1150)`（`oP9Ey`，時間軸切換·強制下拉，板高不同是因為要容納展開的下拉選單，膠囊高仍是同一顆 AX3 token 88，三組數字都滿足公式：852−34−64=754、1500−34−88=1378、1272−34−88=1150）。**R4/R5-R8 版本誤寫成「只有 754／1378 兩個值」，遺漏了 `oP9Ey` 這組——校對／實作以公式為準，不要死記兩個數字。**
- **板高固定＝裝置語意，不隨內容延伸（R4，推翻 R3 機制）**：R3 一度把 6 張板的板高改成「內容需要多高就多高」（896/876/888/888/1600/1648），R4 review BL-7 判定這個機制本身不成立——延伸後的板高不對應任何 iPhone 裝置（393×852 才是 15/16 Pro；393×896 不是任何機型），且讓同一畫面的四個狀態（有內容／深色／下拉中／空狀態）的膠囊落在 754/778/790/798 四個不同 y，正面違反十條不可協商第 10 條「狀態切換不搬動版面」，且 `yXSht` 是 LS-126 逐 frame 對稿的基準板，實作膠囊永遠釘在 754，板高延伸會讓對稿平白多出 44pt 落差。R4 已把全部 6 板板高**還原**回 852／1500，膠囊 y 回到固定公式值。
- **驗收判準（R5 定案、R6-R7 逐板實測驗證收斂，R8 補記為通用判準）**：兩條，缺一不可——①板內任何**文字／icon 葉節點**（含旋轉節點，見下；判定要 respect `enabled` 鏈，停用節點與其子樹不參與）不得被膠囊矩形的邊緣**部分**切到（上緣穿出膠囊上緣、或下緣穿出膠囊下緣但還沒到板底，兩者皆算）②膠囊下緣到板底的 34pt home indicator 帶內不得有任何文字／icon 葉節點的哪怕一部分。等價講法：內容合法的終態只有三種——完全在膠囊頂之上、完全被膠囊整個吞掉在內（不穿出膠囊任一邊緣）、或完全在板底之外（被 `clip` 裁掉）；不合法的只有「卡在膠囊邊緣一半」與「卡進 34pt 帶」兩種，「完全遮在膠囊後面」是合法的真機捲動狀態，不是違規。**這是不限本票的通用判準**——後續任何新增或修改的 Tab-root 板都比照，不是 LS-120 專屬規則。**標準構圖範例：`a67Na`**（LS-21/11c 時間軸·下拉更新中）——Day Group 1 只放一張卡，內容天然結束在膠囊之上有餘裕的位置，Day Group 2 只需極小 padding-top（24）即可讓其全部內容（含旋轉的 Day Divider 2）完全落在板底之外，是這條判準底下結構最乾淨、最少特例的構圖；新增 Tab-root 板優先照抄「Day Group 1 收斂到剛好清空膠囊、Day Group 2 順勢自然落外或落在膠囊後」的邏輯，不要每次逐板重新試錯 padding 數值（R6/R7 的 `HLXo3` 就是先落入「Day1 太短→留白過大」與「Day1 太長→Divider 卡邊」兩個坑才收斂到最終解，過程細節見 Notes `LuHbv` R6/R7/R8 段）。
- **旋轉節點的 bounds（R5，訂正 R4 的錯誤模型，MJ-11）**：`cmp/Day Divider` 的 `Stamp`（rotation −6°）／`Ghost`（−3°）兩個節點，`ctx.bounds` 回傳的**已經是旋轉後的包絡框**（在其 parent 座標空間裡），不是未旋轉的原始區域框。R4 版本「`ctx.bounds` 是未旋轉區域框，需另外套 `Hp=w·|sinθ|+h·|cosθ|` 公式」與「Pencil rotation 繞包絡框中心、不是 execute.md 文件字面寫的左上角」兩個講法都是錯的——不存在這個工具限制，`execute.md` 文件字面沒有問題。這兩個錯誤講法是循環論證的產物：R3 與 R4 的覆核各自獨立對同一組「已經旋轉過」的 bounds 又外加套了一次旋轉公式（雙重旋轉），兩次獨立的錯誤剛好互相「對上數字」，被誤判為驗證通過。**正確判準**：沿 parentCtx 鏈單純累加 x/y／w/h 到 Stamp／Ghost 節點本身即可直接使用，不需要、也不應該再套任何旋轉公式；且**不再往下展開子節點**（`ctx.skipChildren()`）——子節點（如 Date Text）的 bounds 是相對於 Stamp 自己「未旋轉」的本地座標系，繼續往下累加才會算錯，Stamp／Ghost 自身的 bounds 已是安全、精確的邊界。**獨立覆核數字**（HLXo3 `kGF7O/xlLIo` Stamp −6°）：本地 bounds `{bx:0, by:0, bw:335.51, bh:104.11}`；對應未旋轉內容 314×58 文字＋padding[6,8]＝330×70，代入標準旋轉包絡公式（W'=330·cos6°+70·sin6°、H'=330·sin6°+70·cos6°）算出 335.51×104.11，與 Pencil 回傳的 Stamp bounds 精確吻合（<0.01pt）——這證實這個公式只該套一次（算 Stamp 自己 bounds 時 Pencil 內部已經算過了），外部再對 `ctx.bounds` 套第二次就是本錯誤的根源。
- **修法：兩個內容側旋鈕，皆為 padding／gap，不是板空間**（R4 引入，R5 依訂正後模型與放寬後判準重算）：①**preShift**——R4 曾把 3 板（`yXSht`／`a67Na`／`HLXo3`）的 `Spacer Section` 從 44 降到 0，R5 判定此舉造成 Child Filter 到首枚日期章間距歸零、脫離 8/16/24/44 節奏、且與同畫面深色版（`V4Ktak`）不一致（BL-8）——已**全數還原為 44**，與另 3 板（`V4Ktak`／`A33la`／`lKoZG`，本來就沒降過）一致，6 板 `Spacer Section` 皆＝44，回到 R1 基線；還原後 Child Filter→首枚日期章間距 6 板統一為 44pt（`a67Na` 因下拉更新狀態多一個 `Pull Refresh Row` 手足節點，量出 129pt 屬預期的內容差異，不是節奏違規）。②**Day Group 2 的 `padding-top`**——依訂正後的旋轉模型與放寬後判準（完全遮在膠囊後面合法）重新逐板精算：yXSht 0／a67Na 24／V4Ktak 8／A33la 8／lKoZG 96／**HLXo3 48（R5 當時值，已作廢，見下）**。yXSht／a67Na 兩板 Day Group 1 內容本來就比較高，padding-top 小幅（0／24）即可把整個 Day Group 2 推到板底之外；V4Ktak／A33la 內容較短，Day Group 2 起點原本就卡在膠囊上緣附近一點點，小幅 padding（8）把它完全推進膠囊縫隙內即可（不必推出板外）；lKoZG／HLXo3 是 AX3 板，Stamp 旋轉後包絡框高達 104pt、大於膠囊本身高度 88pt，物理上不可能「完全遮在膠囊後面」，只能整段推到板底之外（R5 當時值 96／48）。**HLXo3 這個數字後續兩輪都變了，是本表唯一不穩定的值**：R6 為修 BL-9（部分覆蓋）把 `HLXo3` Day Group 1 從兩張卡減為一張（`fZ3KF` 保留、`P1CltA` 刪除），連帶 Day Group 2 的 `CFlP7`（Card Album 1）也因同款「平移無解」被刪，padding-top 一度衝高到 **510** 才能把剩餘內容推出板外；R7 判定 510 造成 440.2pt 空洞（BL-10），改回 **padding-top 0**（讓 Day Divider 2／Snippet／Name 自然落在膠囊之上，不必推出板外，最後一項可見內容到膠囊頂僅 49.04pt）——**目前 `HLXo3` 的 Day Group 2 padding-top＝0，不是本段最初算出的 48，也不是 R6 中繼態的 510**，其餘 5 板（yXSht 0／a67Na 24／V4Ktak 8／A33la 8／lKoZG 96）自 R5 起未變。逐板精算數字與驗證見 Notes `LuHbv` R5／R6／R7 段。**踩雷記錄（沿用，未變）**：第一次嘗試改 `Feed` 自己的 `gap`（$sp-section 44→G）只想推 Day Group 2，但 `gap` 是 Feed 對全部子節點統一套用的屬性——`a67Na` 在 Day Group 1 之前多一個 `Pull Refresh Row`，同一個 gap 改動連它與 Day Group 1 的間距也一起變了，反而把 Day Group 1 推進膠囊裡（新增 5 筆重疊）；改成只對 `Day Group 2` 自己的 `padding-top`，不動 Feed 共用的 `gap`，才不會波及其他手足節點。**節點命名（R5，MN-12）**：6 板的 `Day Group 2` 節點已改名為「Day Group 2（padding-top＝捲動位置模擬，見 Notes LuHbv）」——padding-top 掛在一個看似普通的內容容器上，對 ios-dev 讀圖來說語意不明顯，改名讓用途在圖層名稱本身就看得懂，不需要另外查文件才知道這個 padding 是刻意的定位機制、不是誤植的殘留值。
- **捲動內容底部 inset 契約**（實作契約，寫給 ios-dev，與稿面機制分離）：Tab-root 畫面捲動容器的 `safeAreaInset(edge:.bottom)`／`contentInset.bottom` ＝ `34 ＋ 膠囊高`——預設 **98**、AX3 **122**。這是給 ios-dev 的實作契約值，.pen 稿面不放對應的隱形節點（R3 曾放 6 個 `Bottom Inset` 節點在板外，R4 已刪除，見 MN-10：契約值寫在這裡就夠，稿面上一個永遠不會被渲染的節點沒有額外資訊量）。
- **非手勢替代路徑**（前提⑤，比照 LS-119 拖曳例外前提④同型；`elder-constraints.md` 例外二第⑤前提、`entry-conditions.md` ⑬ 同步補）：四個 tab 對應的目的地畫面，**display 標題＝該 tab 名稱**（時間軸／相簿／寶貝／設定）——這是拿掉可見 tab 文字後、不依賴長按 Large Content Viewer 也能對照「這顆圖示是什麼」的路徑，是 Tab-root 畫面的硬規則、寫進 `entry-conditions.md` ⑬（含四列對照表＋機械化 gate 候選：XCUITest 斷言每個 Tab-root 首屏存在等於 tab 名稱的 heading，比照 `tap-target-check.sh` 同型）。現況：時間軸✅；寶貝現用「寶貝管理」❌（LS-96 comment `c2dd0ed2`）；相簿／設定畫面尚未存在。
- **定案形態全畫出，含深色（MJ-4／MJ-7／MJ-8）**：`cmp/Tab Bar` 旁 `cmp/Tab Bar · 四態對照（LS-120 R2）`（`Lo8Ae`，預設＋AX3 兩排）＋獨立頂層板 `cmp/Tab Bar · 四態對照 · 深色（LS-120 R3）`（`cKFJq`，比照既有深色板慣例設在板層級的 `theme:{mode:"dark"}`——**巢狀 theme 設在子 frame 上，資料層算得出深色 hex 但 `TakeScreenshot` 渲染引擎不吃，R3 新發現的 Pencil 限制**，深色排因此改成獨立頂層板而非 Lo8Ae 內的第三排）。三排×四欄共 12 個 instance，是驗收條件 1–2「有定案形態、全 app 一條規則」在四個狀態×三種主題都畫出來意義下的證據；override 配方（R9 訂正，取代先前「含 4 個 cell 的 `metadata.selected`」的錯誤描述）＝每個 instance 的 `descendants` 只顯式覆寫全部 4 顆 Indicator（fill/stroke/strokeWidth/effect）＋4 顆 Icon（fill/width/height）共 8 個節點的視覺屬性，**不覆寫 `metadata.selected`**——全檔 `metadata.selected` 只有 4 筆，全部屬於 `cmp/Tab Bar` 元件定義本身（`z2egdT`/`nMfej`/`kHQai`/`Js28q`，固定「時間軸」true、其餘 false），12 個 demo instance 沒有各自的 `selected` 覆寫。**已知後續影響（未修，超出本次 docs 訂正範圍）**：這代表 demo 對照板上 11 個「視覺上畫成選中」的非時間軸 cell（相簿／寶貝／設定各狀態），其 a11y `selected` 中繼資料仍讀回元件預設值（時間軸 true、其餘 false），VoiceOver 對這些 demo cell 唸出的選中狀態會與畫面視覺不一致——但這些是 demo 對照板（純視覺文件用途），不是使用者會導覽到的真實畫面，優先度低，記錄於此供之後若要修正時參照。**選中片 `strokeWidth` 必須跟緊元件本體的值**（R3 元件改 1.5 後 12 個 demo instance 一度卡在硬寫的 1，R4 已同步改 1.5，見 MJ-8）。
- **iPad 不適用**：iPad 用 NavigationSplitView（PLAN.md），全文件掃描確認沒有任何板在 iPad 寬度使用本元件，維持現狀即可，不需要造一個 iPad 版本；若未來出現這種用法，屬於「該畫面不該用 Tab Bar」的問題，不是本元件要改尺寸。
- Pencil 實作細節（旋轉 bounds 訂正證據、preShift／padding-top 逐板精算值與踩雷記錄、MJ-6 標題對照表、MJ-7 深色板限制記錄、MJ-8～BL-10 處置、Tab-root 通用判準與 `a67Na` 範例補記、R9 merge-review minor 訂正）見 `design/littlesprout.pen` Handoff Notes `LuHbv`（LS-120／LS-120 R2／LS-120 R3／LS-120 R4／LS-120 R5／LS-120 R6～R9 段；**R3 段的板高延伸數字、R4 段的旋轉包絡公式與逐板 padding-top 舊數值均已標記作廢，勿依其實作，以 R5 段起（含 R6～R9 對 `HLXo3` padding-top、metadata.selected 覆寫範圍等細節的後續訂正）為準**）。

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

## 照片佇列：點選＋長按拖曳（LS-119 R5 起）

日記編輯器的照片佇列（`Photos` 區塊，跨 11 個編輯器板同一套結構）：Photos Header（label＋「N／20 張」計數）→ Photo Strip（新增照片 cell 永遠第一格，其後縮圖依序排列）→ 提示文字「按住照片可拖動調整順序」→ 條件式「移除所選 N 張」鈕。

- **雙手勢分流**：單擊縮圖＝切換勾選（驅動批次刪除），長按＝進入拖曳排序（放開後依放開位置重排，不影響選取狀態）。這是品牌長輩硬約束「不用長按等進階手勢」的**唯一明文例外**（見 `elder-constraints.md`，使用者 2026-09-02 裁決，僅限本畫面照片排序、且必須有文字提示）。
- **選中態視覺**沿用全稿唯一的「打勾徽章」語彙：2pt `$text-primary` 內描邊＋右上角 24×24 實心圓＋`$surface` 勾（絕對定位，poke 出縮圖邊緣，屬既有已知溢出白名單）。同一套視覺後來也用在 Attribution Sheet 的多選 checkbox（R5，見下）——「打勾＝已選」在全稿只有一種畫法。
- **拖曳中視覺**：被提起的縮圖用獨立節點呈現——放大到 112×112、旋轉 -6°、3pt `$print-paper` 描邊（**不是** `$surface`——`$surface` 掛 theme，深色模式對比只剩 1.18:1，等於「提起感」在深色模式消失；`$print-paper` 不掛 theme，兩模式都是紙色，這圈白邊本來就是「紙」，不該跟著 UI 反轉）、加重 outer shadow（`$paper-shadow`，offset 2,8／blur 16），原位置留一個 96×96 虛位佔位框（`$surface-2` 底＋`$control-line` 1.5pt 框線＋0.6 透明度）代表落點，框內置中偏右加一條 2pt `$control-line` 垂直插入線（x=75，非置中的 x=47——因為拖曳縮圖本身會蓋住佔位框左側約 53pt，插入線要落在**右側曝光區**才看得見，這是 R6 修的：R5 版本插入線置中反而被蓋住）。拖曳縮圖必須留白至少 40pt 讓佔位框可見（本例曝光 42.6pt）——這是這張示範板存在的唯一理由，不能被自己要示範的東西完全蓋住。示範板：「LS-21 / 12e 日記編輯器 · 照片排序（拖曳中）」與其 AX3 變體。**非手勢替代路徑**（做不到長按拖曳的人）：排序為選配，不排序也能發佈（此時順序＝挑選順序）；每張縮圖另提供 VoiceOver `accessibilityCustomActions`「往前移」／「往後移」，是拿掉兩顆可見按鈕換長按拖曳的交換條件，寫進 `elder-constraints.md` 第④前提。
- **20 張上限**：達上限時「新增照片」不 disable，點了原地出現回話列（`$text-primary`＋circle-alert，十條之八），不用 danger。
- **不做為 token**：Photo Strip 的縮圖尺寸（96）、Add Photo 尺寸、頭像堆疊重疊量等仍是規格值（Pencil `width`/`height` 不收 `$variable`），不是正式 Size token，沿用既有「規格值、硬寫」慣例。

## 影片格：沖印品格＋播放徽章（LS-119 R5 起）

照片／影片項共用同一個沖印品格（縮圖或 Photo Wrap），影片項在右下角疊一顆膠囊徽章：`$print-ink` 75% 不透明底、`$on-photo` 白色 play 圖示＋文字「影片 M:SS」（radius-full，`padding:[2,"$sp-tight"]`）。用在三處：①編輯器佇列縮圖（96×96，示範 mkxzU／MOLyd 的 Photo 2）②時間軸 `cmp/Card Photo` 的 Photo Wrap（enabled:false 預設子節點，示範 `xrCoj`）③詳情頁格狀照片牆的 Print Cell（示範 `vzYXz` 第 2 格，觸發態——點一下開全螢幕系統播放器，稿面不畫播放器本身）。

- **徽章文字一律固定 `$fs-imprint` 12**（不是「視密度而定的 11–14 自由數字」——R5 版本三個尺寸各自取了不同字級，被判定為「沒有主人的數字」，R6 已收斂成一個值）：徽章疊在物理尺寸固定的縮圖／Photo Wrap 上（縮圖本身不隨 AX3 長大），比照既有 `$fs-imprint`／Selected Badge 勾號 14pt 的「疊在固定尺寸物件上的字不長大」先例。徽章盒改 `fit_content` 讓文字不被截斷，統一右下內縮 8pt（三處尺寸不同的縮圖／Photo Wrap 各自算出對應 x/y，內縮量本身統一）。**AX3 不得讓「這是影片」的唯一文字證據停在 12pt 讀不到**：徽章本身文字仍固定 12（那是印在縮圖上的裝飾標記，不是主要資訊），但 AX3 密度的縮圖（目前只有編輯器 `MOLyd` 這一處示範）額外在縮圖下方加一行走 `$fs-note`（AX3＝40）的獨立文字標籤「影片 M:SS」，這行才是長輩在 AX3 下真正讀取『這是影片』的文字證據，不與徽章共用字級。opacity 75% 一律烘進 `fill`（如 `#2B141CBF`，`$print-ink` 的十六進位值疊 75% alpha），不掛在 frame 的 `opacity` 屬性上——否則白字與 play 圖示也會被打到 75%，與這裡寫的「75% 不透明底」字面不符（R5 曾犯此錯，R6 已修正，兩者現在一致）。
- **`$print-ink`／`$on-photo` 不掛 theme**，深色模式自動套用相同視覺，不需要另外做一份深色示範（詳情頁只在 iPhone 淺色示範一次，dark 對應格沿用同一 token 邏輯）。
- **行為規格（稿面畫不出來，寫在這裡）**：時間軸卡片上的影片項不自動播放、不內嵌播放器——card 本身仍是一張沖印品照片（縮圖用影片首格畫面），徽章只是靜態標示。編輯器選到超過 1 分鐘的影片時，回話列「影片最長 1 分鐘，會保留前 60 秒」（示範板「LS-21 / 12g 日記編輯器 · 影片超過 1 分鐘」），行為只提示不阻擋——裁切動作在後端／發佈時處理，編輯器內不剪輯。

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
