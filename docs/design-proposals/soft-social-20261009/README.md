# LS-511 · 柔粉社群共用元件提案

## r1g → r1i（2026-10-13）

狀態：**ready_for_pitch**。基準設計 A2 `349e2a19`、收據 B `b59e6338`。本輪只修共用元件庫與實例繼承；沒有繪製 r2 進入流程。

- 89 個 reusable 定義，含 18 個 AX3 定義；全部仍在 `C / Components · 共用元件`（`YiySC`）。原119個 authored refs 逐一保留沿革：既有板95、庫內24；新增6個OTP內容實例後共125，全部官方 Get 可解析。
- 樣式由定義繼承：根層嚴格樣式514→0（同值496、異值18）；明列10項禁用根層屬性479→0；遞迴後代樣式2093→0。VR原497同值／45異值口徑另含允許的context（21項）與文字content（7項）；根層image fill包含於514項樣式計數，完整數字保存在manifest。`geONL` 22pt段標現有3個實例。
- 實際狀態已成具名變體；選單觸發改`cmp/Menu Trigger`，新增文字動作改`cmp/Button Text / Add`，家庭提示改`cmp/Family Context Label`且role=text。Chip僅膠囊篩選；每個樣本有用途註記。
- `Button Icon` 命名統一；7個純圖示定義各有正確AX語意，另有水平／直向常駐文字版與AX3。Avatar依28／32／44／48／84排序。Notes既有列與`YPZvK`完全保留，只新增命名補註`V8lV2`。
- `HwhMJ`／`jxHRS`的content與Unicode分隔不變；13板ID不變。12張畫面重新原生匯出，交付PNG與A2每個RGBA通道差0，bytes亦相同。
- 已由主thread官方Pencil MCP編輯／Get／Export，官方CLI `save()`保存；未切檔、關閉或重啟Pen，保存後Get讀回。worker只讀檔／PNG／研究。未commit、push、PR或改Linear。

三位指定worker沿用 `gpt-6.1-sol / high`，無子層委派；實際thread資訊見manifest。`git status --porcelain`僅9個allowlist路徑，`git diff --check`通過。docs/REVIEW-RUBRIC.md的R1–R3因無實作不適用，R4 scope通過。

原生稿SHA256：`14cc71bc9376ea7b042f23ce3940b6163591a93a283f221b78624aa33c7439f8`。

### 逐板像素比較

每張780×1688；P模式畫面沿用原核准palette、無dither或縮放。比較最終交付PNG與Git A2，不把壓縮中間檔當交付。

| PNG | 最大通道差 | 變動像素 | bytes vs A2 |
| --- | ---: | ---: | --- |
| exports/01-home.png | 0 | 0 | 相同 |
| exports/02-memory.png | 0 | 0 | 相同 |
| exports/03-albums.png | 0 | 0 | 相同 |
| exports/04-child.png | 0 | 0 | 相同 |
| exports/05-food.png | 0 | 0 | 相同 |
| exports/06-family.png | 0 | 0 | 相同 |
| exports/07-composer.png | 0 | 0 | 相同 |
| exports/08-album-detail.png | 0 | 0 | 相同 |
| exports/09-notifications.png | 0 | 0 | 相同 |
| exports/10-search.png | 0 | 0 | 相同 |
| exports/11-invite.png | 0 | 0 | 相同 |
| exports/12-album-empty.png | 0 | 0 | 相同 |

r1e修改前重匯相對原LS-455圖已有0.051–0.082%噪訊的歷史、原>48門檻逐板結果仍保留於manifest screens.pixel_comparison與revision_history；本輪未調整門檻，直接要求A2 exact0。

### 元件庫匯出

以下5個section都在同一YiySC頂層板內，資料落點「元件庫，無」。全部2x；單檔≤400000bytes。較大圖採256色無dither量化，不重採樣；原生／交付SHA分列manifest。五圖原生vs交付RGB差>48占比依表序為0%、0.00003241%、0.00011145%、0.00963458%、0%，完整數字亦在manifest；此為元件庫量化差異，既有12畫面仍exact0。

| PNG | section ID | 像素尺寸 | bytes |
| --- | --- | --- | ---: |
| exports/00-components.png | `KnE0j` | 3216×3446 | 371755 |
| exports/00-components-inputs.png | `Y9pv2K` | 3216×2878 | 221114 |
| exports/00-components-content.png | `gSdyW` | 3216×1674 | 394259 |
| exports/00-components-ax3.png | `QLCky` | 3216×2569 | 226533 |
| exports/00-components-ax3-inputs.png | `X8cyG` | 3216×1454 | 212033 |

### AX3 實測

358pt＝390−16×2；正文／動作40pt、fixed-width與自動高度。表中行數來自官方Get文字高度÷行高，並以匯出圖視看。Tab四欄各89.5pt，四個標籤各1行。互動目標實測均≥44pt；靜態圖不代表原生Dynamic Type已測。

OTP依VR mn-4與品牌tokens.md的fs-otp規則使用Courier Prime 52pt；這是等寬數字例外，不把正文縮小。單格53×76pt，6格＋5個8pt間隔＝358pt。Apple／Google為官方點陣示意，實作用原生控制項，不宣稱點陣有可重排40pt文字。

| ID | 定義 | 寬 × 高 pt | 文字依序行數 |
| --- | --- | ---: | --- |
| `YWBav` | cmp/Button Primary · AX3 | 358 × 200.00 | 3 |
| `lAKcR` | cmp/Button Secondary · AX3 | 358 × 88.00 | 1 |
| `WzoZS` | cmp/Button Text · AX3 | 358 × 144.00 | 2 |
| `ZHbY7` | cmp/Chip · AX3 | 358 × 136.00 | 2 |
| `TYVis` | cmp/Nav Header · AX3 | 358 × 240.00 | 1／2 |
| `E7hep` | cmp/Section Title · AX3 | 358 × 112.00 | 2 |
| `Puhr6` | cmp/Family Scope Note · AX3 | 358 × 80.00 | 1 |
| `F7ROI` | cmp/List Row · AX3 | 358 × 370.00 | 1／2／1 |
| `x9L7US` | cmp/Tab Bar · AX3 | 358 × 140.00 | 1／1／1／1 |
| `xWtkY` | cmp/Empty State · AX3 | 358 × 620.00 | 2／4／1 |
| `VdPW8` | cmp/Button Apple · AX3 | 358 × 83.79 | 官方點陣，不適用 |
| `IDvsb` | cmp/Button Google · AX3 | 358 × 57.28 | 官方點陣，不適用 |
| `A2piF` | cmp/Text Field · AX3 | 358 × 320.00 | 1／2／2 |
| `F8AZF` | cmp/Button Icon / Labeled · AX3 | 358 × 80.00 | 1 |
| `hBVjU` | cmp/Button Icon / Labeled Vertical · AX3 | 358 × 124.00 | 1 |
| `P7DYXt` | cmp/OTP Cell · AX3 | 53 × 76.00 | 0 |
| `qQ0jL` | cmp/OTP Cell / Filled · AX3 | 53 × 76.00 | 1 |
| `DSnyu` | cmp/OTP Cell / Focused · AX3 | 53 × 76.00 | 1 |

### 官方登入圖稿 provenance

下載／渲染日期2026-10-13（Asia/Taipei）。兩個元件引用相對assets檔案，無data URI。

- Apple：[Sign in with Apple / 官方按鈕服務](https://developer.apple.com/documentation/signinwithapplerestapi/get-a-sign-in-with-apple-button-that-is-center-aligned)，black／continue／zh_TW／188×44pt／scale2，原文「透過 Apple 繼續」。既有376×88資產bytes與SHA不變；`zjeFm`188×44命中區不變。
- Google：[Google Identity Services for Web](https://developers.google.com/identity/gsi/web/reference/js-reference)官方`renderButton`，載入`https://accounts.google.com/gsi/client?hl=zh-TW`；locale `zh-TW`、standard／outline／large／continue_with／rectangular／width250。**官方 branding 包僅英文 PNG，繁中版由官方 SDK 渲染**。
- SDK版本：官方web endpoint自動更新、未公開semver；不捏造版本號。採2026-10-13同渲染瀏覽器取得的SDK快照識別：276700bytes，SHA256 `217de26e415f3d85403d2d8a0b7f37ad35e3abb1777d12214a5f32f9401b3bcd`。暫存來源檔另加1個換行，其檔案SHA為`cea33b43b48122e3f162394ec44ad62fefc2c1872f8ede8a73482fb4a7c9505f`；去掉新增換行即為上述官方response SHA。完整版本限制與fingerprint方法見manifest。
- SDK原文字串「透過 Google 帳戶繼續操作」，CSS字體Google Sans 500／14px，色值#3C4043、白底、#DADCE0框。使用官方輸出，未改字、改字體或自繪。Pen1.2.16的Chromium152.0.7977.130以deviceScaleFactor2截取完整250×40CSSpx按鈕，得到500×80 PNG；元件外層250×44pt命中區，圖稿不變形。
- 素材`assets/google-sign-in-ios-light-zh-TW@2x.png`，SHA256 `9b95700c661bfdafd7795fcc7e512859a6514ac4624f98860f5e1801988a640f`，16320bytes；一般定義`qmcWS`與AX3`IDvsb`都引用它，AX label與SDK原文相同。旧英文素材僅保留歷史來源，不被現行元件引用。
- **動詞不一致**：Apple「透過 Apple 繼續」vs Google「透過 Google 帳戶繼續操作」為兩家官方字串，不是設計決定。r1i裁決採SDK原文／字體，取代r1h的短文案／Roboto條件。

此為SDK視覺渲染；使用placeholder client ID，未執行登入或宣稱原生驗證通過。

### 實算對比

使用WCAG sRGB相對亮度公式，全部≥4.5:1。主鈕5.624:1低於7:1的AAA期望，保留既定色票並列informational。

| 前景 | 背景 | 比值 |
| --- | --- | ---: |
| #8E2447 | #F3C8D4 | 5.624:1 |
| #8E2447 | #FFFFFF | 8.422:1 |
| #8E2447 | #F6DDE2 | 6.561:1 |
| #715C65 | #FAF3F5 | 5.614:1 |
| #715C65 | #FFFFFF | 6.139:1 |
| #362B2F | #FAF3F5 | 12.442:1 |
| #3C4043 | #FFFFFF | 10.466:1 |
| #FFFFFF | #000000 | 21.000:1 |

### r2 待辦

**已轉r2，附清單**。18個純icon動作跨10板，下面涵蓋全部13板。r2及遷移使用`cmp/Button Icon / Labeled`（`Vy6NW`）或`Labeled Vertical`（`Qzs1X`），每個動作有常駐文字。A2舊ID與目前可Get的路徑同列；沒有另開後續票。

| 板ID | 目前動作ID → 建議標籤（A2沿革） |
| --- | --- |
| `ev2Pc` | 無 |
| `rsm56` | `jhJOL/xWRP3` → 通知（A2 `jijrr`）；`fp3pA/oAT3c/wtgxf` → 更多選項（A2 `dnOUH`） |
| `M7qpWP` | `VR4q4/IRH6k` → 返回（A2 `TEBBy`）；`z34rVC/wtgxf` → 更多選項（A2 `tiEk3`）；`FHrWY` → 傳送留言（A2 `UBUlb`） |
| `WavOD` | 無 |
| `ftrBE` | 無 |
| `e347tY` | `PIYIA/krKB0` → 返回（A2 `oht9A`） |
| `CxGiV` | `x4pFP/n839ci` → 查看媽媽（A2 `gNxjn`）；`DkYgE/n839ci` → 查看爸爸（A2 `C6uU5E`）；`HHFSL/n839ci` → 查看阿嬤（A2 `wPjty`） |
| `LefzY` | `H1K2h/krKB0` → 返回（A2 `FtgLT`） |
| `m8Dfo` | `X8VMJ/nPBZb` → 返回（A2 `Q0cDAS`）；`X8VMJ/cFQSZ` → 更多選項（A2 `jhmIE`） |
| `Y506Lc` | `L0ok0/U15iFr` → 返回（A2 `X9nkc6`） |
| `MZghz` | `e7RVQ/IRH6k` → 返回（A2 `TaBbn`）；`Qcigg/OdDUh` → 清除搜尋（A2 `bYwoa`） |
| `g5YJ4r` | `imt1I/IRH6k` → 返回（A2 `fsjM4`） |
| `Qr7b0` | `y2k9h/nPBZb` → 返回（A2 `FxJ8l`）；`y2k9h/cFQSZ` → 更多選項（A2 `GoBqy`） |

### 實例AX與節點沿革

53筆source AX語意已全部對應新路徑，官方Get確認53/53 context原值保留；manifest `source_accessibility_annotations`記錄當前ID、A2舊ID、原metadata與繼承觀察值。**未宣稱ref metadata override已修復**；依r1g裁決採manifest作實作語意來源，屬informational。Family Context Label本身已改成非互動role=text。

| 板ID | A2 authored節點 | 現在 authored節點 | A2 refs | 現在 refs | 現在展開節點 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `ev2Pc` | 15 | 15 | 2 | 2 | 17 |
| `rsm56` | 17 | 17 | 10 | 10 | 70 |
| `M7qpWP` | 16 | 16 | 8 | 8 | 45 |
| `WavOD` | 17 | 17 | 11 | 11 | 61 |
| `ftrBE` | 39 | 39 | 9 | 9 | 72 |
| `e347tY` | 36 | 36 | 9 | 9 | 50 |
| `CxGiV` | 21 | 21 | 8 | 8 | 66 |
| `LefzY` | 21 | 21 | 9 | 9 | 43 |
| `m8Dfo` | 23 | 23 | 5 | 5 | 35 |
| `Y506Lc` | 38 | 38 | 8 | 8 | 52 |
| `MZghz` | 29 | 29 | 7 | 7 | 60 |
| `g5YJ4r` | 23 | 23 | 4 | 4 | 33 |
| `Qr7b0` | 10 | 10 | 5 | 5 | 43 |

### 新增／重建定義

包含真實畫面狀態變體、語意更正後的新定義ID與新增AX3。完整119實例前後沿革在manifest `original_ref_lineage`。

| ID | 定義 |
| --- | --- |
| `f05EGv` | cmp/Button Text / Comment |
| `B4AA9w` | cmp/Button Icon / More |
| `E6dox` | cmp/Button Icon / Back |
| `cRytC` | cmp/Button Icon / Notify |
| `FHO6v` | cmp/Button Icon / Send |
| `eJdEV` | cmp/Button Icon / Clear |
| `iMYQ4` | cmp/Button Icon / Disclosure |
| `f2bLlD` | cmp/Button Icon / Close |
| `Qzs1X` | cmp/Button Icon / Labeled Vertical |
| `qmcWS` | cmp/Button Google |
| `gKW4U` | cmp/Chip / Selected Filled |
| `YxEPY` | cmp/Chip / Unselected |
| `Sy8pQ` | cmp/Chip / Unselected on Page |
| `c8VHv` | cmp/Chip / Unselected Outlined |
| `o3fhUh` | cmp/Chip / Selected Avatar |
| `S2s15` | cmp/Family Context Label |
| `WC1e0` | cmp/Section Title / 17 pt Medium |
| `ySqEr` | cmp/Family Scope Note / Muted Privacy |
| `j8K62` | cmp/Family Scope Note / Muted |
| `BDSwB` | cmp/Family Scope Note / Muted Empty Album |
| `IDvsb` | cmp/Button Google · AX3 |
| `A2piF` | cmp/Text Field · AX3 |
| `F8AZF` | cmp/Button Icon / Labeled · AX3 |
| `hBVjU` | cmp/Button Icon / Labeled Vertical · AX3 |
| `P7DYXt` | cmp/OTP Cell · AX3 |
| `qQ0jL` | cmp/OTP Cell / Filled · AX3 |
| `DSnyu` | cmp/OTP Cell / Focused · AX3 |

### 全部共用元件

命名規則：`cmp/家族 / 狀態`；大字變體以` · AX3`結尾。

| ID | 定義 | authored實例數 |
| --- | --- | ---: |
| `omZ3B` | cmp/Status Bar | 12 |
| `HH1QX` | cmp/Nav Header | 1 |
| `P7mWr` | cmp/Nav Header / Back Balanced | 3 |
| `rDHvN` | cmp/Nav Header / Right Text | 3 |
| `J8CcLb` | cmp/Nav Header / Back and Text | 2 |
| `Wz0yi` | cmp/Nav Header / Back and Icon | 2 |
| `z6ri9` | cmp/Nav Header / Notification | 1 |
| `KQFqi` | cmp/Button Primary | 7 |
| `vMRIi` | cmp/Button Primary / Icon 44 | 1 |
| `o9DR9i` | cmp/Button Secondary | 1 |
| `AzENe` | cmp/Button Text / Icon on Surface | 1 |
| `RAFgI` | cmp/Button Text / Like | 1 |
| `f05EGv` | cmp/Button Text / Comment | 1 |
| `Sm3n8` | cmp/Button Text / Compact Add | 1 |
| `SpvTW` | cmp/Button Text / Add | 1 |
| `wsApu` | cmp/Button Text / Record Link | 1 |
| `spdU6` | cmp/Button Text / Compact | 4 |
| `r7FT9D` | cmp/Button Text / Outlined Link | 1 |
| `B4AA9w` | cmp/Button Icon / More | 2 |
| `E6dox` | cmp/Button Icon / Back | 4 |
| `cRytC` | cmp/Button Icon / Notify | 1 |
| `FHO6v` | cmp/Button Icon / Send | 1 |
| `eJdEV` | cmp/Button Icon / Clear | 1 |
| `iMYQ4` | cmp/Button Icon / Disclosure | 1 |
| `f2bLlD` | cmp/Button Icon / Close | 0 |
| `Vy6NW` | cmp/Button Icon / Labeled | 0 |
| `Qzs1X` | cmp/Button Icon / Labeled Vertical | 0 |
| `Umbo7` | cmp/Tab Bar | 2 |
| `rfO68` | cmp/Tab Bar / Selected 2 | 2 |
| `doiqi` | cmp/Tab Bar / Selected 3 | 1 |
| `o5gk0` | cmp/Tab Bar / Selected 4 | 1 |
| `zjeFm` | cmp/Button Apple | 0 |
| `qmcWS` | cmp/Button Google | 0 |
| `gKW4U` | cmp/Chip / Selected Filled | 3 |
| `TKP5U` | cmp/Chip / Selected Outlined | 2 |
| `YxEPY` | cmp/Chip / Unselected | 4 |
| `Sy8pQ` | cmp/Chip / Unselected on Page | 2 |
| `c8VHv` | cmp/Chip / Unselected Outlined | 1 |
| `AbF6y` | cmp/Chip / Unselected Avatar | 1 |
| `o3fhUh` | cmp/Chip / Selected Avatar | 0 |
| `dqH6x` | cmp/Menu Trigger / Avatar | 1 |
| `ztLwH` | cmp/Menu Trigger / Tag | 1 |
| `yG31M` | cmp/Menu Trigger / Date | 1 |
| `S2s15` | cmp/Family Context Label | 1 |
| `PkeXE` | cmp/Avatar / 28 pt | 2 |
| `NxYOK` | cmp/Avatar / 32 pt | 1 |
| `Xgk7U` | cmp/Avatar / 44 pt | 7 |
| `FF1yR` | cmp/Avatar / 48 pt | 1 |
| `fzLJC` | cmp/Avatar / 84 pt | 1 |
| `rtKjT` | cmp/Text Field | 0 |
| `V0xV0` | cmp/Text Field / Comment | 1 |
| `kgvVr` | cmp/Text Field / Multiline | 1 |
| `fBw8K` | cmp/Text Field / Search | 1 |
| `ojvcu` | cmp/OTP Cell | 0 |
| `B9wID` | cmp/OTP Cell / Filled | 0 |
| `v7CIP` | cmp/OTP Cell / Focused | 0 |
| `l0LrlB` | cmp/Section Title | 3 |
| `geONL` | cmp/Section Title / 22 pt | 3 |
| `WC1e0` | cmp/Section Title / 17 pt Medium | 1 |
| `TJsFD` | cmp/Family Scope Note | 1 |
| `ySqEr` | cmp/Family Scope Note / Muted Privacy | 1 |
| `j8K62` | cmp/Family Scope Note / Muted | 1 |
| `BDSwB` | cmp/Family Scope Note / Muted Empty Album | 1 |
| `dSNcO` | cmp/Card Post | 1 |
| `vhkQe` | cmp/Card Album | 4 |
| `VJPTn` | cmp/Comment Row | 1 |
| `rTQZR` | cmp/Post Author | 2 |
| `Xu5Bf` | cmp/Post Reaction Summary | 2 |
| `y9s1z` | cmp/Post Actions | 2 |
| `PiIWd` | cmp/List Row | 3 |
| `KeOi7` | cmp/Empty State | 1 |
| `YWBav` | cmp/Button Primary · AX3 | 0 |
| `lAKcR` | cmp/Button Secondary · AX3 | 0 |
| `WzoZS` | cmp/Button Text · AX3 | 0 |
| `ZHbY7` | cmp/Chip · AX3 | 0 |
| `TYVis` | cmp/Nav Header · AX3 | 0 |
| `E7hep` | cmp/Section Title · AX3 | 0 |
| `Puhr6` | cmp/Family Scope Note · AX3 | 0 |
| `F7ROI` | cmp/List Row · AX3 | 0 |
| `x9L7US` | cmp/Tab Bar · AX3 | 0 |
| `xWtkY` | cmp/Empty State · AX3 | 0 |
| `VdPW8` | cmp/Button Apple · AX3 | 0 |
| `IDvsb` | cmp/Button Google · AX3 | 0 |
| `A2piF` | cmp/Text Field · AX3 | 0 |
| `F8AZF` | cmp/Button Icon / Labeled · AX3 | 0 |
| `hBVjU` | cmp/Button Icon / Labeled Vertical · AX3 | 0 |
| `P7DYXt` | cmp/OTP Cell · AX3 | 0 |
| `qQ0jL` | cmp/OTP Cell / Filled · AX3 | 6 |
| `DSnyu` | cmp/OTP Cell / Focused · AX3 | 0 |

### 審查與未完成

本輪實際1輪內部凍結複核，含1次minor修正後追驗；視覺 reviewer 對目前原生SHA回報 APPROVE，delivery verifier 回報 PASS。最後只更新文件狀態與審查紀錄，設計及PNG維持凍結。先前r1f／r1e紀錄完整保留manifest revision_history，Claude VR R1的A2結論為ITERATE，不改寫歷史。

- 四項MAJOR與命名／排序／用途／AX3／2x匯出已修正；內部抓到未選外框Chip缺strokeWidth，已補1pt，只影響庫內範例。
- INFORMATIONAL：18純icon動作已轉r2；53實例AX依manifest；官方provider AX3點陣示意；無corner_anchor元件，皆依r1g裁決。
- INFORMATIONAL：原生VoiceOver／DynamicType／鍵盤／登入與既有整屏AX3未驗證，留r2／遷移。
- INFORMATIONAL：GIS不提供公開semver，以官方URL、日期、環境與來源SHA識別。
- INFORMATIONAL：保存＋Get讀回完成；共享Pen未關閉重開，獨立重開驗證未做。
- 待Claude：凍結下一個設計commit A、以`scripts/design/overflow-scan.js`跑正典全樹收據與gates、後續盲審。Codex未跑全樹scanner、未寫`design/evidence`，不填虛構0。

暫存官方Get／像素／AX尺寸佐證位於`/tmp/LS-511-r1g-evidence/`，原生重匯位於`/tmp/LS-511-r1i-final-native-v3/`。這些不是Git錨定收據。

### 目前交付 SHA256

README不自列hash，避免循環參照；manifest不自列hash，由本表列出。

| 路徑 | SHA256 |
| --- | --- |
| `.gitattributes` | `41d1d6b8931ca0534a187b19f57585d644616540ddc344cb1d0661a449524827` |
| `SCREEN-MANIFEST.json` | `018ed3fc29e010660cfe2d679c15d4a62e43cd98554a194ec9518cf7260bb8c9` |
| `assets/app-icon.png` | `356a7f56136abe8068c7c2d21a3dc73d6287e5faea88ec8186e79361d7d77a37` |
| `assets/apple-sign-in-zh-TW@2x.png` | `81c4419beb013011e511b2bed6976004c4d2c28a4316d09d9a66577f1449ece2` |
| `assets/child-leaf.jpg` | `f57ac0bbdab129a61dd51a99eb8c0444c531075cfd1705d6b651524645b8cf7f` |
| `assets/child.jpg` | `768dc67cfcb193a6fe344af6dabab781153c000926b871847917e38bfeebf127` |
| `assets/dad.jpg` | `2e5538256f84012de3f3f21f92682a29f10e620bc982f2ef0ec9ce71fcc19fd4` |
| `assets/family-moment.jpg` | `b603e388bdd7638b2a17c6cb9cfb1ac236e1394b2fe6c3bb06220af37a3a3754` |
| `assets/family-picnic.jpg` | `18d2601ab4bc6e4bbd737ff916aae6ca8368ecbdc6bba612577cbc405e2184ff` |
| `assets/google-sign-in-ios-light-zh-TW@2x.png` | `9b95700c661bfdafd7795fcc7e512859a6514ac4624f98860f5e1801988a640f` |
| `assets/google-sign-in-ios-light@2x.png` | `13cd8a896195c12332cdfa74135f7075339a23482210c4f484098cf7e77ff631` |
| `assets/grandma.jpg` | `2e4faf9cb95ca983c64d907a951998d67a9e55d1699e2f906f0a41c8b965ee5d` |
| `assets/mandarin-sticker.png` | `e25b803b978c20bf9e7f61ca30882aa766fdc06c2e8f97db049afa82b5bbef0b` |
| `assets/mom.jpg` | `dbef7acf304bd38e436824f3c0469724659da3d9c245879edff9f15e0774ccf4` |
| `assets/wordmark.png` | `f17e92c5ffe215356ff5a8d54ad25f842efa11d4c49fbc6ced1707be3c38195b` |
| `exports/00-components-ax3-inputs.png` | `abbdc13cab5c484c3e3edb2f396791451c28a2f702836192c755cc3eec7fad62` |
| `exports/00-components-ax3.png` | `c29759afc0d5195c86d68db256d0bf42a16fc0d35746a29ac12157892430324d` |
| `exports/00-components-content.png` | `70670feaa2ef17430e69a4766e4674960bfd04bf5c737fb9c8f6a0c77aae6ff4` |
| `exports/00-components-inputs.png` | `59ddce5113e21959e3d4a38124000fc0948b3d19ed15b30f01151ef0f8728af2` |
| `exports/00-components.png` | `7b9b6c3ff81d5a3ef1a0e35c4cf7ea74ac7bfd8723e327b4f69ae409f8c9185e` |
| `exports/01-home.png` | `1d60265c62df0752ece5e5b382b93db8b3ec1cb0c977c251713cc5171817d1ea` |
| `exports/02-memory.png` | `49b5bd789b08b60efaa5e051c1103e71950270b586a4db6f970082db3a8a2bee` |
| `exports/03-albums.png` | `29eb1594b70dc13e19094cbfc25538f12c1b138c02384eb3366de07c49f33f61` |
| `exports/04-child.png` | `8818254dd95ec5c304a72eab11a27973c275cb7a58d51e5c3a896d0b171aa710` |
| `exports/05-food.png` | `ea24ec45a2c9f13339100d01af3a7177b1a3f82eb8e8af76bd002751f1db16a7` |
| `exports/06-family.png` | `782181f16ad89e92275ad3d92f05067807238998c6b46dcce59b71b883f2eb7a` |
| `exports/07-composer.png` | `e6f353c5b2490ea45e414a2e0e03f63bd3e452f3fe4069360b246e825a6019b6` |
| `exports/08-album-detail.png` | `ec00fc0dcc62854d151bcf6d04cecb200978236d37c2d22b19ca5de683bf2fd9` |
| `exports/09-notifications.png` | `ababde8738b64ea370348fdf6a53996833630fb14e926078ccab08e1035b2765` |
| `exports/10-search.png` | `44d65177985d4304c6db1699218a11d5158ecbeac78b211feefbcfd552611e3b` |
| `exports/11-invite.png` | `427c717b8fe4df51fe8927b35be1a1d934d1e1df8da2976888ffa8e7a95694cd` |
| `exports/12-album-empty.png` | `52a583ade46b5adfe437580fd4b4e185584cd23d199b69ece15edcee22569356` |
| `littlesprout-soft-social.pen` | `14cc71bc9376ea7b042f23ce3940b6163591a93a283f221b78624aa33c7439f8` |
| `skill/SKILL.md` | `9b4a627dc735bf3f26209a6751d1002ef0ef8dd0800ae23eb099850f13a2e760` |
| `skill/agents/openai.yaml` | `ab452d2f8df8e0ec0342dd7beeef04bf4a33b3c3cb0091eec15348b250a26fa3` |
| `skill/references/baseline.md` | `b5208d9136068d815efd8f8e3e0dd4d8e0187c3b54870f6fa6974aa00c44a095` |
| `skill/references/images/growth.png` | `0a8369f1117f7b07b40956104417c0aa37e9a1282ef6632d450785ed0db67da2` |
| `skill/references/images/home.png` | `18b6fd6fa4ac9b460c1bd2ce1c12beec7cd0bcbbe363c75ab2fefaea69ed0377` |
| `skill/references/visual-system.md` | `3902d2565485113a6986fde314573a804157c26714dee254409822b062281e30` |
