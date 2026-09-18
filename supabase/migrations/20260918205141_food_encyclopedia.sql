-- LS-325（LS-310 F5b 後端先行）—— 飲食圖鑑後端：`food_catalog`（靜態目錄，migration
-- seed）＋`child_food_records`（每寶貝每食物一筆第一次記錄）＋RLS／RPC＋時間軸
-- `food_first` feed 項。
--
-- 先例（沿用寫法，不重新發明）：
--   - `supabase/migrations/20260913065021_growth_records.sql`（LS-255）——本票權限模型
--     逐字沿用其檔頭第 0 段的推導：真 RLS（不是 diaries/albums/comments/children 那種
--     RPC-only 收斂）、owner 完全不在 UPDATE policy 裡（「更新只限作者」，避免 owner
--     藉 grant 過寬竄改別人內容）、`family_id in (select private.contributor_family_ids())`
--     即時子查詢（避免「author_id 沒變、舊授權繼續有效」的窗口）、軟刪唯一路徑是
--     `SECURITY DEFINER` RPC（`deleted_at`／`deleted_by` 對 authenticated 無 UPDATE
--     grant）。`child_food_records` 逐條套用同一套，不重新推導一次。
--   - `supabase/migrations/20260917155738_media_children.sql`（LS-317）——
--     `feed_items`／`feed_item_children` 同步 trigger 寫法（statement-level trigger＋
--     transition table）、`get_family_timeline` 的 `CREATE OR REPLACE`（只加 `child_ids`
--     CASE 分支，其餘逐字保留，見該檔第 5 段），本票對 `get_family_timeline` 套用同一個
--     手法。
--   - `20260918205134_food_encyclopedia_feed_kind.sql`（本票前一支）——`feed_kind` 已經
--     `ALTER TYPE ... ADD VALUE 'food_first'` 並 commit，這支才能使用這個新值。
--
-- ---------------------------------------------------------------------------
-- 0. 設計取捨
--
-- a) `upsert_child_food_record` 用 `INSERT ... ON CONFLICT (child_id, food_id) WHERE
--    deleted_at IS NULL DO UPDATE` 而不是 growth_records 那種「先查、再靠 p_id 分支
--    INSERT／UPDATE」——因為本票的「同一寶貝同一食物」是自然鍵（不像 growth_records
--    允許同一天多筆、需要呼叫端自己認 `p_id` 分辨），`p_id`-based 分支在這裡沒有意義：
--    呼叫端根本不知道、也不需要知道目前有沒有一筆既存紀錄的 `id`。改用 `ON CONFLICT`
--    有雙重好處：
--      1. 語意直接對齊「同一寶貝同一食物最多一筆未軟刪紀錄」這條票面規則本身——
--         partial unique index 既是約束、也是這支 RPC 唯一需要的併發仲裁點，不需要
--         額外的 `pg_advisory_xact_lock`（`toggle_reaction`／`record_notification_event`
--         用鎖是因為它們的「衝突」判斷本身不是靠一個現成的 unique index 表達；這裡
--         已經有 partial unique index 可以直接當 `ON CONFLICT` 的仲裁目標，不必多繞一層）。
--      2. RLS 對 `INSERT ... ON CONFLICT DO UPDATE` 的既有行為（本 repo 已有先例，見
--         `20260822120200_rls_policies.sql:336` 對 `register_device_token` 的檔頭說明：
--         「UPSERT → on conflict 的 UPDATE 要通過舊列的 USING，舊列屬於別人，噴
--         42501」）恰好精確表達票面「更新僅原作者可，否則明確錯誤」——衝突發生時
--         Postgres 對 DO UPDATE 套用 `child_food_records_update` policy 的 USING／
--         WITH CHECK；不通過**不是**靜默 0 列（那是純 `UPDATE ... WHERE` 語句的行為，
--         growth_records §2 R1 informational i5 記載的那種例外），而是直接噴
--         `42501`——INSERT 家族的陳述式對 RLS 違反一律 fail loud，沒有「這一列不在
--         USING 範圍內就跳過」這個概念（INSERT 沒有「既有可見列」的概念，只有「這一
--         次要不要讓這個結果落地」）。這正是票面「並發：...第二筆得到明確錯誤或轉為
--         更新」的两種結果——同一位作者的重疊呼叫轉為更新（USING 通過）；不同作者
--         互相踩線得到明確 42501（USING 不通過）——由 Postgres 原生機制保證，函式
--         本體不需要再手寫一次判斷。
--    因此本函式**不需要**額外的 `if not found then raise` 防禦——`RETURNING * INTO`
--    在陳述式沒有拋例外的前提下必定填到一列（INSERT 家族陳述式的 RLS 違反是例外，
--    不是「這一列消失」），寫一個永遠不會執行到的分支不符合「no error handling for
--    impossible scenarios」（本機 `supabase db reset`＋`117_food_encyclopedia.sql`
--    §5 已實際驗證兩種結果都是例外，不是靜默）。
--
-- b) `media_id` 的「必須同家庭」比照票面括號裡的「trigger 或 check」二選一——選
--    **複合外鍵**（既不是 trigger 也不是裸 CHECK，但同屬「DB 層約束」的精神，且是
--    本 repo 對這個確切問題的既定寫法）：`albums.cover_media_id`（`20260822120000_
--    init_schema.sql:162-164`）用同一招——`foreign key (family_id, media_id)
--    references media (family_id, id) on delete set null (media_id)`，media 表已有
--    `media_family_id_id_key unique (family_id, id)` 可供參照（同檔 136 行）。這比
--    另寫一支 trigger 簡單、且是資料庫層的硬約束（不像 trigger 需要正確處理
--    INSERT／UPDATE 兩種操作各自的觸發條件），選它不是偷懶，是「有現成、更強的機制
--    就不要多寫一支功能重複的 trigger」（Rule 2）。`on delete set null (media_id)`
--    （只 NULL 掉 `media_id`，不動 `family_id`）比照 `cover_media_id`，不是
--    `media_children`／`album_media` 那種連結表用的 `on delete cascade`——道理相同：
--    `child_food_records` 是一筆帶著「附一張照片」這個選填屬性的內容列，不是純粹的
--    連結列，photo 被刪不該連帶整筆飲食紀錄都消失。
--
-- c) `food_catalog` 為什麼用 migration seed 而不是留給 client／別的機制填：這是一份
--    app 內建、v1 不開放自訂的靜態目錄（票面 F1a：「app 內建，v1 不開放自訂」），且
--    `id` 同時是插圖資產名（F3a）——這代表 id／清單內容本質上是程式碼（跟畫面繫結的
--    常數），不是使用者資料，seed 在 migration 裡讓它跟 schema 版本綁在一起（改清單＝
--    改 schema 版本＝走 migration 流程），也让「哪個環境有哪個版本的清單」永遠可以從
--    「套用到哪支 migration」直接回答，不需要另外一套「seed 資料同步」機制。CSV
--    （`supabase/seed-data/food_catalog.csv`）是這份清單的人類可讀來源與使用者過目
--    介面，`scripts/ops/food-catalog-sql.py` 把它轉成下面第 2 段的 INSERT——兩者一致性
--    由 `supabase/tests/run.sh` 在跑 `117_food_encyclopedia.sql` 之前，host 端呼叫同一支
--    腳本動態產生並執行機械驗證（標記為 §1；`117_food_encyclopedia.sql` 本檔從 §2
--    開始，見該檔檔頭，merge-review R1 informational i2：不是文字直接寫在該檔案內，
--    不是靠人工目視）。
--
-- d) `list_child_food_records`／`upsert_child_food_record` 皆 `security invoker`
--    （同 `list_growth_records`／`upsert_growth_record` 的既有慣例）——完全依賴
--    `child_food_records_select`／`_insert`／`_update` 三條真 RLS，函式本體不做任何
--    手動授權判斷；只有 `delete_child_food_record` 需要 `security definer`（理由同
--    `delete_growth_record`：`deleted_at`／`deleted_by` 對 authenticated 無 UPDATE
--    grant，且「owner 可移除他人紀錄」無法只靠 author-scoped RLS 表達）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. food_catalog（靜態目錄）
-- ---------------------------------------------------------------------------
create table public.food_catalog (
  id text primary key,
  name_zh text not null,
  category text not null,
  sort_order int not null,
  allergens text[] not null default '{}'::text[],
  min_age_months int,
  active boolean not null default true,
  constraint food_catalog_category_valid check (category in (
    'grain_root', 'vegetable', 'fruit', 'protein', 'dairy', 'fat_nut', 'tw_home', 'snack_drink'
  )),
  -- 8 種常見過敏原子集（票面 F2a），子集用 `<@`（contained by）——每個元素都必須是
  -- 這 8 種之一，不限制陣列長度／是否重複（`upsert_child_food_record`／iOS 端都不會
  -- 產生重複值，這裡的 seed 資料也不重複，加 DISTINCT 約束是沒有實際案例的過度設計）。
  constraint food_catalog_allergens_valid check (
    allergens <@ array['egg', 'milk', 'peanut', 'tree_nut', 'shellfish', 'fish', 'wheat', 'soy']::text[]
  )
);

comment on table public.food_catalog is
  '飲食圖鑑靜態目錄（LS-325，LS-310 F1a／F2a／F3a）：約 120 種台灣常見食物，8 類
  （`grain_root`／`vegetable`／`fruit`／`protein`／`dairy`／`fat_nut`／`tw_home`／
  `snack_drink`），依國健署副食品引入順序排 `sort_order`。`id` 同時是 app 插圖資產名
  （F3a），v1 不開放自訂（F1a）。內容來源：`supabase/seed-data/food_catalog.csv`（人類
  可讀，供使用者過目），由 `scripts/ops/food-catalog-sql.py` 轉成下面第 2 段的 INSERT
  ——兩者一致性見 `supabase/tests/run.sh`（跑 `117_food_encyclopedia.sql` 之前
  host 端動態產生執行，標記 §1，見該檔檔頭）。全表唯讀：
  `authenticated` 只有 SELECT，沒有任何寫入 grant（只有本 migration、以表擁有者身分
  執行的 INSERT 寫過這張表）。`allergens`／`min_age_months` 純資訊、附免責聲明（F2a，
  文案在 iOS 端呈現，不在後端），不構成醫療建議。';

alter table public.food_catalog enable row level security;

create policy food_catalog_select on public.food_catalog for select to authenticated
  using (true);

grant select on public.food_catalog to authenticated;

-- ---------------------------------------------------------------------------
-- 2. food_catalog seed（由 scripts/ops/food-catalog-sql.py 依
--    supabase/seed-data/food_catalog.csv 生成；本區塊與 CSV 逐列一致，由
--    supabase/tests/run.sh 動態產生執行機械驗證（標記 §1，見
--    117_food_encyclopedia.sql 檔頭）——改動清單一律先改 CSV，
--    重新跑一次腳本貼過來，不要手改下面的 INSERT）
-- ---------------------------------------------------------------------------
insert into public.food_catalog (id, name_zh, category, sort_order, allergens, min_age_months)
values
('rice_cereal', '米精', 'grain_root', 1, '{}'::text[], null),
('rice_porridge', '白粥', 'grain_root', 2, '{}'::text[], null),
('oatmeal', '燕麥粥', 'grain_root', 3, '{}'::text[], null),
('white_rice', '白米飯', 'grain_root', 4, '{}'::text[], null),
('brown_rice', '糙米飯', 'grain_root', 5, '{}'::text[], null),
('sweet_potato', '地瓜', 'grain_root', 6, '{}'::text[], null),
('purple_sweet_potato', '紫地瓜', 'grain_root', 7, '{}'::text[], null),
('potato', '馬鈴薯', 'grain_root', 8, '{}'::text[], null),
('pumpkin', '南瓜', 'grain_root', 9, '{}'::text[], null),
('taro', '芋頭', 'grain_root', 10, '{}'::text[], null),
('yam', '山藥', 'grain_root', 11, '{}'::text[], null),
('corn', '玉米', 'grain_root', 12, '{}'::text[], null),
('quinoa', '藜麥', 'grain_root', 13, '{}'::text[], null),
('noodles', '麵條', 'grain_root', 14, array['wheat']::text[], null),
('bread', '吐司麵包', 'grain_root', 15, array['wheat']::text[], null),
('steamed_bun', '白饅頭', 'grain_root', 16, array['wheat']::text[], null),
('spinach', '菠菜', 'vegetable', 17, '{}'::text[], null),
('carrot', '紅蘿蔔', 'vegetable', 18, '{}'::text[], null),
('broccoli', '花椰菜', 'vegetable', 19, '{}'::text[], null),
('cauliflower', '白花椰菜', 'vegetable', 20, '{}'::text[], null),
('napa_cabbage', '大白菜', 'vegetable', 21, '{}'::text[], null),
('bok_choy', '青江菜', 'vegetable', 22, '{}'::text[], null),
('water_spinach', '空心菜', 'vegetable', 23, '{}'::text[], null),
('cabbage', '高麗菜', 'vegetable', 24, '{}'::text[], null),
('lettuce', '萵苣', 'vegetable', 25, '{}'::text[], null),
('tomato', '番茄', 'vegetable', 26, '{}'::text[], null),
('cucumber', '小黃瓜', 'vegetable', 27, '{}'::text[], null),
('eggplant', '茄子', 'vegetable', 28, '{}'::text[], null),
('bitter_melon', '苦瓜', 'vegetable', 29, '{}'::text[], null),
('loofah', '絲瓜', 'vegetable', 30, '{}'::text[], null),
('white_radish', '白蘿蔔', 'vegetable', 31, '{}'::text[], null),
('mushroom', '香菇', 'vegetable', 32, '{}'::text[], null),
('green_bean', '四季豆', 'vegetable', 33, '{}'::text[], null),
('pea', '豌豆', 'vegetable', 34, '{}'::text[], null),
('banana', '香蕉', 'fruit', 35, '{}'::text[], null),
('apple', '蘋果', 'fruit', 36, '{}'::text[], null),
('papaya', '木瓜', 'fruit', 37, '{}'::text[], null),
('avocado', '酪梨', 'fruit', 38, '{}'::text[], null),
('pear', '水梨', 'fruit', 39, '{}'::text[], null),
('peach', '桃子', 'fruit', 40, '{}'::text[], null),
('orange', '橘子', 'fruit', 41, '{}'::text[], null),
('watermelon', '西瓜', 'fruit', 42, '{}'::text[], null),
('cantaloupe', '哈密瓜', 'fruit', 43, '{}'::text[], null),
('mango', '芒果', 'fruit', 44, '{}'::text[], null),
('guava', '芭樂', 'fruit', 45, '{}'::text[], null),
('dragon_fruit', '火龍果', 'fruit', 46, '{}'::text[], null),
('kiwi', '奇異果', 'fruit', 47, '{}'::text[], null),
('strawberry', '草莓', 'fruit', 48, '{}'::text[], null),
('pineapple', '鳳梨', 'fruit', 49, '{}'::text[], null),
('persimmon', '柿子', 'fruit', 50, '{}'::text[], null),
('lemon', '檸檬', 'fruit', 51, '{}'::text[], null),
('grape', '葡萄', 'fruit', 52, '{}'::text[], null),
('egg_yolk', '蛋黃', 'protein', 53, array['egg']::text[], null),
('egg_white', '蛋白', 'protein', 54, array['egg']::text[], null),
('whole_egg', '全蛋', 'protein', 55, array['egg']::text[], null),
('chicken_breast', '雞胸肉', 'protein', 56, '{}'::text[], null),
('chicken_thigh', '雞腿肉', 'protein', 57, '{}'::text[], null),
('pork_lean', '豬里肌肉', 'protein', 58, '{}'::text[], null),
('pork_liver', '豬肝', 'protein', 59, '{}'::text[], null),
('beef', '牛肉', 'protein', 60, '{}'::text[], null),
('duck', '鴨肉', 'protein', 61, '{}'::text[], null),
('sea_bass', '鱸魚', 'protein', 62, array['fish']::text[], null),
('salmon', '鮭魚', 'protein', 63, array['fish']::text[], null),
('tilapia', '吳郭魚', 'protein', 64, array['fish']::text[], null),
('mackerel', '鯖魚', 'protein', 65, array['fish']::text[], null),
('shrimp', '蝦', 'protein', 66, array['shellfish']::text[], null),
('crab', '螃蟹', 'protein', 67, array['shellfish']::text[], null),
('clam', '蛤蜊', 'protein', 68, array['shellfish']::text[], null),
('squid', '花枝', 'protein', 69, '{}'::text[], null),
('tofu', '豆腐', 'protein', 70, array['soy']::text[], null),
('soy_milk', '豆漿', 'protein', 71, array['soy']::text[], null),
('edamame', '毛豆', 'protein', 72, array['soy']::text[], null),
('red_beans', '紅豆', 'protein', 73, '{}'::text[], null),
('fresh_milk', '鮮奶', 'dairy', 74, array['milk']::text[], 12),
('yogurt', '優格', 'dairy', 75, array['milk']::text[], null),
('cheese', '起司', 'dairy', 76, array['milk']::text[], null),
('butter', '奶油', 'dairy', 77, array['milk']::text[], null),
('cream', '鮮奶油', 'dairy', 78, array['milk']::text[], null),
('milk_pudding', '布丁', 'dairy', 79, array['milk','egg']::text[], null),
('cottage_cheese', '茅屋起司', 'dairy', 80, array['milk']::text[], null),
('sesame_oil', '芝麻油', 'fat_nut', 81, '{}'::text[], null),
('olive_oil', '橄欖油', 'fat_nut', 82, '{}'::text[], null),
('peanut_butter', '花生醬', 'fat_nut', 83, array['peanut']::text[], null),
('whole_peanuts', '整顆花生', 'fat_nut', 84, array['peanut']::text[], 12),
('almond_butter', '杏仁醬', 'fat_nut', 85, array['tree_nut']::text[], null),
('whole_almonds', '整顆杏仁', 'fat_nut', 86, array['tree_nut']::text[], 12),
('walnuts', '核桃', 'fat_nut', 87, array['tree_nut']::text[], 12),
('cashews', '腰果', 'fat_nut', 88, array['tree_nut']::text[], 12),
('tahini', '芝麻醬', 'fat_nut', 89, '{}'::text[], null),
('sunflower_seed_butter', '葵花籽醬', 'fat_nut', 90, '{}'::text[], null),
('steamed_egg', '蒸蛋', 'tw_home', 91, array['egg']::text[], null),
('tofu_pudding', '豆花', 'tw_home', 92, array['soy']::text[], null),
('fish_soup', '魚湯', 'tw_home', 93, array['fish']::text[], null),
('braised_pork_sauce', '滷肉燥', 'tw_home', 94, array['soy']::text[], null),
('rice_noodle_soup', '米粉湯', 'tw_home', 95, '{}'::text[], null),
('radish_cake', '蘿蔔糕', 'tw_home', 96, array['shellfish']::text[], null),
('danzai_noodle', '擔仔麵', 'tw_home', 97, array['shellfish','wheat']::text[], null),
('oyster_omelet', '蚵仔煎', 'tw_home', 98, array['shellfish','egg','wheat']::text[], null),
('braised_pork_rice', '滷肉飯', 'tw_home', 99, array['soy']::text[], null),
('taiwanese_meatball', '肉圓', 'tw_home', 100, array['wheat']::text[], null),
('tempura', '甜不辣', 'tw_home', 101, array['fish','wheat']::text[], null),
('fish_ball', '魚丸', 'tw_home', 102, array['fish']::text[], null),
('century_egg', '皮蛋', 'tw_home', 103, array['egg']::text[], null),
('salted_egg', '鹹蛋', 'tw_home', 104, array['egg']::text[], null),
('three_cup_chicken', '三杯雞', 'tw_home', 105, array['soy']::text[], null),
('wonton_soup', '餛飩湯', 'tw_home', 106, array['wheat']::text[], null),
('taiwanese_congee', '鹹粥', 'tw_home', 107, '{}'::text[], null),
('scallion_pancake', '蔥油餅', 'tw_home', 108, array['wheat']::text[], null),
('honey', '蜂蜜', 'snack_drink', 109, '{}'::text[], 12),
('popsicle', '冰棒', 'snack_drink', 110, '{}'::text[], null),
('ice_cream', '冰淇淋', 'snack_drink', 111, array['milk']::text[], null),
('sponge_cake', '海綿蛋糕', 'snack_drink', 112, array['egg','wheat','milk']::text[], null),
('cookies', '餅乾', 'snack_drink', 113, array['wheat']::text[], null),
('rice_cracker', '米餅', 'snack_drink', 114, '{}'::text[], null),
('soda', '汽水', 'snack_drink', 115, '{}'::text[], null),
('fruit_juice', '果汁', 'snack_drink', 116, '{}'::text[], null),
('herbal_jelly', '仙草凍', 'snack_drink', 117, '{}'::text[], null),
('aiyu_jelly', '愛玉', 'snack_drink', 118, '{}'::text[], null),
('barley_tea', '麥仔茶', 'snack_drink', 119, array['wheat']::text[], null),
('black_tea', '紅茶', 'snack_drink', 120, '{}'::text[], null),
('mung_bean_soup', '綠豆湯', 'snack_drink', 121, '{}'::text[], null),
('red_bean_soup', '紅豆湯', 'snack_drink', 122, '{}'::text[], null);

-- ---------------------------------------------------------------------------
-- 3. child_food_records（每寶貝每食物一筆第一次記錄；軟刪＝格子回未嘗試）
-- ---------------------------------------------------------------------------
create table public.child_food_records (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  child_id uuid not null,
  food_id text not null references public.food_catalog (id),
  author_id uuid references public.profiles (id) on delete set null,
  first_tried_on date not null,
  media_id uuid,
  note text,
  reaction text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles (id) on delete set null,
  -- 複合外鍵：孩子必須屬於同一個 family（同 growth_records 既有慣例）。
  constraint child_food_records_child_same_family_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete cascade,
  -- 複合外鍵：關聯照片必須屬於同一個 family（見檔頭第 0 段 b）；on delete set null 只
  -- 清 media_id 這一欄，不動 family_id（比照 albums.cover_media_id 既有慣例，不是
  -- media_children 那種連結表的 on delete cascade——這筆飲食紀錄不因照片被刪而消失）。
  constraint child_food_records_media_same_family_fkey foreign key (family_id, media_id)
    references public.media (family_id, id) on delete set null (media_id),
  -- 備註長度上限：沿 growth_records.note 既有慣例（1–2000，btrim 後）。
  constraint child_food_records_note_length
    check (note is null or char_length(btrim(note)) between 1 and 2000),
  -- 反應（票面 F4a：喜歡／普通／不愛吃）。
  constraint child_food_records_reaction_valid
    check (reaction is null or reaction in ('liked', 'neutral', 'disliked'))
);

comment on table public.child_food_records is
  '寶貝飲食圖鑑——每寶貝每食物一筆「第一次吃到」記錄（LS-325，LS-310 F4a）：日期
  （first_tried_on，必填）／關聯照片（media_id，選填，必須同家庭）／備註／反應。權限
  模型逐字沿用 growth_records（LS-255）：INSERT／UPDATE（內容）走真正的 RLS（家庭
  成員 SELECT；owner／member INSERT，author_id 必須是自己；僅原作者 UPDATE，owner
  不在這條路徑），不是 diaries/albums/comments/children 那種 RPC-only 收斂；設計理由見
  20260913065021_growth_records.sql 檔頭第 0 段，本表不重複展開。軟刪（deleted_at／
  deleted_by）兩欄對 authenticated 沒有任何 UPDATE grant，唯一寫入路徑是
  public.delete_child_food_record()（SECURITY DEFINER）——UI 語意是「這格飲食圖鑑
  退回未嘗試（灰階）」，不是刪除歷史，且軟刪後可透過 upsert_child_food_record() 對
  同一寶貝同一食物再次新增一筆全新記錄（partial unique index 只保護「未刪」列，見
  下）。';

comment on column public.child_food_records.deleted_by is
  '軟刪這筆紀錄的人（LS-57 規則沿用，由 private.enforce_deletion_attribution()
  trigger 推導寫入，呼叫端無法指定）。規則細節見 growth_records 對同一欄位的既有
  comment（20260913065021_growth_records.sql），本表逐字沿用不重複展開。';

-- 同一寶貝同一食物最多一筆未軟刪記錄（票面規則）；同時是 upsert_child_food_record()
-- 的 ON CONFLICT 仲裁目標（見檔頭第 0 段 a），也是 list_child_food_records 依
-- child_id 等值篩選未刪列（票面「list 查詢用的 (child_id) where deleted_at is
-- null」）唯一需要的索引——leading column child_id、謂詞相同，完全涵蓋這個查詢，
-- 不需要另外一支只有 (child_id) 的 partial index（merge-review R1 informational
-- i3：原本多開的 child_food_records_child_active_idx 是重複索引，已移除）。
create unique index child_food_records_child_food_unique
  on public.child_food_records (child_id, food_id)
  where deleted_at is null;

-- FK 反向索引（65_fk_reverse_index.sql 要求）：family_id 單獨的 FK 與複合
-- (family_id, child_id) FK 共用這個非 partial 索引（leading column family_id 涵蓋
-- 前者，完整二欄涵蓋後者，同 growth_records_family_child_idx 的既有寫法）。
create index child_food_records_family_child_idx
  on public.child_food_records (family_id, child_id);
-- food_id 單獨 FK 的反向索引。
create index child_food_records_food_id_idx
  on public.child_food_records (food_id);
-- author_id 單獨 FK 的反向索引。
create index child_food_records_author_id_idx
  on public.child_food_records (author_id);
-- 複合 (family_id, media_id) FK 的反向索引。
create index child_food_records_family_media_idx
  on public.child_food_records (family_id, media_id);
-- deleted_by 單獨 FK 的反向索引。
create index child_food_records_deleted_by_idx
  on public.child_food_records (deleted_by);

alter table public.child_food_records enable row level security;

-- 讀：家庭成員（不分角色）可讀未刪的列（沿 growth_records_select）。
create policy child_food_records_select on public.child_food_records for select to authenticated
  using (
    family_id in (select private.family_ids())
    and deleted_at is null
  );

-- 新增：owner／member 皆可（viewer 不行），author_id 必須是自己（沿
-- growth_records_insert）。
create policy child_food_records_insert on public.child_food_records for insert to authenticated
  with check (
    family_id in (select private.contributor_family_ids())
    and author_id = (select auth.uid())
  );

-- 更新（內容編輯）：僅作者本人，owner 不在這條路徑（沿 growth_records_update，理由見
-- 20260913065021_growth_records.sql 檔頭第 0 段——owner 若也放進這條，會重蹈
-- diaries 當初「owner 竟能竄改別人內容」的覆轍）。這條 policy 也是
-- upsert_child_food_record() 的 ON CONFLICT DO UPDATE 分支唯一的授權面（見檔頭
-- 第 0 段 a）。沒有第四條「軟刪」policy——理由與 growth_records 完全相同（同一
-- UPDATE 命令的多條 permissive policy 用 OR 合併，加一條「owner 或作者皆可觸碰
-- deleted_at」會讓 owner 分支意外對整次 UPDATE 涉及的所有欄位放行，見
-- growth_records 檔頭第 2 段的實測教訓，這裡不重蹈）。
create policy child_food_records_update on public.child_food_records for update to authenticated
  using (
    author_id = (select auth.uid())
    and family_id in (select private.contributor_family_ids())
  )
  with check (
    author_id = (select auth.uid())
    and family_id in (select private.contributor_family_ids())
  );

-- GRANT：SELECT 整表開放（列的可見性交給 RLS）；INSERT 不開放 id／created_at／
-- updated_at／deleted_at／deleted_by（沿用預設值）；UPDATE 只開放內容欄位＋
-- updated_at（upsert_child_food_record 的 DO UPDATE 分支會把它 SET 成 now()，理由
-- 同 growth_records 對 updated_at 的既有說明：呼叫端參數列表沒有 p_updated_at 可以
-- 指定別的值）。
grant select on public.child_food_records to authenticated;

grant insert (family_id, child_id, food_id, author_id, first_tried_on, media_id, note, reaction)
  on public.child_food_records to authenticated;

grant update (first_tried_on, media_id, note, reaction, updated_at)
  on public.child_food_records to authenticated;

-- ---------------------------------------------------------------------------
-- 4. 軟刪 trigger：重用 LS-57 共用函式，CREATE OR REPLACE 加一個 CASE 分支
--    （同 growth_records 第 4 段的既有手法：只加分支，其餘邏輯逐字不變，不修改
--    20260825040000_deletion_attribution.sql／20260913065021_growth_records.sql
--    本身，append-only）。
-- ---------------------------------------------------------------------------
create or replace function private.enforce_deletion_attribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_label text;
  v_is_owner boolean;
begin
  v_label := case tg_table_name
               when 'diaries' then '這篇日記'
               when 'albums' then '這本相簿'
               when 'comments' then '這則留言'
               when 'growth_records' then '這筆成長紀錄'
               when 'child_food_records' then '這筆飲食紀錄'
               else '這筆內容'
             end;

  if new.family_id is distinct from old.family_id then
    raise exception '% 所屬的家庭不可變更（family_id 是不可變欄位，LS-57）', v_label
      using errcode = '42501';
  end if;

  if new.deleted_by is null
     and old.deleted_by is not null
     and to_jsonb(new) - 'deleted_by' = to_jsonb(old) - 'deleted_by' then
    return new;
  end if;

  if new.deleted_at is not distinct from old.deleted_at then
    return new;
  end if;

  v_uid := auth.uid();

  v_is_owner := exists (
    select 1 from public.family_members m
     where m.family_id = old.family_id and m.user_id = v_uid and m.role = 'owner'
  );

  if v_is_owner then
    if new.deleted_at is null then
      new.deleted_by := null;
    else
      new.deleted_by := v_uid;
    end if;
    return new;
  end if;

  if old.deleted_at is not null and old.deleted_by is distinct from v_uid then
    raise exception '% 已被家庭管理者移除，只有管理者能還原', v_label
      using errcode = 'LS027';
  end if;

  if new.deleted_at is null then
    new.deleted_by := null;
  elsif old.deleted_at is null then
    new.deleted_by := v_uid;
  else
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end;
$$;

create trigger child_food_records_deletion_attribution
  before update on public.child_food_records
  for each row execute function private.enforce_deletion_attribution();

-- ---------------------------------------------------------------------------
-- 5. LS044 守門：已軟刪的孩子不能再被指定為新內容（重用 LS-66/LS-121 共用函式
--    private.enforce_child_not_deleted()，只掛 BEFORE INSERT OR UPDATE——UPDATE
--    分支從不 SET child_id（GRANT 未開放，見第 3 段），這支 trigger 對 UPDATE
--    恆為 no-op，掛 insert or update 純粹跟既有表的宣告形狀一致，同 growth_records
--    第 4b 段的既有寫法）。
-- ---------------------------------------------------------------------------
create trigger child_food_records_child_not_deleted
  before insert or update on public.child_food_records
  for each row execute function private.enforce_child_not_deleted();

-- ---------------------------------------------------------------------------
-- 6. 掛上既有的兩支共用 guard trigger（LS-151／LS-179），同 growth_records 第 5 段。
-- ---------------------------------------------------------------------------
create trigger child_food_records_deletion_guard
  before insert on public.child_food_records
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger child_food_records_not_suspended
  before insert or update or delete on public.child_food_records
  for each row execute function private.enforce_not_suspended();

-- ---------------------------------------------------------------------------
-- 7. feed_items／feed_item_children 同步（票面 F5b）：statement-level trigger＋
--    transition table，沿 private.feed_sync_diaries()／feed_sync_albums()（
--    20260822120100_triggers.sql，20260902011514_diary_album_multi_child_tags.sql
--    第 7 段追加 feed_item_children 展開）既有寫法。
--
--    跟 diary_children／album_children／media_children 三個「連結表另掛一支
--    AFTER INSERT/DELETE trigger 同步 feed_item_children」的既有模式不同——
--    child_food_records 沒有連結表：`child_id` 是這張表自己的 NOT NULL 單一欄位
--    （一筆飲食紀錄恆對應一個孩子，不像日記／相簿／照片可以標 0～N 個），因此
--    feed_items／feed_item_children 兩者的維護直接收在同一支函式裡，跟著本體
--    INSERT/UPDATE/DELETE 一起處理，不需要額外的連結表與它自己的 trigger。
--
--    `occurred_at` 取 first_tried_on（date），轉 UTC 午夜的理由與 diary.entry_date
--    完全相同（見 20260822120100_triggers.sql feed_sync_diaries 的既有註解：不能
--    直接 `::timestamptz`，會吃呼叫端 session 的 TimeZone）。
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_food_records()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'food_first' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
      select n.family_id, 'food_first', n.id, (n.first_tried_on::timestamp at time zone 'utc')
        from new_rows n where n.deleted_at is null;

    -- feed_item_children：恆一列（單一孩子），沿 diary/album 還原時重新展開的既有
    -- 手法——on conflict do nothing 是防禦性（第 6 段 comment on table 的六支
    -- trigger 函式清單改成七支，理由與寫法同 LS-317 第 6 段末尾）。
    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'food_first', n.id, n.child_id, (n.first_tried_on::timestamp at time zone 'utc')
        from new_rows n where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create trigger child_food_records_feed_insert after insert on public.child_food_records
  referencing new table as new_rows
  for each statement execute function private.feed_sync_food_records();
create trigger child_food_records_feed_update after update on public.child_food_records
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.feed_sync_food_records();
create trigger child_food_records_feed_delete after delete on public.child_food_records
  referencing old table as old_rows
  for each statement execute function private.feed_sync_food_records();

-- feed_item_children 表註解：維護的 trigger 函式清單從六支變七支（LS-317 末尾把
-- 20260902011514_diary_album_multi_child_tags.sql:140-141 的原文（那支是既有
-- migration，immutable gate 不能改）用 comment on table 訂正過一次，這裡延續同一
-- 個訂正手法，不是回頭改舊 migration）。
comment on table public.feed_item_children is
  'get_family_timeline 篩 child 用的扁平查詢表（LS-121）：一個時間軸項目標記 N 個孩子
  就有 N 列，每列 (kind, ref_id, child_id) 各自可以被等值篩選、走
  feed_item_children_family_child_occurred_idx 做 keyset 分頁——不篩 child 的查詢
  完全不碰這張表，走 feed_items 本身（一個項目一列，天然不重複）。完全由
  private.feed_sync_diary_children() / private.feed_sync_album_children() /
  private.feed_sync_diaries() / private.feed_sync_albums() /
  private.feed_sync_media_children() / private.feed_sync_media() /
  private.feed_sync_food_records()（LS-325 起，最後一支）七支 trigger 函式維護，
  authenticated 沒有任何寫入 grant。';

-- ---------------------------------------------------------------------------
-- 8. RPC
-- ---------------------------------------------------------------------------

-- list_child_food_records：依 child_id 列出未刪的飲食紀錄，依 sort_order 併 food_catalog
-- 排序留給呼叫端（iOS 依 food_catalog 的 category／sort_order 排版，這支只回傳
-- child_food_records 原始列，不 join food_catalog——同 list_growth_records「回傳整列，
-- 排序/呈現邏輯留給呼叫端」的既有精神）。不分頁：食物目錄約 120 種上限，單一家庭單一
-- 孩子的「已嘗試」列數天花板就是 food_catalog 的總列數，遠低於需要 keyset 分頁的量級
-- （對比 growth_records／comments 那種隨時間無上限增長的列表，這裡沒有同樣的理由）。
-- security invoker（同 list_growth_records 既有慣例）：完全依賴 child_food_records_select
-- RLS（family 成員＋未刪），呼叫端傳一個自己不屬於的 p_child_id 不會報錯，只會回傳 0 列。
create or replace function public.list_child_food_records(p_child_id uuid)
returns setof public.child_food_records
language sql
stable
set search_path = ''
as $$
  select r.*
    from public.child_food_records r
   where r.child_id = p_child_id
     and r.deleted_at is null
   order by r.first_tried_on desc, r.id desc;
$$;

revoke execute on function public.list_child_food_records(uuid) from public, anon;
grant execute on function public.list_child_food_records(uuid) to authenticated;

-- upsert_child_food_record：自然鍵 upsert（同寶貝同食物已有未刪紀錄→更新該筆，僅
-- 作者可；否則新增），設計取捨見檔頭第 0 段 a。security invoker：完全依賴
-- child_food_records_insert／_update 兩條真 RLS，函式本體不做任何手動授權判斷。
--
-- 新增分支：p_child_id 對應的 family_id 用一句 SELECT 解出（同 upsert_growth_record
-- 既有寫法）；p_child_id 不存在或指向呼叫者不屬於的家庭時，family_id 解析為 NULL，
-- INSERT 撞 child_food_records_insert 的 WITH CHECK（NULL in (...) 求值為非 TRUE）
-- 得到 42501（本機實測結果，同 upsert_growth_record 的既有記載，不是猜測）。
-- p_food_id 不存在於 food_catalog 撞 23503（一般外鍵違反，不特別處理——food_catalog
-- 是固定清單，iOS 呼叫端的候選值只會來自這張表本身，不存在的 food_id 屬於呼叫端
-- 組錯參數，同 upsert_growth_record 對「一般 Postgres 錯誤碼，不逐碼開自訂碼」的
-- 既有裁量）。p_child_id 指向已軟刪的孩子撞 LS044（第 5 段 trigger）——這支 trigger
-- 掛 BEFORE INSERT/UPDATE，但 `INSERT ... ON CONFLICT DO UPDATE` 的 BEFORE INSERT
-- 對「提議列」求值，不論最後有沒有撞到衝突都會觸發：這次呼叫落地成新增，或撞
-- 衝突轉成更新既有紀錄，只要目前傳入的 p_child_id 對應孩子已軟刪，兩種分支都會
-- 撞（跟 growth_records 用 p_id 分支的純 UPDATE 陳述式不同，那裡不會重新觸發
-- BEFORE INSERT，見該函式既有記載；merge-review R1 m1 登記）。
create or replace function public.upsert_child_food_record(
  p_child_id uuid,
  p_food_id text,
  p_first_tried_on date,
  p_media_id uuid,
  p_note text,
  p_reaction text
)
returns public.child_food_records
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_family uuid;
  v_row public.child_food_records%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法記錄飲食圖鑑' using errcode = '42501';
  end if;

  select c.family_id into v_family from public.children c where c.id = p_child_id;

  insert into public.child_food_records
    (family_id, child_id, food_id, author_id, first_tried_on, media_id, note, reaction)
  values
    (v_family, p_child_id, p_food_id, v_uid, p_first_tried_on, p_media_id, p_note, p_reaction)
  on conflict (child_id, food_id) where deleted_at is null
  do update set
    first_tried_on = excluded.first_tried_on,
    media_id = excluded.media_id,
    note = excluded.note,
    reaction = excluded.reaction,
    updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke execute on function
  public.upsert_child_food_record(uuid, text, date, uuid, text, text)
  from public, anon;
grant execute on function
  public.upsert_child_food_record(uuid, text, date, uuid, text, text)
  to authenticated;

-- delete_child_food_record：軟刪，作者本人（且仍是該家庭成員）或該家庭 owner——
-- 邏輯逐字沿用 delete_growth_record（理由見該函式與檔頭第 0 段），UI 語意是
-- 「這格圖鑑退回未嘗試」。必須是 SECURITY DEFINER：deleted_at／deleted_by 對
-- authenticated 沒有任何 UPDATE grant（第 3 段），且「owner 可移除他人紀錄」無法
-- 只靠 author-scoped 的 child_food_records_update 表達。FOR UPDATE 鎖住目標列
-- 再讀 family_id／author_id 做授權判斷（LS-52 既定規則，防 TOCTOU）。
create or replace function public.delete_child_food_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_rec public.child_food_records%rowtype;
  v_is_owner boolean;
  v_is_current_member boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除飲食紀錄' using errcode = '42501';
  end if;

  select r.* into v_rec from public.child_food_records r where r.id = p_id for update;

  if not found then
    raise exception '找不到這筆飲食紀錄' using errcode = '42501';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_rec.family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_rec.family_id and m.user_id = v_uid
  ) into v_is_current_member;

  if not v_is_owner
     and (v_rec.author_id is distinct from v_uid or not v_is_current_member) then
    raise exception '只有作者本人（且仍是該家庭成員）或該家庭的 owner 能移除這筆飲食紀錄'
      using errcode = '42501';
  end if;

  update public.child_food_records r set deleted_at = now() where r.id = p_id;
end;
$$;

revoke execute on function public.delete_child_food_record(uuid) from public, anon;
grant execute on function public.delete_child_food_record(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8b. private.feed_item_actor_id()：CREATE OR REPLACE 加 food_first 分支
--
-- 本機實測抓到的第二個「既有函式對新 kind 沒有 ELSE／分支」漏洞（第一個是 9. 段
-- comment_count 的轉型，見下）：`20260903091317_report_block_rpc.sql` 定義的這支
-- 函式用的是 **PL/pgSQL CASE 陳述式**（`case p_kind when ... end case;`），不是
-- CASE 運算式（`get_family_timeline` 的 `child_ids`／`taken_at` 用的是後者，運算式
-- 沒有命中的分支求值為 NULL，不報錯）——陳述式沒有命中任何 WHEN、又沒有 ELSE 分支
-- 時，PL/pgSQL 直接拋 `CASE_NOT_FOUND` 例外，不是「回傳 NULL」。這支函式被
-- `get_family_timeline` 的 `v_has_blocks` 為真時的四個分支（呼叫者在該家庭封鎖過
-- 任何人）拿來對 `feed_items` **每一列**求值（`NOT EXISTS (... bp.blocked_id =
-- private.feed_item_actor_id(f.kind, f.ref_id) ...)`）——本機 `supabase db reset`
-- 實測：只要呼叫者在該家庭封鎖過任何人，時間軸裡只要混進一筆 `food_first` 項目，
-- 呼叫就會直接撞 `CASE_NOT_FOUND`（`supabase/tests/117_food_encyclopedia.sql` §6
-- 已把這個情境釘成回歸測試，不是憑空假設）。
--
-- 修法：`food_first` 的「actor」取 `child_food_records.author_id`（記錄這筆飲食
-- 紀錄的人，跟 diary 的 `author_id`／album 的 `created_by`／media 的 `uploaded_by`
-- 是同一種「誰做了這個動作」的概念）——被封鎖者記錄的飲食紀錄，時間軸上一樣要被
-- 過濾掉，跟其餘三種 kind 待遇一致。`CREATE OR REPLACE`：函式簽章、回傳型別、
-- 其餘三個既有分支皆逐字不變，只加這一個 `when` 分支——不修改
-- `20260903091317_report_block_rpc.sql` 本身（immutable gate，append-only）。
-- ---------------------------------------------------------------------------
create or replace function private.feed_item_actor_id(
  p_kind public.feed_kind,
  p_ref_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
begin
  case p_kind
    when 'album' then select a.created_by into v_actor from public.albums a where a.id = p_ref_id;
    when 'diary' then select d.author_id into v_actor from public.diaries d where d.id = p_ref_id;
    when 'media' then select m.uploaded_by into v_actor from public.media m where m.id = p_ref_id;
    when 'food_first' then select cfr.author_id into v_actor from public.child_food_records cfr where cfr.id = p_ref_id;
  end case;
  return v_actor;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. get_family_timeline：CREATE OR REPLACE 加 food_first 分支（票面「與 p_child_id
--    篩選支援此 kind」）。**只加分支，其餘逐字保留，含既有註解**（LS-317 R1 m3 的
--    教訓——見本票派工單「必讀」段）。OUT 參數型別完全不變，不需要 DROP FUNCTION；
--    參數簽章不變（get_family_timeline(uuid, uuid, timestamptz, uuid, integer)），
--    docs/API.md §9 機械對帳清單的 RPC 簽章那一行不用改。
--
-- 兩處變動（八個 return query 分支各自套用，逐字相同）：
--   a) child_ids CASE 加一個 `when 'food_first' then (...)` 分支——恆為單一孩子
--      （child_food_records.child_id 是 NOT NULL 單一欄位，不是連結表），直接包成
--      單元素陣列，不需要像 diary/album/media 那樣 join 連結表＋array_agg。
--   b) comment_count 子查詢的 `cm.target_type = (p.kind::text)::public.content_
--      target_type` 這一行改用 CASE 短路 food_first——`public.content_target_type`
--      （`album`／`media`／`diary`／`comment`／`family`）不含 `food_first`（本票不
--      擴充 comments／reactions 的 target_type，票面「不做」段明訂，卡片互動留給
--      日後的票），若不改這一行，任何一頁時間軸只要出現一筆 food_first 項目，這句
--      轉型就會對該列撞 22P02（invalid_text_representation）、讓整支 RPC 呼叫直接
--      失敗——不是「food_first 那一列的 comment_count 算錯」這種局部問題，是**整個
--      呼叫**（該頁全部列，不分 kind）都拿不到結果。這不是假設性風險，但會不會撞到
--      取決於 planner 評估 filter 的順序，不是「只要混進一筆就必定撞」：fixture
--      資料量下 comments 從不指向 food_first，target_type 這句轉型排在 Filter 最
--      後一條，天生評估不到；只要有一列留言讓 family_id／target_id 兩個較便宜的
--      條件對 food_first 列成立，轉型就一定會被求值、撞上這個錯誤——
--      `supabase/tests/117_food_encyclopedia.sql` §8 已放一筆這樣的留言把情境釘成
--      回歸測試（merge-review R1 M1；原註解寫「必定」與引用「§6」皆與實測不符，已
--      訂正為 §8 並補上前提）。CASE 短路讓 food_first 這個
--      分支永遠不求值到右邊的轉型（Postgres 只評估 CASE 命中的那個分支），比對
--      結果因此是 NULL（WHERE 視為不成立），comment_count 自然是 0——這也正確反映
--      「food_first 卡片目前不能被留言」的事實，不是繞過錯誤、是語意上就該是 0。
-- ---------------------------------------------------------------------------
create or replace function public.get_family_timeline(
  p_family_id uuid,
  p_child_id uuid default null,
  p_cursor_occurred_at timestamptz default null,
  p_cursor_ref_id uuid default null,
  p_limit integer default 20
)
returns table (
  kind public.feed_kind,
  ref_id uuid,
  occurred_at timestamptz,
  taken_at timestamptz,
  child_ids uuid[],
  comment_count bigint
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  -- LS-243：呼叫者在這個家庭封鎖過的所有人，一次性算成陣列（不是逐列呼叫
  -- private.blocked_pairs()）——comment_count 子查詢在下面對每一列（最多 v_limit
  -- 列）都要判斷一次作者是否被封鎖，若沿用 child_ids 那種「per-row 呼叫 SQL
  -- 函式」的寫法，v_limit 上限 100 時就是 100 次 private.blocked_pairs() 呼叫；
  -- 改成陣列後，每一列只是一個常數陣列的 in-memory 成員檢查，不再有額外函式呼叫，
  -- 見 supabase/tests/50_rls_plan_no_percall_subquery.sql 對 comment_count 的
  -- 效能回歸段落。空陣列（無封鎖）時 `= any('{}')` 恆為 false，語意與「沒有封鎖」
  -- 完全一致，不需要另外判斷是否為空。
  v_blocked_ids uuid[] := array(
    select bp.blocked_id from private.blocked_pairs() bp where bp.family_id = p_family_id
  );
  -- 一次性判斷（不是逐列）：呼叫者在這個家庭封鎖過任何人嗎？絕大多數情況是 false，
  -- 走完全未加過濾條件的原始查詢，效能不受影響（見上方說明）。沿用 v_blocked_ids
  -- 算出來的陣列，不再另外呼叫一次 private.blocked_pairs()。
  v_has_blocks boolean := coalesce(array_length(v_blocked_ids, 1), 0) > 0;
begin
  if (p_cursor_occurred_at is null) <> (p_cursor_ref_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_occurred_at／p_cursor_ref_id）'
      using errcode = 'LS022';
  end if;

  if p_child_id is null then
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    end if;
  else
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    end if;
  end if;
end;
$$;
