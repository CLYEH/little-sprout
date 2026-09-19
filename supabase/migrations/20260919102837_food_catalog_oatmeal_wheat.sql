-- LS-342 R2（merge-review R1 major m1，orchestrator 裁決 (a)）—— `oatmeal`
-- （燕麥粥）補標 `wheat` 過敏原。
--
-- 背景：`20260918205141_food_encyclopedia.sql` seed 把 `oatmeal` 的 allergens 留空，
-- 但同一份 seed 把 `barley_tea`（麥仔茶，大麥製品）標成 `wheat`——同一支
-- migration 對「wheat」這個標籤的語意其實是未定義的：對大麥採「含麩質穀物代理」
-- 讀法，對燕麥卻沒有。LS-342 過敏原啟發式規則（`scripts/ops/food_catalog_rules.py`）
-- 把這個矛盾攤在陽光下（同一條「名稱含麥→wheat」規則，對 `麥仔茶` 要求標
-- `wheat`、對 `燕麥粥` 原本給了例外），merge-review R1 major m1 指出後，
-- orchestrator 裁決本表 `wheat` 的語意定為「含麩質穀物代理」——對齊台灣食品過敏原
-- 強制標示「含麩質之穀物及其製品」：小麥、大麥、黑麥、燕麥——與既有 `barley_tea`
-- 標記一致。依此定義，`oatmeal` 是既有漏標，不是規則的例外。
--
-- 既有 migration（`20260918205141_food_encyclopedia.sql`）不可改（immutable gate），
-- 所以用新 migration 訂正這一列；`supabase/seed-data/food_catalog.csv` 同步改動，
-- `scripts/ops/food-catalog-sql.py check` 驗兩者一致。
--
-- 冪等：UPDATE 只用 `where id = 'oatmeal'` 鎖定單一列，重跑（例如 CI 對同一份
-- migration 序列重放）不會因為值已經是 `{wheat}` 而失敗——UPDATE 對「已是目標值」
-- 的列是 no-op，不像 INSERT 會撞 23505；不需要額外的 idempotency guard。

update public.food_catalog
   set allergens = array['wheat']::text[]
 where id = 'oatmeal';
