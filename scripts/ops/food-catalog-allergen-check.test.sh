#!/bin/bash
# food_catalog_rules.py／food-catalog-sql.py check-allergens／check-allergens-sql 自測
# （LS-342）。CI rules job 每個 PR 都跑（無需 DB，見 ci.yml 與 selftest-wiring-check）。
#
# 涵蓋範圍（票文範圍 1／3）：
#   A. 真實 CSV（supabase/seed-data/food_catalog.csv）跑 check-allergens 全過（exit 0）
#      ——基準：LS-342 對現況 274 列跑過一次，見 handoff。
#   B. 合成夾具：一列名稱含「魚」但 allergens 空、且不在白名單 → check-allergens
#      exit 1，訊息點名該 id 與缺的 allergen（CSV 端 deny）。
#   C. 合成夾具：SOY_SAUCE_DISH_IDS 其中一個 id（braised_pork_rice）allergens 空
#      → exit 1，訊息點名「醬油調味慣例列」（顯式 id 清單路徑的 deny，不是關鍵字
#      路徑）。
#   D. 白名單真的有作用：用真實 CSV 裡的 flying_squid（魷魚，allergens 空，靠
#      WHITELIST 的 (flying_squid, fish) 例外通過）單獨跑 check_rows() 不紅；把
#      WHITELIST 那個條目拿掉重跑同一列 → 紅（Mutation：白名單拿掉一條 → 紅，
#      票文要求）。
#   E. check-allergens-sql 產生的 SQL 文字含 flying_squid 的白名單排除子句與八個
#      allergen 的 raise exception——證明 SQL 是從同一份規則產生，不是另外手寫
#      （單一來源）。Mutation：拿掉 WHITELIST 的 flying_squid 條目重新產生 → SQL
#      不再含排除子句，證明兩條路徑（Python 直跑／產生 SQL）真的吃同一份資料。
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

# ==== B. 合成夾具：名稱含「魚」但 allergens 空、不在白名單 → deny ====
synth_b="${work}/food_catalog_b.csv"
cat > "$synth_b" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
ls342_test_fish,測試魚,protein,1,,
CSV
b_out="$(python3 - "$script" "$synth_b" <<'PY'
import importlib.util
import sys

script_path, csv_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("food_catalog_sql", script_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.CSV_PATH = csv_path
rows = mod.load_rows()
violations = mod.food_catalog_rules.check_rows(rows)
for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PY
)"
b_rc=$?
expect_exit 1 "$b_rc" "B. 名稱含「魚」但 allergens 空的合成列 → check_rows 紅"
expect_has "$b_out" "ls342_test_fish" "B. 錯誤訊息點名 id"
expect_has "$b_out" "'fish'" "B. 錯誤訊息點名缺的 allergen（fish）"

# ==== C. 合成夾具：醬油調味慣例列（顯式 id 清單）allergens 空 → deny ====
synth_c="${work}/food_catalog_c.csv"
cat > "$synth_c" <<'CSV'
id,name_zh,category,sort_order,allergens,min_age_months
braised_pork_rice,滷肉飯,tw_home,1,,
CSV
c_out="$(python3 - "$script" "$synth_c" <<'PY'
import importlib.util
import sys

script_path, csv_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("food_catalog_sql", script_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.CSV_PATH = csv_path
rows = mod.load_rows()
violations = mod.food_catalog_rules.check_rows(rows)
for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PY
)"
c_rc=$?
expect_exit 1 "$c_rc" "C. 醬油調味慣例列（braised_pork_rice）allergens 空 → check_rows 紅"
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

echo ""
echo "food-catalog-allergen-check 自測：${selftest_helpers_n} 項，失敗 ${selftest_helpers_fail}"
[ "$selftest_helpers_fail" = 0 ]
