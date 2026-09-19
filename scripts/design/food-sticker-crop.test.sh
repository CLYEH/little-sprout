#!/bin/bash
# food-sticker-crop.py 自測（LS-338）。CI rules job 每個 PR 都跑（見 ci.yml 與 selftest-wiring-check）。
#
# 涵蓋範圍（票文範圍 2）：
#   A. 參考樣張（真實 design/food-stickers/style/reference-sheet.png）裁出剛好 8 張，檔名＝食物 id。
#   B. 合成「少一張貼紙」夾具（7 個連通區塊、plan 卻列 8 個 id）→ exit 非 0，訊息點名哪張 sheet／預期與實際數量。
#   C. sheet-15（真實 design/food-stickers/sheets/sheet-15.png，唯一的單列 2 食物 sheet）裁出剛好 2 張、檔名相符。
#   D. `sort_reading_order()` 純函式單元測試：用一組刻意 y 幾乎相等、x 差很大的座標，證明新演算法（找最大間隔，
#      小於門檻視為單一列）跟舊版「y 中位數切兩列」在這組座標上給出**不同**且新版才對的排序結果——這正是
#      票文點名的迴歸（sheet-15 用中位數切割會把單列 2 食物誤判成兩列各一個，此測試把它縮成最小可重現案例）。
#   E. Mutation：拿掉區塊數檢查（REGION-COUNT-CHECK 標記行），驗 B 的斷言翻紅——證明 B 真的在測這個檢查、
#      不是意外通過。
#
# 依賴：全部透過 `uv run`（本檔頭 PEP 723 inline metadata 宣告 Pillow）執行 food-sticker-crop.py 與合成
# 夾具產生器，不假設系統 Python 已裝 Pillow（Rule 12：Python 套件一律走 uv）。
#
# 夾具體積：B／D 全是合成的極小圖或純數字，不落地大檔；A／C 直接讀已進版控的正式資產（reference-sheet.png
# 418 KB、sheet-15.png 388 KB，兩者都已通過 design-asset-size-check 的 500 KB／檔門檻，用真資產不會拖慢
# CI 也不會另外增加 repo 體積）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${root}/scripts/gates/lib/selftest-helpers.sh"

script="${root}/scripts/design/food-sticker-crop.py"
plan="${root}/design/food-stickers/sheets/plan.json"
ref_plan="${root}/design/food-stickers/style/reference-plan.json"
sheets_dir="${root}/design/food-stickers/sheets"
style_dir="${root}/design/food-stickers/style"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

run_crop() {
  uv run "$script" crop "$@"
}

# ==== A. 參考樣張 → 剛好 8 張，檔名＝食物 id ====
out_a="${work}/out-a"
if out="$(run_crop --sheet reference-sheet --plan "$plan" --reference-plan "$ref_plan" \
  --sheets-dir "$sheets_dir" --style-dir "$style_dir" --out-dir "$out_a" 2>&1)"; then
  got_a=$(ls "$out_a" 2>/dev/null | sort | tr '\n' ' ')
  want_a="banana.png carrot.png peanut_butter.png rice_cracker.png sweet_potato.png tofu_pudding.png whole_egg.png yogurt.png "
  if [ "$got_a" = "$want_a" ]; then
    ok "A. 參考樣張裁出剛好 8 張，檔名＝食物 id"
  else
    fail "A. 參考樣張輸出檔名不符（實得「${got_a}」，預期「${want_a}」）"
  fi
else
  fail "A. 參考樣張裁切不該失敗（exit 非 0）"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ==== B. 合成「少一張貼紙」夾具：7 個連通區塊、plan 列 8 個 id → exit 非 0 ====
synth_dir="${work}/synth"
mkdir -p "$synth_dir"
cat > "${work}/gen_seven.py" <<'PYEOF'
import sys
from PIL import Image, ImageDraw

path = sys.argv[1]
im = Image.new("RGBA", (400, 200), (0, 0, 0, 0))
draw = ImageDraw.Draw(im)
# 4 欄 x 2 列的格位，只畫 7 個（漏掉最後一格），每格一個實心圓，之間留足夠間距不相連
cols, rows, box = 4, 2, 80
n = 0
for r in range(rows):
    for c in range(cols):
        if n == 7:
            break
        cx = c * box + box // 2 + 10
        cy = r * box + box // 2 + 10
        draw.ellipse([cx - 25, cy - 25, cx + 25, cy + 25], fill=(200, 120, 60, 255))
        n += 1
im.save(path)
PYEOF
uv run --with pillow python3 "${work}/gen_seven.py" "${synth_dir}/synthetic-fewer.png"

cat > "${work}/plan-fewer.json" <<'JSONEOF'
[
 {"sheet": "synthetic-fewer", "foods": [
   {"id": "f1", "name_zh": "1", "category": "x"},
   {"id": "f2", "name_zh": "2", "category": "x"},
   {"id": "f3", "name_zh": "3", "category": "x"},
   {"id": "f4", "name_zh": "4", "category": "x"},
   {"id": "f5", "name_zh": "5", "category": "x"},
   {"id": "f6", "name_zh": "6", "category": "x"},
   {"id": "f7", "name_zh": "7", "category": "x"},
   {"id": "f8", "name_zh": "8", "category": "x"}
 ]}
]
JSONEOF

no_ref="${work}/no-reference-plan.json"
out_b="${work}/out-b"
b_out="$(run_crop --sheet synthetic-fewer --plan "${work}/plan-fewer.json" --reference-plan "$no_ref" \
  --sheets-dir "$synth_dir" --style-dir "$synth_dir" --out-dir "$out_b" 2>&1)"; rc_b=$?
expect_exit 1 "$rc_b" "B. 少一張貼紙的夾具 exit 非 0"
expect_has "$b_out" "連通區塊 7 個，預期 8 個" "B. 錯誤訊息點名區塊數與預期數量"
expect_has "$b_out" "synthetic-fewer.png" "B. 錯誤訊息點名是哪張 sheet"

# ==== C. sheet-15（真實資產，唯一的單列 2 食物 sheet）→ 剛好 2 張、檔名相符 ====
out_c="${work}/out-c"
if out="$(run_crop --sheet sheet-15 --plan "$plan" --reference-plan "$no_ref" \
  --sheets-dir "$sheets_dir" --style-dir "$style_dir" --out-dir "$out_c" 2>&1)"; then
  got_c=$(ls "$out_c" 2>/dev/null | sort | tr '\n' ' ')
  want_c="mung_bean_soup.png red_bean_soup.png "
  if [ "$got_c" = "$want_c" ]; then
    ok "C. sheet-15（單列 2 食物）裁出剛好 2 張，檔名＝食物 id"
  else
    fail "C. sheet-15 輸出檔名不符（實得「${got_c}」，預期「${want_c}」）"
  fi
else
  fail "C. sheet-15 裁切不該失敗（exit 非 0）"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ==== D. sort_reading_order() 純函式單元測試：y 幾乎相等、x 差很大 → 新舊演算法給出不同排序 ====
cat > "${work}/check_sort.py" <<'PYEOF'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("food_sticker_crop", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# 兩點 y 幾乎相等（100.5 / 100.0，差 0.5）、x 差很大（10.0 / 90.0）；圖高 1000 → 門檻 150，
# 0.5 遠小於門檻 → 判定同一列 → 依 x 由小到大排序，正解＝[0, 1]（x=10 的點在左）。
order = mod.sort_reading_order([100.5, 100.0], [10.0, 90.0], 1000)
print("order=" + ",".join(str(i) for i in order))

# 舊版「y 中位數切兩列」在同一組座標會給錯的答案：mid_y=100.25，點 0（y=100.5>mid_y）判到第二列、
# 點 1（y=100.0<=mid_y）判到第一列 → 錯誤排序 [1, 0]（跟正解相反，把 x 較大的點排在前面）。
mid_y = (100.5 + 100.0) / 2
naive_order = sorted([0, 1], key=lambda i: ([100.5, 100.0][i] > mid_y, [10.0, 90.0][i]))
print("naive_order=" + ",".join(str(i) for i in naive_order))
PYEOF
d_out="$(uv run --with pillow python3 "${work}/check_sort.py" "$script" 2>&1)"
expect_has "$d_out" "order=0,1" "D. sort_reading_order() 在 y 幾乎相等、x 差很大的座標上依 x 排序（正解 [0,1]）"
expect_has "$d_out" "naive_order=1,0" "D. 舊版 y 中位數切割在同一組座標給出相反的錯誤排序（[1,0]），證明這是真的迴歸修正"

# ==== E. Mutation：拿掉 REGION-COUNT-CHECK 標記行的檢查 → B 的斷言翻紅 ====
mut="${work}/food-sticker-crop.no-region-check.py"
awk '
  index($0, "# REGION-COUNT-CHECK") > 0 { print "    if False:  # REGION-COUNT-CHECK-MUTATED"; next }
  { print }
' "$script" > "$mut"
if grep -qF 'REGION-COUNT-CHECK-MUTATED' "$mut"; then
  out_e="${work}/out-e"
  e_out="$(uv run --with pillow python3 "$mut" crop --sheet synthetic-fewer --plan "${work}/plan-fewer.json" \
    --reference-plan "$no_ref" --sheets-dir "$synth_dir" --style-dir "$synth_dir" --out-dir "$out_e" 2>&1)"; rc_e=$?
  if [ "$rc_e" -eq 0 ]; then
    ok "E. mutant（拿掉區塊數檢查）：B 的夾具改判 exit 0——證明 B 的「expect_exit 1」與「expect_has … 連通區塊 7 個，預期 8 個」兩條斷言真的在測這個檢查"
  else
    fail "E. mutant 未如預期翻轉（拿掉檢查後仍 exit ${rc_e}，負控本身無效）"
    printf '%s\n' "$e_out" | sed 's/^/    /' >&2
  fi
else
  fail "E. 找不到 REGION-COUNT-CHECK 標記行，負控本身無效"
fi

if [ "$selftest_helpers_fail" -eq 0 ]; then
  echo "✓ food-sticker-crop 自測通過（${selftest_helpers_n} 組樣本）"
  exit 0
fi
exit 1
