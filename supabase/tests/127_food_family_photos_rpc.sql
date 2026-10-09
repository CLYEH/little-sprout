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
