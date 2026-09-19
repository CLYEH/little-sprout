-- LS-347 —— `food_catalog_allergens_valid` 列舉補 `sesame`（芝麻）、`mango`（芒果）。
--
-- 背景：LS-342 範圍明講「不做：新增 allergen 列舉值」，所以當時 `sesame_oil`
-- （芝麻油）／`tahini`（芝麻醬）的芝麻缺口只能記入 LS-96 池項 `9fb5f0b3` i1，沒有
-- 規則能檢查它們。LS-347 盤點台灣食品過敏原強制標示（衛福部 107 年 8 月 21 日
-- 公告「食品過敏原標示規定」，109 年 7 月 1 日生效，11 類：甲殼類、芒果、花生、
-- 牛奶及羊奶、蛋、堅果類、芝麻、含麩質之穀物、大豆、魚類、亞硫酸鹽——出處
-- https://www.mohw.gov.tw/cp-16-43376-1.html，2026-09-19 查證，PR body 附完整
-- 查證；merge-review R1 m2：公告文號在該頁全文核對不到，故不寫進本檔）
-- 對照本表現有 8 個列舉值，缺 2 項：`sesame`（芝麻）、`mango`（芒果）——第 11 項
-- 亞硫酸鹽是添加物殘留量標示（終產品以二氧化硫殘留量計），不適用本表這種原型食物
-- 目錄，不新增列舉值。`shellfish` 沿用既有命名對應「甲殼類」，但範圍略寬（LS-325
-- 起也涵蓋蛤／蚵／牡蠣等雙殼貝類，非嚴格意義的甲殼類），不改名、維持現狀。
--
-- Postgres 無法直接 ALTER 一個 CHECK 約束的運算式，只能 DROP 舊約束、ADD 新約束——
-- 這是這條規則從「8 選 1」放寬成「10 選 1」的唯一寫法，不是移除任何既有允許值
-- （新舊約束對現有 274 列資料的驗證結果完全相同，純粹放寬）。
alter table public.food_catalog
  drop constraint food_catalog_allergens_valid;

alter table public.food_catalog
  add constraint food_catalog_allergens_valid check (
    allergens <@ array[
      'egg', 'milk', 'peanut', 'tree_nut', 'shellfish', 'fish', 'wheat', 'soy',
      'sesame', 'mango'
    ]::text[]
  );

-- 既有 migration（`20260918205141_food_encyclopedia.sql`）不可改（immutable gate），
-- 用 UPDATE 補標三列既有漏標；`supabase/seed-data/food_catalog.csv` 同步改動，
-- `scripts/ops/food-catalog-sql.py check` 驗兩者一致。
--
-- 冪等：三支 UPDATE 皆用 `where id = '<slug>'` 鎖定單一列，重跑（例如 CI 對同一份
-- migration 序列重放）不會因為值已經是目標陣列而失敗——UPDATE 對「已是目標值」的列
-- 是 no-op，不需要額外 idempotency guard（同 `20260919102837_food_catalog_oatmeal_wheat.sql`
-- 的既有慣例）。

update public.food_catalog
   set allergens = array['mango']::text[]
 where id = 'mango';

update public.food_catalog
   set allergens = array['sesame']::text[]
 where id = 'sesame_oil';

update public.food_catalog
   set allergens = array['sesame']::text[]
 where id = 'tahini';
