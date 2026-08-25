# 實作票進場條件（定稿 12 項）

原文收錄自 LS-46 comment `ba6dbabb`（第 11 輪核銷審查 APPROVE，2026-08-25）。**實作票開工前逐條檢查**；R8／R10 的早期版本（含「01b 為舊式 absolute-positioning」）已被本版取代。實作票另加：`design/*.png` 相片為設計佔位圖，勿原樣進 Assets（merge-review I1）。

① **深色模式紙條＝設計例外，且紙條同時承載字標與 Tagline。** 01c 的字標與 tagline 都不進 Head（Head 只剩 Trust Row 25pt），坐在 Print Stage 上緣、與相片同寬 361 的 `$print-paper` 紙條上；紙條 fit_content 136.6 ＝ 4＋90.6＋8＋26＋8，字標→tagline 間距 `$sp-label` 8 與淺色 Head 內相同。**不另出淺色字標資產**（`mengya-diary-crayon-v3-dark.png` 不需要）。**`qajNG` 若未依 D1 更新，以本條為準。**

② **`print-ink` / `print-ink-secondary` 是不掛 theme 的單值 token**：Asset Catalog 建 Color Set 時 Any 與 Dark 兩欄填同值，不要套 `text-primary`/`text-secondary`。規則一句話：紙永遠是淺表面、墨永遠是深色，不隨關燈反轉。深色 tagline 用 `$print-ink-secondary`（8.13:1），淺色 tagline 用 `$text-secondary`——**同一個元素在兩個模式綁不同 token，是刻意的，不是漏改**。

③ **紙上小字必須置中**：Lab Imprint（`$fs-imprint` 12／ls 3.5／不吃 Dynamic Type）在白邊帶內水平置中——印品帶四角暗角漸層，靠左會讓深色對比從 8.13 掉到 3.5 附近。（字標紙條無暗角，不受此限，但仍置中。）同時依 `xInPT`/`h3pQhZ` 標 `.accessibilityHidden(true)` 或併入相片 alt 尾段（二選一，不得兩者皆無）。

④ **LITTLE SPROUT 小字的唯一出現地**：歡迎頁家族（01／01b／01c／01-iPad／AX3／F16）相片白邊 Imprint Row。其他任何 UI 不得再出現英文名。

⑤ **Print Stage 三個值，各自的組成要照抄**（不是同一個數字）：
- **01／01b：292** ＝ 5（角托上溢）＋ 印品 230.1 ＋ 5（角托下溢）＋ 51.9 呼吸帶；角托下緣→字標頂 ＝ 51.9＋`$sp-section` 44 ＝ **95.9**。
- **01c：424.6** ＝ 紙條 136.6 ＋ 5 ＋ 印品 230.1 ＋ 5（角托下溢）＋ 47.9 呼吸帶；角托下緣→Trust Row 頂 ＝ **91.9**。
- **AX3：296** ＝ 5 ＋ 230.1 ＋ 5 ＋ 55.9；AX3 的法務行會折行成 64pt，**不套 ⑥ 的 38pt 插槽**。
白邊 ＝ 側/上 8、下緣視覺 32（8＋7＋Imprint Row 17），下緣厚度由壓印那行字掙來，不要當成 padding 去調。

⑥ **法務／狀態行是一個 38pt 固定高度插槽**（01 `qde59`／01b `zOBxh`／01c `r1rUgn`），兩者**取代非併存**。節點名 `Signing Status` 裝的是登入狀態句、不是法務內容。狀態句字級必須 ≥ `$fs-note` 17，**不得降到 `$fs-meta` 13**（`NHDwj` 成員資格規則禁止「寫著你是誰／要怎麼改」的字用 13pt）。

⑦ **01b 與 01 只准差三件事**：Apple 鍵換 in-flight、Google/Email 鍵轉 `$surface-2`、法務行換狀態行（同一插槽）。**印品幾何、字標、tagline、信任行、按鈕座標一律不得變動**——驗收判準已量化：兩板逐像素差異必須全部落在 pt 589 以下的四條帶內。

⑧ `ZBIhu`／AX3 法務行四段式：SwiftUI 用 `AttributedString`/`Link` ＋ `ViewThatFits`，勿照抄 .pen 的四段排列（`flduf`/`XtNLC`/`XTCyT` 溢出屬工具表達力限制，計入已知 51 項）。

⑨ `mXQJh`（`cmp/Approval Status` 母版量測異常）：instance 全部正常，**勿拿母版量測做自動化 gate**。

⑩ `yOHuy` 的 `content:" "`：空狀態保留白邊帶行高、卡高 175 不塌縮是版式意圖，**不可整列隱藏**（`Text(name ?? " ")` 或等值寫法）。

⑪ **所有節點 id 必須以 PR 合併時的 HEAD 重新解析**——本輪 01c 字標 `G3kSy`→`AyjZc`（原 id 已查無），R10 `bPhGg`→`n4riFd`，R9 01 家族全換血。輪次中途 comment 裡的 id 一律不可沿用；以節點**名稱**定位比 id 可靠。

⑫ **已知溢出 51 項是設計意圖，不是 bug**：出血 13／角托 34／`mXQJh` 1／AX3 法務 3。任何自動化版面檢查要以這組數字當白名單基線。

---

補充（同一 comment 的「值得保留的清單」，實作時勿倒洗澡水）：沖印品白邊 8/8/32/8 且下緣厚度由 Imprint Row 掙來（勿改回 24）｜Lab Imprint 置中｜`print-ink`／`print-ink-secondary` 單值 token 與 Tokens 板 Row 2c/2d｜深色紙條與相片同寬 361、角托釘住接縫、紙條本身無暗角｜紙條內字標→tagline 8pt＝淺色 Head 內同一數字｜角托壓過紙緣 5pt｜iPad 直式大印品＋右欄登入的非對稱構圖｜AX3 鎖頭包 wrap 對第一行中線｜`yOHuy` 的單一空白｜06 家族 Upper/Footer flex spacer｜44pt 七張豁免的兩板一致措辭｜01/01b pt 589 以上逐像素相同。
