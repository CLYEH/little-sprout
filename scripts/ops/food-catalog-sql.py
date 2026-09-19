#!/usr/bin/env python3
"""LS-325 — 把 supabase/seed-data/food_catalog.csv 轉成 food_catalog 的 INSERT 語句。

用途：
  1. 產生本票 migration（20260918205141_food_encyclopedia.sql）的 seed INSERT 區塊——
     這個腳本的輸出直接貼進該 migration，不是執行期依賴（migration 套用時不會、也不能
     呼叫這支腳本；CSV 是「產出 migration 內容」的來源，不是 migration 的執行期輸入）。
  2. 供 `supabase/tests/117_food_encyclopedia.sql` 的「CSV↔migration 一致性」測試比對：
     該測試把這支腳本的輸出（穩定、可重現）與資料庫裡 `food_catalog` 的實際內容逐列比對
     ——而不是讓 SQL 測試直接讀取 CSV 檔案本身，理由是 `supabase/tests/run.sh` 有兩種連線
     通道（host psql／docker exec psql -f -），docker exec 通道下 psql 行程跑在容器內、
     看不到 host 的 repo 路徑，`\\copy`／`\\i` 這類需要用戶端存取檔案系統的指令在那條通道
     會失敗——改成「host 端先用這支腳本把 CSV 轉成一段 SQL（VALUES 常值），寫進暫存檔，
     再用既有的 run_sql()（本來就是把檔案內容整個讀進來、經 stdin 餵給 psql）執行」，
     兩種通道都適用，不需要幫 docker exec 額外掛 volume mount。

用法：
  python3 scripts/ops/food-catalog-sql.py insert   > 一段 `insert into public.food_catalog (...) values (...);`
  python3 scripts/ops/food-catalog-sql.py values   > 只印 VALUES 的每一列（給測試比對用，不含 insert 前綴／分號）
  python3 scripts/ops/food-catalog-sql.py check    > 一段自我完整的 DO 區塊，逐列比對 public.food_catalog
                                                      與 CSV 目前內容（供 supabase/tests/run.sh 在跑
                                                      117_food_encyclopedia.sql 之前，host 端動態產生後
                                                      交給既有的 run_sql() 執行——兩種連線通道皆適用，
                                                      理由見上）

不用任何第三方套件（Rule 12 對 Python 套件安裝的規定不適用——這裡完全不需要安裝套件，
標準庫 csv／sys 就夠）。
"""
import csv
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
CSV_PATH = HERE.parent.parent / "supabase" / "seed-data" / "food_catalog.csv"

COLUMNS = ["id", "name_zh", "category", "sort_order", "allergens", "min_age_months"]


def sql_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def allergens_literal(raw: str) -> str:
    if not raw:
        return "'{}'::text[]"
    items = [sql_quote(a) for a in raw.split(";") if a]
    return "array[" + ",".join(items) + "]::text[]"


def row_to_values(row: dict) -> str:
    min_age = row["min_age_months"].strip()
    min_age_sql = min_age if min_age else "null"
    return "({id}, {name}, {category}, {sort_order}, {allergens}, {min_age})".format(
        id=sql_quote(row["id"]),
        name=sql_quote(row["name_zh"]),
        category=sql_quote(row["category"]),
        sort_order=row["sort_order"],
        allergens=allergens_literal(row["allergens"]),
        min_age=min_age_sql,
    )


def load_rows():
    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != COLUMNS:
            raise SystemExit(f"CSV 表頭不符期待：{reader.fieldnames} != {COLUMNS}")
        return list(reader)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "insert"
    rows = load_rows()
    values = [row_to_values(r) for r in rows]
    if mode == "values":
        for v in values:
            print(v + ",")
        return
    if mode == "insert":
        print("insert into public.food_catalog (id, name_zh, category, sort_order, allergens, min_age_months)")
        print("values")
        print(",\n".join(values) + ";")
        return
    if mode == "check":
        print(r"\set ON_ERROR_STOP on")
        print("do $$")
        print("declare")
        print("  v_expected_count int;")
        print("  v_mismatch text;")
        print("begin")
        print("  create temp table ls325_food_catalog_expected (")
        print("    id text, name_zh text, category text, sort_order int,")
        print("    allergens text[], min_age_months int")
        print("  ) on commit drop;")
        print("  insert into ls325_food_catalog_expected")
        print("    (id, name_zh, category, sort_order, allergens, min_age_months)")
        print("  values")
        print(",\n".join(values) + ";")
        print("")
        print("  select count(*) into v_expected_count from ls325_food_catalog_expected;")
        print("  if v_expected_count <> " + str(len(rows)) + " then")
        print(
            "    raise exception 'FAIL：CSV 產生器與 CSV 本身列數不一致（不應發生）：%s vs %s', "
            "v_expected_count, " + str(len(rows)) + ";"
        )
        print("  end if;")
        print("")
        print("  -- 多出來或缺少的 id（集合差集，任一邊非空即 FAIL）")
        print("  select string_agg(id, ', ') into v_mismatch")
        print("    from (select id from public.food_catalog except select id from ls325_food_catalog_expected) x;")
        print("  if v_mismatch is not null then")
        print(
            "    raise exception 'FAIL：food_catalog 有 CSV 沒有的 id（migration seed 與 CSV 不一致）：%', v_mismatch;"
        )
        print("  end if;")
        print("  select string_agg(id, ', ') into v_mismatch")
        print("    from (select id from ls325_food_catalog_expected except select id from public.food_catalog) x;")
        print("  if v_mismatch is not null then")
        print(
            "    raise exception 'FAIL：CSV 有 food_catalog 沒有的 id（migration seed 缺列）：%', v_mismatch;"
        )
        print("  end if;")
        print("")
        print("  -- 逐欄比對（id 相同但內容不同）")
        print("  select string_agg(f.id, ', ') into v_mismatch")
        print("    from public.food_catalog f")
        print("    join ls325_food_catalog_expected e on e.id = f.id")
        print("   where f.name_zh is distinct from e.name_zh")
        print("      or f.category is distinct from e.category")
        print("      or f.sort_order is distinct from e.sort_order")
        print("      or f.allergens is distinct from e.allergens")
        print("      or f.min_age_months is distinct from e.min_age_months;")
        print("  if v_mismatch is not null then")
        print(
            "    raise exception 'FAIL：food_catalog 與 CSV 內容不一致的 id：%', v_mismatch;"
        )
        print("  end if;")
        print("")
        print(f"  raise notice 'ok：food_catalog（{len(rows)} 列）與 CSV（scripts/ops/food-catalog-sql.py 產生）逐列一致';")
        print("end;")
        print("$$;")
        return
    raise SystemExit(f"未知模式：{mode}（用 insert／values／check）")


if __name__ == "__main__":
    main()
