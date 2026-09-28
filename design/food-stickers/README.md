# 食物圖鑑貼紙（LS-338；LS-340 擴充）

274 種食物的水彩＋色鉛筆風格貼紙插圖，供 `food_catalog` 食物圖鑑畫面使用（LS-326 設計、後續 iOS 實作票引用）。
LS-338 首批 122 種（15 張 sheet＋1 張參考樣張），LS-340 擴充蔬菜／水果／蛋白質 152 種（19 張 sheet，
sheet-16…34），同一份 `style/style-prompt.txt` 畫風、同一支裁切腳本。

## 產線流程

1. **生圖**（Codex，orchestrator 執行，不在本 repo 的自動化範圍內）：用 `style/style-prompt.txt` 的畫風描述原文，
   只換每張 sheet 的食物清單（見 `sheets/plan.json`），並附參考圖（見下方「體積取捨」段的 masters 目錄），
   逐張生成 `sheets/sheet-NN.png`（1536×1024、透明背景）。
2. **裁切**（決定性，`scripts/design/food-sticker-crop.py`）：alpha ≥128 的連通區塊數必須等於該 sheet 的食物數；
   依列（row）再依欄（column）排序對應食物 id，若 `plan.json` 該筆帶 `grid`（`{"rows": R, "cols": C}`）則列分組
   結果也須與 `grid` 相符，兩者任一不符都 exit 非 0（LS-338 merge-review m3：只驗區塊數，版型跑掉時會安靜把
   id 掛到別張圖）；遮罩膨脹 6px 清光暈後置中裁到正方形畫布，再做**調色盤量化**（LS-387，見下方「量化」段），
   輸出 `stickers/<food_id>.png`（8-bit 調色盤 PNG＋透明、單張 ≤40 KB、不含灰階版——App 端 `.saturation(0)`
   即時去飽和）。
3. **一致性檢查**：`stickers/` 的檔名集合須與 `supabase/seed-data/food_catalog.csv` 的 `id` 欄一一對應（274 個，
   無缺無多），且每張成品須可開啟、384×384、mode P 且帶透明（RGBA＝沒走量化，算不合格）。
4. **體積 gate**（LS-387，CI rules job `scripts/gates/food-sticker-size-check.sh`）：`stickers/` 單張 ≤40 KB
   （40960 bytes）、總量 ≤11 MB（11534336 bytes），任一超標即紅。

## 量化（LS-387）

274 張 384² RGBA PNG 原本共 ~43 MB（每張 80–212 KB），以 folder reference 進 app bundle 太重。裁切後改做
8-bit 調色盤量化：libimagequant（pngquant 同一顆引擎，PyPI `imagequant` 綁定，無抖色），色數 256→192→160→
128→96→64→48→32 逐級試，取第一個編碼後 ≤40 KB 的結果；32 色仍超標就 exit 非 0，不默默寫出超標檔。全量重切 35 張 sheet（274 張）實測約 1 分 43 秒（Apple Silicon
本機，`time` 牆鐘 102.5 s；量化逐級試色數佔大半）。
現況：總量 ~10.0 MB（10521446 bytes）、最大單張 40942 bytes；色數分佈 256×21／192×8／160×14／128×29／
96×76／64×93／48×26／32×7（多數落在 64–96 色）。三案對照見 LS-387 handoff：Pillow FASTOCTREE
在 3× 放大下淺色水彩面出現色塊、HEIC 需改 App 載入與 Pencil 引用，皆未採用。

## 可重放範圍（LS-387 量化後重測）

版控內的 274 張成品是用腳本檔頭釘死的 **Pillow==11.3.0＋imagequant==1.1.5** 產出（Pillow 釘版沿革：LS-338
merge-review m2、LS-340 R2 merge-review `1c80d549` M1——不同 Pillow 版本 PNG 編碼層會變，整批無視覺差異的
churn；升級任一依賴得連同全部成品一起重切再 commit，不能只改依賴宣告）。

- **同一台機器、同一組釘版**：重切 `cmp` 逐位元組相同（LS-387 實測 274/274）。
- **跨平台**（例如 macOS arm64 與 Linux amd64 容器，同一組釘版）：**位元組與像素都不保證相同**。色數是依
  「編碼後位元組數」逐級挑的，而 zlib 的輸出長度跨平台不同，貼近 40 KB 的檔就可能挑到不同色數（實測 274 張中
  254 張像素相同，其餘 20 張全落在 34–41 KB，RGBA 平均每通道絕對差最大 1.72／255）。這跟 LS-387 之前「跨平台
  cmp 不同但像素相同」的說法不同——量化後連像素這層保證也沒有了。
- 因此 CI 自測（`scripts/design/food-sticker-crop.test.sh`）驗重切正確性用**容差比對**：mode 都是 P＋透明、
  尺寸相同、RGBA 平均絕對差 ≤4.0 才算相同（同 sheet 953 組不同食物配對實測最小 10.49——sheet-01 rice_cereal vs rice_porridge，錯配照樣抓得到），不用 `cmp`、
  也不用逐像素相等。
- 重切成品要進版控時，**整批在同一台機器上產出**，避免同一批混入不同平台挑出的色數。

## 重新裁切 / 重生單張 sheet

使用者可能點名某張 sheet 跑掉，要求整張重生。流程：

1. Orchestrator 用同一份 `style/style-prompt.txt`（或該張 sheet 專屬的 `sheets/sheet-NN-prompt.txt`）＋
   全解析度參考圖（見下方「體積取捨」的 masters 目錄）重新生成 `sheets/sheet-NN.png`，存到 masters 目錄
   （不進版控，見下方「體積取捨」）。
2. 只重跑那一張，覆寫它對應食物 id 的輸出檔，其餘 sheet 的輸出不受影響，`--sheets-dir` 指到 masters 目錄：

   ```
   uv run scripts/design/food-sticker-crop.py crop --sheet sheet-NN --sheets-dir ~/little-sprout-design-masters/food-stickers/sheets
   ```

   （LS-340 擴充的 sheet-16…34 原稿在 `~/little-sprout-design-masters/food-stickers/expansion/sheets/`，換那個
   路徑即可；`plan.json` 是同一份，`--sheet` 只篩選要跑哪個 job。）參考樣張（8 個 id）同理：
   `uv run scripts/design/food-sticker-crop.py crop --sheet reference-sheet`（這張的縮小版本來就在版控內的
   `style/reference-sheet.png`，不需要另外指 `--sheets-dir`）。
3. 驗一致性：`uv run scripts/design/food-sticker-crop.py check-consistency`。

**不帶 `--sheet` 在 clone 出來的乾淨 repo 上會直接 exit 2**：`sheets/` 目錄裡大多數正式 sheet 原始檔不在版控
內（見下方「體積取捨」），`crop` 依 `plan.json` 的順序逐張處理，遇到第一張在 `--sheets-dir` 找不到的圖檔就報
「找不到圖檔」並 exit 2、後面的張都不會跑到。要重切全部 34＋1 張，因為 LS-338（15 張）與 LS-340（19 張）的
原稿分別放在 masters 目錄下兩個不同的子路徑（`sheets/` 與 `expansion/sheets/`），單一 `--sheets-dir` 指不到
兩邊，得用 `--sheet` 逐張跑（或先把兩個 masters 子目錄的 PNG 複製進同一個暫存目錄再不帶 `--sheet` 跑一次）。

## 畫風原文不得更動

`style/style-prompt.txt` 是使用者已核可的畫風描述原文（LS-332 裁決「選 A」）。**重生任何 sheet 一律沿用這份原文
的畫風描述，只換食物清單**——不得為了單張 sheet 調整畫風措辭，否則會破壞 274 張之間的風格一致性（使用者原始
指示：「盡量讓所有的食物圖片的繪圖風格都一致」；LS-340 擴充的 152 張沿用同一份原文，見票文 comment
`797552c0`／`fb0ec1dc`）。

## 體積取捨（design-asset-size-check，LS-74 教訓）

`design/` 下二進位新增／修改單檔超過 500 KB 會被 CI 擋下。34 張正式 sheet 原始檔（1536×1024，各 2.0–2.8 MB）與
`style/reference-sheet.png` 原始解析度（1536×1024，2.2 MB）都超過這個門檻。取捨：

- **只進版控 `stickers/` 274 張裁切後的成品**（384×384 調色盤 PNG，LS-387 起每張 ≤40 KB、總量 ~10 MB）與 `style/reference-sheet.png`
  的**縮小版**（1536×1024 → 768×512，418 KB，仍清楚可辨識畫風／線條／配色，供未來重生 sheet 時當參考圖）。
- **不進版控 sheet-01～sheet-14、sheet-16～sheet-34 這 33 張原始 sheet**（`sheet-15.png` 例外——內容只有 2 個
  食物、壓縮後 388 KB，本來就在門檻內，直接留著）。

**原稿不是「裁切完成即可捨棄」——保存在 repo 外的 masters 目錄**（LS-338 merge-review m1：先前這裡寫「即可
捨棄」不實，orchestrator 實際上把全部原稿留著，一度只存在單一 session 的 scratchpad，險些遺失）：

  - `~/little-sprout-design-masters/food-stickers/`：LS-338 的 15 張正式 sheet（`sheets/sheet-01.png`…
    `sheet-15.png`）＋全解析度參考圖（`reference-sheet-fullres.png`，1536×1024）。
  - `~/little-sprout-design-masters/food-stickers/expansion/sheets/`：LS-340 的 19 張正式 sheet
    （`sheet-16.png`…`sheet-34.png`）。

  這份 masters 目錄不在版控範圍、也沒有自動備份機制，只是 orchestrator 本機磁碟上的資料夾——不是「不會
  遺失」的保證，只是比 session scratchpad 穩固。

  版控內真正保留、且已保留的「怎麼重生」配方是：`sheets/plan.json`（每張 sheet 的食物清單＋`grid`）＋
  `sheets/sheet-NN-prompt.txt`（每張 sheet 實際送給 Codex 的完整 prompt 原文）＋`style/style-prompt.txt`
  （畫風描述原文，不得更動）＋`style/reference-sheet.png`（縮小版參考圖）。要重生某張 sheet，照上面
  「重新裁切 / 重生單張 sheet」用 masters 目錄的原稿重新生成即可；不是位元級重放（生成式模型本來就不是
  決定性的），但配方齊全，重生結果的畫風／構圖與原稿高度一致。**不要把 masters 的原稿複製回
  `design/food-stickers/sheets/`**——這個路徑沒有 gitignore 覆蓋，複製進來會讓工作樹髒掉，只靠
  `design-asset-size-check` 的 500 KB 門檻擋（該檔案一旦被 `git add`，gate 就會紅）。

## 檔案

- `style/style-prompt.txt`：畫風描述原文（8 種食物樣張，已核可，見上方「畫風原文不得更動」）。
- `style/reference-sheet.png`：核可樣張，768×512（縮小版，見上方體積取捨）。
- `style/reference-plan.json`：參考樣張的 8 個食物 id 對應表（`id`／`name_zh`／`category`／`grid`，順序＝樣張
  內的排列順序）。
- `sheets/plan.json`：34 張 sheet（LS-338 14×8＋1×2＝114 個食物、LS-340 19×8=152 個食物）的 sheet→食物清單
  對應表，每筆帶 `grid`（`{"rows": R, "cols": C}`，供裁切腳本做列分組合理性檢查，見上方「產線流程」步驟 2）。
- `sheets/sheet-NN-prompt.txt`：第 NN 張 sheet 實際送出的完整 prompt 原文（LS-338 01～15、LS-340 16～34）。
- `sheets/sheet-15.png`：唯一保留在版控內的正式 sheet 原始檔（見上方體積取捨）。
- `stickers/<food_id>.png`：274 張裁切後的成品（8-bit 調色盤 PNG＋透明，≤40 KB），檔名＝`food_catalog.id`。

## gray-preview/（LS-326）

`gray-preview/<food_id>.png`（192px、Rec.709 亮度灰階、保留 alpha）只給 Pencil 稿面模擬「還沒吃」的灰階貼紙；**不進 App**——App 端一律對 `stickers/` 原圖做 `.saturation(0).opacity(0.6)`。
