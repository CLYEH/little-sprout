-- LS-200（LS-20 後端）— album_summaries：security invoker view
--
-- 對應 20260905074037_album_summaries_view.sql 的驗收：
--   0. schema 形狀：view 帶 security_invoker=true、grant 只開 authenticated
--   1. 可見 1＋隱形 1 → visible_media_count=1，latest_thumb_path 為可見那張
--      （即使被軟刪那張 created_at 更新，也不能被選中，證明過濾在排序之前生效）
--   2. 全隱形 → visible_media_count=0，latest_thumb_path／cover_thumb_path 皆 NULL
--   3. 跨家庭看不到（RLS 逐使用者，security_invoker 生效）
--   4. anon 拒（授權面 has_table_privilege ＋ 實際查詢兩種驗法，比照
--      106_eula_consent.sql 場景 4 的既有慣例）
--   5. keyset 分頁欄位（created_at, id）仍可用——view 只是在 albums 之上疊加彙總欄，
--      不改變分頁會用到的欄位語意
--   6. 效能：50 本相簿、1200 張已連結 media（另加 5 萬列同家庭「背景雜訊」media，
--      比照 50_rls_plan_no_percall_subquery.sql 的既有規模慣例——只灌 1200 列時
--      media 表本身很小，Seq Scan 在小表上成本低，規劃器會選它，測不出「表大了
--      會怎樣」；灌到 5 萬+ 列後 EXPLAIN 才有鑑別力）EXPLAIN 不得出現
--      `Seq Scan on media` 或 `Seq Scan on album_media`
--
-- Mutation 自證（本機開發時手動驗證，非本檔自動執行，比照 60_default_privileges.sql
-- LS-84 的既有慣例；本檔第 1 段的斷言本身就是這份證明的常駐版本——見該段落）：
--   拿掉 view 定義裡「join media」帶來的可見性過濾，直接數 album_media 連結列
--   （即 LS-165 R2 原本的 bug 形狀：`select count(*) from album_media where
--   album_id = <本檔第 1 段的測試相簿>`），本機實測拿到 2（兩個連結列都算進去，
--   其中一個指到已軟刪、呼叫者看不到的 media）；view 正確答案是 1。差異正是本檔
--   第 1 段要保護的東西——第 1 段用同一組 fixture 直接斷言這兩個數字不相等
--   （而不只是斷言 visible_media_count=1），拿掉 join 之後兩者會變成相等，
--   斷言會失敗，具備鑑別力。

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
  v_latest text;
  v_cover text;
  v_link_count bigint;
begin
  select visible_media_count, latest_thumb_path, cover_thumb_path
    into v_count, v_latest, v_cover
    from public.album_summaries
   where id = '4a000000-0000-4000-8000-0000000000e1';

  if v_count <> 1 then
    raise exception 'FAIL：可見1隱形1 相簿的 visible_media_count 應為 1，實際 %', v_count;
  end if;
  if v_latest <> 'fa000000-0000-4000-8000-000000000001/2026/09/e1_thumb.jpg' then
    raise exception 'FAIL：latest_thumb_path 應為可見那張（e1），實際 %（若選到 e2 表示軟刪過濾沒生效）', v_latest;
  end if;
  if v_cover <> 'fa000000-0000-4000-8000-000000000001/2026/09/e1_thumb.jpg' then
    raise exception 'FAIL：cover_thumb_path 應為 e1 的縮圖，實際 %', v_cover;
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
    'ok：可見1隱形1 → visible_media_count=1（連結列實際 %，證明有濾掉軟刪那筆）、latest/cover 皆為可見那張',
    v_link_count;
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
  v_latest text;
  v_cover text;
begin
  select visible_media_count, latest_thumb_path, cover_thumb_path
    into v_count, v_latest, v_cover
    from public.album_summaries
   where id = '4a000000-0000-4000-8000-0000000000e2';

  if v_count <> 0 then
    raise exception 'FAIL：全隱形相簿的 visible_media_count 應為 0，實際 %', v_count;
  end if;
  if v_latest is not null then
    raise exception 'FAIL：全隱形相簿的 latest_thumb_path 應為 NULL，實際 %', v_latest;
  end if;
  if v_cover is not null then
    raise exception 'FAIL：全隱形相簿的 cover_thumb_path 應為 NULL（cover 指到已軟刪的 media），實際 %', v_cover;
  end if;

  raise notice 'ok：全隱形相簿 → visible_media_count=0、latest/cover 皆 NULL';
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

  if v_ids <> array['4a000000-0000-4000-8000-0000000000e6'::uuid,
                     '4a000000-0000-4000-8000-0000000000e5'::uuid] then
    raise exception 'FAIL：keyset 第一頁應為 [新, 中]，實際 %', v_ids;
  end if;

  select created_at, id into v_cursor_created_at, v_cursor_id
    from public.album_summaries where id = '4a000000-0000-4000-8000-0000000000e5';

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

  if v_ids <> array['4a000000-0000-4000-8000-0000000000e4'::uuid] then
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

do $$
declare
  v_line text;
  v_plan text := '';
  v_stmt text := '
    select * from public.album_summaries
     where family_id = ''fc000000-0000-4000-8000-000000000001''
     order by created_at desc, id desc
     limit 20';
begin
  for v_line in execute 'explain (analyze, verbose, buffers) ' || v_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan ~* 'seq scan on (public\.)?media\b' then
    raise exception E'FAIL 效能：album_summaries 查詢的 plan 出現 media 的 Seq Scan\n%', v_plan;
  end if;
  if v_plan ~* 'seq scan on (public\.)?album_media\b' then
    raise exception E'FAIL 效能：album_summaries 查詢的 plan 出現 album_media 的 Seq Scan\n%', v_plan;
  end if;

  raise notice 'ok 效能：50 本相簿／1200 張已連結 media（另加 5 萬列背景雜訊）的 keyset 查詢，plan 無 Seq Scan on media／album_media';
end;
$$;

-- 證據輸出（run.sh 會把本檔案這段輸出存成 evidence/album_summaries_explain.txt，
-- 比照 50_rls_plan_no_percall_subquery.sql 的既有慣例）
\echo ''
\echo '=== EXPLAIN 證據：album_summaries keyset 分頁（50 本相簿、1200+50000 張 media）==='
explain (analyze, verbose, buffers)
select * from public.album_summaries
 where family_id = 'fc000000-0000-4000-8000-000000000001'
 order by created_at desc, id desc
 limit 20;

reset role;
rollback;
