#!/bin/bash
# food_catalog_rules.py／food-catalog-sql.py check-allergens／check-allergens-sql 自測
# （LS-342）。CI rules job 每個 PR 都跑（無需 DB，見 ci.yml 與 selftest-wiring-check）。
#
# 涵蓋範圍（票文範圍 1／3）：
#   A. 真實 CSV（supabase/seed-data/food_catalog.csv）跑 check-allergens 全過（exit 0）
#      ——基準：LS-342 對現況 274 列跑過一次，見 handoff。
#   B. 合成夾具：一列名稱含「魚」但 allergens 空、且不在白名單 → **實際跑 CLI**
#      （`python3 food-catalog-sql.py check-allergens`，用 `FOOD_CATALOG_CSV_PATH`
#      環境變數指向合成 CSV），驗真正的出口碼與 stderr——不是繞過 CLI 直接呼叫
#      `check_rows()`（R1 merge-review informational i2：呼叫 `check_rows()` 測不到
#      `raise SystemExit(1)` 被改壞的情況，CLI 出口碼才是 CI `rules` job 實際依賴
#      的介面）。
#   C. 合成夾具：SOY_SAUCE_DISH_IDS 其中一個 id（braised_pork_rice）allergens 空
#      → 同樣實跑 CLI，exit 1，訊息點名「醬油調味慣例列」（顯式 id 清單路徑的
#      deny，不是關鍵字路徑）。
#   D. 白名單真的有作用：用真實 CSV 裡的 flying_squid（魷魚，allergens 空，靠
#      WHITELIST 的 (flying_squid, fish) 例外通過）單獨跑 check_rows() 不紅；把
#      WHITELIST 那個條目拿掉重跑同一列 → 紅（Mutation：白名單拿掉一條 → 紅，
#      票文要求）。
#   E. check-allergens-sql 產生的 SQL 文字含 flying_squid 的白名單排除子句與八個
#      allergen 的 raise exception——證明 SQL 是從同一份規則產生，不是另外手寫
#      （單一來源）。Mutation：拿掉 WHITELIST 的 flying_squid 條目重新產生 → SQL
#      不再含排除子句，證明兩條路徑（Python 直跑／產生 SQL）真的吃同一份資料。
#   F. R1 merge-review minor m1：`KEYWORD_RULES` 的 `desc` 若含 `%` 與單引號（例如
#      日後有人寫「含 100% 全麥字」這種說明），`generate_sql_do_block()` 產生的
#      SQL 必須正確跳脫（`%%`／`''`），不能讓 RAISE 因為佔位符數量對不上而
#      `too few parameters specified for RAISE`，也不能讓未跳脫的 `'` 弄壞 SQL
#      語法。
#   G／H. LS-347：新規則（sesame／mango）各一支 CSV 端 deny——合成夾具名稱含
#      「芝麻」／「芒果」但 allergens 空、不在白名單 → 實跑 CLI，exit 1，訊息點名
#      對應 allergen（DB 端 deny 見 supabase/tests/run.sh，理由同既有 cod／
#      braised_pork_rice 兩支）。
#   I. LS-96 池項 25fea8c7 m1'：`FOOD_CATALOG_CSV_PATH` 覆寫時，`ok` 成功訊息印出
#      實際讀到的路徑——不是空泛地宣稱「通過」，讓殘留的環境變數覆寫無所遁形。
#   J. LS-96 池項 25fea8c7 i2'：`SOY_SAUCE_DISH_IDS` 為空時，`generate_sql_do_block()`
#      不再產生 `where id in ()` 這種恆假子句（也不再產生醬油慣例列的 raise
#      exception）——整段略過，其餘規則與收尾（raise notice／end／$$）正常產生。
#   K. LS-347 merge-review R1 m1：`food-catalog-sql.py row-count`（供
#      `supabase/tests/run.sh` 取代原本的 `wc -l`）對「CSV 檔尾沒有換行」仍正確
#      回報列數——沿用 `load_rows()` 的 `csv.DictReader`，不受尾換行影響。
#
# 依賴：純標準庫，`python3` 直接呼叫（不需要 uv／第三方套件，同 food-catalog-sql.py
# 檔頭的既有宣告）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${root}/scripts/gates/lib/selftest-helpers.sh"

script="${root}/scripts/ops/food-catalog-sql.py"
real_csv="${root}/supabase/seed-data/food_catalog.csv"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ==== A. 真實 CSV 全過 ====
if out_a="$(python3 "$script" check-allergens 2>&1)"; then
  ok "A. 真實 CSV（274 列）check-allergens 全過"
else
  fail "A. 真實 CSV check-allergens 不該失敗"
  printf '%s\n' "$out_a" | sed 's/^/    /' >&2
fi

# ==== B. 合成夾具：名稱含「魚」但 allergens 空、不在白名單 → 實跑 CLI deny ====
synth_b="${work}/food_catalog_b.csv"
cat > "$synth_b" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
ls342_test_fish,測試魚,protein,1,,
CSV
b_out="$(FOOD_CATALOG_CSV_PATH="$synth_b" python3 "$script" check-allergens 2>&1)"
b_rc=$?
expect_exit 1 "$b_rc" "B. 名稱含「魚」但 allergens 空的合成列 → CLI check-allergens 紅（實際出口碼）"
expect_has "$b_out" "ls342_test_fish" "B. 錯誤訊息點名 id"
expect_has "$b_out" "'fish'" "B. 錯誤訊息點名缺的 allergen（fish）"

# ==== C. 合成夾具：醬油調味慣例列（顯式 id 清單）allergens 空 → 實跑 CLI deny ====
synth_c="${work}/food_catalog_c.csv"
cat > "$synth_c" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
braised_pork_rice,滷肉飯,tw_home,1,,
CSV
c_out="$(FOOD_CATALOG_CSV_PATH="$synth_c" python3 "$script" check-allergens 2>&1)"
c_rc=$?
expect_exit 1 "$c_rc" "C. 醬油調味慣例列（braised_pork_rice）allergens 空 → CLI check-allergens 紅（實際出口碼）"
expect_has "$c_out" "醬油調味慣例列" "C. 錯誤訊息點名是醬油調味慣例列規則（不是關鍵字規則）"

# ==== D. 白名單真的有作用：真實 flying_squid 通過；拿掉白名單條目 → 紅 ====
d_out="$(python3 - "$root" <<'PY'
import importlib.util
import sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "food_catalog_rules", root + "/scripts/ops/food_catalog_rules.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

row = {"id": "flying_squid", "name_zh": "魷魚", "allergens": ""}

# D1：正常規則表（含白名單）→ 不紅
before = mod.check_rows([row])
print("before=" + ("empty" if not before else "|".join(before)))

# D2：拿掉 (flying_squid, fish) 這條白名單條目 → 重跑同一列，應該變紅
mod.WHITELIST = {k: v for k, v in mod.WHITELIST.items() if k != ("flying_squid", "fish")}
after = mod.check_rows([row])
print("after=" + ("empty" if not after else "|".join(after)))
PY
)"
expect_has "$d_out" "before=empty" "D1. flying_squid（魷魚）靠白名單通過，不誤判成漏標 fish"
expect_has "$d_out" "after=FAIL" "D2. Mutation：拿掉 WHITELIST 的 (flying_squid, fish) 條目 → 同一列變紅"

# ==== E. check-allergens-sql 是從同一份規則產生（單一來源），不是另外手寫 ====
sql_before="$(python3 "$script" check-allergens-sql)"
expect_has "$sql_before" "id not in ('flying_squid', 'octopus')" "E1. 產生的 SQL 含白名單排除子句（flying_squid／octopus）"
expect_has "$sql_before" "raise exception 'FAIL：名稱含魚類字但 allergens 缺 fish" "E2. 產生的 SQL 含 fish 規則的 raise exception"

e_out="$(python3 - "$root" <<'PY'
import importlib.util
import sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "food_catalog_rules", root + "/scripts/ops/food_catalog_rules.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.WHITELIST = {k: v for k, v in mod.WHITELIST.items() if k != ("flying_squid", "fish")}
print(mod.generate_sql_do_block())
PY
)"
expect_not_has "$e_out" "flying_squid" "E3. Mutation：拿掉 WHITELIST 條目後重新產生 SQL，flying_squid 排除子句消失（證明 SQL 真的吃同一份資料，不是另外手寫的靜態文字）"

# ==== F. R1 minor m1：desc 含 % 與單引號時，產生的 SQL 正確跳脫 ====
f_out="$(python3 - "$root" <<'PY'
import importlib.util
import sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "food_catalog_rules", root + "/scripts/ops/food_catalog_rules.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.KEYWORD_RULES = mod.KEYWORD_RULES + [
    ("wheat", ["ls342測試關鍵字"], "含 100% 全麥字＋單引號'測試'說明")
]
print(mod.generate_sql_do_block())
PY
)"
expect_has "$f_out" "含 100%% 全麥字＋單引號''測試''說明" "F1. desc 內的 % 跳脫成 %%、單引號跳脫成 ''（不是原樣貼進 RAISE 格式字串）"
expect_not_has "$f_out" "100% 全麥字" "F2. 未跳脫版本（單個 %）不應出現在輸出裡"

# F3：跳脫後，這一行只剩 1 個「真正的」RAISE 參數佔位符（v_bad 那個）——desc 裡的 %%
# 先消掉（跳脫後的字面 %，不是佔位符），數剩下的 % 應該恰好 1 個。
# LS-96 池項 25fea8c7 i3'：原本用 expect_has（子字串比對）——"1" 命中 "10"／"11"／
# "21" 也會過，改成精確比對（不引入新 helper，selftest-helpers.sh 沒有 expect_eq；
# `[ ... -eq ... ]` 已足夠，見檔頭）。
f_line="$(printf '%s\n' "$f_out" | grep -F "100%% 全麥字")"
remaining="$(printf '%s' "$f_line" | sed 's/%%/@/g' | tr -cd '%' | wc -c | tr -d ' ')"
if [ "$remaining" -eq 1 ] 2>/dev/null; then
  ok "F3. 跳脫後只剩 1 個真正的 RAISE 參數佔位符（v_bad），desc 裡的 %% 不會被誤算成佔位符"
else
  fail "F3. 跳脫後只剩 1 個真正的 RAISE 參數佔位符（期望 1，實得 ${remaining}）"
fi

# ==== G. 合成夾具：名稱含「芝麻」但 allergens 空、不在白名單 → 實跑 CLI deny（LS-347）====
synth_g="${work}/food_catalog_g.csv"
cat > "$synth_g" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
ls347_test_sesame,測試芝麻醬,fat_nut,1,,
CSV
g_out="$(FOOD_CATALOG_CSV_PATH="$synth_g" python3 "$script" check-allergens 2>&1)"
g_rc=$?
expect_exit 1 "$g_rc" "G. 名稱含「芝麻」但 allergens 空的合成列 → CLI check-allergens 紅（實際出口碼）"
expect_has "$g_out" "ls347_test_sesame" "G. 錯誤訊息點名 id"
expect_has "$g_out" "'sesame'" "G. 錯誤訊息點名缺的 allergen（sesame）"

# ==== H. 合成夾具：名稱含「芒果」但 allergens 空、不在白名單 → 實跑 CLI deny（LS-347）====
synth_h="${work}/food_catalog_h.csv"
cat > "$synth_h" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
ls347_test_mango,測試芒果乾,fruit,1,,
CSV
h_out="$(FOOD_CATALOG_CSV_PATH="$synth_h" python3 "$script" check-allergens 2>&1)"
h_rc=$?
expect_exit 1 "$h_rc" "H. 名稱含「芒果」但 allergens 空的合成列 → CLI check-allergens 紅（實際出口碼）"
expect_has "$h_out" "ls347_test_mango" "H. 錯誤訊息點名 id"
expect_has "$h_out" "'mango'" "H. 錯誤訊息點名缺的 allergen（mango）"

# ==== I. LS-96 池項 25fea8c7 m1'：FOOD_CATALOG_CSV_PATH 覆寫時，ok 訊息印出實際路徑 ====
synth_i="${work}/food_catalog_i.csv"
cat > "$synth_i" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
ls347_test_plain,測試白飯,grain_root,1,,
CSV
i_out="$(FOOD_CATALOG_CSV_PATH="$synth_i" python3 "$script" check-allergens 2>&1)"
i_rc=$?
expect_exit 0 "$i_rc" "I. 合成 CSV（無違規）check-allergens 通過"
expect_has "$i_out" "$synth_i" "I. ok 訊息印出實際讀到的路徑（覆寫用的合成 CSV，不是預設路徑）——拿掉這個修法，訊息會只寫死『CSV 端』不帶路徑，殘留的環境變數覆寫會無聲量錯資料"

# ==== J. LS-96 池項 25fea8c7 i2'：SOY_SAUCE_DISH_IDS 為空時，整段略過而非 `in ()` ====
j_out="$(python3 - "$root" <<'PY'
import importlib.util
import sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "food_catalog_rules", root + "/scripts/ops/food_catalog_rules.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.SOY_SAUCE_DISH_IDS = frozenset()
print(mod.generate_sql_do_block())
PY
)"
expect_not_has "$j_out" "id in ()" "J1. Mutation：SOY_SAUCE_DISH_IDS 清空後，產生的 SQL 不含恆假子句 \`id in ()\`（拿掉 generate_sql_do_block() 的 guard，這裡會變紅——原本的無 guard 版本會產生 \`where id in ()\`）"
expect_not_has "$j_out" "屬醬油調味慣例列" "J2. SOY_SAUCE_DISH_IDS 清空後，醬油慣例列的 raise exception 也一併消失"
expect_has "$j_out" "raise notice 'ok" "J3. 其餘收尾（raise notice／end／\$\$）仍正常產生，guard 沒有連帶炸掉整個 SQL 區塊"

# ==== K. LS-347 merge-review R1 m1：row-count 模式對「CSV 無尾換行」仍正確 ====
# synth_k 故意用 printf（不是 heredoc）、最後一列刻意不接 \n——`wc -l` 對這種檔案
# 只數得到 2 個換行符（會少算最後一列），`row-count`（沿用 load_rows() 的
# csv.DictReader）讀到 EOF 不論有沒有尾換行都正確，應回報 2。
synth_k="${work}/food_catalog_k.csv"
printf 'id,name_zh,category,sort_order,allergens,min_age_months\nls347_nlt_a,測試A,grain_root,1,,\nls347_nlt_b,測試B,grain_root,2,,' > "$synth_k"
k_newline_count="$(tr -cd '\n' < "$synth_k" | wc -c | tr -d ' ')"
expect_has "$k_newline_count" "2" "K0. 夾具本身確實缺尾換行（只有 2 個換行符，對應表頭＋第 1 列，最後一列沒有換行）"
k_out="$(FOOD_CATALOG_CSV_PATH="$synth_k" python3 "$script" row-count 2>&1)"
if [ "$k_out" = "2" ]; then
  ok "K1. row-count 對無尾換行的 CSV 仍正確回報 2 列（沿用 load_rows()，不受尾換行影響；\`wc -l\` 手法會少算成 1）"
else
  fail "K1. row-count 對無尾換行的 CSV 應回報 2（實得 ${k_out}）"
fi

echo ""
echo "food-catalog-allergen-check 自測：${selftest_helpers_n} 項，失敗 ${selftest_helpers_fail}"
[ "$selftest_helpers_fail" = 0 ]
