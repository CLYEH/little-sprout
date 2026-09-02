# 長輩硬約束

這是長輩看孫子照片的 app（docs/PLAN.md「長輩優先」）。下列是 gate 級的硬約束，不是建議；設計稿與實作都要能拿出量測證據。

## 對比

- 所有文字對 `$bg`（窗光暗端）≥ **4.5:1**；內文目標 **7:1 AAA**（Tokens 板主表逐列實測，全數 AAA）。
- 壓在漸層或照片上的字以**最不利點**計（`$on-photo` 7.36／8.71——板上 `sQsj1` 標「印相罩」已過期，印相罩 R4 除役；數字實為深色套 `$photo-dim` 後的最不利點）。
- 紙上的墨在深色模式必須仍是深色（`$print-ink` 12.55、`$print-ink-secondary` 8.13 對 #E8D9D4）——綁 `$text-*` 會掉到 1.11–1.46:1（primary 1.11／secondary 1.46，R9-A）。
- 裝飾線可申報豁免 3:1（`$border`、`$photo-corner`），但**有意義的邊界**（輸入框、外框鈕、焦點框）用 `$control-line` ≥3:1；風險最高的控件（核准狀態）不得用 `$border` 當框。
- 「還沒做完」的即時回話用 `$text-primary`，不用 danger。

## 點擊與尺寸

- 可點元件 ≥ **44pt**（含 AX 字級下）；控件高度由 padding 推導、不寫死，AX 字級自己長高。
- 邀請碼輸入格、OTP 六格、主 CTA 在鍵盤升起時仍在可視範圍（06-kbd 板實證：配件條 60pt＝主 CTA 高度）。

## Dynamic Type 與 AX3 板

- 七級字級全走 Dynamic Type；唯二不吃的是 `fs-imprint` 12（印在紙上的字）與角托（實體物）。`$sp-section` 44 不隨字級放大以免 AX3 爆版。
- **每張重要畫面必附 AX3 壓力板**（`theme.size=ax3`），0 clip、slack≈0；基準畫面結構有實質變動時衍生板整板重建（`iR7` 規則）。
- 文字節點一律 `textGrowth:fixed-width`＋`width:fill_container`（AX3 才會換行而不是溢出）；Code Card 這類容器不寫死高度。
- AX3 法務行改 `ViewThatFits`；歡迎頁頂層包 `ScrollView`。
- iPhone 用 TabView、iPad 用 NavigationSplitView，重要畫面兩種尺寸都出稿（iPad 直式大印品＋右欄登入的非對稱構圖是全套最強的一張）。

## a11y metadata

- 字標：`accessibilityLabel:"萌芽日記"`／`exemptDynamicType:true`／`role:"image"`＋`.isHeader`。
- 相片：alt 寫人與情境（不是「圖片」）；Lab Imprint `.accessibilityHidden(true)` 或併入 alt 尾段，二選一不得兩者皆無。
- 品牌鍵：可見文字 ⊂ 無障礙名稱（WCAG 2.5.3 Label in Name）；三顆鍵在 AX4／AX5 仍各自保有「Apple 登入／Google 登入／Email 登入」身分，不得剩「登入」。
- OTP 欄 `.textContentType(.oneTimeCode)`。

## 認知負荷

- icon 一律帶文字標籤；層級淺（首頁 2 步內到內容）；不用雙擊、長按等進階手勢。
  - **明文例外（使用者 2026-09-02 裁決，LS-119 R5；R6 補第④前提）**：日記編輯器的照片排序，且僅限這一處，允許長按拖曳。前提四條缺一不可：①限定在編輯器照片佇列的排序動作，不得擴大到其他畫面或其他操作；②畫面上必須有文字提示（本例定案文案「按住照片可拖動調整順序」，`$text-secondary`／`$fs-note`）；③長按拖曳與單擊選取（多選批次刪除）共用同一張縮圖時，兩種手勢要能清楚分流（長按進入拖曳、單擊切換勾選），不得互相誤觸；**④必須同時提供非手勢替代路徑——做不到長按拖曳手勢（手抖、關節退化）的使用者不能因此受損**。替代路徑兩件事缺一不可：(a) 排序本身是選配，不排序也能發佈，此時附加順序＝挑選（點擊新增）的先後順序；(b) 每張縮圖必須提供 VoiceOver 自訂動作（`accessibilityCustomActions`）「往前移」／「往後移」，作為 long-press 拖曳之外唯一的鍵盤／輔助技術可達路徑——這是刪掉兩顆可見按鈕（往前移／往後移具名鈕）換來長按拖曳的交換條件，不得省略。除此之外，全 app 其餘畫面的「不用長按等進階手勢」硬約束不變。設計稿見 `design/littlesprout.pen`「LS-21 / 12e 日記編輯器 · 照片排序（拖曳中）」與其 AX3 變體；SwiftUI 實作指引見 Notes 板 `v0tLp`（R6 已補 VoiceOver custom actions 段落）。
  - **明文例外二（使用者 2026-09-02 16:00 裁決，LS-120；R2 補第⑤前提＋修正②③；R3 機械化第⑤條）**：`cmp/Tab Bar` 全字級（含預設字級，不只 AX 字級）純 icon，不掛文字標籤。前提五條缺一不可：①四顆 icon（時間軸／相簿／寶貝／設定）語意必須自明、彼此剪影可辨——選型理由見 `motifs.md`「Tab Bar 全字級純 icon」；②選中態對比與形狀變化要強，非只換色，且**必須附量測數字**（R1「三個維度」的斷言被深色模式實測 1.140:1 反駁；R2 起改為四個維度：背景 `$surface` 圓角方形實心＋落影＋1.5pt `$control-line` 描邊使背景維度本身達淺 3.249:1／深 3.527:1（R3 描邊由 1pt 加粗、形狀由圓形改方形 `$radius-md`，見 motifs.md MN-6/MN-8）、icon 尺寸 26→32、色次要轉主要）；③VoiceOver `accessibilityLabel`（＝原中文標籤，掛在**可點的 cell**、非 icon 葉節點）與 `selected` trait 必備；AX 字級的 Large Content Viewer（長按彈出大字標籤）是**加強**，不是唯一文字路徑——長按本身是本硬約束「不用長按等進階手勢」禁止的手勢，只押寶在它身上等於文字路徑 100% 依賴一個被禁止的手勢，見第⑤條；④點擊目標 ≥44pt，AX3 下 icon 隨 `$icon-tab-md`／`$icon-tab-lg` token 放大且零溢出（AX3 膠囊改 361×88，見 motifs.md）；**⑤非手勢替代路徑（R2 新增，比照拖曳例外前提④同型；R3 機械化，見 `entry-conditions.md` ⑬）：四個 tab 對應的目的地畫面，display 標題＝該 tab 名稱**（時間軸／相簿／寶貝／設定），是不需要長按、不需要 VoiceOver 也能對照「這顆圖示是什麼」的路徑；Tab-root 畫面的硬規則，未來新增的畫面票必須遵守，不得自由發揮標題（現況：時間軸已符合，寶貝用「寶貝管理」非精確比對、已記入 LS-96 comment `c2dd0ed2`，相簿／設定畫面尚未存在；`entry-conditions.md` ⑬ 附四列對照表與機械化 gate 候選）。除此之外，全 app 其餘畫面「icon 一律帶文字標籤」硬約束不變——這個例外限定 `cmp/Tab Bar` 一個元件，不得比照推廣到其他 icon。設計稿見 `design/littlesprout.pen` Handoff Notes `LuHbv`（LS-120／LS-120 R2／LS-120 R3 段）。
- 每畫面一個 display 標題、最多一個 lead；一個畫面最多一個實心主動作；success 一流程一次。
- 13pt 只給「不讀也能完成任務」的內容——錯誤、載入、輸入指示、核准依據（申請人 email／身分／等待時間）一律 ≥17（給長輩的 app 最不可原諒的是把這些塞進最小字級次要色）。
- 驗證型 disable＝0：長輩不會遇到「按不下去又不知道為什麼」；只在 in-flight 才 disable。
- 錯誤先講發生什麼再講怎麼辦，句子控制在 C 的句長；OTP 輸錯保留輸入＋計次。
- 邀請碼 6 碼 3+3 分組（念的時候分兩組；LS-89 定案、後端 LS-90 對齊中，見 motifs.md 邀請碼）；「接下來會發生什麼」預告表在等待頁，讓長輩知道送出後誰要做什麼。

## 平台手感

- iOS 慣例（導航、手勢暗示、控件位置）不可破壞——個性長在慣例之上。系統控件解剖與狀態以現行 HIG／iOS 27 世代為準。
- Apple／Google 登入鍵用官方資產與規格，色值不得改。
