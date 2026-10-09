-- LS-430：飲食記錄照片的 media 生命週期（C3a：從手機新加進 child_food_records 的照片
-- 只在該筆記錄內可見，記錄刪除／換照片後不得留下活的孤兒 media，也不得被每日清理
-- 誤刪還掛在有效記錄上的照片）。
--
-- 來源：LS-425 C3a 裁決＋池 1a684a3a 後半。盤點（LS-430 comment 6bd0003a）：
--   - `private.soft_delete_unreferenced_media`（LS-213）的「引用」只認 diary_media／
--     album_media，不認 child_food_records.media_id。→ ①活資料被誤清（記錄仍有效、
--     照片上傳滿 24h 就被軟刪）；②記錄刪除／換照片後舊 media 不會即時清。
--   - feed_sync_media 對每一列 media INSERT 都寫 feed_items(kind='media')，飲食專屬照片
--     因此會以獨立照片卡出現在時間軸（違反 C3a）。→ 第 5 段（migration B）。
--
-- 每段 begin…rollback；時間邊界以 clock_timestamp() 區塊內推算，不寫死日曆日期。
-- fixtures 沿用 00_fixtures.sql：家庭 A（owner a0…01／member a0…02）、寶貝 2a…01。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 每日清理不得誤刪「掛在有效飲食記錄上」的照片（先紅：現況只認日記／相簿）
--    a) 掛在未刪記錄、超過寬限期、不在日記／相簿 → 不動
--    b) 沒有任何引用、同樣超過寬限期 → 照舊軟刪（對照組，證明判準沒被放寬成全不刪）
--    c) 只被「已軟刪」的記錄掛著 → 視為無引用，軟刪（記錄退回未嘗試後，照片不該永遠佔額度）
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_bound uuid := 'f4300000-0000-4000-8000-000000000011';
  v_free uuid := 'f4300000-0000-4000-8000-000000000012';
  v_dead_record_media uuid := 'f4300000-0000-4000-8000-000000000013';
  v_rec_deleted uuid := 'f4300000-0000-4000-8000-0000000000a3';
begin
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at) values
    (v_bound, v_family, v_family::text || '/2026/10/' || v_bound::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now - interval '25 hours'),
    (v_free, v_family, v_family::text || '/2026/10/' || v_free::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now - interval '25 hours'),
    (v_dead_record_media, v_family, v_family::text || '/2026/10/' || v_dead_record_media::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now - interval '25 hours');

  -- 以 postgres 直接寫入（略過 RLS）：此段只驗清理判準，不驗 RPC 權限。
  insert into public.child_food_records (family_id, child_id, food_id, author_id, first_tried_on, media_id)
    values (v_family, v_child, 'banana', v_owner, current_date, v_bound);
  insert into public.child_food_records (id, family_id, child_id, food_id, author_id, first_tried_on, media_id, deleted_at)
    values (v_rec_deleted, v_family, v_child, 'mango', v_owner, current_date, v_dead_record_media, v_now - interval '1 hour');

  perform private.soft_delete_unreferenced_media(interval '24 hours', v_now);

  if exists (select 1 from public.media where id = v_bound and deleted_at is not null) then
    raise exception 'FAIL：掛在未刪飲食記錄上的照片（超過 24h、不在日記／相簿）被每日清理軟刪了——活資料被誤清，記錄會顯示「照片沒有載入」';
  end if;
  if not exists (select 1 from public.media where id = v_free and deleted_at is not null) then
    raise exception 'FAIL：沒有任何引用的過期照片應照舊被軟刪（對照組）';
  end if;
  if not exists (select 1 from public.media where id = v_dead_record_media and deleted_at is not null) then
    raise exception 'FAIL：只被已軟刪記錄掛著的過期照片應視為無引用而軟刪';
  end if;
  raise notice 'ok：每日清理認得有效飲食記錄的引用；無引用／只被已刪記錄引用的照片照舊清掉';
end;
$$;

rollback;

-- ===========================================================================
-- 2. 刪除記錄 → 其 media 若無其他引用即軟刪（先紅：現況沒有任何即時清理）
--    a) 作者刪除自己記錄，media 無其他引用 → 軟刪，額度回落
--    b) member 刪自己的記錄，media 是 owner 上傳的（03d 從家庭相簿挑到的照片）→ 仍軟刪
--    c) media 同時在相簿 → 不刪（有相簿引用的不得被清）
--    d) media 同時被另一筆有效記錄引用 → 不刪
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_album uuid := 'f4300000-0000-4000-8000-0000000000b1';
  v_m_a uuid := 'f4300000-0000-4000-8000-000000000021';
  v_m_b uuid := 'f4300000-0000-4000-8000-000000000022';
  v_m_c uuid := 'f4300000-0000-4000-8000-000000000023';
  v_m_d uuid := 'f4300000-0000-4000-8000-000000000024';
  v_rec uuid;
  v_rec_d2 uuid;
  v_quota_before bigint;
  v_quota_after bigint;
begin
  insert into public.albums (id, family_id, title, created_by) values (v_album, v_family, 'LS430 相簿', v_owner);
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at) values
    (v_m_a, v_family, v_family::text || '/2026/10/' || v_m_a::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now),
    (v_m_b, v_family, v_family::text || '/2026/10/' || v_m_b::text || '.jpg', 'photo', 2000, v_now, 10, 10, v_owner, v_now),
    (v_m_c, v_family, v_family::text || '/2026/10/' || v_m_c::text || '.jpg', 'photo', 4000, v_now, 10, 10, v_owner, v_now),
    (v_m_d, v_family, v_family::text || '/2026/10/' || v_m_d::text || '.jpg', 'photo', 8000, v_now, 10, 10, v_owner, v_now);
  insert into public.album_media (album_id, media_id, family_id) values (v_album, v_m_c, v_family);

  -- a) 作者刪除自己的記錄
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_rec := (public.upsert_child_food_record(v_child, 'banana', current_date, v_m_a, null, null)).id;
  reset role;
  select storage_used_bytes into v_quota_before from public.families where id = v_family;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_child_food_record(v_rec);
  reset role;
  if not exists (select 1 from public.media where id = v_m_a and deleted_at is not null) then
    raise exception 'FAIL：刪除記錄後，無其他引用的照片（案 a）應即軟刪，實際 deleted_at 仍是 NULL';
  end if;
  select storage_used_bytes into v_quota_after from public.families where id = v_family;
  if v_quota_after <> v_quota_before - 1000 then
    raise exception 'FAIL：額度應回落 1000（案 a 照片的 byte_size），實際 %（原 %）', v_quota_after, v_quota_before;
  end if;

  -- b) member 刪自己的記錄，media 是 owner 上傳的
  perform set_config('request.jwt.claims', json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_rec := (public.upsert_child_food_record(v_child, 'mango', current_date, v_m_b, null, null)).id;
  perform public.delete_child_food_record(v_rec);
  reset role;
  if not exists (select 1 from public.media where id = v_m_b and deleted_at is not null) then
    raise exception 'FAIL：member 刪除自己的記錄後，owner 上傳的照片（案 b）應即軟刪';
  end if;

  -- c) media 同時在相簿
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_rec := (public.upsert_child_food_record(v_child, 'shrimp', current_date, v_m_c, null, null)).id;
  perform public.delete_child_food_record(v_rec);
  reset role;
  if exists (select 1 from public.media where id = v_m_c and deleted_at is not null) then
    raise exception 'FAIL：在相簿（album_media）裡的照片（案 c）不得因飲食記錄被刪而軟刪';
  end if;

  -- d) media 同時被另一筆有效記錄引用（03d 從家庭相簿挑到同一張）
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_rec := (public.upsert_child_food_record(v_child, 'apple', current_date, v_m_d, null, null)).id;
  v_rec_d2 := (public.upsert_child_food_record(v_child, 'pear', current_date, v_m_d, null, null)).id;
  perform public.delete_child_food_record(v_rec);
  reset role;
  if exists (select 1 from public.media where id = v_m_d and deleted_at is not null) then
    raise exception 'FAIL：仍被另一筆有效記錄引用的照片（案 d）不得軟刪';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_child_food_record(v_rec_d2);
  reset role;
  if not exists (select 1 from public.media where id = v_m_d and deleted_at is not null) then
    raise exception 'FAIL：最後一筆引用也刪除後，照片（案 d）應即軟刪';
  end if;

  raise notice 'ok：刪除記錄→無其他引用即軟刪＋額度回落；非上傳者刪記錄也清；相簿／另一筆有效記錄引用的不刪';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 換照片／移除照片 → 舊 media 若無其他引用即軟刪（先紅）
--    a) upsert 換成另一張 → 舊的軟刪、新的活著
--    b) upsert 把 media_id 設 null（「不用照片」）→ 舊的軟刪
--    c) 舊的在相簿 → 不刪
--    d) 重存同一張（media_id 沒變）→ 不動
--    e) member 換掉 owner 上傳的舊照片（upsert 是 SECURITY INVOKER，member 對別人的 media 沒有
--       UPDATE 權——media_update 只認上傳者／owner）→ 仍軟刪：清理 trigger 必須是 SECURITY DEFINER
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_album uuid := 'f4300000-0000-4000-8000-0000000000b2';
  v_old uuid := 'f4300000-0000-4000-8000-000000000031';
  v_new uuid := 'f4300000-0000-4000-8000-000000000032';
  v_old_b uuid := 'f4300000-0000-4000-8000-000000000033';
  v_old_c uuid := 'f4300000-0000-4000-8000-000000000034';
  v_keep uuid := 'f4300000-0000-4000-8000-000000000035';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_by_owner uuid := 'f4300000-0000-4000-8000-000000000036';
begin
  insert into public.albums (id, family_id, title, created_by) values (v_album, v_family, 'LS430 相簿 2', v_owner);
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
    select m, v_family, v_family::text || '/2026/10/' || m::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now
      from unnest(array[v_old, v_new, v_old_b, v_old_c, v_keep, v_by_owner]) as m;
  insert into public.album_media (album_id, media_id, family_id) values (v_album, v_old_c, v_family);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- a) 換一張
  perform public.upsert_child_food_record(v_child, 'banana', current_date, v_old, null, null);
  perform public.upsert_child_food_record(v_child, 'banana', current_date, v_new, null, null);
  reset role;
  if not exists (select 1 from public.media where id = v_old and deleted_at is not null) then
    raise exception 'FAIL：換照片後，舊照片（案 a）應即軟刪';
  end if;
  if exists (select 1 from public.media where id = v_new and deleted_at is not null) then
    raise exception 'FAIL：換上去的新照片（案 a）不得被軟刪';
  end if;

  -- b) 不用照片
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.upsert_child_food_record(v_child, 'mango', current_date, v_old_b, null, null);
  perform public.upsert_child_food_record(v_child, 'mango', current_date, null, null, null);
  reset role;
  if not exists (select 1 from public.media where id = v_old_b and deleted_at is not null) then
    raise exception 'FAIL：把 media_id 設 null 後，舊照片（案 b）應即軟刪';
  end if;

  -- c) 舊照片在相簿
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.upsert_child_food_record(v_child, 'shrimp', current_date, v_old_c, null, null);
  perform public.upsert_child_food_record(v_child, 'shrimp', current_date, null, null, null);
  reset role;
  if exists (select 1 from public.media where id = v_old_c and deleted_at is not null) then
    raise exception 'FAIL：在相簿裡的舊照片（案 c）換照片後不得軟刪';
  end if;

  -- d) 重存同一張
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.upsert_child_food_record(v_child, 'apple', current_date, v_keep, '備註一', null);
  perform public.upsert_child_food_record(v_child, 'apple', current_date, v_keep, '備註二', null);
  reset role;
  if exists (select 1 from public.media where id = v_keep and deleted_at is not null) then
    raise exception 'FAIL：只改備註、media_id 沒變的重存（案 d）不得軟刪照片';
  end if;

  -- e) member 換掉 owner 上傳的舊照片
  perform set_config('request.jwt.claims', json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.upsert_child_food_record(v_child, 'pear', current_date, v_by_owner, null, null);
  perform public.upsert_child_food_record(v_child, 'pear', current_date, v_new, null, null);
  reset role;
  if not exists (select 1 from public.media where id = v_by_owner and deleted_at is not null) then
    raise exception 'FAIL：member 換掉 owner 上傳的舊照片（案 e）應即軟刪（清理 trigger 須為 SECURITY DEFINER，member 對別人的 media 無 UPDATE 權）';
  end if;

  raise notice 'ok：換照片／不用照片→舊照片無其他引用即軟刪；在相簿的不刪；重存同一張不動';
end;
$$;

rollback;
