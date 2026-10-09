-- LS-441：飲食記錄 03d「從家庭相簿挑」排除飲食專屬照片。
--
-- RPC `public.list_family_photos_for_food(p_child_id, p_limit)`：該寶貝所屬家庭的未刪照片
-- （新到舊、最多 p_limit 張），但「只屬於飲食記錄」的照片（LS-430
-- `private.media_hidden_as_food_record_only`：掛在有效 child_food_records、且不在任何日記／相簿）
-- 不列——C3a：從手機新加的專屬照片只在該筆記錄內可見。
--
-- 案：1 相簿照片列出（含：已軟刪、影片不列）／2 飲食專屬照片不列／3 同時在相簿的飲食照片列出／
--     4 他家庭看不到（兩個方向）／5 p_limit 生效／6 created_at 新到舊。
-- created_at 設在未來 1 小時內，確保排在 fixtures 既有照片之前（案 6 只比較自己的兩張）。
-- 每段 begin…rollback；fixtures 沿用 00_fixtures.sql：家庭 A（owner a0…01／member a0…02）、
-- 寶貝 2a…01；家庭 B（owner b0…01）、寶貝 2b…01；A 家既有兩張相簿照片 3a…01／3a…02。

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_b_owner uuid := 'b0000000-0000-4000-8000-000000000001';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'fb000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_child_b uuid := '2b000000-0000-4000-8000-000000000001';
  v_album uuid := '4a000000-0000-4000-8000-000000000001';
  v_now timestamptz := clock_timestamp();
  v_plain uuid := 'f4410000-0000-4000-8000-000000000001';  -- 一般照片（不在相簿、不在飲食記錄）
  v_food_only uuid := 'f4410000-0000-4000-8000-000000000002';  -- 飲食專屬：只被有效記錄引用
  v_food_album uuid := 'f4410000-0000-4000-8000-000000000003';  -- 飲食記錄引用，但同時在相簿
  v_deleted uuid := 'f4410000-0000-4000-8000-000000000004';  -- 已軟刪
  v_video uuid := 'f4410000-0000-4000-8000-000000000005';  -- 影片
  v_ids uuid[];
  v_count int;
begin
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at, deleted_at) values
    (v_plain, v_family, v_family::text || '/2026/10/' || v_plain::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now + interval '56 minutes', null),
    (v_food_only, v_family, v_family::text || '/2026/10/' || v_food_only::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now + interval '57 minutes', null),
    (v_food_album, v_family, v_family::text || '/2026/10/' || v_food_album::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now + interval '58 minutes', null),
    (v_deleted, v_family, v_family::text || '/2026/10/' || v_deleted::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now + interval '59 minutes', v_now),
    (v_video, v_family, v_family::text || '/2026/10/' || v_video::text || '.mp4', 'video', 1000, v_now, 10, 10, v_owner, v_now + interval '60 minutes', null);
  insert into public.album_media (album_id, media_id, family_id) values (v_album, v_plain, v_family), (v_album, v_food_album, v_family);

  -- 以 postgres 直接寫入記錄（略過 RLS）：本檔只驗列表 RPC，不驗 upsert 權限。
  insert into public.child_food_records (family_id, child_id, food_id, author_id, first_tried_on, media_id) values
    (v_family, v_child, 'banana', v_owner, current_date, v_food_only),
    (v_family, v_child, 'mango', v_owner, current_date, v_food_album);

  -- 1) 相簿照片列出；已軟刪、影片不列
  perform set_config('request.jwt.claims', json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select coalesce(array_agg(id), '{}') into v_ids from public.list_family_photos_for_food(v_child);
  reset role;
  if not (v_plain = any (v_ids)) or not ('3a000000-0000-4000-8000-000000000001'::uuid = any (v_ids)) then
    raise exception 'FAIL（案 1）：相簿裡的照片應列出，實際 %', v_ids;
  end if;
  if v_deleted = any (v_ids) or v_video = any (v_ids) then
    raise exception 'FAIL（案 1）：已軟刪的照片與影片不得列出，實際 %', v_ids;
  end if;

  -- 2) 飲食專屬照片（被有效記錄引用、不在相簿／日記）不列
  if v_food_only = any (v_ids) then
    raise exception 'FAIL（案 2）：只屬於飲食記錄的照片不得出現在 03d 家庭相簿選擇器，實際 %', v_ids;
  end if;

  -- 3) 同時在相簿的飲食照片照列
  if not (v_food_album = any (v_ids)) then
    raise exception 'FAIL（案 3）：被飲食記錄引用、但同時在相簿的照片應列出，實際 %', v_ids;
  end if;

  -- 4) 他家庭看不到：B 家成員拿 A 家寶貝 id → 0 列；拿自己的寶貝 → 只有 B 家照片
  perform set_config('request.jwt.claims', json_build_object('sub', v_b_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.list_family_photos_for_food(v_child);
  select coalesce(array_agg(id), '{}') into v_ids from public.list_family_photos_for_food(v_child_b);
  reset role;
  if v_count <> 0 then
    raise exception 'FAIL（案 4）：他家庭成員不得列出 A 家照片，實際 % 列', v_count;
  end if;
  if v_ids <> array['3b000000-0000-4000-8000-000000000001'::uuid] then
    raise exception 'FAIL（案 4）：B 家成員用自己的寶貝只應看到 B 家照片，實際 %', v_ids;
  end if;

  -- 5) p_limit 生效、6) created_at 新到舊
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select array_agg(id) into v_ids from public.list_family_photos_for_food(v_child, 2);
  reset role;
  if coalesce(array_length(v_ids, 1), 0) <> 2 then
    raise exception 'FAIL（案 5）：p_limit = 2 應只回 2 列，實際 %', v_ids;
  end if;
  if v_ids <> array[v_food_album, v_plain] then
    raise exception 'FAIL（案 6）：應 created_at 新到舊（先 food_album 再 plain），實際 %', v_ids;
  end if;

  raise notice 'ok：list_family_photos_for_food 列相簿照片、排除飲食專屬照片、RLS 隔離、limit／排序';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- LS-444：邊界（寶貝不存在／已軟刪／p_limit 0 與 null）＋計畫形狀（10k 張級家庭不得全表掃）。
-- 上面的 LS-441 案不改，本段只追加。
-- ---------------------------------------------------------------------------

-- 案 7–10：邊界。家庭 A 既有兩張相簿照片 3a…01／3a…02（fixtures），本段再加一個已軟刪寶貝。
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_gone_child uuid := '2a000000-0000-4000-8000-0000000000d1';
  v_ids uuid[];
  v_all int;
begin
  insert into public.children (id, family_id, name, birthday, deleted_at)
    values (v_gone_child, v_family, '已軟刪寶貝', date '2024-01-01', now());

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_all from public.list_family_photos_for_food(v_child, null);
  select coalesce(array_agg(id), '{}') into v_ids from public.list_family_photos_for_food(v_gone_child);
  if coalesce(array_length(v_ids, 1), 0) <> 0 then
    raise exception 'FAIL（案 7）：已軟刪的寶貝應回空，實際 %', v_ids;
  end if;
  select coalesce(array_agg(id), '{}') into v_ids from public.list_family_photos_for_food('2a000000-0000-4000-8000-0000000000ff');
  if coalesce(array_length(v_ids, 1), 0) <> 0 then
    raise exception 'FAIL（案 8）：不存在的寶貝 id 應回空（不報錯），實際 %', v_ids;
  end if;
  select coalesce(array_agg(id), '{}') into v_ids from public.list_family_photos_for_food(v_child, 0);
  if coalesce(array_length(v_ids, 1), 0) <> 0 then
    raise exception 'FAIL（案 9）：p_limit = 0 應回空，實際 %', v_ids;
  end if;
  reset role;
  -- p_limit = null 不限：至少含 fixtures 兩張相簿照片（案 10）
  if v_all < 2 then
    raise exception 'FAIL（案 10）：p_limit = null 應回全部（>= 2 張），實際 % 張', v_all;
  end if;

  raise notice 'ok：list_family_photos_for_food 邊界（不存在／已軟刪寶貝回空、limit 0 空、null 不限）';
end;
$$;

rollback;

-- 案 11：計畫形狀。對「函式本體」做 explain（從 pg_proc.prosrc 取、把 p_child_id／p_limit 代成字面值），
-- 所以 migration 改動時不必同步第二份 SQL；以 postgres 身分執行並設 JWT claims
-- （private.family_ids() 取 auth.uid()）。
-- 為什麼不能只擋 Seq Scan：舊寫法（children join media on family_id）planner 在 5000 張級資料量下
-- 也用 media_family_created_idx，但 family_id 是 join 欄位 → 索引序無法保證輸出順序 → 計畫頂上多一個 Sort，
-- 全家庭每張 media 都先跑判準函式再排序（10k 張 39.6–52ms），limit 不能提早停。
-- 新寫法（family_id = 單值子查詢）→ Limit 直接疊在 index scan 上，無 Sort。所以斷言三件：
-- ① media 無 Seq Scan ② 用 media_family_created_idx ③ 無 Sort 節點。
begin;

do $$
declare
  v_owner uuid := 'c0000000-0000-4000-8000-000000000001';
  v_family uuid := 'fc000000-0000-4000-8000-000000000001';
  v_child uuid := '2c000000-0000-4000-8000-0000000000a1';
  v_src text;
  v_sql text;
  v_plan jsonb;
begin
  insert into public.children (id, family_id, name, birthday) values (v_child, v_family, 'perf', date '2024-01-01');
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
  select gen_random_uuid(), v_family, v_family::text || '/2026/10/p' || i || '.jpg', 'photo', 1000, now(), 10, 10,
         v_owner, now() - (i || ' seconds')::interval
    from generate_series(1, 5000) i;
  analyze public.media;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select prosrc into v_src from pg_proc
   where oid = 'public.list_family_photos_for_food(uuid, int)'::regprocedure;
  v_sql := replace(replace(rtrim(rtrim(v_src), ';'), 'p_child_id', quote_literal(v_child) || '::uuid'), 'p_limit', '300');
  if v_sql like '%p_child_id%' or v_sql like '%p_limit%' then
    raise exception 'FAIL（案 11 前置）：函式本體參數未代換乾淨，EXPLAIN 不可信：%', v_sql;
  end if;

  execute 'explain (format json) ' || v_sql into v_plan;

  if jsonb_path_exists(v_plan, '$.** ? (@."Node Type" == "Seq Scan" && @."Relation Name" == "media")') then
    raise exception 'FAIL（案 11）：函式主查詢對 media 做了 Seq Scan，計畫：%', v_plan;
  end if;
  if not jsonb_path_exists(v_plan, '$.** ? (@."Index Name" == "media_family_created_idx")') then
    raise exception 'FAIL（案 11）：函式主查詢應走 media_family_created_idx，計畫：%', v_plan;
  end if;
  if jsonb_path_exists(v_plan, '$.** ? (@."Node Type" == "Sort")') then
    raise exception 'FAIL（案 11）：計畫含 Sort——order by 沒有被索引序吃掉、limit 不能提早停（family_id 須為單值子查詢，LS-444），計畫：%', v_plan;
  end if;

  raise notice 'ok：list_family_photos_for_food 計畫走 media_family_created_idx、無 Seq Scan／Sort';
end;
$$;

rollback;
