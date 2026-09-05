-- LS-200（LS-20 後端）— album_summaries：security invoker view
--
-- 對應 20260905074037_album_summaries_view.sql 的驗收：
--   0.  schema 形狀：view 帶 security_invoker=true、grant 只開 authenticated
--   0b. 結構斷言：albums 欄位集合 ⊆ album_summaries（view 欄位於 CREATE VIEW
--       當下由 albums.* 展開凍結，之後 albums 加欄不會自動出現在這裡，見
--       migration 檔尾 comment on view 與 docs/API.md §3 的凍結說明）
--   1.  可見 1＋隱形 1 → visible_media_count=1，latest_media_id／latest_thumb_path／
--       latest_storage_path／cover_thumb_path／cover_storage_path 皆為可見那張
--       （即使被軟刪那張 created_at 更新，也不能被選中，證明過濾在排序之前生效）
--   1b. 最新可見那張沒有縮圖（縮圖產生失敗的過渡列）→ latest_thumb_path NULL，
--       但 latest_storage_path 有值——驗證 iOS 的退回規則（docs/API.md §6）在
--       view 這一層有資料可退
--   2.  全隱形 → visible_media_count=0，六個彙總欄（latest_*／cover_*）皆 NULL
--   3.  跨家庭看不到（RLS 逐使用者，security_invoker 生效）
--   4.  anon 拒（授權面 has_table_privilege ＋ 實際查詢兩種驗法，比照
--       106_eula_consent.sql 場景 4 的既有慣例）
--   5.  keyset 分頁欄位（created_at, id）仍可用——view 只是在 albums 之上疊加彙總欄，
--       不改變分頁會用到的欄位語意
--   6.  效能：50 本相簿、1200 張已連結 media（另加 5 萬列同家庭「背景雜訊」media，
--       比照 50_rls_plan_no_percall_subquery.sql 的既有規模慣例——只灌 1200 列時
--       media 表本身很小，Seq Scan 在小表上成本低，規劃器會選它，測不出「表大了
--       會怎樣」；灌到 5 萬+ 列後 EXPLAIN 才有鑑別力）查詢形狀改成 iOS 實際會送的
--       樣子（`deleted_at is null`＋keyset 游標，不只是裸 `order by ... limit`），
--       EXPLAIN 不得出現 `Seq Scan on media`／`Seq Scan on album_media`，且不得出現
--       非 hashed 的逐列 correlated `(SubPlan N)` 引用；另附「偵測器自我驗證」——
--       強制關掉 index/bitmap scan 逼出真正的 Seq Scan，證明上面的 regex 真的抓
--       得到，不是恆綠的空案
--
-- R2（merge-review R1 `37674513` major-1／major-2，comment `37674513`）修正兩類
-- 「測試假綠」，逐條記錄给之後改這個檔案的人參考，避免重踩：
--   major-1：PostgreSQL ARE（Advanced Regular Expression）的 `\b` 是退格字元
--     （backspace）的跳脫，不是像 Perl 那樣的字界——`'media\b'` 實際上要求
--     「media」後面接一個退格控制字元，EXPLAIN 文字輸出裡永遠不會有這個字元，
--     這條斷言因此恆假（regex 永遠不 match），不論 plan 裡有沒有真的出現
--     `Seq Scan on media` 都不會被抓到。PostgreSQL ARE 的字界跳脫是 `\y`
--     （`\m`／`\M` 是字首／字尾），改用 `\y` 才是真的字界。第 6 段新增「偵測器
--     自我驗證」子區塊，故意關掉 `enable_indexscan`／`enable_bitmapscan`／
--     `enable_indexonlyscan` 逼出真正的 `Seq Scan on public.media`，驗證修好的
--     regex 真的抓得到，再把設定還原——不然「改對了語法」跟「真的有鑑別力」是
--     兩件事，光看語法改對看不出來。
--   major-2：`select ... into` 在 0 列命中時不會報錯，變數維持宣告時的 NULL，
--     若後面的比較用 `<>`（或 `=`）而不是 `is distinct from`，NULL 兩側的
--     `<>`／`=` 一律得到 NULL，PL/pgSQL 的 `if NULL then` 視為 false、不會
--     raise——等於「列整個消失」與「值變成非預期的 NULL」這兩種壞掉的形狀都测
--     不出來，斷言看起來綠但保護不到任何東西。修法兩件事都要做，缺一不可：
--     ① 每個從 `album_summaries`／其他 fixture 表讀單列值的 `select ... into`
--     後面補 `if not found then raise exception ... end if;`，擋住「列消失」；
--     ② 涉及可能合法為 NULL 的欄位（`latest_*`／`cover_*` 六欄、keyset 游標）的
--     相等比較一律改用 `is distinct from`／`is not distinct from`，擋住
--     「值變成非預期的 NULL 但比較式本身也跟著失能」。`count(*)` 聚合本身
--     保證非 NULL（沒有列命中回 0，不是 NULL），沿用既有 `<>` 不受影響，不用改。
--
-- Mutation 自證（本機開發時手動驗證，非本檔自動執行，比照 60_default_privileges.sql
-- LS-84 的既有慣例；本檔第 1／1b 段的斷言本身就是這份證明的常駐版本——見各段落）：
--   (A) migration `left join public.media cm on cm.id = a.cover_media_id`
--       改成 `join`（INNER JOIN）：cover 指到使用者看不到的 media 時，整個
--       album 列會從 view 消失（不是 cover_thumb_path 變 NULL）——本檔第 2 段
--       的 fixture（cover 指到已軟刪的 media）正好命中這個形狀，`if not found`
--       會抓到；R2 已實際套用此突變重跑，見 PR handoff 的輸出記錄。
--   (B) migration `(array_agg(m.thumb_path order by ...))[1]` 的 `[1]` 改成
--       `[2]`：對只有一張可見 media 的相簿（本檔第 1 段），陣列只有一個元素，
--       `[2]` 越界回 NULL——`latest_thumb_path` 從正確的縮圖路徑變成 NULL，
--       列本身還在（`found` 仍為 true）。第 1 段改用 `is distinct from` 後
--       會抓到；R2 已實際套用此突變重跑，見 PR handoff 的輸出記錄。
--   拿掉 view 定義裡「join media」帶來的可見性過濾（直接數 album_media 連結列，
--   即 LS-165 R2 原本的 bug 形狀）：本機實測 `select count(*) from album_media
--   where album_id = <本檔第 1 段的測試相簿>` 拿到 2（兩個連結列都算進去，其中
--   一個指到已軟刪、呼叫者看不到的 media）；view 正確答案是 1。第 1 段用同一組
--   fixture 直接斷言這兩個數字不相等（而不只是斷言 visible_media_count=1），
--   拿掉 join 之後兩者會變成相等，斷言會失敗，具備鑑別力。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 0. schema 形狀：security_invoker、grant 只開 authenticated
-- ===========================================================================
do $$
declare
  v_opts text[];
begin
  select c.reloptions into v_opts
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'album_summaries';

  if not found then
    raise exception 'FAIL：public.album_summaries 不存在（pg_class 查無此列）';
  end if;
  if v_opts is null or not ('security_invoker=true' = any(v_opts)) then
    raise exception 'FAIL：public.album_summaries 沒有 security_invoker=true（reloptions=%）', v_opts;
  end if;

  if not has_table_privilege('authenticated', 'public.album_summaries', 'select') then
    raise exception 'FAIL：authenticated 應該對 album_summaries 有 SELECT';
  end if;
  if has_table_privilege('anon', 'public.album_summaries', 'select') then
    raise exception 'FAIL：anon 竟然對 album_summaries 有 SELECT';
  end if;

  raise notice 'ok：album_summaries 是 security_invoker view，authenticated 可讀、anon 不可讀';
end;
$$;

-- ===========================================================================
-- 0b. 結構斷言：albums 欄位集合 ⊆ album_summaries（R2 N3）
--
-- PostgreSQL 對 `select a.*, ...` 形式的 view，`a.*` 是在 CREATE VIEW 當下就展開
-- 成固定欄位清單、寫死進 pg_rewrite，不是查詢時動態解析——之後對 albums 下
-- ADD COLUMN，新欄位不會自動出現在這支 view 裡，除非有人用同一份 CREATE OR
-- REPLACE VIEW 文字重建。這件事不明顯、也沒有 Postgres 錯誤會提醒，只會在
-- iOS 端納悶「明明 albums 有這欄，為什麼 album_summaries 讀不到」時才發現。
-- 這裡把「albums 的每個欄位都在 album_summaries 裡」釘成機械斷言：未來有人
-- 幫 albums 加欄卻忘了重建 view，這條會直接紅，不必等人手動發現。
-- ===========================================================================
do $$
declare
  v_missing text[];
begin
  select array_agg(c.column_name order by c.column_name) into v_missing
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'albums'
     and not exists (
       select 1 from information_schema.columns v
        where v.table_schema = 'public' and v.table_name = 'album_summaries'
          and v.column_name = c.column_name
     );

  if v_missing is not null then
    raise exception
      'FAIL：albums 有欄位不在 album_summaries 裡（%）——view 欄位於 CREATE VIEW
       當下由 albums.* 展開凍結，albums 加欄後需要用同一份 CREATE OR REPLACE VIEW
       文字重建，見 migration 檔尾 comment on view 的說明', v_missing;
  end if;

  raise notice 'ok：albums 欄位集合 ⊆ album_summaries（view 欄位未凍結漏欄）';
end;
$$;

-- ===========================================================================
-- 1. 可見 1＋隱形 1 → visible_media_count=1、latest_thumb_path 為可見那張
--
-- e2 刻意設成比 e1 更晚的 created_at 且已軟刪（上傳者是 a3，查詢者是 a1，
-- a1 不是上傳者，media_select 的上傳者例外不成立）：如果過濾沒有生效，
-- 「依 created_at 挑最新一張」會選到 e2，斷言會抓到。
-- ===========================================================================
begin;

insert into public.media
  (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by,
   thumb_path, thumb_width, thumb_height, created_at)
values
  ('3a000000-0000-4000-8000-0000000000e1', 'fa000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001/2026/09/e1.jpg', 'photo', 1024,
   now() - interval '2 hours', 800, 600, 'a0000000-0000-4000-8000-000000000002',
   'fa000000-0000-4000-8000-000000000001/2026/09/e1_thumb.jpg', 200, 150, now() - interval '2 hours'),
  ('3a000000-0000-4000-8000-0000000000e2', 'fa000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001/2026/09/e2.jpg', 'photo', 1024,
   now() - interval '1 hours', 800, 600, 'a0000000-0000-4000-8000-000000000003',
   'fa000000-0000-4000-8000-000000000001/2026/09/e2_thumb.jpg', 200, 150, now() - interval '1 hours');

-- e2 軟刪（上傳者 a3 自己）——對非上傳者的 a1 而言即為「隱形」
update public.media set deleted_at = now() where id = '3a000000-0000-4000-8000-0000000000e2';

insert into public.albums (id, family_id, title, cover_media_id, created_by) values
  ('4a000000-0000-4000-8000-0000000000e1', 'fa000000-0000-4000-8000-000000000001',
   'LS-200 可見1隱形1', '3a000000-0000-4000-8000-0000000000e1', 'a0000000-0000-4000-8000-000000000001');

insert into public.album_media (album_id, media_id, family_id, sort_order) values
  ('4a000000-0000-4000-8000-0000000000e1', '3a000000-0000-4000-8000-0000000000e1',
   'fa000000-0000-4000-8000-000000000001', 0),
  ('4a000000-0000-4000-8000-0000000000e1', '3a000000-0000-4000-8000-0000000000e2',
   'fa000000-0000-4000-8000-000000000001', 1);

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_count bigint;
  v_latest_id uuid;
  v_latest text;
  v_latest_storage text;
  v_cover text;
  v_cover_storage text;
  v_link_count bigint;
  v_expected_thumb text := 'fa000000-0000-4000-8000-000000000001/2026/09/e1_thumb.jpg';
  v_expected_storage text := 'fa000000-0000-4000-8000-000000000001/2026/09/e1.jpg';
begin
  select visible_media_count, latest_media_id, latest_thumb_path, latest_storage_path,
         cover_thumb_path, cover_storage_path
    into v_count, v_latest_id, v_latest, v_latest_storage, v_cover, v_cover_storage
    from public.album_summaries
   where id = '4a000000-0000-4000-8000-0000000000e1';

  -- major-2 修法①：0 列命中時上面六個變數會維持 NULL、不會報錯（PL/pgSQL
  -- 的 select ... into 語意），沒有這句「整本相簿從 view 消失」會被下面的
  -- <> 比較悄悄放過（NULL <> 期望值 = NULL，if NULL 視為 false 不會 raise）。
  if not found then
    raise exception 'FAIL：查不到可見1隱形1 測試相簿（4a...e1）——album_summaries 裡整列消失';
  end if;

  -- major-2 修法②：以下六個比較全部改用 is distinct from——這些欄位在其他
  -- 案例合法為 NULL，用 <> 的話「期望非 NULL、實際變成 NULL」這種壞掉的形狀
  -- NULL <> 非NULL 得到 NULL，一樣會被 if NULL 悄悄放過。
  if v_count is distinct from 1 then
    raise exception 'FAIL：可見1隱形1 相簿的 visible_media_count 應為 1，實際 %', v_count;
  end if;
  if v_latest_id is distinct from '3a000000-0000-4000-8000-0000000000e1'::uuid then
    raise exception 'FAIL：latest_media_id 應為可見那張（e1），實際 %', v_latest_id;
  end if;
  if v_latest is distinct from v_expected_thumb then
    raise exception 'FAIL：latest_thumb_path 應為可見那張（e1），實際 %（若選到 e2 表示軟刪過濾沒生效）', v_latest;
  end if;
  if v_latest_storage is distinct from v_expected_storage then
    raise exception 'FAIL：latest_storage_path 應為可見那張（e1）的原圖路徑，實際 %', v_latest_storage;
  end if;
  if v_cover is distinct from v_expected_thumb then
    raise exception 'FAIL：cover_thumb_path 應為 e1 的縮圖，實際 %', v_cover;
  end if;
  if v_cover_storage is distinct from v_expected_storage then
    raise exception 'FAIL：cover_storage_path 應為 e1 的原圖路徑，實際 %', v_cover_storage;
  end if;

  -- mutation 鑑別力自證（常駐版）：拿掉 join media 的可見過濾、只數連結列，
  -- 會把已軟刪那筆也算進去（=2），跟正確答案（=1）不相等——拿掉那個 join
  -- 之後這條斷言會失敗，證明它真的在保護這件事，不是恆真句。
  select count(*) into v_link_count from public.album_media
   where album_id = '4a000000-0000-4000-8000-0000000000e1';
  if v_link_count = v_count then
    raise exception
      'FAIL：本案例的 fixture 失去鑑別力——連結列數（%）不該等於 visible_media_count（%），
       否則拿掉 media 過濾也測不出差異', v_link_count, v_count;
  end if;

  raise notice
    'ok：可見1隱形1 → visible_media_count=1（連結列實際 %，證明有濾掉軟刪那筆）、latest/cover 六欄皆為可見那張（e1）',
    v_link_count;
end;
$$;

reset role;
rollback;

-- ===========================================================================
-- 1b. 最新可見那張沒有縮圖（縮圖產生失敗／既有過渡列）→ latest_thumb_path NULL，
-- 但 latest_storage_path 有值（R2 N2）
--
-- e7 是本相簿唯一連結、可見的 media，thumb_path／thumb_width／thumb_height 皆
-- 留空（media_thumb_dimensions_consistency 允許三欄同為 NULL，見
-- 20260902101842_media_thumb_path.sql）。驗證 view 在這種過渡狀態下仍然把
-- storage_path 遞出去，讓 iOS 端能落實 docs/API.md §6 的退回規則
-- （thumb_path 為 NULL 時退回 storage_path 簽名 URL），不會兩個路徑都拿不到。
-- ===========================================================================
begin;

insert into public.media
  (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
values
  ('3a000000-0000-4000-8000-0000000000e7', 'fa000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001/2026/09/e7.jpg', 'photo', 1024,
   now() - interval '30 minutes', 800, 600, 'a0000000-0000-4000-8000-000000000001',
   now() - interval '30 minutes');

insert into public.albums (id, family_id, title, cover_media_id, created_by) values
  ('4a000000-0000-4000-8000-0000000000e7', 'fa000000-0000-4000-8000-000000000001',
   'LS-200 最新無縮圖', '3a000000-0000-4000-8000-0000000000e7', 'a0000000-0000-4000-8000-000000000001');

insert into public.album_media (album_id, media_id, family_id, sort_order) values
  ('4a000000-0000-4000-8000-0000000000e7', '3a000000-0000-4000-8000-0000000000e7',
   'fa000000-0000-4000-8000-000000000001', 0);

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_count bigint;
  v_latest_id uuid;
  v_latest text;
  v_latest_storage text;
  v_cover text;
  v_cover_storage text;
begin
  select visible_media_count, latest_media_id, latest_thumb_path, latest_storage_path,
         cover_thumb_path, cover_storage_path
    into v_count, v_latest_id, v_latest, v_latest_storage, v_cover, v_cover_storage
    from public.album_summaries
   where id = '4a000000-0000-4000-8000-0000000000e7';

  if not found then
    raise exception 'FAIL：查不到「最新無縮圖」測試相簿（4a...e7）';
  end if;

  if v_count is distinct from 1 then
    raise exception 'FAIL：「最新無縮圖」相簿的 visible_media_count 應為 1，實際 %', v_count;
  end if;
  if v_latest_id is distinct from '3a000000-0000-4000-8000-0000000000e7'::uuid then
    raise exception 'FAIL：latest_media_id 應為 e7，實際 %', v_latest_id;
  end if;
  if v_latest is not null then
    raise exception 'FAIL：e7 沒有縮圖，latest_thumb_path 應為 NULL，實際 %', v_latest;
  end if;
  if v_latest_storage is distinct from 'fa000000-0000-4000-8000-000000000001/2026/09/e7.jpg' then
    raise exception 'FAIL：latest_storage_path 應為 e7 的原圖路徑（縮圖缺席時的退回來源），實際 %', v_latest_storage;
  end if;
  if v_cover is not null then
    raise exception 'FAIL：cover 同樣是 e7，沒有縮圖，cover_thumb_path 應為 NULL，實際 %', v_cover;
  end if;
  if v_cover_storage is distinct from 'fa000000-0000-4000-8000-000000000001/2026/09/e7.jpg' then
    raise exception 'FAIL：cover_storage_path 應為 e7 的原圖路徑，實際 %', v_cover_storage;
  end if;

  raise notice 'ok：最新可見那張無縮圖 → latest_thumb_path／cover_thumb_path 皆 NULL，但 *_storage_path 皆有值可退回';
end;
$$;

reset role;
rollback;

-- ===========================================================================
-- 2. 全隱形 → visible_media_count=0、latest_thumb_path／cover_thumb_path 皆 NULL
-- ===========================================================================
begin;

insert into public.media
  (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by,
   thumb_path, thumb_width, thumb_height, created_at)
values
  ('3a000000-0000-4000-8000-0000000000e3', 'fa000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001/2026/09/e3.jpg', 'photo', 1024,
   now() - interval '1 hours', 800, 600, 'a0000000-0000-4000-8000-000000000002',
   'fa000000-0000-4000-8000-000000000001/2026/09/e3_thumb.jpg', 200, 150, now() - interval '1 hours');

update public.media set deleted_at = now() where id = '3a000000-0000-4000-8000-0000000000e3';

insert into public.albums (id, family_id, title, cover_media_id, created_by) values
  ('4a000000-0000-4000-8000-0000000000e2', 'fa000000-0000-4000-8000-000000000001',
   'LS-200 全隱形', '3a000000-0000-4000-8000-0000000000e3', 'a0000000-0000-4000-8000-000000000001');

insert into public.album_media (album_id, media_id, family_id, sort_order) values
  ('4a000000-0000-4000-8000-0000000000e2', '3a000000-0000-4000-8000-0000000000e3',
   'fa000000-0000-4000-8000-000000000001', 0);

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_count bigint;
  v_latest_id uuid;
  v_latest text;
  v_latest_storage text;
  v_cover text;
  v_cover_storage text;
begin
  select visible_media_count, latest_media_id, latest_thumb_path, latest_storage_path,
         cover_thumb_path, cover_storage_path
    into v_count, v_latest_id, v_latest, v_latest_storage, v_cover, v_cover_storage
    from public.album_summaries
   where id = '4a000000-0000-4000-8000-0000000000e2';

  -- major-2 修法①：全隱形案例的期望值恰好是 0／NULL，跟「列整個消失時變數
  -- 維持的 NULL／未初始化狀態」長得一樣——沒有這句 IF NOT FOUND，mutation (A)
  -- 那種「cover 指到不可見 media 導致整列消失」的壞法會被本段徹底放過（見
  -- 檔頭「Mutation 自證」段落，本案例正是命中該突變形狀的 fixture）。
  if not found then
    raise exception 'FAIL：查不到全隱形測試相簿（4a...e2）——album_summaries 裡整列消失（cover 指到不可見 media 時最容易踩到，見檔頭 mutation (A)）';
  end if;

  if v_count is distinct from 0 then
    raise exception 'FAIL：全隱形相簿的 visible_media_count 應為 0，實際 %', v_count;
  end if;
  if v_latest_id is not null then
    raise exception 'FAIL：全隱形相簿的 latest_media_id 應為 NULL，實際 %', v_latest_id;
  end if;
  if v_latest is not null then
    raise exception 'FAIL：全隱形相簿的 latest_thumb_path 應為 NULL，實際 %', v_latest;
  end if;
  if v_latest_storage is not null then
    raise exception 'FAIL：全隱形相簿的 latest_storage_path 應為 NULL，實際 %', v_latest_storage;
  end if;
  if v_cover is not null then
    raise exception 'FAIL：全隱形相簿的 cover_thumb_path 應為 NULL（cover 指到已軟刪的 media），實際 %', v_cover;
  end if;
  if v_cover_storage is not null then
    raise exception 'FAIL：全隱形相簿的 cover_storage_path 應為 NULL（cover 指到已軟刪的 media），實際 %', v_cover_storage;
  end if;

  raise notice 'ok：全隱形相簿 → visible_media_count=0、latest/cover 六個彙總欄皆 NULL';
end;
$$;

reset role;
rollback;

-- ===========================================================================
-- 3. 跨家庭看不到
--
-- 必須真的切換成 authenticated 角色（不能只設 request.jwt.claims）——本檔第一版
-- 只設 GUC、沒有 `set local role`，整段其實仍以連線角色（postgres，表擁有者）
-- 執行，RLS 對表擁有者天生不生效，會讓這個案例恆真通過（本機實測踩過，見 PR
-- handoff）。`set local role` 必須在 `begin;` 開的顯式交易內才會真的生效
-- （run.sh 用的連線本身不是 autocommit 外的隱式交易，裸執行只會印
-- 「SET LOCAL can only be used in transaction blocks」警告、角色不會真的换掉）。
-- ===========================================================================
begin;

do $$
declare
  v_n bigint;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  select count(*) into v_n from public.album_summaries
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if v_n <> 0 then
    raise exception 'FAIL 隔離：B 家 owner 透過 album_summaries 看到了 A 家 % 本相簿', v_n;
  end if;
  reset role;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  select count(*) into v_n from public.album_summaries
   where id = '4a000000-0000-4000-8000-000000000001';
  if v_n <> 1 then
    raise exception 'FAIL：A 家 owner 查不到自己家既有的相簿（影響 % 列）', v_n;
  end if;
  reset role;

  raise notice 'ok 隔離：B 家看不到 A 家的 album_summaries（0 列），A 家 owner 查得到自己的（1 列）';
end;
$$;

rollback;

-- ===========================================================================
-- 4. anon 拒（授權面與實際呼叫兩種驗法，比照 106_eula_consent.sql 場景 4）
-- ===========================================================================
begin;

do $$
begin
  set local role anon;
  begin
    perform count(*) from public.album_summaries;
    raise exception 'FAIL：anon 角色竟然能查詢 album_summaries';
  exception when insufficient_privilege then
    null; -- ok（42501，沒有 SELECT grant）
  end;
  reset role;
  raise notice 'ok：anon 角色實際查詢 album_summaries 被擋下（insufficient_privilege）';
end;
$$;

rollback;

-- ===========================================================================
-- 5. keyset 分頁欄位（created_at, id）仍可用
--
-- view 只是在 albums 之上疊加彙總欄，分頁會用到的 created_at／id 直接來自
-- `a.*`，語意跟直接查 albums 表完全一樣——這裡用三本 created_at 完全可控的
-- 相簿驗證「排序 + (created_at, id) < 游標」這個 keyset 條件組合仍然成立。
-- 用 id in (...) 把結果集限定在這三本，避免其他 fixture 相簿（建立時間不可控）
-- 干擾分頁邊界的判斷。
-- ===========================================================================
begin;

insert into public.albums (id, family_id, title, created_by, created_at) values
  ('4a000000-0000-4000-8000-0000000000e4', 'fa000000-0000-4000-8000-000000000001',
   'LS-200 keyset 舊', 'a0000000-0000-4000-8000-000000000001', now() - interval '3 days'),
  ('4a000000-0000-4000-8000-0000000000e5', 'fa000000-0000-4000-8000-000000000001',
   'LS-200 keyset 中', 'a0000000-0000-4000-8000-000000000001', now() - interval '2 days'),
  ('4a000000-0000-4000-8000-0000000000e6', 'fa000000-0000-4000-8000-000000000001',
   'LS-200 keyset 新', 'a0000000-0000-4000-8000-000000000001', now() - interval '1 days');

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_ids uuid[];
  v_cursor_created_at timestamptz;
  v_cursor_id uuid;
begin
  -- 第一頁：limit 2，最新的兩本
  select array_agg(id order by created_at desc, id desc) into v_ids
    from (
      select id, created_at from public.album_summaries
       where id in ('4a000000-0000-4000-8000-0000000000e4',
                    '4a000000-0000-4000-8000-0000000000e5',
                    '4a000000-0000-4000-8000-0000000000e6')
       order by created_at desc, id desc
       limit 2
    ) t;

  -- major-2 修法②：array_agg 對 0 列輸入會回 NULL（不是空陣列），跟 <>
  -- 一起用一樣會被 if NULL 悄悄放過——改用 is distinct from。
  if v_ids is distinct from array['4a000000-0000-4000-8000-0000000000e6'::uuid,
                                   '4a000000-0000-4000-8000-0000000000e5'::uuid] then
    raise exception 'FAIL：keyset 第一頁應為 [新, 中]，實際 %', v_ids;
  end if;

  select created_at, id into v_cursor_created_at, v_cursor_id
    from public.album_summaries where id = '4a000000-0000-4000-8000-0000000000e5';
  if not found then
    raise exception 'FAIL：查不到 keyset 游標來源相簿（4a...e5）——album_summaries 裡整列消失';
  end if;

  -- 第二頁：用第一頁最後一列當游標
  select array_agg(id order by created_at desc, id desc) into v_ids
    from (
      select id, created_at from public.album_summaries
       where id in ('4a000000-0000-4000-8000-0000000000e4',
                    '4a000000-0000-4000-8000-0000000000e5',
                    '4a000000-0000-4000-8000-0000000000e6')
         and (created_at, id) < (v_cursor_created_at, v_cursor_id)
       order by created_at desc, id desc
       limit 2
    ) t;

  if v_ids is distinct from array['4a000000-0000-4000-8000-0000000000e4'::uuid] then
    raise exception 'FAIL：keyset 第二頁應只剩 [舊]，實際 %', v_ids;
  end if;

  raise notice 'ok：keyset 分頁欄位（created_at, id）透過 album_summaries 查詢行為與直接查 albums 一致';
end;
$$;

reset role;
rollback;

-- ===========================================================================
-- 6. 效能：50 本相簿、1200 張已連結 media（另加 5 萬列同家庭背景雜訊 media）
-- EXPLAIN 不得出現 Seq Scan on media／album_media
-- ===========================================================================
begin;

-- 背景雜訊：5 萬列未連結任何相簿的 media，比照 50_rls_plan_no_percall_subquery.sql
-- 既有規模慣例——media 表只有 1200 列時本身就很小，Seq Scan 成本低，規劃器會
-- 直接選它，測不出「表大了會怎樣」；灌到 5 萬+ 列後 EXPLAIN 才有鑑別力
-- （本機實測：只有 1200 列時規劃器選 Hash Join＋Seq Scan on media；加了 5 萬列
-- 背景雜訊之後规劃器改選 Nested Loop＋Index Scan using media_pkey）。
insert into public.media
  (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
select
  ('3d000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'fc000000-0000-4000-8000-000000000001',
  'fc000000-0000-4000-8000-000000000001/2026/' || lpad((1 + (i % 12))::text, 2, '0') || '/noise-' || i || '.jpg',
  'photo', 1024, now() - (i * interval '1 minute'), 800, 600,
  'c0000000-0000-4000-8000-000000000001', now() - (i * interval '1 minute')
  from generate_series(1, 50000) i;

-- 50 本相簿、1200 張已連結 media（每本 24 張，1200 / 50）
insert into public.media
  (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by,
   thumb_path, thumb_width, thumb_height, created_at)
select
  ('3c000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'fc000000-0000-4000-8000-000000000001',
  'fc000000-0000-4000-8000-000000000001/2026/' || lpad((1 + (i % 12))::text, 2, '0') || '/perf-' || i || '.jpg',
  'photo', 1024, now() - (i * interval '1 minute'), 800, 600,
  'c0000000-0000-4000-8000-000000000001',
  'fc000000-0000-4000-8000-000000000001/2026/' || lpad((1 + (i % 12))::text, 2, '0') || '/perf-' || i || '_thumb.jpg',
  200, 150, now() - (i * interval '1 minute')
  from generate_series(1, 1200) i;

insert into public.albums (id, family_id, title, cover_media_id, created_by, created_at)
select
  ('4c000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'fc000000-0000-4000-8000-000000000001',
  '效能相簿 ' || i,
  ('3c000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'c0000000-0000-4000-8000-000000000001',
  now() - (i * interval '1 hour')
  from generate_series(1, 50) i;

insert into public.album_media (album_id, media_id, family_id, sort_order)
select
  ('4c000000-0000-4000-8000-' || lpad((1 + (i % 50))::text, 12, '0'))::uuid,
  ('3c000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'fc000000-0000-4000-8000-000000000001',
  i / 50
  from generate_series(1, 1200) i;

analyze public.media;
analyze public.album_media;
analyze public.albums;

do $$
declare
  v_n bigint;
begin
  select count(*) into v_n from public.media where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n < 51200 then
    raise exception 'FAIL：效能 fixture 需要 media ≥51200 列，實際 %', v_n;
  end if;
  select count(*) into v_n from public.albums where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n <> 50 then
    raise exception 'FAIL：效能 fixture 需要 50 本相簿，實際 %', v_n;
  end if;
  select count(*) into v_n from public.album_media where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n <> 1200 then
    raise exception 'FAIL：效能 fixture 需要 1200 筆 album_media 連結，實際 %', v_n;
  end if;
  raise notice 'ok：效能 fixture 就緒（51200 列 media、50 本相簿、1200 筆連結）';
end;
$$;

select set_config('request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

-- R2 N1：查詢形狀改成 iOS 實際會送的樣子——不只是裸 `order by ... limit`，
-- 而是相簿列表混合模式既有的 `deleted_at is null`（見 §2「albums」列，軟刪相簿
-- 不該出現在列表）＋keyset 游標條件（`(created_at, id) < 游標`，第一頁用
-- `(now(), 最大 uuid)` 當「從最上面開始」的哨兵值，比照
-- 50_rls_plan_no_percall_subquery.sql 主查詢 3 的既有寫法）。這個形狀能讓
-- 規劃器真的用上 `albums_family_created_idx`（`(family_id, created_at desc)
-- where deleted_at is null`，20260822120000_init_schema.sql 既有的 partial
-- index，只有查詢帶了同一個 `deleted_at is null` 述詞才會被考慮）——R2 之前
-- 沒帶這個述詞，實測規劃器改走別的 index（仍非 Seq Scan，但不是真正上線後
-- iOS 會走的那條路徑，測的東西跟正式行為對不齊）。
do $$
declare
  v_line text;
  v_plan text := '';
  v_stmt text := '
    select * from public.album_summaries
     where family_id = ''fc000000-0000-4000-8000-000000000001''
       and deleted_at is null
       and (created_at, id) < (now(), ''ffffffff-ffff-ffff-ffff-ffffffffffff''::uuid)
     order by created_at desc, id desc
     limit 20';
begin
  for v_line in execute 'explain (analyze, verbose, buffers) ' || v_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  -- major-1 修法：PostgreSQL ARE 的字界跳脫是 \y，不是 \b（\b 是退格字元的
  -- 跳脫，這條 regex 原本永遠不 match，見檔頭「major-1」說明與下面的偵測器
  -- 自我驗證）。
  if v_plan ~* 'seq scan on (public\.)?media\y' then
    raise exception E'FAIL 效能：album_summaries 查詢的 plan 出現 media 的 Seq Scan\n%', v_plan;
  end if;
  if v_plan ~* 'seq scan on (public\.)?album_media\y' then
    raise exception E'FAIL 效能：album_summaries 查詢的 plan 出現 album_media 的 Seq Scan\n%', v_plan;
  end if;

  -- 順帶釘住「沒有逐列重算」這件事（比照 50_rls_plan_no_percall_subquery.sql）：
  -- `(SubPlan N)`（不帶 hashed）是 correlated、逐外層列重算一次的形狀；目前
  -- plan 裡對 private.family_ids() 等子查詢的引用全部是 `(hashed SubPlan N)`
  -- （一次性求值），這條斷言目前應為綠。
  if v_plan ~ '\(SubPlan [0-9]+\)' then
    raise exception E'FAIL 效能：album_summaries 查詢的 plan 出現非 hashed 的逐列 correlated SubPlan\n%', v_plan;
  end if;

  raise notice 'ok 效能：50 本相簿／1200 張已連結 media（另加 5 萬列背景雜訊）的 iOS 實際查詢形狀，plan 無 Seq Scan on media／album_media、無逐列 correlated SubPlan';
end;
$$;

-- major-1 偵測器自我驗證：光是「regex 語法改對了」不代表「真的抓得到」——這裡
-- 故意關掉三種 index 相關的規劃器開關逼出真正的 `Seq Scan on public.media`，
-- 驗證上面那條（已修好的）regex 真的會抓到，抓不到代表偵測器本身失效，
-- 上面那條「應為綠」的斷言就沒有意義（比照
-- 50_rls_plan_no_percall_subquery.sql 檔尾的偵測器自我驗證，那裡驗的是
-- correlated SubPlan 判準，這裡驗的是 Seq Scan 判準，手法不同、目的相同）。
do $$
declare
  v_line text;
  v_plan text := '';
begin
  set local enable_indexscan = off;
  set local enable_bitmapscan = off;
  set local enable_indexonlyscan = off;

  for v_line in execute 'explain (analyze, verbose, buffers)
    select * from public.album_summaries
     where family_id = ''fc000000-0000-4000-8000-000000000001''
       and deleted_at is null
     order by created_at desc, id desc
     limit 20' loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  set local enable_indexscan = on;
  set local enable_bitmapscan = on;
  set local enable_indexonlyscan = on;

  if v_plan !~* 'seq scan on (public\.)?media\y' then
    raise exception
      E'FAIL：偵測器自我驗證失效——關掉 index/bitmap scan 後應該強制出現
       Seq Scan on media，卻沒被 regex 抓到（代表上面「應為綠」的斷言測不出
       任何東西）\n%', v_plan;
  end if;

  raise notice 'ok 偵測器自我驗證：關掉 index/bitmap scan 後 Seq Scan on media 被正確抓到（修好的 \y regex 有鑑別力，不是恆綠的空案）';
end;
$$;

-- 證據輸出（run.sh 會把本檔案這段輸出存成 evidence/album_summaries_explain.txt，
-- 比照 50_rls_plan_no_percall_subquery.sql 的既有慣例）——與上面機械斷言同一個
-- 查詢形狀（iOS 實際會送的樣子），不是裸 order by。
\echo ''
\echo '=== EXPLAIN 證據：album_summaries keyset 分頁（50 本相簿、1200+50000 張 media，iOS 實際查詢形狀）==='
explain (analyze, verbose, buffers)
select * from public.album_summaries
 where family_id = 'fc000000-0000-4000-8000-000000000001'
   and deleted_at is null
   and (created_at, id) < (now(), 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
 order by created_at desc, id desc
 limit 20;

reset role;
rollback;
