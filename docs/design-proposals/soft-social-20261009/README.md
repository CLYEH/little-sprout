# LS-511 · 柔粉社群共用元件提案

## LS-511 r1e 元件化（2026-10-13）

狀態：**needs_revision**。原生元件化與匯出已完成；下列 open findings 尚未解除，並非人審接受或原生實作完成。原 LS-455 說明保留於下方歷史段落。

- 新增 `C / Components · 共用元件`（`YiySC`），54 個 reusable 定義；Notes 僅新增 `YPZvK`，資料落點「元件庫，無」。原13列、13板ID與`HwhMJ`/`jxHRS`精確Unicode內容保留。
- 既有13板共134次由手畫節點改為ref；最終既有板95個 authored refs，含元件庫全稿119個 authored refs，所有目標可由官方Get解析。包含父層收納後的數量與134次操作不同，不混稱。
- 12張畫面的同環境修改前後原生PNG **所有像素完全相同，最大通道差0**。r1e裁決以此為主驗收；原基準比較與交付PNG壓縮差異完整記錄，不調整門檻。
- PNG維持780×1688；元件板1608×2605、scale1；所有交付PNG與新官方素材≤400000bytes。較大螢幕PNG使用原基準palette量化，無dither或縮放；元件板使用256色量化。原生與壓縮後SHA256分列manifest。
- 原生稿由主thread官方Pencil MCP編輯/匯出，以`pen interactive --app desktop`的`save()`存檔；未用`--in/--out`、未切換或重啟共享Pen。保存後active文件Get讀回；未獨立關閉重開。
- 三個worker實際runtime皆`gpt-6.1-sol/high`；只做規格/PNG/檔案驗證，r1d起無worker Pencil呼叫。內部凍結審查實際完成2輪，視覺審查ITERATE，交付機械核對PASS、就緒狀態needs_revision；Claude盲審、commit A/B與正典掃描未完成。

### 像素比較（百分比；RGB任一通道差>48）

| PNG | 同環境前後原生 | 原基準vs原生 | 原基準vs交付PNG |
| --- | ---: | ---: | ---: |
| exports/01-home.png | 0.00000000 | 0.08134342 | 0.07663446 |
| exports/02-memory.png | 0.00000000 | 0.08225483 | 0.09045753 |
| exports/03-albums.png | 0.00000000 | 0.06303925 | 0.05658342 |
| exports/04-child.png | 0.00000000 | 0.05263398 | 0.05263398 |
| exports/05-food.png | 0.00000000 | 0.04032993 | 0.04032993 |
| exports/06-family.png | 0.00000000 | 0.05096306 | 0.05096306 |
| exports/07-composer.png | 0.00000000 | 0.04344392 | 0.06281140 |
| exports/08-album-detail.png | 0.00000000 | 0.05035545 | 0.04070969 |
| exports/09-notifications.png | 0.00000000 | 0.03379815 | 0.03379815 |
| exports/10-search.png | 0.00000000 | 0.02962085 | 0.02962085 |
| exports/11-invite.png | 0.00000000 | 0.05817839 | 0.05817839 |
| exports/12-album-empty.png | 0.00000000 | 0.03007656 | 0.03007656 |

原基準7張超過0.05%在編輯前即出現；邊缘分析支持抗鋸齒/調色盤差異的推論，並非已證實渲染器原因。未把原門檻結果改寫為pass。

### 節點與實例

| 板ID | 原節點 | 替換操作 | 最終authored節點 | 最終authored refs | 展開節點 |
| --- | ---: | ---: | ---: | ---: | ---: |
| ev2Pc | 17 | 2 | 15 | 2 | 17 |
| rsm56 | 67 | 19 | 17 | 10 | 67 |
| M7qpWP | 43 | 14 | 16 | 8 | 43 |
| WavOD | 61 | 12 | 17 | 11 | 61 |
| ftrBE | 70 | 11 | 39 | 9 | 70 |
| e347tY | 49 | 11 | 36 | 9 | 49 |
| CxGiV | 63 | 15 | 21 | 8 | 63 |
| LefzY | 42 | 11 | 21 | 9 | 42 |
| m8Dfo | 35 | 7 | 23 | 5 | 35 |
| Y506Lc | 49 | 10 | 38 | 8 | 49 |
| MZghz | 60 | 9 | 29 | 7 | 60 |
| g5YJ4r | 33 | 5 | 23 | 4 | 33 |
| Qr7b0 | 43 | 8 | 10 | 5 | 43 |

### 共用元件與變體

| 定義 | 節點ID |
| --- | --- |
| `cmp/Status Bar` | `omZ3B` |
| `cmp/Nav Header` | `HH1QX` |
| `cmp/Nav Header / Back Balanced` | `P7mWr` |
| `cmp/Nav Header / Right Text` | `rDHvN` |
| `cmp/Nav Header / Back and Text` | `J8CcLb` |
| `cmp/Nav Header / Back and Icon` | `Wz0yi` |
| `cmp/Nav Header / Notification` | `z6ri9` |
| `cmp/Tab Bar` | `Umbo7` |
| `cmp/Tab Bar / Selected 2` | `rfO68` |
| `cmp/Tab Bar / Selected 3` | `doiqi` |
| `cmp/Tab Bar / Selected 4` | `o5gk0` |
| `cmp/Avatar` | `Xgk7U` |
| `cmp/Avatar / 28 pt` | `PkeXE` |
| `cmp/Avatar / 48 pt` | `FF1yR` |
| `cmp/Avatar / 84 pt` | `fzLJC` |
| `cmp/Avatar / 32 pt` | `NxYOK` |
| `cmp/Button Primary / Icon 44` | `vMRIi` |
| `cmp/Button Primary` | `KQFqi` |
| `cmp/Button Secondary` | `o9DR9i` |
| `cmp/Button Text / Icon on Surface` | `AzENe` |
| `cmp/Button Text / Icon and Label` | `RAFgI` |
| `cmp/Button Text / Compact Add` | `Sm3n8` |
| `cmp/Button Text / Record Link` | `wsApu` |
| `cmp/Button Text` | `spdU6` |
| `cmp/Button Text / Outlined Link` | `r7FT9D` |
| `cmp/Button Icon` | `oi3E0` |
| `cmp/Chip` | `c4WEm` |
| `cmp/Chip / Selected Label` | `TKP5U` |
| `cmp/Chip / Avatar Unselected` | `AbF6y` |
| `cmp/Chip / Family Context` | `mwQ24` |
| `cmp/Chip / Avatar Selected` | `dqH6x` |
| `cmp/Chip / Add Child` | `SpvTW` |
| `cmp/Chip / Child Tag` | `ztLwH` |
| `cmp/Chip / Date Tag` | `yG31M` |
| `cmp/Button Apple` | `zjeFm` |
| `cmp/Button Google` | `mkAh0` |
| `cmp/Section Title` | `l0LrlB` |
| `cmp/Section Title / 22 pt` | `geONL` |
| `cmp/Text Field / Comment` | `V0xV0` |
| `cmp/Text Field / Multiline` | `kgvVr` |
| `cmp/Text Field / Search` | `fBw8K` |
| `cmp/Text Field` | `rtKjT` |
| `cmp/OTP Cell` | `ojvcu` |
| `cmp/OTP Cell / Filled` | `B9wID` |
| `cmp/OTP Cell / Focused` | `v7CIP` |
| `cmp/Comment Row` | `VJPTn` |
| `cmp/List Row` | `PiIWd` |
| `cmp/Empty State` | `KeOi7` |
| `cmp/Card Post` | `dSNcO` |
| `cmp/Post Author` | `rTQZR` |
| `cmp/Post Reaction Summary` | `Xu5Bf` |
| `cmp/Post Actions` | `y9s1z` |
| `cmp/Card Album` | `vhkQe` |
| `cmp/Family Scope Note` | `TJsFD` |

### 官方登入圖稿 provenance

兩檔下載日期均2026-10-13（Asia/Taipei），原始bytes未修改、無改字、自繪或裁切；376×88 pixels原比例呈現188×44pt。

- `assets/apple-sign-in-zh-TW@2x.png`：[Apple Design Resources / Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple/)，使用Apple官方[按鈕圖像服務](https://developer.apple.com/documentation/signinwithapplerestapi/get-a-sign-in-with-apple-button-that-is-center-aligned)發布的black / Continue / zh_TW / radius12 / scale2變體（「透過 Apple 繼續」）。SHA256 `81c4419beb013011e511b2bed6976004c4d2c28a4316d09d9a66577f1449ece2`。
- `assets/google-sign-in-ios-light@2x.png`：[Google Identity / Sign in with Google branding guidelines](https://developers.google.com/identity/branding-guidelines)，官方[signin-assets.zip](https://developers.google.com/static/identity/images/signin-assets.zip)的`iOS/PNG @2x/Light/Theme=Light, Show text=Yes, Shape=Square, Platform=iOS@2x.png`。SHA256 `13cd8a896195c12332cdfa74135f7075339a23482210c4f484098cf7e77ff631`。

兩個provider元件均引用相對assets路徑，無data URI。Google英文官方字樣/14pt品牌規格屬provider圖稿，不能當成17pt app正文規則或繁中完成證據。

### 實際檢查與open findings

- 實算對比：rose/primary5.624、muted/canvas5.614、ink/canvas12.442、muted/blush4.782、Google ink/white16.483、Apple white/black21:1。靜態明定Button/Tab容器≥44pt；fill寬度與原生命中行為另待驗。
- **MAJOR F01**：原稿返回/通知/更多/傳送/清除等icon-only動作未有常駐可見文字，與嚴格icon文字規則衝突；本輪保留原像素，未默默豁免。無後續票ID。
- **MAJOR F02**：AX3未驗證；正常字級PNG不能證明Dynamic Type不截斷。
- **MAJOR F03**：Pencil對ref的metadata覆寫未保留，53處原始AX標籤繼承定義值；已把原始metadata保存在實例context與manifest的`source_accessibility_annotations`。不得直接採用繼承值生成實作AX標籤；需工具支援或經審查的語意變體策略。
- **INFO F04**：原PNG差異如上，r1e已裁定主比對方法。
- **INFO F05**：Claude對設計commit A跑`scripts/design/overflow-scan.js`，收據`design/evidence/LS-511-r1-overflow.json`、`head_sha=A`，再commit B；Codex未跑scanner/gates、未寫收據。外部盲審待Claude。
- **INFO F06**：`cmp/`命名依brief；為避免切換共享Pen，未直接開主稿對照。
- **INFO F07**：provider raster圖稿/語言與原生控制行為需r2驗證。
- **INFO F08**：保存後Get讀回，未關閉重開共享文件。

- **RESOLVED F09（原MINOR）**：第一輪發現Apple定義的素材hash與標籤過時；第二輪以`zjeFm`修正為「透過 Apple 繼續」及實際官方素材hash。已核對舊`Lonlu`無ref；視覺schema與元件板PNG不變。
- **INFO F10**：palette壓縮造成交付PNG與原生PNG差異；兩者hash與數值分列，exact0僅指同環境前後原生圖。
- **INFO F11**：僅核對已提供狀態（含OTP空白/已填/聚焦）；error/disabled未要求或提供，不視為已驗證。

### 內部審查記錄

| 輪次 | 凍結原生稿SHA256 | 範圍與結果 |
| --- | --- | --- |
| 1 | `297fa9ba8f7296420658e32d6221739a5564b6efb2c57d564ec73a79c63368ef` | 12屏＋元件板完整檢視；視覺ITERATE；交付檔案、ref、素材來源、像素機械核對PASS，就緒FAIL。發現F09。 |
| 2 | `5be1b222c0d5d56d385b4546a57ac2b94252df60eaf694388c5d0e9c1e665dcf` | 重審Apple定義及元件板；F09解除。13張交付PNG hash皆不變，承接前輪畫面結果。視覺仍ITERATE；交付局部核對PASS，就緒needs_revision。 |

F01兩位reviewer皆列MAJOR；F02/03視覺reviewer列INFORMATIONAL，交付verifier列MAJOR readiness條件，兩者評估均保留。不得以context註記取代實際AX metadata正確性。

本機暫存證據位於`/tmp/LS-511-r1e-freeze/`與`/tmp/LS-511-r1e-review2/`；第一輪Get、manifest、README歷史快照有保留，第一輪原生二進位未另存，第二輪原生稿已有獨立副本。它們不是Git錨定收據。最終只補審查記錄與hash，未再次修改原生稿或匯出圖。

詳細定義、134次替換沿革、逐板數字、SHA256與來源見`SCREEN-MANIFEST.json`。未commit/push/開PR/改Linear；r2流程畫面未繪製。

## LS-455 歷史交付說明（以下數值為歷史快照）

# 一起長大・柔粉社群視覺提案

**LS-455** · 來源：[GitHub issue #597](https://github.com/CLYEH/little-sprout/issues/597) · 設計日期：2026-10-09 · 交付日期：2026-10-10（Asia/Taipei）。

本包為十二屏手機視覺提案與獨立品牌 skill，供方向評估。初始七屏方向獲使用者認可，新增五屏為延伸提案。此交付不代表正式產品設計替換或實作完成。

## 交付內容

- `littlesprout-soft-social.pen`：獨立、可編輯的 Pencil 原生稿；2026-10-12 已加入 r1 註記與年齡分隔修正。
- `exports/`：十二張 780×1688（2x）原生匯出預覽，每張嚴格小於 400,000 bytes（400 KB）；較大的圖使用 PNG 調色盤壓縮，沒有縮小尺寸。
- `assets/`：原生稿引用的十個必要素材；相對路徑保留在此提案目錄。素材來源類型見索引，PNG 同樣小於 400,000 bytes。
- `skill/`：完整、獨立的品牌 skill，包含入口、agent 設定、兩份規範與兩張內附參考；不安裝或替換現有 skill。
- `SCREEN-MANIFEST.json`：畫面、原生節點、匯出檔與素材來源類型索引。
- `.gitattributes`：固定本包文字換行為 LF，並將原生稿與圖片視為二進位，讓跨平台 checkout 的 SHA256 一致。

以 Pencil 開啟原生稿時，請保留 assets/ 相對位置。字型為 Noto Sans TC，未隨包附帶。PNG 是靜態預覽；ImageGen 只提供部分畫面內素材，並非十二屏的原生 UI 稿。

## r1 修稿（2026-10-12；續派 r1b）

- 原生稿已存檔：新增 `實作註記 / Handoff Notes`（`tVh58`）的「畫面級屬性」13 列，每列九欄；每列含現行正典板名、節點 id 與「資料落點」。不確定的實作契約明列「待實作票定」。
- 原有 632 個節點僅 `HwhMJ.content`、`jxHRS.content` 改變：年齡片語為 `1\u00A0歲\u00A03\u00A0個\u2060月`；字型、版面及其他原有屬性未改。新增 Notes 後共 649 個節點。
- 官方 Pencil `Get` 核對修改前後屬性、Notes 13 × 9 欄及 Unicode；以官方 CLI `save()` 存入同一文件，未切換或重開文件。
- `exports/` 保留 `c2ef2fde` 的十二張基準預覽，雜湊未變；它們不是 r1 新匯出。鎖屏期間未做 bounds／溢出／新渲染驗證。
- 本輪未 commit、push 或寫入掃描收據。Claude 接手提交設計 commit A、執行兩支 development 版 gate、解鎖後跑正典掃描並以 `head_sha=A` 產出收據，再提交審查／收據 commit B。
- 畫面 state、來源路徑、原生稿 SHA256、基準匯出 provenance 及未完成驗證見 `SCREEN-MANIFEST.json`。

## 畫面索引

| 畫面 | 原生節點 | 預覽 | Bytes |
| --- | --- | --- | ---: |
| 家庭動態 | `rsm56` | [exports/01-home.png](exports/01-home.png) | 206,836 |
| 回憶詳情 | `M7qpWP` | [exports/02-memory.png](exports/02-memory.png) | 224,025 |
| 相簿 | `WavOD` | [exports/03-albums.png](exports/03-albums.png) | 290,900 |
| 寶貝成長 | `ftrBE` | [exports/04-child.png](exports/04-child.png) | 190,974 |
| 飲食小記 | `e347tY` | [exports/05-food.png](exports/05-food.png) | 175,122 |
| 家庭 | `CxGiV` | [exports/06-family.png](exports/06-family.png) | 197,921 |
| 加入照片 | `LefzY` | [exports/07-composer.png](exports/07-composer.png) | 214,398 |
| 相簿內頁 | `m8Dfo` | [exports/08-album-detail.png](exports/08-album-detail.png) | 311,699 |
| 通知 | `Y506Lc` | [exports/09-notifications.png](exports/09-notifications.png) | 236,276 |
| 回憶搜尋 | `MZghz` | [exports/10-search.png](exports/10-search.png) | 381,506 |
| 邀請家人 | `g5YJ4r` | [exports/11-invite.png](exports/11-invite.png) | 157,666 |
| 相簿尚無照片 | `Qr7b0` | [exports/12-album-empty.png](exports/12-album-empty.png) | 115,583 |

## 目前交付 SHA256

README不自列hash，避免循環參照。

| 路徑 | SHA256 |
| --- | --- |
| `.gitattributes` | `41d1d6b8931ca0534a187b19f57585d644616540ddc344cb1d0661a449524827` |
| `SCREEN-MANIFEST.json` | `fd6c2367dfdfd3fd6781179e7bd423be020f90b081d7173b7a4a703cf431f050` |
| `assets/app-icon.png` | `356a7f56136abe8068c7c2d21a3dc73d6287e5faea88ec8186e79361d7d77a37` |
| `assets/apple-sign-in-zh-TW@2x.png` | `81c4419beb013011e511b2bed6976004c4d2c28a4316d09d9a66577f1449ece2` |
| `assets/child-leaf.jpg` | `f57ac0bbdab129a61dd51a99eb8c0444c531075cfd1705d6b651524645b8cf7f` |
| `assets/child.jpg` | `768dc67cfcb193a6fe344af6dabab781153c000926b871847917e38bfeebf127` |
| `assets/dad.jpg` | `2e5538256f84012de3f3f21f92682a29f10e620bc982f2ef0ec9ce71fcc19fd4` |
| `assets/family-moment.jpg` | `b603e388bdd7638b2a17c6cb9cfb1ac236e1394b2fe6c3bb06220af37a3a3754` |
| `assets/family-picnic.jpg` | `18d2601ab4bc6e4bbd737ff916aae6ca8368ecbdc6bba612577cbc405e2184ff` |
| `assets/google-sign-in-ios-light@2x.png` | `13cd8a896195c12332cdfa74135f7075339a23482210c4f484098cf7e77ff631` |
| `assets/grandma.jpg` | `2e4faf9cb95ca983c64d907a951998d67a9e55d1699e2f906f0a41c8b965ee5d` |
| `assets/mandarin-sticker.png` | `e25b803b978c20bf9e7f61ca30882aa766fdc06c2e8f97db049afa82b5bbef0b` |
| `assets/mom.jpg` | `dbef7acf304bd38e436824f3c0469724659da3d9c245879edff9f15e0774ccf4` |
| `assets/wordmark.png` | `f17e92c5ffe215356ff5a8d54ad25f842efa11d4c49fbc6ced1707be3c38195b` |
| `exports/00-components.png` | `c596df0d64893115f50c0485298e3790840196aef81ae29b75bd3648d5a413f3` |
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
| `littlesprout-soft-social.pen` | `5be1b222c0d5d56d385b4546a57ac2b94252df60eaf694388c5d0e9c1e665dcf` |
| `skill/SKILL.md` | `9b4a627dc735bf3f26209a6751d1002ef0ef8dd0800ae23eb099850f13a2e760` |
| `skill/agents/openai.yaml` | `ab452d2f8df8e0ec0342dd7beeef04bf4a33b3c3cb0091eec15348b250a26fa3` |
| `skill/references/baseline.md` | `b5208d9136068d815efd8f8e3e0dd4d8e0187c3b54870f6fa6974aa00c44a095` |
| `skill/references/images/growth.png` | `0a8369f1117f7b07b40956104417c0aa37e9a1282ef6632d450785ed0db67da2` |
| `skill/references/images/home.png` | `18b6fd6fa4ac9b460c1bd2ce1c12beec7cd0bcbbe363c75ab2fefaea69ed0377` |
| `skill/references/visual-system.md` | `3902d2565485113a6986fde314573a804157c26714dee254409822b062281e30` |
