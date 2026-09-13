-- LS-262（LS-249 後端先行；00:5x 訂正版）—— 補強既有 `media.taken_at`（不是新增
-- `captured_at`，見 migration 20260913163828_media_taken_at_hardening.sql 檔頭與
-- 票 comment）自測：
--   1. 既有值域不受新 CHECK 影響——NULL（無 EXIF）與合理過去值（既有資料常見形狀）
--      插入照常成功，`VALIDATE CONSTRAINT` 已在 migration apply 當下對既有列驗證過
--      （本檔只需證明「正常值域」不會被誤擋，不是重跑 VALIDATE 本身）。
--   2. 回填寫入：插入時給定 taken_at，讀回值不失真。
--   3. 邊界值拒絕：早於 1970-01-01、晚於 now()+1 天皆擋下（23514），邊界本身
--      （恰好 1970-01-01、恰好 now()+1 天）仍允許。
--   4. `get_family_timeline` 回傳原始 `taken_at`，`occurred_at` 仍是既有的
--      `coalesce(taken_at, created_at)`（本票不改排序規則）。
--   5. RLS 不變：非該家庭成員透過 get_family_timeline 讀不到這筆（既有
--      feed_items_select policy 本票未觸碰）。
\set ON_ERROR_STOP on

-- ===========================================================================
-- 1～3：CHECK 約束——既有值域／回填／邊界值
-- ===========================================================================
begin;
do $$
declare
  v_family constant uuid := 'ff260000-0000-4000-8000-000000000001';
  v_owner  constant uuid := 'ee260000-0000-4000-8000-000000000001';
  v_media_null   constant uuid := '39260000-0000-4000-8000-000000000001'; -- 無 EXIF
  v_media_old    constant uuid := '39260000-0000-4000-8000-000000000002'; -- 既有資料常見形狀（兩年前）
  v_media_refill constant uuid := '39260000-0000-4000-8000-000000000003'; -- 回填寫入
  v_media_epoch  constant uuid := '39260000-0000-4000-8000-000000000004'; -- 邊界：恰好 1970-01-01
  v_media_future_edge constant uuid := '39260000-0000-4000-8000-000000000005'; -- 邊界：恰好 now()+1 天
  v_read_back timestamptz;
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ls262-owner@ls262.test', now(), now(), '{}', '{}');

  insert into public.families (id, name, created_by) values (v_family, 'LS-262 測試家', v_owner);

  -- ---- 1. 既有值域：NULL（無 EXIF）與合理過去值（既有資料常見形狀）仍成功 ----
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_null, v_family,
          v_family::text || '/2026/09/' || v_media_null::text || '.jpg',
          'photo', 1048576, null, 3024, 4032, v_owner);
  raise notice 'ok：taken_at=NULL（無 EXIF）插入成功，未被新 CHECK 誤擋';

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_old, v_family,
          v_family::text || '/2026/09/' || v_media_old::text || '.jpg',
          'photo', 1048576, now() - interval '2 years', 3024, 4032, v_owner);
  raise notice 'ok：taken_at＝兩年前（既有資料常見形狀）插入成功';

  -- ---- 2. 回填寫入：讀回值不失真 ----
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_refill, v_family,
          v_family::text || '/2026/09/' || v_media_refill::text || '.jpg',
          'photo', 1048576, '2026-01-15 08:30:00+00'::timestamptz, 3024, 4032, v_owner);

  select taken_at into v_read_back from public.media where id = v_media_refill;
  if v_read_back is distinct from '2026-01-15 08:30:00+00'::timestamptz then
    raise exception 'FAIL 回填寫入：預期 2026-01-15 08:30:00+00，實際 %', v_read_back;
  end if;
  raise notice 'ok：回填寫入的 taken_at 讀回值不失真＝%', v_read_back;

  -- ---- 3a. 邊界本身仍允許（恰好 1970-01-01／恰好 now()+1 天）----
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_epoch, v_family,
          v_family::text || '/2026/09/' || v_media_epoch::text || '.jpg',
          'photo', 1048576, '1970-01-01'::timestamptz, 3024, 4032, v_owner);
  raise notice 'ok：taken_at＝恰好 1970-01-01（下邊界）插入成功';

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_future_edge, v_family,
          v_family::text || '/2026/09/' || v_media_future_edge::text || '.jpg',
          'photo', 1048576, now() + interval '1 day', 3024, 4032, v_owner);
  raise notice 'ok：taken_at＝恰好 now()+1 天（上邊界）插入成功';

  -- ---- 3b. 邊界外拒絕：早於 1970-01-01 ----
  begin
    insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
    values (gen_random_uuid(), v_family,
            v_family::text || '/2026/09/ls262-reject-1969.jpg',
            'photo', 1048576, '1969-12-31 23:59:59+00'::timestamptz, 3024, 4032, v_owner);
    raise exception 'FAIL：taken_at 早於 1970-01-01 沒有被擋下';
  exception when check_violation then
    raise notice 'ok：taken_at＝1969-12-31 被 media_taken_at_range_check 擋下（23514）';
  end;

  -- ---- 3c. 邊界外拒絕：晚於 now()+1 天 ----
  begin
    insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
    values (gen_random_uuid(), v_family,
            v_family::text || '/2026/09/ls262-reject-future.jpg',
            'photo', 1048576, now() + interval '2 days', 3024, 4032, v_owner);
    raise exception 'FAIL：taken_at 晚於 now()+1 天沒有被擋下（mutation：拿掉 CHECK 或把邊界改成 now()+2天 這裡會不紅）';
  exception when check_violation then
    raise notice 'ok：taken_at＝now()+2 天被 media_taken_at_range_check 擋下（23514）';
  end;

  -- ---- 3d. UPDATE 路徑一樣受 CHECK 約束（不只 INSERT）----
  begin
    update public.media set taken_at = now() + interval '10 days' where id = v_media_old;
    raise exception 'FAIL：UPDATE taken_at 到未來 10 天沒有被擋下';
  exception when check_violation then
    raise notice 'ok：UPDATE taken_at 到未來 10 天一樣被擋下（CHECK 對 INSERT／UPDATE 皆生效）';
  end;
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 4～5：get_family_timeline 回傳 taken_at／occurred_at 仍為 coalesce／RLS 不變
-- ===========================================================================
begin;
do $$
declare
  v_family  constant uuid := 'ff260000-0000-4000-8000-000000000002';
  v_owner   constant uuid := 'ee260000-0000-4000-8000-000000000002';
  v_stranger constant uuid := 'ee260000-0000-4000-8000-000000000099'; -- 非該家庭成員
  v_media_with_exif constant uuid := '39260000-0000-4000-8000-000000000006';
  v_media_no_exif    constant uuid := '39260000-0000-4000-8000-000000000007';
  v_taken_at constant timestamptz := '2026-02-20 09:00:00+00'::timestamptz;
  v_out_taken_at timestamptz;
  v_out_occurred_at timestamptz;
  v_row_count int;
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls262-owner2@ls262.test',    now(), now(), '{}', '{}'),
    (v_stranger, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls262-stranger@ls262.test', now(), now(), '{}', '{}');

  insert into public.families (id, name, created_by) values (v_family, 'LS-262 timeline 測試家', v_owner);

  -- 有 EXIF：taken_at 明確給定，早於 created_at（模擬「補上傳舊照片」——created_at
  -- 恆為 now()，taken_at 可以是過去任何合法值，這正是 LS-249 批次匯入舊照片的
  -- 核心情境）。
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_with_exif, v_family,
          v_family::text || '/2026/09/' || v_media_with_exif::text || '.jpg',
          'photo', 1048576, v_taken_at, 3024, 4032, v_owner);

  -- 無 EXIF：taken_at 留 NULL，occurred_at 應退回 created_at（既有規則，本票不變）。
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_no_exif, v_family,
          v_family::text || '/2026/09/' || v_media_no_exif::text || '.jpg',
          'photo', 1048576, null, 3024, 4032, v_owner);

  -- ---- 4. owner 視角：taken_at 回傳原值，occurred_at 仍是 coalesce(taken_at, created_at) ----
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select taken_at, occurred_at into v_out_taken_at, v_out_occurred_at
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'media' and ref_id = v_media_with_exif;
  if v_out_taken_at is distinct from v_taken_at then
    raise exception 'FAIL：有 EXIF 的 media，get_family_timeline.taken_at 預期 %，實際 %', v_taken_at, v_out_taken_at;
  end if;
  if v_out_occurred_at is distinct from v_taken_at then
    raise exception 'FAIL：有 EXIF 的 media，occurred_at 預期等於 taken_at（%），實際 %（排序規則本票不動）', v_taken_at, v_out_occurred_at;
  end if;
  raise notice 'ok：有 EXIF 的 media——taken_at=%（原值）、occurred_at=%（與 taken_at 相同，coalesce 語意不變）', v_out_taken_at, v_out_occurred_at;

  select taken_at, occurred_at into v_out_taken_at, v_out_occurred_at
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'media' and ref_id = v_media_no_exif;
  if v_out_taken_at is not null then
    raise exception 'FAIL：無 EXIF 的 media，taken_at 預期 NULL，實際 %', v_out_taken_at;
  end if;
  if v_out_occurred_at is null then
    raise exception 'FAIL：無 EXIF 的 media，occurred_at 不應為 NULL（應退回 created_at）';
  end if;
  raise notice 'ok：無 EXIF 的 media——taken_at=NULL、occurred_at 退回 created_at＝%（coalesce 既有語意，mutation：把 taken_at 欄位換成 occurred_at 這裡會紅）', v_out_occurred_at;

  -- diary／album kind 的 taken_at 恆為 NULL（既有 CASE 無 ELSE 分支）——用既有相簿
  -- 型態順手驗一次，不必額外建資料：這裡插一本相簿確認。
  declare
    v_album constant uuid := '49260000-0000-4000-8000-000000000001';
  begin
    reset role;
    set local role postgres;
    insert into public.albums (id, family_id, title, created_by)
    values (v_album, v_family, 'LS-262 taken_at 對照相簿', v_owner);

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    set local role authenticated;

    select taken_at into v_out_taken_at from public.get_family_timeline(v_family, null, null, null, 20)
     where kind = 'album' and ref_id = v_album;
    if v_out_taken_at is not null then
      raise exception 'FAIL：album kind 的 taken_at 應恆為 NULL，實際 %', v_out_taken_at;
    end if;
    raise notice 'ok：album kind 的 taken_at 恆為 NULL（CASE 無 ELSE 分支的既有語意）';
  end;

  -- ---- 5. RLS 不變：非該家庭成員讀不到 ----
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into v_row_count
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'media' and ref_id = v_media_with_exif;
  if v_row_count is distinct from 0 then
    raise exception 'FAIL RLS：非該家庭成員不應讀到任何列，實際 % 列（feed_items_select 本票未觸碰，不該變寬）', v_row_count;
  end if;
  raise notice 'ok：非該家庭成員透過 get_family_timeline 讀不到這筆（feed_items_select RLS 不變）';
end;
$$;
reset role;
rollback;
