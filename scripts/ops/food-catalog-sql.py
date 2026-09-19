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
                                                      （目前 CSV 全部列）
  python3 scripts/ops/food-catalog-sql.py insert --only-new <base-csv>
                                                    > 同上，但只印 id 不存在於 <base-csv> 的列——
                                                      LS-339：新增一批品項時，拿舊版 CSV（例如
                                                      `git show <前一支 migration 的 commit>:supabase/
                                                      seed-data/food_catalog.csv > /tmp/old.csv`）當
                                                      base，只產生「這支新 migration 該 INSERT 的列」，
                                                      不必手動從全量 insert 輸出裡挑出新增的部分。
  python3 scripts/ops/food-catalog-sql.py check    > 一段自我完整的 DO 區塊，逐列比對 public.food_catalog
                                                      與 CSV 目前內容（供 supabase/tests/run.sh 在跑
                                                      117_food_encyclopedia.sql 之前，host 端動態產生後
                                                      交給既有的 run_sql() 執行——兩種連線通道皆適用，
                                                      理由見上；比對涵蓋全部欄位含 sort_order／
                                                      allergens，不論資料是哪一支 migration 寫入的，
                                                      因為比的是 DB 現況與目前 CSV 現況，天然涵蓋「多支
                                                      migration 累加」）
  python3 scripts/ops/food-catalog-sql.py check-allergens
                                                    > 純 Python／CSV，不需要 DB：對 CSV 目前內容跑
                                                      food_catalog_rules.py 的過敏原啟發式規則（LS-342），
                                                      有違規時把每一列印到 stderr 並 exit 1，供 CI
                                                      `rules` job（無 DB）與本機快速檢查使用。環境變數
                                                      `FOOD_CATALOG_CSV_PATH` 可覆寫讀取路徑（自測用合成
                                                      CSV 跑真正的 CLI 出口碼，不必 monkeypatch，LS-342
                                                      R2 informational i2；這個覆寫對 insert／check／
                                                      check-allergens 三個模式皆生效——`ok` 訊息印出實際
                                                      讀到的路徑，避免殘留的環境變數覆寫讓人誤以為驗的是
                                                      正式 CSV，LS-96 池項 25fea8c7 m1'）。
  python3 scripts/ops/food-catalog-sql.py check-allergens-sql
                                                    > 把同一份規則（food_catalog_rules.py）轉成一段 SQL
                                                      DO 區塊，對 public.food_catalog 目前內容（DB 現況）
                                                      跑同樣的檢查（供 supabase/tests/run.sh 使用，理由
                                                      與 check 相同）。
  python3 scripts/ops/food-catalog-sql.py row-count
                                                    > 印出 CSV 目前列數（單一整數，無其他輸出）——供
                                                      supabase/tests/run.sh 的 sort_order 探針飄移偵測
                                                      使用，沿用 load_rows() 既有的 CSV 讀取路徑，不論
                                                      檔尾有沒有換行都正確（LS-347 merge-review R1 m1：
                                                      原本 bash 端用 `wc -l` 推算會少算缺尾換行的檔案）。

不用任何第三方套件（Rule 12 對 Python 套件安裝的規定不適用——這裡完全不需要安裝套件，
標準庫 csv／sys 就夠）。
"""
import csv
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import food_catalog_rules  # noqa: E402

CSV_PATH = pathlib.Path(
    os.environ.get("FOOD_CATALOG_CSV_PATH")
    or (HERE.parent.parent / "supabase" / "seed-data" / "food_catalog.csv")
)

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
    args = sys.argv[1:]
    mode = args[0] if args else "insert"
    only_new_base = None
    if mode == "insert" and len(args) > 1:
        if len(args) == 3 and args[1] == "--only-new":
            only_new_base = args[2]
        else:
            raise SystemExit("insert 模式只接受 --only-new <base-csv> 這一種額外參數")
    elif mode != "insert" and len(args) > 1:
        raise SystemExit(f"{mode} 模式不接受額外參數")

    if mode == "check-allergens":
        rows = load_rows()
        violations = food_catalog_rules.check_rows(rows)
        if violations:
            for v in violations:
                print(v, file=sys.stderr)
            raise SystemExit(1)
        print(
            f"ok：food_catalog 過敏原啟發式檢查通過（CSV 端，{len(rows)} 列，LS-342，"
            f"讀取路徑：{CSV_PATH}）"
        )
        return
    if mode == "check-allergens-sql":
        sys.stdout.write(food_catalog_rules.generate_sql_do_block())
        return
    if mode == "row-count":
        # LS-347 merge-review R1 m1：run.sh 原本用 `wc -l` 推算 CSV 列數（隱含「檔尾
        # 有換行」的假設，缺尾換行會少算 1）。改讓 run.sh 呼叫這個模式，沿用
        # load_rows()（csv.DictReader）既有的 CSV 讀取路徑——不論檔尾有沒有換行都
        # 讀得到最後一行，不必在 bash 端另外維護第二套「數列數」的算法。
        print(len(load_rows()))
        return

    rows = load_rows()
    if only_new_base:
        with open(only_new_base, newline="", encoding="utf-8") as f:
            base_ids = {r["id"] for r in csv.DictReader(f)}
        rows = [r for r in rows if r["id"] not in base_ids]
        if not rows:
            raise SystemExit(f"--only-new：{only_new_base} 與目前 CSV 沒有差異（0 筆新增列）")

    values = [row_to_values(r) for r in rows]
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
    raise SystemExit(
        f"未知模式：{mode}（用 insert／check／check-allergens／check-allergens-sql／row-count）"
    )


if __name__ == "__main__":
    main()
