-- LS-339（LS-310 M8）—— 飲食圖鑑 food_catalog 擴充：蔬菜 +73／水果 +28／蛋白質 +51
-- （122 → 274），並重排這三個類別的 sort_order。
--
-- 來源：使用者要求參考全聯（小時達）、大潤發蔬果菜單盡可能豐富（三則指示，見票面
-- 「來源」段）；候選由 general-purpose agent 研究，使用者於候選過目頁裁定最終清單
-- （orchestrator comment 797552c0，`LS-339-final-additions.csv`）。
--
-- 不做的事：candidate CSV 有 `alt_names` 欄（研究建議的別名，如「鯛魚片→吳郭魚」），
-- 使用者定案時把這些「建議併為別名」的品項全部選成獨立品項（鯛魚片
-- `taiwan_tilapia_fillet`、金目鱸 `barramundi`、嫩豆腐 `silken_tofu`、牛腱
-- `beef_shank`、雞里肌 `chicken_tenderloin`）——沒有人要求搜尋別名，`food_catalog`
-- **不加 `alt_names` 欄**（Rule 2：不做沒被要求的推測性欄位）；候選 CSV 的 alt_names
-- 只是研究資料，不入庫，也不寫進 `supabase/seed-data/food_catalog.csv`（該檔欄位格式
-- 不變：id,name_zh,category,sort_order,allergens,min_age_months）。別名搜尋需求記入
-- LS-96。
--
-- `sort_order`：本表沒有唯一約束（不論全域或類內），原本 1–122 全域遞增、依 8 類
-- 各佔一段連續區間（`grain_root` 1–16、`vegetable` 17–34…）純粹是 CSV／seed 手動維護
-- 出來的慣例，不是 DB 強制的。本票延續這個「類別各佔一段連續區間、跨類不重疊」的
-- 既有慣例（不引入新的唯一約束——這是既有慣例的延伸，不是本票該決定要不要加約束）：
--   - `grain_root`（16 項，不動）：sort_order 維持 1–16。
--   - `vegetable`／`fruit`／`protein` 三類：既有列＋新增列依票面範圍 3 的規則（蔬菜
--     葉菜→花菜→瓜果茄→根莖筍→豆莢芽菜→菇→海藻→辛香；水果常見→柑橘→瓜→莓果小圓果
--     →台灣特色→熱帶進口；蛋白質蛋→禽→豬→牛羊→魚→蝦蟹貝→頭足→豆製品→乾豆→加工，
--     細節排序見研究檔 `~/little-sprout-design-masters/food-stickers/research/
--     LS-339-veg-research.md` §4.4／A.5／B.7）重新分類、類內依規則排序，整段重編為
--     17–225（vegetable 17–107、fruit 108–153、protein 154–225）。
--   - `dairy`／`fat_nut`／`tw_home`／`snack_drink`（4 類，共 49 項，內容與相對順序
--     完全不動）：因為前面 vegetable／fruit／protein 三類合計多出 152 項（73+28+51），
--     這 4 類原本緊接在 protein 之後的區間（74–122）整段平移 +152（226–274），保持
--     「各類一段連續區間、依原有類別順序排列」不變——這是票面「其餘類別維持不變或
--     一起平移，並說明理由」的後者：不平移的話 74–122 會跟新的 vegetable/fruit/protein
--     區間（17–225）重疊。
--
-- Idempotency：沿用 `20260918205141_food_encyclopedia.sql` 第 2 段既有 seed 慣例——
-- 純 `insert`，不用 `on conflict do nothing`。理由：Supabase 的 migration 是
-- append-only 帳本，由 `supabase_migrations.schema_migrations` 保證每支檔案對每個
-- 環境只套用一次，不是「可重複執行的腳本」；若真的被誤重跑（例如手動對已套用過的
-- DB 再跑一次這支檔），`id` 的 primary key 會讓它直接噴 `23505` fail loud，而不是
-- 靜默吞掉——這與原本 122 項 seed 的既有選擇一致（fail loudly，非 idempotent 的
-- ON CONFLICT 寫法）。
--
-- 內容來源：`supabase/seed-data/food_catalog.csv`（已合併新舊 274 列，仍是唯一的
-- 人類可讀來源），下面第 1 段是拿掉既有 122 列後的純新增部分，由
-- `scripts/ops/food-catalog-sql.py insert --only-new <舊版 CSV>` 產生（本票新增的
-- 用法，見該腳本檔頭）；第 2 段是既有列的 sort_order 調整。CSV↔DB 全表一致性（含
-- sort_order／allergens，累加多支 migration 後的最終狀態）由
-- `supabase/tests/run.sh`／`scripts/ops/food-catalog-sql.py check` 驗證，理由同
-- `20260918205141_food_encyclopedia.sql` 檔頭 0-c 段，這裡不重複展開。

-- ---------------------------------------------------------------------------
-- 1. 新增 152 列（蔬菜 73／水果 28／蛋白質 51）
-- ---------------------------------------------------------------------------
insert into public.food_catalog (id, name_zh, category, sort_order, allergens, min_age_months)
values
('small_pak_choi', '小白菜', 'vegetable', 21, '{}'::text[], null),
('sweet_potato_leaves', '地瓜葉', 'vegetable', 23, '{}'::text[], null),
('a_choy', 'A菜', 'vegetable', 24, '{}'::text[], null),
('fushan_lettuce', '大陸妹', 'vegetable', 25, '{}'::text[], null),
('amaranth_greens', '莧菜', 'vegetable', 27, '{}'::text[], null),
('rape_greens', '油菜', 'vegetable', 28, '{}'::text[], null),
('kai_lan', '芥藍', 'vegetable', 29, '{}'::text[], null),
('komatsuna', '小松菜', 'vegetable', 30, '{}'::text[], null),
('mustard_greens', '芥菜', 'vegetable', 31, '{}'::text[], null),
('garland_chrysanthemum', '茼蒿', 'vegetable', 32, '{}'::text[], null),
('baby_napa_cabbage', '娃娃菜', 'vegetable', 33, '{}'::text[], null),
('cream_bok_choy', '奶油白菜', 'vegetable', 34, '{}'::text[], null),
('kale', '羽衣甘藍', 'vegetable', 35, '{}'::text[], null),
('mountain_spinach', '山菠菜', 'vegetable', 36, '{}'::text[], null),
('chinese_celery', '芹菜', 'vegetable', 37, '{}'::text[], null),
('western_celery', '西洋芹', 'vegetable', 38, '{}'::text[], null),
('chayote_shoots', '龍鬚菜', 'vegetable', 39, '{}'::text[], null),
('madeira_vine', '川七', 'vegetable', 40, '{}'::text[], null),
('malabar_spinach', '皇宮菜', 'vegetable', 41, '{}'::text[], null),
('gynura', '紅鳳菜', 'vegetable', 42, '{}'::text[], null),
('water_snowflake', '水蓮', 'vegetable', 43, '{}'::text[], null),
('birds_nest_fern', '山蘇', 'vegetable', 44, '{}'::text[], null),
('vegetable_fern', '過貓', 'vegetable', 45, '{}'::text[], null),
('large_cucumber', '大黃瓜', 'vegetable', 50, '{}'::text[], null),
('winter_melon', '冬瓜', 'vegetable', 53, '{}'::text[], null),
('bottle_gourd', '瓠瓜', 'vegetable', 54, '{}'::text[], null),
('chayote', '佛手瓜', 'vegetable', 55, '{}'::text[], null),
('zucchini', '櫛瓜', 'vegetable', 56, '{}'::text[], null),
('green_bell_pepper', '青椒', 'vegetable', 58, '{}'::text[], null),
('sweet_bell_pepper', '甜椒', 'vegetable', 59, '{}'::text[], null),
('okra', '秋葵', 'vegetable', 60, '{}'::text[], null),
('baby_corn', '玉米筍', 'vegetable', 61, '{}'::text[], null),
('onion', '洋蔥', 'vegetable', 64, '{}'::text[], null),
('kohlrabi', '大頭菜', 'vegetable', 65, '{}'::text[], null),
('beetroot', '甜菜根', 'vegetable', 66, '{}'::text[], null),
('burdock', '牛蒡', 'vegetable', 67, '{}'::text[], null),
('lotus_root', '蓮藕', 'vegetable', 68, '{}'::text[], null),
('bamboo_shoot', '竹筍', 'vegetable', 69, '{}'::text[], null),
('water_bamboo', '茭白筍', 'vegetable', 70, '{}'::text[], null),
('asparagus', '蘆筍', 'vegetable', 71, '{}'::text[], null),
('water_chestnut', '荸薺', 'vegetable', 72, '{}'::text[], null),
('water_caltrop', '菱角', 'vegetable', 73, '{}'::text[], null),
('jicama', '豆薯', 'vegetable', 74, '{}'::text[], null),
('sugar_snap_pea', '甜豆', 'vegetable', 77, '{}'::text[], null),
('snow_pea', '荷蘭豆', 'vegetable', 78, '{}'::text[], null),
('yardlong_bean', '長豆', 'vegetable', 79, '{}'::text[], null),
('mung_bean_sprouts', '綠豆芽', 'vegetable', 80, '{}'::text[], null),
('soybean_sprouts', '黃豆芽', 'vegetable', 81, array['soy']::text[], null),
('pea_shoots', '豌豆苗', 'vegetable', 82, '{}'::text[], null),
('alfalfa_sprouts', '苜蓿芽', 'vegetable', 83, '{}'::text[], null),
('enoki_mushroom', '金針菇', 'vegetable', 85, '{}'::text[], null),
('king_oyster_mushroom', '杏鮑菇', 'vegetable', 86, '{}'::text[], null),
('brown_shimeji', '鴻喜菇', 'vegetable', 87, '{}'::text[], null),
('white_shimeji', '雪白菇', 'vegetable', 88, '{}'::text[], null),
('oyster_mushroom', '秀珍菇', 'vegetable', 89, '{}'::text[], null),
('button_mushroom', '洋菇', 'vegetable', 90, '{}'::text[], null),
('black_fungus', '黑木耳', 'vegetable', 91, '{}'::text[], null),
('white_fungus', '白木耳', 'vegetable', 92, '{}'::text[], null),
('maitake', '舞菇', 'vegetable', 93, '{}'::text[], null),
('coral_mushroom', '珊瑚菇', 'vegetable', 94, '{}'::text[], null),
('black_oyster_mushroom', '黑蠔菇', 'vegetable', 95, '{}'::text[], null),
('white_elf_mushroom', '白精靈菇', 'vegetable', 96, '{}'::text[], null),
('portobello', '波特貝勒菇', 'vegetable', 97, '{}'::text[], null),
('kelp', '海帶', 'vegetable', 98, '{}'::text[], null),
('nori', '紫菜', 'vegetable', 99, '{}'::text[], null),
('green_onion', '青蔥', 'vegetable', 100, '{}'::text[], null),
('garlic', '大蒜', 'vegetable', 101, '{}'::text[], null),
('garlic_sprouts', '蒜苗', 'vegetable', 102, '{}'::text[], null),
('chinese_chives', '韭菜', 'vegetable', 103, '{}'::text[], null),
('ginger', '薑', 'vegetable', 104, '{}'::text[], null),
('cilantro', '香菜', 'vegetable', 105, '{}'::text[], null),
('thai_basil', '九層塔', 'vegetable', 106, '{}'::text[], null),
('shallot', '紅蔥頭', 'vegetable', 107, '{}'::text[], null),
('liucheng_orange', '柳橙', 'fruit', 116, '{}'::text[], null),
('grapefruit', '葡萄柚', 'fruit', 117, '{}'::text[], null),
('pomelo', '文旦', 'fruit', 118, '{}'::text[], null),
('kumquat', '金桔', 'fruit', 119, '{}'::text[], null),
('oriental_melon', '香瓜', 'fruit', 123, '{}'::text[], null),
('blueberry', '藍莓', 'fruit', 126, '{}'::text[], null),
('cherry', '櫻桃', 'fruit', 127, '{}'::text[], null),
('cherry_tomato', '小番茄', 'fruit', 128, '{}'::text[], null),
('raspberry', '覆盆莓', 'fruit', 129, '{}'::text[], null),
('mulberry', '桑椹', 'fruit', 130, '{}'::text[], null),
('wax_apple', '蓮霧', 'fruit', 131, '{}'::text[], null),
('sugar_apple', '釋迦', 'fruit', 132, '{}'::text[], null),
('lychee', '荔枝', 'fruit', 133, '{}'::text[], null),
('longan', '龍眼', 'fruit', 134, '{}'::text[], null),
('loquat', '枇杷', 'fruit', 135, '{}'::text[], null),
('starfruit', '楊桃', 'fruit', 136, '{}'::text[], null),
('passion_fruit', '百香果', 'fruit', 137, '{}'::text[], null),
('jujube', '蜜棗', 'fruit', 138, '{}'::text[], null),
('plum', '李子', 'fruit', 139, '{}'::text[], null),
('coconut', '椰子', 'fruit', 145, '{}'::text[], null),
('durian', '榴槤', 'fruit', 146, '{}'::text[], null),
('mangosteen', '山竹', 'fruit', 147, '{}'::text[], null),
('rambutan', '紅毛丹', 'fruit', 148, '{}'::text[], null),
('pomegranate', '石榴', 'fruit', 149, '{}'::text[], null),
('western_pear', '西洋梨', 'fruit', 150, '{}'::text[], null),
('sugarcane', '甘蔗', 'fruit', 151, '{}'::text[], null),
('jackfruit', '波羅蜜', 'fruit', 152, '{}'::text[], null),
('olive', '橄欖', 'fruit', 153, '{}'::text[], null),
('quail_egg', '鵪鶉蛋', 'protein', 157, array['egg']::text[], null),
('chicken_wing', '雞翅', 'protein', 160, '{}'::text[], null),
('chicken_tenderloin', '雞里肌', 'protein', 161, '{}'::text[], null),
('chicken_mince', '雞絞肉', 'protein', 162, '{}'::text[], null),
('chicken_gizzard', '雞胗', 'protein', 163, '{}'::text[], null),
('pork_mince', '豬絞肉', 'protein', 167, '{}'::text[], null),
('pork_belly', '豬五花', 'protein', 168, '{}'::text[], null),
('pork_shoulder', '豬梅花肉', 'protein', 169, '{}'::text[], null),
('pork_ribs', '排骨', 'protein', 170, '{}'::text[], null),
('pork_knuckle', '豬腳', 'protein', 171, '{}'::text[], null),
('beef_shank', '牛腱', 'protein', 173, '{}'::text[], null),
('beef_mince', '牛絞肉', 'protein', 174, '{}'::text[], null),
('lamb', '羊肉', 'protein', 175, '{}'::text[], null),
('taiwan_tilapia_fillet', '鯛魚片', 'protein', 178, array['fish']::text[], null),
('barramundi', '金目鱸', 'protein', 179, array['fish']::text[], null),
('milkfish', '虱目魚', 'protein', 180, array['fish']::text[], null),
('grouper', '石斑魚', 'protein', 181, array['fish']::text[], null),
('threadfin', '午仔魚', 'protein', 182, array['fish']::text[], null),
('pomfret', '鯧魚', 'protein', 183, array['fish']::text[], null),
('yellow_croaker', '黃魚', 'protein', 184, array['fish']::text[], null),
('cod', '鱈魚', 'protein', 185, array['fish']::text[], null),
('hairtail', '白帶魚', 'protein', 186, array['fish']::text[], null),
('saury', '秋刀魚', 'protein', 189, array['fish']::text[], null),
('spanish_mackerel', '土魠魚', 'protein', 190, array['fish']::text[], null),
('horse_mackerel', '竹筴魚', 'protein', 191, array['fish']::text[], null),
('golden_threadfin_bream', '金線魚', 'protein', 192, array['fish']::text[], null),
('sweetfish', '香魚', 'protein', 193, array['fish']::text[], null),
('tuna', '鮪魚', 'protein', 194, array['fish']::text[], null),
('swordfish', '旗魚', 'protein', 195, array['fish']::text[], null),
('eel', '鰻魚', 'protein', 196, array['fish']::text[], null),
('trout', '鱒魚', 'protein', 197, array['fish']::text[], null),
('whitebait', '魩仔魚', 'protein', 198, array['fish']::text[], null),
('fish_roe', '魚卵', 'protein', 199, array['fish']::text[], null),
('oyster', '牡蠣', 'protein', 203, array['shellfish']::text[], null),
('scallop', '干貝', 'protein', 204, array['shellfish']::text[], null),
('abalone', '九孔', 'protein', 205, array['shellfish']::text[], null),
('lobster', '龍蝦', 'protein', 206, array['shellfish']::text[], null),
('neritic_squid', '透抽', 'protein', 208, '{}'::text[], null),
('flying_squid', '魷魚', 'protein', 209, '{}'::text[], null),
('octopus', '章魚', 'protein', 210, '{}'::text[], null),
('silken_tofu', '嫩豆腐', 'protein', 212, array['soy']::text[], null),
('egg_tofu', '雞蛋豆腐', 'protein', 213, array['soy','egg']::text[], null),
('dried_tofu', '豆干', 'protein', 214, array['soy']::text[], null),
('tofu_skin', '豆皮', 'protein', 215, array['soy']::text[], null),
('natto', '納豆', 'protein', 216, array['soy']::text[], null),
('soybean', '黃豆', 'protein', 220, array['soy']::text[], null),
('black_soybean', '黑豆', 'protein', 221, array['soy']::text[], null),
('mung_bean', '綠豆', 'protein', 222, '{}'::text[], null),
('chickpea', '鷹嘴豆', 'protein', 223, '{}'::text[], null),
('pork_floss', '肉鬆', 'protein', 224, '{}'::text[], null),
('fish_floss', '魚鬆', 'protein', 225, array['fish']::text[], null);

-- ---------------------------------------------------------------------------
-- 2. 既有 105 列的 sort_order 調整（`spinach` 剛好新舊值都是 17，不出現在下面清單；
--    `grain_root` 16 列完全不動，`dairy`／`fat_nut`／`tw_home`／`snack_drink` 49 列
--    的調整值＝舊值 + 152，皆包含在下表）。
-- ---------------------------------------------------------------------------
update public.food_catalog f
   set sort_order = v.sort_order
  from (values
  ('cabbage', 18),
  ('napa_cabbage', 19),
  ('bok_choy', 20),
  ('water_spinach', 22),
  ('lettuce', 26),
  ('broccoli', 46),
  ('cauliflower', 47),
  ('tomato', 48),
  ('cucumber', 49),
  ('loofah', 51),
  ('bitter_melon', 52),
  ('eggplant', 57),
  ('carrot', 62),
  ('white_radish', 63),
  ('green_bean', 75),
  ('pea', 76),
  ('mushroom', 84),
  ('banana', 108),
  ('apple', 109),
  ('papaya', 110),
  ('avocado', 111),
  ('pear', 112),
  ('peach', 113),
  ('persimmon', 114),
  ('orange', 115),
  ('lemon', 120),
  ('watermelon', 121),
  ('cantaloupe', 122),
  ('strawberry', 124),
  ('grape', 125),
  ('mango', 140),
  ('guava', 141),
  ('dragon_fruit', 142),
  ('kiwi', 143),
  ('pineapple', 144),
  ('egg_yolk', 154),
  ('egg_white', 155),
  ('whole_egg', 156),
  ('chicken_breast', 158),
  ('chicken_thigh', 159),
  ('duck', 164),
  ('pork_lean', 165),
  ('pork_liver', 166),
  ('beef', 172),
  ('sea_bass', 176),
  ('tilapia', 177),
  ('salmon', 187),
  ('mackerel', 188),
  ('shrimp', 200),
  ('crab', 201),
  ('clam', 202),
  ('squid', 207),
  ('tofu', 211),
  ('soy_milk', 217),
  ('edamame', 218),
  ('red_beans', 219),
  ('fresh_milk', 226),
  ('yogurt', 227),
  ('cheese', 228),
  ('butter', 229),
  ('cream', 230),
  ('milk_pudding', 231),
  ('cottage_cheese', 232),
  ('sesame_oil', 233),
  ('olive_oil', 234),
  ('peanut_butter', 235),
  ('whole_peanuts', 236),
  ('almond_butter', 237),
  ('whole_almonds', 238),
  ('walnuts', 239),
  ('cashews', 240),
  ('tahini', 241),
  ('sunflower_seed_butter', 242),
  ('steamed_egg', 243),
  ('tofu_pudding', 244),
  ('fish_soup', 245),
  ('braised_pork_sauce', 246),
  ('rice_noodle_soup', 247),
  ('radish_cake', 248),
  ('danzai_noodle', 249),
  ('oyster_omelet', 250),
  ('braised_pork_rice', 251),
  ('taiwanese_meatball', 252),
  ('tempura', 253),
  ('fish_ball', 254),
  ('century_egg', 255),
  ('salted_egg', 256),
  ('three_cup_chicken', 257),
  ('wonton_soup', 258),
  ('taiwanese_congee', 259),
  ('scallion_pancake', 260),
  ('honey', 261),
  ('popsicle', 262),
  ('ice_cream', 263),
  ('sponge_cake', 264),
  ('cookies', 265),
  ('rice_cracker', 266),
  ('soda', 267),
  ('fruit_juice', 268),
  ('herbal_jelly', 269),
  ('aiyu_jelly', 270),
  ('barley_tea', 271),
  ('black_tea', 272),
  ('mung_bean_soup', 273),
  ('red_bean_soup', 274)
  ) as v(id, sort_order)
 where f.id = v.id;

-- ---------------------------------------------------------------------------
-- 3. 表註解訂正：原本寫「約 120 種」（`20260918205141_food_encyclopedia.sql` 第 1 段
--    定義時的數字），本票起改成 274 種——`comment on table` 覆寫，不改既有 migration
--    本身（immutable，同本票沿用 `feed_item_children` 的既有訂正手法，見該檔第 7 段
--    末尾）。
-- ---------------------------------------------------------------------------
comment on table public.food_catalog is
  '飲食圖鑑靜態目錄（LS-325，LS-310 F1a／F2a／F3a；LS-339 起 274 種）：274 種台灣
  常見食物，8 類（`grain_root`／`vegetable`／`fruit`／`protein`／`dairy`／`fat_nut`／
  `tw_home`／`snack_drink`），`sort_order` 依類別分區間、類內依引入順序或研究排序排
  （細節見本票 migration 檔頭）。`id` 同時是 app 插圖資產名（F3a），v1 不開放自訂
  （F1a）。內容來源：`supabase/seed-data/food_catalog.csv`（人類可讀，供使用者過目），
  由 `scripts/ops/food-catalog-sql.py` 轉成 INSERT／UPDATE——兩者一致性見
  `supabase/tests/run.sh`（跑 `117_food_encyclopedia.sql` 之前 host 端動態產生執行，
  標記 §1，見該檔檔頭）。全表唯讀：`authenticated` 只有 SELECT，沒有任何寫入 grant。
  `allergens`／`min_age_months` 純資訊、附免責聲明（F2a，文案在 iOS 端呈現），不構成
  醫療建議。';
