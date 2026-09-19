# 食物圖鑑貼紙（LS-338）

122 種食物的水彩＋色鉛筆風格貼紙插圖，供 `food_catalog` 食物圖鑑畫面使用（LS-326 設計、後續 iOS 實作票引用）。

## 產線流程

1. **生圖**（Codex，orchestrator 執行，不在本 repo 的自動化範圍內）：用 `style/style-prompt.txt` 的畫風描述原文，
   只換每張 sheet 的食物清單（見 `sheets/plan.json`），並附 `style/reference-sheet.png` 當參考圖，逐張生成
   `sheets/sheet-NN.png`（1536×1024、透明背景）。
2. **裁切**（決定性，`scripts/design/food-sticker-crop.py`）：alpha ≥128 的連通區塊數必須等於該 sheet 的食物數，
   依列（row）再依欄（column）排序對應食物 id，遮罩膨脹 6px 清光暈後置中裁到正方形畫布，輸出
   `stickers/<food_id>.png`（RGBA、不含灰階版——App 端 `.saturation(0)` 即時去飽和）。
3. **一致性檢查**：`stickers/` 的檔名集合須與 `supabase/seed-data/food_catalog.csv` 的 `id` 欄一一對應（122 個，
   無缺無多）。

## 重新裁切 / 重生單張 sheet

使用者可能點名某張 sheet 跑掉，要求整張重生。流程：

1. Orchestrator 用同一份 `style/style-prompt.txt`（或該張 sheet 專屬的 `sheets/sheet-NN-prompt.txt`）＋
   `style/reference-sheet.png` 重新生成 `sheets/sheet-NN.png`，覆蓋原檔。
2. 只重跑那一張，覆寫它對應食物 id 的輸出檔，其餘 sheet 的輸出不受影響：

   ```
   uv run scripts/design/food-sticker-crop.py crop --sheet sheet-NN
   ```

   參考樣張（8 個 id）同理：`uv run scripts/design/food-sticker-crop.py crop --sheet reference-sheet`。
3. 驗一致性：`uv run scripts/design/food-sticker-crop.py check-consistency`。

不帶 `--sheet` 則裁全部 15 張＋參考樣張（122 個 id）。

## 畫風原文不得更動

`style/style-prompt.txt` 是使用者已核可的畫風描述原文（LS-332 裁決「選 A」）。**重生任何 sheet 一律沿用這份原文
的畫風描述，只換食物清單**——不得為了單張 sheet 調整畫風措辭，否則會破壞 122 張之間的風格一致性（使用者原始
指示：「盡量讓所有的食物圖片的繪圖風格都一致」）。

## 體積取捨（design-asset-size-check，LS-74 教訓）

`design/` 下二進位新增／修改單檔超過 500 KB 會被 CI 擋下。15 張正式 sheet 原始檔（1536×1024，各 2.0–2.4 MB）與
`style/reference-sheet.png` 原始解析度（1536×1024，2.2 MB）都超過這個門檻。取捨：

- **只進版控 `stickers/` 122 張裁切後的成品**（384×384，實測 91–212 KB／檔，全數 <500 KB）與 `style/reference-sheet.png`
  的**縮小版**（1536×1024 → 768×512，418 KB，仍清楚可辨識畫風／線條／配色，供未來重生 sheet 時當參考圖）。
- **不進版控 sheet-01～sheet-14 這 14 張原始 sheet**（`sheet-15.png` 例外——內容只有 2 個食物、壓縮後 388 KB，
  本來就在門檻內，直接留著）。這些原始 sheet 只是生圖→裁切之間的中繼產物，裁切完成、驗過一致性之後即可捨棄；
  真正需要保留、且已保留的是「怎麼重生」的配方：`sheets/plan.json`（每張 sheet 的食物清單）＋
  `sheets/sheet-NN-prompt.txt`（每張 sheet 實際送給 Codex 的完整 prompt 原文）＋
  `style/style-prompt.txt`（畫風描述原文，不得更動）＋`style/reference-sheet.png`（參考圖）。
  要重生某張 sheet，照上面「重新裁切 / 重生單張 sheet」重新生成即可；不是位元級重放（生成式模型本來就不是
  決定性的），但配方齊全，重生結果的畫風／構圖與原稿高度一致。

## 檔案

- `style/style-prompt.txt`：畫風描述原文（8 種食物樣張，已核可，見上方「畫風原文不得更動」）。
- `style/reference-sheet.png`：核可樣張，768×512（縮小版，見上方體積取捨）。
- `style/reference-plan.json`：參考樣張的 8 個食物 id 對應表（`id`／`name_zh`／`category`，順序＝樣張內的排列順序）。
- `sheets/plan.json`：15 張 sheet（14×8＋1×2＝114 個食物）的 sheet→食物清單對應表。
- `sheets/sheet-NN-prompt.txt`：第 NN 張 sheet 實際送出的完整 prompt 原文。
- `sheets/sheet-15.png`：唯一保留在版控內的正式 sheet 原始檔（見上方體積取捨）。
- `stickers/<food_id>.png`：122 張裁切後的成品，檔名＝`food_catalog.id`。
