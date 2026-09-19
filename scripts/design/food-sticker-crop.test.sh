#!/bin/bash
# food-sticker-crop.py 自測（LS-338）。CI rules job 每個 PR 都跑（見 ci.yml 與 selftest-wiring-check）。
#
# 涵蓋範圍（票文範圍 2；LS-340 scope 5 補 F/G/H/I，承接 LS-338 merge-review m3／m4／i2，見 4d4fbe33；
# LS-340 R2 補 J，承接 merge-review `1c80d549` i1）：
#   A. 參考樣張（真實 design/food-stickers/style/reference-sheet.png）裁出剛好 8 張，檔名＝食物 id，且與
#      已入庫的 design/food-stickers/stickers/*.png **像素內容相同**（見下方「A／C 用像素比對而非 cmp」）。
#   B. 合成「少一張貼紙」夾具（7 個連通區塊、plan 卻列 8 個 id）→ exit 非 0，訊息點名哪張 sheet／預期與實際數量。
#   C. sheet-15（真實 design/food-stickers/sheets/sheet-15.png，唯一的單列 2 食物 sheet）裁出剛好 2 張、檔名
#      相符，且與已入庫成品像素內容相同（同 A）。
#   D. `sort_reading_order()` 純函式單元測試：用一組刻意 y 幾乎相等、x 差很大的座標，證明新演算法（找最大間隔，
#      小於門檻視為單一列）跟舊版「y 中位數切兩列」在這組座標上給出**不同**且新版才對的排序結果——這正是
#      票文點名的迴歸（sheet-15 用中位數切割會把單列 2 食物誤判成兩列各一個，此測試把它縮成最小可重現案例）。
#   E. Mutation：拿掉區塊數檢查（REGION-COUNT-CHECK 標記行），驗 B 的斷言翻紅——證明 B 真的在測這個檢查、
#      不是意外通過。
#   F.（LS-340 m3）合成「格數不對」夾具：8 個連通區塊排成 5 個在上列、3 個在下列，但 plan 宣告
#      `grid: {rows:2, cols:4}`（預期每列 4 個）→ exit 非 0，訊息點名實際列分組與預期 grid 不符。這是
#      merge-review m3 點名的真實失敗情境（版型跑掉，區塊數仍對，但列分組錯了會安靜把 id 掛到別張圖）。
#   G.（LS-340 m3）Mutation：拿掉 GRID-CHECK 標記行的檢查，驗 F 的斷言翻紅——證明 F 真的在測 grid 檢查。
#   H.（LS-340 i2）check-consistency：合成「缺一張」夾具（CSV 3 個 id、stickers 目錄只有 2 個）→ exit 非 0，
#      訊息點名缺的 id。
#   I.（LS-340 i2）check-consistency：合成「多一張孤兒」夾具（stickers 目錄比 CSV 多一個檔名）→ exit 非 0，
#      訊息點名多的 id。
#   J.（LS-340 R2，merge-review `1c80d549` i1）合成「列數不對」夾具：F／G 測的是「格數對但每列個數不對」
#      （2 列各 4／各 4 → 實際 5／3），J 補另一條 deny 路徑——8 個連通區塊全排成單列（不足門檻，判定 1 列），
#      但 plan 宣告 `grid: {rows:2, cols:4}`（預期 2 列）→ exit 非 0，訊息點名實際只有 1 列。兩條路徑都走
#      同一個 `actual_sizes != expected_sizes` 比較，但先前只有 F 有版控測試，J 補上列數本身不符這條。
#
# A／C 用像素比對而非逐位元組 cmp（LS-340 m4 的落地決定，偏離派工單「改用 cmp 逐位元組比對」的字面；
# 診斷經 LS-340 R2 merge-review `1c80d549` M1 校正——原稿誤判「同機器同版本 cmp 仍不同」，實為誤用
# Pillow==10.3.0 重切、版控成品其實是 11.3.0 產出，見 food-sticker-crop.py 檔頭與 README）：
# 實測**同一台機器、同一個 Pillow 版本**重切，`cmp` 逐位元組比對版控成品是**相同**的（122/122，
# Pillow==11.3.0）；**跨平台**（macOS 與 Linux 容器同為 Pillow 11.3.0）重切，`cmp` 逐位元組比對
# **不同**，但用 `Image.tobytes()` 解碼後像素**相同**——PNG 編碼層（zlib/optimize 的候選篩選）不保證
# 跨平台位元重放，即使版本號釘死、同版本也一樣。逐位元組 cmp 放進 CI 自測會在與「產出版控成品的那台
# 機器」不同平台的任何環境（例如 CI 的 Linux runner vs 本機 macOS）上恆紅，等於做出一個測不出真問題、
# 卻永遠擋 PR 的假警報 gate。像素比對保留 m4 真正要抓的迴歸能力（id↔圖錯配，例如 mutant 把 sheet-15
# 兩張對調，像素會不同）、同時對跨平台 PNG 編碼層差異免疫；`pixels_equal.py` 額外斷言兩張圖的
# `mode`（見 i3，避免 `convert("RGBA")` 把 mode 差異正規化掉）。若之後想收斂到逐位元組，前提是先把
# 「用哪支 Pillow wheel／哪個 OS／哪個 Python 版本產出版控內成品」定義成可重放的建置環境（例如固定在
# CI 容器內產出＋入庫），本票不擴大處理。
#
# B1（LS-340 R2，merge-review `1c80d549`）：`pixels_match()` 呼叫 `uv run --with <pin>` 時若 uv 快取是
# 冷的，stderr 會印下載進度／安裝訊息；先前版本把 stderr 併進比對字串（`2>&1`）導致冷快取環境（例如
# CI 剛啟動的 runner）第一次呼叫必定判定「不相同」——這不是像素真的不同，是字串比對混進了 uv 自己的
# 輸出。修法：`pixels_equal.py` 的呼叫只留 stdout（`2>/dev/null`），並在迴圈前先暖機一次同樣的 `uv run`
# 呼叫，讓後續呼叫不再印下載訊息（效能考量，非正確性必要——stdout-only 比對本身已經對 stderr 免疫）。
#
# i4（LS-340 R2，merge-review `1c80d549`）：所有輔助 `uv run --with <pkg>` 呼叫（像素比對、合成夾具產生器、
# mutant E／G／J 的直接呼叫）一律釘同一個 Pillow 版本（見下方 `PILLOW_PIN`），與 production 的 PEP 723
# 釘版路徑一致，不再用鬆散的 `--with pillow`。
#
# 依賴：全部透過 `uv run`（本檔頭 PEP 723 inline metadata 宣告 Pillow）執行 food-sticker-crop.py 與合成
# 夾具產生器，不假設系統 Python 已裝 Pillow（Rule 12：Python 套件一律走 uv）。
#
# 夾具體積：B／D／F／H／I／J 全是合成的極小圖或純數字，不落地大檔；A／C 直接讀已進版控的正式資產
# （reference-sheet.png 418 KB、sheet-15.png 388 KB，兩者都已通過 design-asset-size-check 的 500 KB／檔
# 門檻，用真資產不會拖慢 CI 也不會另外增加 repo 體積）。
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

stickers_dir="${root}/design/food-stickers/stickers"

# i4：所有輔助 `uv run --with` 呼叫釘同一個 Pillow 版本，與 production 的 PEP 723 釘版路徑一致
# （見上方檔頭「i4」段）。這裡直接讀 production 腳本檔頭的 pin，兩處只有一個事實來源，改版時不會漏改。
PILLOW_PIN="$(sed -n 's/^# dependencies = \["\(Pillow==[0-9.]*\)"\]$/\1/p' "$script")"
if [ -z "$PILLOW_PIN" ]; then
  fail "PILLOW_PIN：讀不到 ${script} 檔頭的 PEP 723 Pillow 版本宣告（自測其餘部分無法可靠比對像素）"
  PILLOW_PIN="pillow"  # 退回鬆散版本，至少能繼續跑、不整支中止
else
  PILLOW_PIN="$(printf '%s' "$PILLOW_PIN" | tr 'P' 'p')"  # PEP 723 用 "Pillow"，--with 慣例用小寫套件名
fi

# 像素內容比對（見上方「A／C 用像素比對而非 cmp」）：兩檔都能開、mode 相同（i3：不靠 convert 正規化掉
# mode 差異）、轉 RGBA 後 tobytes() 相等才算通過；任一檔打不開或尺寸／mode 不同也算不相等（不拋例外
# 中斷自測）。印出 "MATCH"／"MISMATCH: <原因>"。
cat > "${work}/pixels_equal.py" <<'PYEOF'
import sys
from PIL import Image

a_path, b_path = sys.argv[1], sys.argv[2]
try:
    with Image.open(a_path) as a, Image.open(b_path) as b:
        # i3：先斷言兩檔本來就是 RGBA，不要讓下面的 convert("RGBA") 把「crop 退化成輸出 RGB」這類迴歸
        # 正規化掉——RGB 轉 RGBA 時 alpha 補滿 255，若顏色相同會跟真正的 RGBA 版本位元相同，convert()
        # 本身抓不到「本來就不該是 RGB」這件事，必須在 convert() 之前先擋。
        if a.mode != "RGBA":
            print(f"MISMATCH: {a_path} mode {a.mode} != RGBA")
        elif b.mode != "RGBA":
            print(f"MISMATCH: {b_path} mode {b.mode} != RGBA")
        elif a.size != b.size:
            print(f"MISMATCH: size {a.size} != {b.size}")
        elif a.convert("RGBA").tobytes() != b.convert("RGBA").tobytes():
            print("MISMATCH: pixels differ")
        else:
            print("MATCH")
except Exception as exc:  # noqa: BLE001
    print(f"MISMATCH: {exc}")
PYEOF
# B1（見上方檔頭「B1」段）：只留 stdout（2>/dev/null）——uv 冷快取時 stderr 會印下載／安裝訊息，
# 併進比對字串會把「MATCH」誤判成「不等於 MATCH」。先暖機一次讓後續呼叫不必重複印下載訊息（效能，
# 非正確性必要）。
uv run --with "$PILLOW_PIN" python3 -c "import PIL" >/dev/null 2>&1
pixels_match() {
  out="$(uv run --with "$PILLOW_PIN" python3 "${work}/pixels_equal.py" "$1" "$2" 2>/dev/null)"
  [ "$out" = "MATCH" ]
}

# ==== A. 參考樣張 → 剛好 8 張，檔名＝食物 id，且與已入庫成品像素相同 ====
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
  a_mismatch=""
  for f in $got_a; do
    if [ -f "${stickers_dir}/${f}" ] && ! pixels_match "${out_a}/${f}" "${stickers_dir}/${f}"; then
      a_mismatch="${a_mismatch} ${f}"
    fi
  done
  if [ -z "$a_mismatch" ]; then
    ok "A. 參考樣張 8 張輸出與已入庫 design/food-stickers/stickers/*.png 像素內容相同"
  else
    fail "A. 以下輸出與已入庫成品像素不同（id↔圖可能錯配）：${a_mismatch}"
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
uv run --with "$PILLOW_PIN" python3 "${work}/gen_seven.py" "${synth_dir}/synthetic-fewer.png"

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

# ==== C. sheet-15（真實資產，唯一的單列 2 食物 sheet）→ 剛好 2 張、檔名相符，且與已入庫成品像素相同 ====
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
  c_mismatch=""
  for f in $got_c; do
    if [ -f "${stickers_dir}/${f}" ] && ! pixels_match "${out_c}/${f}" "${stickers_dir}/${f}"; then
      c_mismatch="${c_mismatch} ${f}"
    fi
  done
  if [ -z "$c_mismatch" ]; then
    ok "C. sheet-15 2 張輸出與已入庫成品像素內容相同（m4 點名的中位數法 mutant 會讓兩張對調，此斷言會抓到）"
  else
    fail "C. 以下輸出與已入庫成品像素不同（id↔圖可能錯配）：${c_mismatch}"
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
d_out="$(uv run --with "$PILLOW_PIN" python3 "${work}/check_sort.py" "$script" 2>&1)"
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
  e_out="$(uv run --with "$PILLOW_PIN" python3 "$mut" crop --sheet synthetic-fewer --plan "${work}/plan-fewer.json" \
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

# ==== K.（LS-340 R2 i3）mode 斷言防呆：RGB 與同色 RGBA（alpha 全 255）視覺相同但 mode 不同 ====
cat > "${work}/gen_mode_pair.py" <<'PYEOF'
import sys
from PIL import Image

rgb_path, rgba_path = sys.argv[1], sys.argv[2]
Image.new("RGB", (40, 40), (200, 120, 60)).save(rgb_path)
Image.new("RGBA", (40, 40), (200, 120, 60, 255)).save(rgba_path)
PYEOF
uv run --with "$PILLOW_PIN" python3 "${work}/gen_mode_pair.py" "${work}/mode-rgb.png" "${work}/mode-rgba.png"

k_out="$(uv run --with "$PILLOW_PIN" python3 "${work}/pixels_equal.py" "${work}/mode-rgb.png" "${work}/mode-rgba.png" 2>/dev/null)"
expect_has "$k_out" "mode RGB != RGBA" "K. RGB／RGBA 同色不同 mode 的夾具被判 MISMATCH（防 convert() 把 mode 差異正規化掉）"

# ==== L.（LS-340 R2 i3）Mutation：拿掉 pixels_equal.py 的 mode 斷言 → K 的夾具改判 MATCH ====
mut_mode="${work}/pixels_equal.no-mode-check.py"
awk '
  /# i3：先斷言兩檔本來就是 RGBA/ { skip=1; next }
  skip && /^        elif a\.size != b\.size:/ { skip=0; sub(/elif/, "if"); print; next }
  skip { next }
  { print }
' "${work}/pixels_equal.py" > "$mut_mode"
if grep -qF 'mode !=' "$mut_mode"; then
  fail "L. 拿掉 mode 檢查失敗，負控本身無效（mutant 仍含 mode 斷言字樣）"
else
  l_out="$(uv run --with "$PILLOW_PIN" python3 "$mut_mode" "${work}/mode-rgb.png" "${work}/mode-rgba.png" 2>/dev/null)"
  if [ "$l_out" = "MATCH" ]; then
    ok "L. mutant（拿掉 mode 斷言）：K 的夾具改判 MATCH——證明 K 真的在測 mode 防呆，不是意外通過"
  else
    fail "L. mutant 未如預期翻轉（拿掉 mode 斷言後仍判「${l_out}」，負控本身無效）"
  fi
fi

# ==== F. 合成「列分組與 grid 不符」夾具：8 個連通區塊排成 5 上／3 下，plan 宣告 grid 2x4 → exit 非 0 ====
cat > "${work}/gen_mismatch.py" <<'PYEOF'
import sys
from PIL import Image, ImageDraw

path = sys.argv[1]
im = Image.new("RGBA", (420, 300), (0, 0, 0, 0))
draw = ImageDraw.Draw(im)
# 版型跑掉的情境：8 個食物本該是 4x2（每列 4 個），但這張圖實際排成 5 個在上列、3 個在下列
# （兩個 y 高度層、只有一條 gap，gap-based 分列演算法會老實地切成 5/3 兩組）。
top_xs = [30, 110, 190, 270, 350]
bottom_xs = [60, 170, 280]
for x in top_xs:
    draw.ellipse([x - 20, 60 - 20, x + 20, 60 + 20], fill=(200, 120, 60, 255))
for x in bottom_xs:
    draw.ellipse([x - 20, 220 - 20, x + 20, 220 + 20], fill=(200, 120, 60, 255))
im.save(path)
PYEOF
uv run --with "$PILLOW_PIN" python3 "${work}/gen_mismatch.py" "${synth_dir}/synthetic-mismatch.png"

cat > "${work}/plan-mismatch.json" <<'JSONEOF'
[
 {"sheet": "synthetic-mismatch", "grid": {"rows": 2, "cols": 4}, "foods": [
   {"id": "g1", "name_zh": "1", "category": "x"},
   {"id": "g2", "name_zh": "2", "category": "x"},
   {"id": "g3", "name_zh": "3", "category": "x"},
   {"id": "g4", "name_zh": "4", "category": "x"},
   {"id": "g5", "name_zh": "5", "category": "x"},
   {"id": "g6", "name_zh": "6", "category": "x"},
   {"id": "g7", "name_zh": "7", "category": "x"},
   {"id": "g8", "name_zh": "8", "category": "x"}
 ]}
]
JSONEOF

out_f="${work}/out-f"
f_out="$(run_crop --sheet synthetic-mismatch --plan "${work}/plan-mismatch.json" --reference-plan "$no_ref" \
  --sheets-dir "$synth_dir" --style-dir "$synth_dir" --out-dir "$out_f" 2>&1)"; rc_f=$?
expect_exit 1 "$rc_f" "F. 列分組（5/3）與宣告 grid（2x4）不符的夾具 exit 非 0"
expect_has "$f_out" "列分組 [5, 3]" "F. 錯誤訊息點名實際列分組"
expect_has "$f_out" "grid 2x4 不符" "F. 錯誤訊息點名預期 grid"

# ==== G. Mutation：拿掉 GRID-CHECK 標記行的檢查 → F 的斷言翻紅 ====
mut_grid="${work}/food-sticker-crop.no-grid-check.py"
awk '
  index($0, "# GRID-CHECK") > 0 { print "    if False:  # GRID-CHECK-MUTATED"; next }
  { print }
' "$script" > "$mut_grid"
if grep -qF 'GRID-CHECK-MUTATED' "$mut_grid"; then
  out_g="${work}/out-g"
  g_out="$(uv run --with "$PILLOW_PIN" python3 "$mut_grid" crop --sheet synthetic-mismatch \
    --plan "${work}/plan-mismatch.json" --reference-plan "$no_ref" \
    --sheets-dir "$synth_dir" --style-dir "$synth_dir" --out-dir "$out_g" 2>&1)"; rc_g=$?
  if [ "$rc_g" -eq 0 ]; then
    ok "G. mutant（拿掉 grid 檢查）：F 的夾具改判 exit 0——證明 F 的斷言真的在測 grid 檢查"
  else
    fail "G. mutant 未如預期翻轉（拿掉 grid 檢查後仍 exit ${rc_g}，負控本身無效）"
    printf '%s\n' "$g_out" | sed 's/^/    /' >&2
  fi
else
  fail "G. 找不到 GRID-CHECK 標記行，負控本身無效"
fi

# ==== J.（LS-340 R2 i1）合成「列數不對」夾具：8 個連通區塊全排成單列，plan 宣告 grid 2x4（預期 2 列）====
cat > "${work}/gen_singlerow.py" <<'PYEOF'
import sys
from PIL import Image, ImageDraw

path = sys.argv[1]
im = Image.new("RGBA", (650, 200), (0, 0, 0, 0))
draw = ImageDraw.Draw(im)
xs = [30, 110, 190, 270, 350, 430, 510, 590]
for x in xs:
    draw.ellipse([x - 20, 100 - 20, x + 20, 100 + 20], fill=(200, 120, 60, 255))
im.save(path)
PYEOF
uv run --with "$PILLOW_PIN" python3 "${work}/gen_singlerow.py" "${synth_dir}/synthetic-singlerow.png"

cat > "${work}/plan-singlerow.json" <<'JSONEOF'
[
 {"sheet": "synthetic-singlerow", "grid": {"rows": 2, "cols": 4}, "foods": [
   {"id": "j1", "name_zh": "1", "category": "x"},
   {"id": "j2", "name_zh": "2", "category": "x"},
   {"id": "j3", "name_zh": "3", "category": "x"},
   {"id": "j4", "name_zh": "4", "category": "x"},
   {"id": "j5", "name_zh": "5", "category": "x"},
   {"id": "j6", "name_zh": "6", "category": "x"},
   {"id": "j7", "name_zh": "7", "category": "x"},
   {"id": "j8", "name_zh": "8", "category": "x"}
 ]}
]
JSONEOF

out_j="${work}/out-j"
j_out="$(run_crop --sheet synthetic-singlerow --plan "${work}/plan-singlerow.json" --reference-plan "$no_ref" \
  --sheets-dir "$synth_dir" --style-dir "$synth_dir" --out-dir "$out_j" 2>&1)"; rc_j=$?
expect_exit 1 "$rc_j" "J. 單列 8 個與宣告 grid（2x4，預期 2 列）不符的夾具 exit 非 0"
expect_has "$j_out" "列分組 [8]（共 1 列）" "J. 錯誤訊息點名實際只有 1 列"
expect_has "$j_out" "grid 2x4 不符" "J. 錯誤訊息點名預期 grid"

# ==== H／I. check-consistency：合成「缺一張」「多一張孤兒」夾具 → 各自 exit 非 0、訊息點名 id ====
cat > "${work}/gen_solid.py" <<'PYEOF'
import sys
from PIL import Image

path = sys.argv[1]
Image.new("RGBA", (384, 384), (200, 120, 60, 255)).save(path)
PYEOF

csv_h="${work}/food_catalog-missing.csv"
cat > "$csv_h" <<'CSVEOF'
id,name_zh,category,sort_order,allergens,min_age_months
c1,1,x,1,,6
c2,2,x,2,,6
c3,3,x,3,,6
CSVEOF
stickers_h="${work}/stickers-missing"
mkdir -p "$stickers_h"
uv run --with "$PILLOW_PIN" python3 "${work}/gen_solid.py" "${stickers_h}/c1.png"
uv run --with "$PILLOW_PIN" python3 "${work}/gen_solid.py" "${stickers_h}/c2.png"
# c3.png 故意不產生，模擬「CSV 有、stickers/ 沒有」

h_out="$(uv run "$script" check-consistency --stickers-dir "$stickers_h" --csv "$csv_h" 2>&1)"; rc_h=$?
expect_exit 1 "$rc_h" "H. 缺一張的夾具（CSV 3 個 id、stickers/ 只有 2 個）exit 非 0"
expect_has "$h_out" "缺 1 個" "H. 錯誤訊息點名缺幾個"
expect_has "$h_out" "c3" "H. 錯誤訊息點名缺的是哪個 id"

csv_i="${work}/food_catalog-orphan.csv"
cat > "$csv_i" <<'CSVEOF'
id,name_zh,category,sort_order,allergens,min_age_months
c1,1,x,1,,6
c2,2,x,2,,6
CSVEOF
stickers_i="${work}/stickers-orphan"
mkdir -p "$stickers_i"
uv run --with "$PILLOW_PIN" python3 "${work}/gen_solid.py" "${stickers_i}/c1.png"
uv run --with "$PILLOW_PIN" python3 "${work}/gen_solid.py" "${stickers_i}/c2.png"
uv run --with "$PILLOW_PIN" python3 "${work}/gen_solid.py" "${stickers_i}/orphan.png"
# orphan.png 不在 csv_i 裡，模擬「stickers/ 有、CSV 沒有」

i_out="$(uv run "$script" check-consistency --stickers-dir "$stickers_i" --csv "$csv_i" 2>&1)"; rc_i=$?
expect_exit 1 "$rc_i" "I. 多一張孤兒的夾具（stickers/ 比 CSV 多一個檔名）exit 非 0"
expect_has "$i_out" "多 1 個" "I. 錯誤訊息點名多幾個"
expect_has "$i_out" "orphan" "I. 錯誤訊息點名多的是哪個 id"

if [ "$selftest_helpers_fail" -eq 0 ]; then
  echo "✓ food-sticker-crop 自測通過（${selftest_helpers_n} 組樣本）"
  exit 0
fi
exit 1
