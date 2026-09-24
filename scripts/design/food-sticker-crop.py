#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["Pillow==11.3.0", "imagequant==1.1.5"]
# ///
"""LS-338 食物圖鑑貼紙裁切腳本——sticker sheet（一張多種食物、透明背景）→ 單張彩色 PNG，決定性、不靠模型判斷。

背景：LS-332 的 `tools/crop_sheet_draft.py` 只處理 8 食物的樣張，且會多產生一份灰階版（App 端已經即時
`.saturation(0)` 去飽和，灰階檔是多餘輸出，見票文 comment `009f10f2`）。本腳本整理成正式流程；LS-338
涵蓋 15 張 sheet＋1 張參考樣張（122 個食物 id），LS-340 擴充 19 張 sheet（152 個食物 id），張數／食物數
一律讀 `plan.json`，不在程式裡寫死。

決定性轉換（每一步都可重放、不依賴模型判斷）：
  1. 對每張 sheet：alpha ≥ 128 的像素做四連通連通區塊標記（純 Python 兩遍掃描＋union-find，見
     `connected_components()`），區塊數必須剛好等於該 sheet 的食物數，否則 exit 非 0 並點名是哪張 sheet、
     期望與實際數量。
  2. 依列（row）再依欄（column）排序，對應食物 id 清單：sort by row 排序演算法是「找 y 中心排序後最大的
     間隔（gap）」——若最大間隔小於門檻（圖高 15%）判定為單一列（例如 sheet-15 只有 2 個食物並排，用
     y 中位數切割會誤判成兩列，這裡改用最大間隔偵測就不會誤切）；超過門檻才切成兩列，各列再依 x 排序。
     若 `plan.json` 該筆帶 `grid`（`{"rows": R, "cols": C}`），分列結果（列數＋各列個數）須與 `grid` 相符，
     不符即 exit 非 0（LS-338 merge-review m3：版型跑掉時，光靠區塊數對不出「id 對錯圖」，需要對列分組
     也做合理性檢查，見 `split_into_rows()`／`crop_sheet()` 的 `GRID-CHECK` 標記）。
  3. 裁切：每個區塊的遮罩膨脹 6px（四鄰接、6 次疊代，等同保留白邊抗鋸齒）；alpha < 32 清成 0、
     alpha ≥ 200 拉成 255；依膨脹後遮罩裁出 bounding box，等比縮放置中到正方形畫布，四周留 6% 邊。
  4. 輸出：`design/food-stickers/stickers/<food_id>.png`，不產生灰階版（App 端即時處理）。LS-387 起輸出
     是**8-bit 調色盤 PNG（mode P＋tRNS alpha）**，不再是 RGBA：274 張 RGBA 共 ~43MB 進 app bundle 太重。
     量化用 libimagequant（pngquant 同一顆引擎，PyPI `imagequant` 綁定，無抖色），色數從 256 往下逐級試
     （`QUANTIZE_COLOR_STEPS`），取第一個編碼後 ≤ `MAX_STICKER_BYTES`（40 KB）的結果；最低一級仍超標就
     exit 非 0（`QUANTIZE-LIMIT-CHECK`），不默默寫出超標檔。選 libimagequant 而非 Pillow 內建 FASTOCTREE
     （Pillow wheel 未編入 libimagequant，RGBA 只能用 octree）：octree 在 3× 放大下淺色水彩面（饅頭、
     蛋白）出現明顯色塊，libimagequant 同樣 ≤40 KB 下目視幾乎無差（LS-387 handoff 三案對照）。

依賴決策（Rule 12）：只依賴 Pillow＋imagequant（量化，LS-387），不用 numpy／scipy——scipy 對 CI ubuntu runner 是額外負擔且本腳本
用不到它的進階功能；連通區塊標記與膨脹都用純 Python 實作（見下方兩個函式），在 1536×1024 的 sheet 上
實測每張 <0.3s（labeling）＋<0.1s（單一區塊局部膨脹，只在該區塊 bounding box 的局部陣列上做，不是對
整張圖）。CI／自測一律用 `uv run` 執行本檔（本檔頭的 PEP 723 inline metadata 宣告依賴），不裝系統套件、
不碰 pip（不確定 ubuntu-latest runner 內建是否有 Pillow，用 uv 現拉最保險）。**Pillow 釘死 `==11.3.0`**
（LS-338 merge-review m2；版本號由 LS-340 R2 merge-review `1c80d549` M1 實測校正——版控內全部 274 張
成品都是這個版本產出，逐版掃描 10.3.0／10.4.0／11.0.0 重切皆與版控不同、11.3.0／12.0.0 起才相同）：
不同 Pillow 版本 PNG 編碼層不同會讓「像素沒變、blob 全變」的整批 churn（實測 Pillow 12.3.0 重切像素
相同、位元全不同）；重切前先對齊這個版本，日後要升級 Pillow 得連同全部既有成品一起重切、逐檔 `cmp`
驗過再一起 commit，不能只改依賴宣告（`imagequant` 同理釘 `==1.1.5`）。**可重放範圍（LS-387 量化後
重測）**：同一台機器、同一組釘版重切，`cmp` 逐位元組相同；**跨平台連像素都不保證相同**——色數是依
「編碼後位元組數」逐級挑的，PNG 編碼層（zlib）跨平台輸出長度不同，貼近 40 KB 的檔就可能在兩個平台挑到
不同色數（實測 macOS arm64 vs Linux amd64 容器：274 張中 254 張像素相同，差異的 20 張全落在 34–41 KB
區間，平均每通道絕對差最大 1.72／255；同 sheet 兩張不同食物之間最小 10.49）。所以 CI 自測比對輸出正確性用
「平均絕對差 ≤ 門檻」的容差比對（見 food-sticker-crop.test.sh），不用 `cmp` 也不用逐像素相等。

用法：
  uv run scripts/design/food-sticker-crop.py crop [--sheet <sheet-01|reference-sheet>] [--plan PATH]
      [--reference-plan PATH] [--sheets-dir PATH] [--style-dir PATH] [--out-dir PATH]
    不帶 --sheet＝裁 `plan.json`＋`reference-plan.json` 定義的所有 sheet（目前 34＋1 張，274 個 id）。
    帶 --sheet＝只重跑那一張（供使用者點名重生單張 sheet 後重新裁切，覆寫該張對應的輸出檔，其餘檔案不動）。
  uv run scripts/design/food-sticker-crop.py check-consistency [--stickers-dir PATH] [--csv PATH]
    驗 stickers/ 目錄的檔名集合與 food_catalog.csv 的 id 集合一一對應（無缺無多），否則 exit 非 0。

自測：scripts/design/food-sticker-crop.test.sh（用真正的參考樣張＋合成夾具；不含正式 sheet 原始檔，維持
夾具體積小）。
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import sys
from pathlib import Path

import imagequant
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
DEFAULT_ASSET_DIR = REPO_ROOT / "design" / "food-stickers"
DEFAULT_SHEETS_DIR = DEFAULT_ASSET_DIR / "sheets"
DEFAULT_STYLE_DIR = DEFAULT_ASSET_DIR / "style"
DEFAULT_STICKERS_DIR = DEFAULT_ASSET_DIR / "stickers"
DEFAULT_PLAN_PATH = DEFAULT_SHEETS_DIR / "plan.json"
DEFAULT_REFERENCE_PLAN_PATH = DEFAULT_STYLE_DIR / "reference-plan.json"
DEFAULT_CSV_PATH = REPO_ROOT / "supabase" / "seed-data" / "food_catalog.csv"

CANVAS = 384  # 3x retina 下 110pt 格 ≈ 330px；384 留一點餘裕（LS-387 量化後單張 ≤40 KB，見 MAX_STICKER_BYTES）
MARGIN = 0.06
ALPHA_REGION_THRESHOLD = 128
ALPHA_CLEAR_THRESHOLD = 32
ALPHA_SOLID_THRESHOLD = 200
DILATE_PX = 6
ROW_GAP_RATIO = 0.15  # 最大間隔 < 圖高的 15% 視為同一列（見上方 docstring 第 2 點）
MAX_STICKER_BYTES = 40960  # LS-387：單張 ≤40 KB（274 張總量 ≤11 MB，CI food-sticker-size-check 驗版控成品）
QUANTIZE_COLOR_STEPS = (256, 192, 160, 128, 96, 64, 48, 32)  # 由多到少，取第一個 ≤ MAX_STICKER_BYTES 的


class CropError(Exception):
    """裁切流程中可預期、需要 exit 非 0 並印訊息的錯誤（區塊數不符等）。"""


def connected_components(alpha: bytes, w: int, h: int, threshold: int = ALPHA_REGION_THRESHOLD):
    """四連通連通區塊標記（兩遍掃描＋union-find，純 Python／stdlib）。

    回傳 (labels, n)：labels 是長度 w*h 的 list[int]，0＝背景，1..n＝區塊 id（依掃描到的順序重新編號，
    不代表任何空間順序——排序由呼叫端的 `sort_reading_order()` 另外處理）。
    """
    labels = [0] * (w * h)
    parent = [0]

    def find(x: int) -> int:
        r = x
        while parent[r] != r:
            r = parent[r]
        while parent[x] != r:
            parent[x], x = r, parent[x]
        return r

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            if ra < rb:
                parent[rb] = ra
            else:
                parent[ra] = rb

    fg = [v >= threshold for v in alpha]
    next_label = 0
    for y in range(h):
        row_off = y * w
        for x in range(w):
            idx = row_off + x
            if not fg[idx]:
                continue
            left = labels[idx - 1] if x > 0 and fg[idx - 1] else 0
            up = labels[idx - w] if y > 0 and fg[idx - w] else 0
            if left and up:
                labels[idx] = min(left, up)
                if left != up:
                    union(left, up)
            elif left:
                labels[idx] = left
            elif up:
                labels[idx] = up
            else:
                next_label += 1
                parent.append(next_label)
                labels[idx] = next_label

    root_map: dict[int, int] = {}
    n = 0
    remap = [0] * (next_label + 1)
    for i in range(1, next_label + 1):
        r = find(i)
        if r not in root_map:
            n += 1
            root_map[r] = n
        remap[i] = root_map[r]
    for idx in range(w * h):
        if labels[idx]:
            labels[idx] = remap[labels[idx]]
    return labels, n


def region_bboxes(labels: list[int], n: int, w: int, h: int):
    """回傳每個區塊 1..n 的 (minx, miny, maxx, maxy)（inclusive）。"""
    minx = [w] * (n + 1)
    maxx = [-1] * (n + 1)
    miny = [h] * (n + 1)
    maxy = [-1] * (n + 1)
    for y in range(h):
        row_off = y * w
        for x in range(w):
            lb = labels[row_off + x]
            if lb:
                if x < minx[lb]:
                    minx[lb] = x
                if x > maxx[lb]:
                    maxx[lb] = x
                if y < miny[lb]:
                    miny[lb] = y
                if y > maxy[lb]:
                    maxy[lb] = y
    return minx, miny, maxx, maxy


def split_into_rows(centers_y: list[float], height: int) -> list[list[int]]:
    """依 y 中心把 0-based index 分成 1 或 2 列（列內部未排序，僅依 y 由小到大排在一起）。

    列偵測：y 中心排序後找最大的相鄰間隔；間隔 < 圖高 * ROW_GAP_RATIO 視為單一列（sheet-15 的 2 食物
    並排正是這個情況——沒有第二列，用 y 中位數切割會把它們硬切成兩列各一個）。超過門檻才切成兩列，
    切點就是最大間隔的位置。供 `sort_reading_order()` 排序、以及 `crop_sheet()` 對照 `plan.json` 的
    `grid` 欄位做列分組合理性檢查（LS-338 merge-review m3）共用。
    """
    n = len(centers_y)
    order = sorted(range(n), key=lambda i: centers_y[i])
    if n <= 1:
        return [order]
    ys_sorted = [centers_y[i] for i in order]
    gaps = [(ys_sorted[i + 1] - ys_sorted[i], i) for i in range(n - 1)]
    max_gap, split_idx = max(gaps)
    threshold = height * ROW_GAP_RATIO
    if max_gap < threshold:
        return [order]
    return [order[: split_idx + 1], order[split_idx + 1 :]]


def sort_reading_order(centers_y: list[float], centers_x: list[float], height: int) -> list[int]:
    """依列（row）再依欄（column）排序，回傳 0-based index 順序（列由 `split_into_rows()` 決定，各列
    內部再依 x 由小到大排序，列與列之間由上到下串接）。"""
    result: list[int] = []
    for row in split_into_rows(centers_y, height):
        result.extend(sorted(row, key=lambda i: centers_x[i]))
    return result


def dilate_local(mask_rows: list[list[bool]], iterations: int) -> list[list[bool]]:
    """局部四鄰接膨脹（等同 iterations 次疊代的十字結構元素，與 scipy `binary_dilation` 預設結構同形）。

    只在呼叫端已裁出的局部子陣列（單一區塊 bounding box + 邊界留白）上跑，不是整張 sheet，所以雖然是
    純 Python 巢狀迴圈，實測單一區塊（~300×300）6 次疊代 <0.1s。
    """
    h = len(mask_rows)
    w = len(mask_rows[0]) if h else 0
    cur = [row[:] for row in mask_rows]
    for _ in range(iterations):
        nxt = [row[:] for row in cur]
        for y in range(h):
            cur_row = cur[y]
            for x in range(w):
                if cur_row[x]:
                    continue
                if (
                    (x > 0 and cur_row[x - 1])
                    or (x < w - 1 and cur_row[x + 1])
                    or (y > 0 and cur[y - 1][x])
                    or (y < h - 1 and cur[y + 1][x])
                ):
                    nxt[y][x] = True
        cur = nxt
    return cur


def quantize_sticker(canvas: Image.Image, food_id: str) -> bytes:
    """RGBA 畫布 → 8-bit 調色盤 PNG 位元組（見 docstring 第 4 點）。色數逐級遞減，取第一個編碼後
    ≤ MAX_STICKER_BYTES 的；最低一級仍超標丟 CropError。"""
    for colors in QUANTIZE_COLOR_STEPS:
        quantized = imagequant.quantize_pil_image(
            canvas, dithering_level=0.0, max_colors=colors, min_quality=0, max_quality=100
        )
        buf = io.BytesIO()
        quantized.save(buf, "PNG", optimize=True)
        if buf.tell() <= MAX_STICKER_BYTES:
            break
    if buf.tell() > MAX_STICKER_BYTES:  # QUANTIZE-LIMIT-CHECK（自測 mutation 標記，見 food-sticker-crop.test.sh）
        raise CropError(
            f"{food_id}：量化到 {QUANTIZE_COLOR_STEPS[-1]} 色仍有 {buf.tell()} bytes，超過單張上限 "
            f"{MAX_STICKER_BYTES} bytes"
        )
    return buf.getvalue()


def crop_sheet(sheet_path: Path, ids: list[str], out_dir: Path, grid: dict | None = None) -> list[str]:
    """裁一張 sheet，回傳實際寫出的檔名（依食物 id）。區塊數不符、或列分組與 `grid`（若有）不符時丟
    CropError。"""
    im = Image.open(sheet_path).convert("RGBA")
    w, h = im.size
    alpha = im.getchannel("A").tobytes()
    labels, n = connected_components(alpha, w, h)
    if n != len(ids):  # REGION-COUNT-CHECK（自測 mutation 標記，見 food-sticker-crop.test.sh）
        raise CropError(
            f"{sheet_path.name}：連通區塊 {n} 個，預期 {len(ids)} 個（食物清單長度）"
        )

    minx, miny, maxx, maxy = region_bboxes(labels, n, w, h)
    centers_y = [(miny[i] + maxy[i]) / 2 for i in range(1, n + 1)]
    centers_x = [(minx[i] + maxx[i]) / 2 for i in range(1, n + 1)]

    if grid is not None:  # GRID-CHECK（自測 mutation 標記，見 food-sticker-crop.test.sh）
        rows = split_into_rows(centers_y, h)
        actual_sizes = [len(r) for r in rows]
        expected_sizes = [grid["cols"]] * grid["rows"]
        if actual_sizes != expected_sizes:
            raise CropError(
                f"{sheet_path.name}：列分組 {actual_sizes}（共 {len(rows)} 列）與 plan.json 的 grid "
                f"{grid['rows']}x{grid['cols']} 不符（預期每列 {expected_sizes}）——版型可能跑掉，"
                f"id 對應到圖的順序不可信"
            )

    order = sort_reading_order(centers_y, centers_x, h)

    pix = im.load()
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for food_id, idx in zip(ids, order):
        label_id = idx + 1
        pad = DILATE_PX + 2
        bx0, bx1 = max(0, minx[label_id] - pad), min(w, maxx[label_id] + 1 + pad)
        by0, by1 = max(0, miny[label_id] - pad), min(h, maxy[label_id] + 1 + pad)
        bw, bh = bx1 - bx0, by1 - by0
        local_mask = [
            [labels[(by0 + yy) * w + (bx0 + xx)] == label_id for xx in range(bw)]
            for yy in range(bh)
        ]
        dilated = dilate_local(local_mask, DILATE_PX)

        xs = [xx for yy in range(bh) for xx in range(bw) if dilated[yy][xx]]
        ys = [yy for yy in range(bh) for xx in range(bw) if dilated[yy][xx]]
        x0, x1 = min(xs), max(xs) + 1
        y0, y1 = min(ys), max(ys) + 1
        tile_w, tile_h = x1 - x0, y1 - y0

        tile = Image.new("RGBA", (tile_w, tile_h), (0, 0, 0, 0))
        tpix = tile.load()
        for yy in range(y0, y1):
            row_mask = dilated[yy]
            for xx in range(x0, x1):
                if row_mask[xx]:
                    r, g, b, a = pix[bx0 + xx, by0 + yy]
                    if a < ALPHA_CLEAR_THRESHOLD:
                        a = 0
                    elif a >= ALPHA_SOLID_THRESHOLD:
                        a = 255
                    tpix[xx - x0, yy - y0] = (r, g, b, a)

        inner = int(CANVAS * (1 - 2 * MARGIN))
        scale = inner / max(tile_w, tile_h)
        new_w, new_h = max(1, round(tile_w * scale)), max(1, round(tile_h * scale))
        tile_resized = tile.resize((new_w, new_h), Image.LANCZOS)
        canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        canvas.paste(tile_resized, ((CANVAS - new_w) // 2, (CANVAS - new_h) // 2), tile_resized)

        out_path = out_dir / f"{food_id}.png"
        out_path.write_bytes(quantize_sticker(canvas, food_id))
        written.append(food_id)
    return written


def load_jobs(plan_path: Path, reference_plan_path: Path, sheets_dir: Path, style_dir: Path):
    """讀 plan.json（＋reference-plan.json）回傳 job list：
    [(sheet_name, image_path, [food_id, ...], grid_or_None), ...]。"""
    jobs = []
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    for entry in plan:
        name = entry["sheet"]
        ids = [f["id"] for f in entry["foods"]]
        jobs.append((name, sheets_dir / f"{name}.png", ids, entry.get("grid")))
    if reference_plan_path.exists():
        ref = json.loads(reference_plan_path.read_text(encoding="utf-8"))
        name = ref["sheet"]
        ids = [f["id"] for f in ref["foods"]]
        jobs.append((name, style_dir / f"{name}.png", ids, ref.get("grid")))
    return jobs


def cmd_crop(args: argparse.Namespace) -> int:
    jobs = load_jobs(args.plan, args.reference_plan, args.sheets_dir, args.style_dir)
    if args.sheet:
        jobs = [j for j in jobs if j[0] == args.sheet]
        if not jobs:
            print(f"✗ food-sticker-crop：找不到 sheet「{args.sheet}」（plan.json／reference-plan.json 都沒有這個名字）", file=sys.stderr)
            return 2

    total_written = 0
    for name, image_path, ids, grid in jobs:
        if not image_path.exists():
            print(f"✗ food-sticker-crop：找不到圖檔「{image_path}」（sheet「{name}」）", file=sys.stderr)
            return 2
        try:
            written = crop_sheet(image_path, ids, args.out_dir, grid=grid)
        except CropError as exc:
            print(f"✗ food-sticker-crop：{exc}", file=sys.stderr)
            return 1
        print(f"✓ {name} → {len(written)} 張：{', '.join(written)}")
        total_written += len(written)

    print(f"✓ food-sticker-crop：共 {len(jobs)} 張 sheet，{total_written} 個食物 id 已寫入 {args.out_dir}")
    return 0


def cmd_check_consistency(args: argparse.Namespace) -> int:
    if not args.stickers_dir.exists():
        print(f"✗ food-sticker-crop check-consistency：找不到目錄「{args.stickers_dir}」", file=sys.stderr)
        return 2
    sticker_ids = {p.stem for p in args.stickers_dir.glob("*.png")}
    with args.csv.open(newline="", encoding="utf-8") as f:
        csv_ids = {row["id"] for row in csv.DictReader(f)}

    missing = sorted(csv_ids - sticker_ids)  # CSV 有、stickers/ 沒有
    extra = sorted(sticker_ids - csv_ids)  # stickers/ 有、CSV 沒有

    rc = 0
    if missing:
        print(f"✗ food-sticker-crop check-consistency：缺 {len(missing)} 個（CSV 有、stickers/ 沒有）：{', '.join(missing)}", file=sys.stderr)
        rc = 1
    if extra:
        print(f"✗ food-sticker-crop check-consistency：多 {len(extra)} 個（stickers/ 有、CSV 沒有）：{', '.join(extra)}", file=sys.stderr)
        rc = 1

    # i2（LS-338 merge-review）：id 集合對得上不代表每張圖本身可用——逐張驗可開啟／384×384／調色盤帶 alpha
    # （LS-387 起成品是 mode P＋tRNS，見 docstring 第 4 點；RGBA 表示沒走量化，也算不合格）。
    bad: list[str] = []
    for food_id in sorted(csv_ids & sticker_ids):
        path = args.stickers_dir / f"{food_id}.png"
        try:
            with Image.open(path) as im:
                im.load()
                if im.size != (CANVAS, CANVAS) or im.mode != "P" or not im.has_transparency_data:
                    bad.append(f"{food_id}（{im.size[0]}x{im.size[1]} {im.mode}）")
        except Exception as exc:  # noqa: BLE001 — 任何開檔／解碼失敗都算壞檔，訊息點名原因
            bad.append(f"{food_id}（無法開啟：{exc}）")
    if bad:
        print(f"✗ food-sticker-crop check-consistency：{len(bad)} 個檔案不是可開啟的 {CANVAS}x{CANVAS} 調色盤 PNG（mode P＋透明）：{', '.join(bad)}", file=sys.stderr)
        rc = 1

    if rc == 0:
        print(f"✓ food-sticker-crop check-consistency：{len(sticker_ids)} 個 id 與 food_catalog.csv 一一對應，且皆為可開啟的 {CANVAS}x{CANVAS} 調色盤 PNG（mode P＋透明）")
    return rc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    crop_p = sub.add_parser("crop", help="裁切 sheet（不帶 --sheet 則裁全部）")
    crop_p.add_argument("--sheet", default=None, help="只裁這一張 sheet（例：sheet-01 或 reference-sheet），覆寫它的輸出檔")
    crop_p.add_argument("--plan", type=Path, default=DEFAULT_PLAN_PATH)
    crop_p.add_argument("--reference-plan", type=Path, default=DEFAULT_REFERENCE_PLAN_PATH)
    crop_p.add_argument("--sheets-dir", type=Path, default=DEFAULT_SHEETS_DIR)
    crop_p.add_argument("--style-dir", type=Path, default=DEFAULT_STYLE_DIR)
    crop_p.add_argument("--out-dir", type=Path, default=DEFAULT_STICKERS_DIR)
    crop_p.set_defaults(func=cmd_crop)

    check_p = sub.add_parser("check-consistency", help="驗 stickers/ 檔名與 food_catalog.csv id 一一對應")
    check_p.add_argument("--stickers-dir", type=Path, default=DEFAULT_STICKERS_DIR)
    check_p.add_argument("--csv", type=Path, default=DEFAULT_CSV_PATH)
    check_p.set_defaults(func=cmd_check_consistency)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
