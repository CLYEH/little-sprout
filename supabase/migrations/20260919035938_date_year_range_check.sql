-- LS-336（源自 LS-331 merge-review R1 X1）—— 對四個 client 可寫入的 `date` 欄位加
-- 合理年份 CHECK 約束，DB 端擋住「裝置曆法（民國／佛曆／和曆）換算錯誤把
-- 0115-…／2569-…／0008-… 這種年份寫進 DB」這類毀損，不依賴 client 一定寫對
-- （LS-331 已經修好 client 端，這裡是最後一道防線；LS-313 × LS-331 的聯動錯誤
-- 甚至寫出過 3937-…，DB 之前照單全收）。
--
-- ---------------------------------------------------------------------------
-- 0. 範圍與邊界選擇
-- ---------------------------------------------------------------------------
--
-- 四個欄位（皆為 `date`、皆 `not null`，皆由 client 透過 RPC 參數寫入，見各自
-- migration：`children.birthday`——20260822120000_init_schema.sql；
-- `diaries.entry_date`——同檔；`growth_records.measured_on`——
-- 20260913065021_growth_records.sql；`child_food_records.first_tried_on`——
-- 20260918205141_food_encyclopedia.sql）：
--   children_birthday_year_range         on children.birthday
--   diaries_entry_date_year_range        on diaries.entry_date
--   growth_records_measured_on_year_range        on growth_records.measured_on
--   child_food_records_first_tried_on_year_range on child_food_records.first_tried_on
--
-- 邊界固定常數 `1900-01-01` ～ `2200-01-01`（**含**兩端；票面建議值，直接採用）：
--   - 下限 1900-01-01：孩子生日理論上不會早於這個世代（app 定位是「當代家庭
--     相簿」，不是家族史工具）；即使有極端案例，也遠早於任何合理的日記／量測／
--     飲食紀錄可能追溯的範圍。
--   - 上限 2200-01-01：留了遠超過「輸入年份多打一位數」（例如打成 2569、3937）
--     這種錯誤形狀的緩衝，但仍然遠低於任何合理輸入會不小心撞到的範圍——真正的
--     筆誤（民國轉換錯位、和曆年號算錯）產生的年份不是「稍微超界」，而是差好幾
--     個數量級（0xxx／25xx／39xx），邊界只需要「擋住這類數量級錯誤」，不需要
--     精確到某一年。
--   - **不用 `current_date`**：CHECK 約束必須是不可變條件（票面明訂），若邊界
--     跟著「現在」漂移，同一列資料在不同時間點求值可能有不同結果，也會讓
--     `VALIDATE CONSTRAINT` 的驗證時機影響哪些既有資料算合法——不可預期、
--     不可重現。四支 CHECK 全部只用字面常數。
--
-- 兩段式（`NOT VALID` + `VALIDATE CONSTRAINT`，沿用
-- `media_taken_at_range_check` 既有慣例，見 20260913163828_media_taken_at_
-- hardening.sql）：正式站現況（orchestrator 09-19 唯讀查詢，LS-331 comment
-- `8f56a6fe`）年份 <1900 或 >2100 皆 0 筆，理論上直接 `ADD CONSTRAINT`（不帶
-- `NOT VALID`）也不會失敗；但沒有在這支 migration 裡重新驗證過就不能假設「查詢
-- 當下」與「這支 migration 實際套用當下」之間沒有新資料寫入（即使視窗很小）。
-- `NOT VALID` 讓新 CHECK 只對之後的 INSERT/UPDATE 生效，既有列由下一句
-- `VALIDATE CONSTRAINT` 單獨掃描驗證，掃描失敗時只有那一句紅、能明確定位是哪
-- 一欄的既有資料出問題，不會讓整支 migration 因為某一欄卡住而連帶擋住其餘三欄。
--
-- ---------------------------------------------------------------------------
-- 1. children.birthday
-- ---------------------------------------------------------------------------
alter table public.children
  add constraint children_birthday_year_range
  check (birthday >= date '1900-01-01' and birthday <= date '2200-01-01')
  not valid;

alter table public.children
  validate constraint children_birthday_year_range;

-- ---------------------------------------------------------------------------
-- 2. diaries.entry_date
-- ---------------------------------------------------------------------------
alter table public.diaries
  add constraint diaries_entry_date_year_range
  check (entry_date >= date '1900-01-01' and entry_date <= date '2200-01-01')
  not valid;

alter table public.diaries
  validate constraint diaries_entry_date_year_range;

-- ---------------------------------------------------------------------------
-- 3. growth_records.measured_on
-- ---------------------------------------------------------------------------
alter table public.growth_records
  add constraint growth_records_measured_on_year_range
  check (measured_on >= date '1900-01-01' and measured_on <= date '2200-01-01')
  not valid;

alter table public.growth_records
  validate constraint growth_records_measured_on_year_range;

-- ---------------------------------------------------------------------------
-- 4. child_food_records.first_tried_on
-- ---------------------------------------------------------------------------
alter table public.child_food_records
  add constraint child_food_records_first_tried_on_year_range
  check (first_tried_on >= date '1900-01-01' and first_tried_on <= date '2200-01-01')
  not valid;

alter table public.child_food_records
  validate constraint child_food_records_first_tried_on_year_range;

-- ---------------------------------------------------------------------------
-- 5. 錯誤碼——沿用既有裁量，不新開 LSnnn 碼
-- ---------------------------------------------------------------------------
--
-- 違反這四支 CHECK 一律標準碼 `23514`（PostgREST／psql 皆是），跟
-- `media_taken_at_range_check`、`growth_records` 三項量測、`child_food_records`
-- 的 note/reaction CHECK 同一組既有裁量：CHECK 約束違反本來就是標準碼，不是
-- RPC 自訂邏輯的分支，不需要也不應該為了「多一種欄位」另開自訂碼——
-- `docs/API.md` §5 標準碼表已經在列，這裡只需要把四個新約束名字加進那個
-- 「觸發情境」欄位當例子（同 PR，見 docs/API.md 改動），`error-codes-check.sh`
-- 只對帳 `LSnnn` 自訂碼集合，不受影響。
