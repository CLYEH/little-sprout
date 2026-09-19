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
   id 掛到別張圖）；遮罩膨脹 6px 清光暈後置中裁到正方形畫布，輸出 `stickers/<food_id>.png`（RGBA、不含灰階
   版——App 端 `.saturation(0)` 即時去飽和）。
3. **一致性檢查**：`stickers/` 的檔名集合須與 `supabase/seed-data/food_catalog.csv` 的 `id` 欄一一對應（274 個，
   無缺無多），且每張成品須可開啟、384×384、RGBA。

版控內的 274 張成品是用腳本檔頭釘死的 **Pillow==11.3.0** 產出（LS-338 merge-review m2；版本號由 LS-340 R2
merge-review `1c80d549` M1 實測校正——逐版掃描 10.3.0／10.4.0／11.0.0 重切都與版控成品位元不同，11.3.0／
12.0.0 起才相同，不同 Pillow 版本像素不變但 PNG 編碼層會變，整批無視覺差異的 churn）。**位元級可重放只在
「同 OS／同 Pillow wheel build」內成立**：同一台機器、同一個 Pillow 版本重切，`cmp` 逐位元組相同；跨平台
（例如 macOS 與 Linux 容器同為 Pillow 11.3.0）重切，`cmp` 不同但像素（`Image.tobytes()`）相同——PNG 編碼層
（zlib/optimize 的候選篩選）不保證跨平台位元重放。所以重切前先對齊版本能避免「換版本造成的」churn，但不要
預期能單靠這個做到跨平台位元級重放；CI 自測驗證重切正確與否用像素內容比對，不用逐位元組 `cmp`。

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

- **只進版控 `stickers/` 274 張裁切後的成品**（384×384，實測 80–212 KB／檔，全數 <500 KB）與 `style/reference-sheet.png`
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
- `stickers/<food_id>.png`：274 張裁切後的成品，檔名＝`food_catalog.id`。
