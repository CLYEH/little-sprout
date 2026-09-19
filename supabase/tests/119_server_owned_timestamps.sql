-- LS-337 — 成員以 member 身分（走 RLS，不是 postgres）直接對 `albums`／`media`
-- 的 `created_at`、`growth_records`／`child_food_records`／`device_tokens` 的
-- `updated_at`、`content_reports`／`blocked_users` 的 `created_at` 送原始
-- INSERT／PATCH，驗證這些欄位已收回為伺服器專屬（見
-- 20260919045339_server_owned_timestamps.sql）。角色矩陣沿用 00_fixtures.sql：
-- A 家（fa…001）owner=a1（a0…001）、member=a2（a0…002）。
--
-- Mutation 自證（開發期用本機 Supabase CLI 映像實跑 `supabase db reset` +
-- 單檔 psql 手動驗證，非本檔自動執行；下面三個 mutation 各自單獨套用、確認精準
-- 命中對應斷言，其餘斷言正常通過；R2 訂正 merge-review R1 i6：M1 這裡原本記錯
-- 失敗訊息文字，已改成實測時真正印出的原文）：
--   M1：把 `revoke insert on public.albums from authenticated;`／
--       `grant insert (…)`（不含 created_at）那兩句改回原本的整表
--       `grant select, insert, update, delete on public.albums to authenticated;`
--       → §1 變紅：`FAIL：member 直接 INSERT albums.created_at='infinity' 竟然
--         成功——會卡進 get_family_timeline 排序第一名，永久佔住時間軸頂端`。
--   M2：拿掉 `create trigger growth_records_touch_updated_at …` 這句
--       → §3 變紅：`FAIL：growth_records.updated_at 竟然真的被寫成呼叫端指定的
--         1970-01-01（trigger 沒有覆寫），值＝1970-01-01 00:00:00+00`。
--   M3（R2 新增，對應 merge-review R1 m1 的修法）：把
--       `growth_records_touch_updated_at`／`child_food_records_touch_updated_at`
--       兩支 trigger 的 `before update of measured_on, …, updated_at`／
--       `before update of first_tried_on, …, updated_at` 改回無條件
--       `before update`（拿掉 `of <cols>`）→ §7／§8 變紅：`FAIL（m1 回歸）：FK
--       on delete set null 的 RI 動作竟然刷新了 growth_records.updated_at
--       （before=2026-01-01 00:00:00+00，after=<now 附近的值>）`（child_food_
--       records 同型訊息）——證明「只有 RI 動作時 updated_at 不該被刷新」這件事
--       真的是靠 `of <cols>` 限制欄位觸發，不是巧合維持不變。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. albums.created_at：member 直接 INSERT 帶 created_at 一律 42501
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.albums (family_id, title, created_by, created_at)
    values (v_family, 'LS337 竄改時間的相簿', v_member, 'infinity');
    raise exception 'FAIL：member 直接 INSERT albums.created_at=''infinity'' 竟然成功——會卡進 get_family_timeline 排序第一名，永久佔住時間軸頂端';
  exception when insufficient_privilege then
    null;
  end;

  -- 正向對照：不指定 created_at 的正常建立仍然成功，且吃 default now()（不是被
  -- 整條 INSERT 路徑打壞，只是這一欄不能直接指定）。
  insert into public.albums (family_id, title, created_by)
  values (v_family, 'LS337 正常建立的相簿', v_member)
  returning id into v_album;
  if (select created_at from public.albums where id = v_album) < now() - interval '1 minute' then
    raise exception 'FAIL：正常建立的相簿 created_at 竟然不是接近 now()';
  end if;
  reset role;
  raise notice 'ok：member 直接 INSERT albums.created_at 被 42501 擋下；不帶 created_at 的正常建立仍成功、吃 default now()';
end;
$$;

rollback;

-- ===========================================================================
-- 2. media.created_at：member 直接 INSERT 帶 created_at 一律 42501（用
--    '1970-01-01' 這個攻擊值，跟上面 albums 的 'infinity' 各驗一種票面指名值）
--
-- R2（merge-review R1 i4）：正向對照改成鏡射完整的 iOS `MediaInsertPayload`
-- （`LittleSprout/Services/Diary/MediaUploadService+Payloads.swift:40-53`）13 個
-- 欄位（`id`／`family_id`／`storage_path`／`type`／`byte_size`／`width`／
-- `height`／`uploaded_by`／`thumb_path`／`thumb_width`／`thumb_height`／
-- `duration_seconds`／`taken_at`，用 `type='video'` 讓 `duration_seconds` 也有
-- 合法非 NULL 值可測），不是只驗 7 個必填欄——「allowlist 涵蓋 client 全部欄位」
-- 這個保證改成集中在本檔一次驗完，不必依賴 98_media_thumbnails.sql／
-- 99_media_duration.sql 等既有檔案分別覆蓋（reviewer 的 M3／M6 探針已證明那些
-- 既有檔案漏欄位時真的會紅，這裡是額外把保證收在同一個檔案裡，不是取代它們）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_media_id uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.media (
      family_id, storage_path, type, byte_size, width, height, uploaded_by, created_at
    ) values (
      v_family, v_family::text || '/2026/09/ls337-tamper.jpg', 'photo', 1024, 100, 100, v_member,
      '1970-01-01'
    );
    raise exception 'FAIL：member 直接 INSERT media.created_at=''1970-01-01'' 竟然成功';
  exception when insufficient_privilege then
    null;
  end;

  -- 正向對照：完整 13 欄（同 iOS MediaInsertPayload 的視訊上傳形狀），不含
  -- created_at，一次驗完 allowlist 涵蓋 client 會實際送的每一欄。
  insert into public.media (
    id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
    thumb_path, thumb_width, thumb_height, duration_seconds, taken_at
  ) values (
    v_media_id, v_family, v_family::text || '/2026/09/ls337-ok.mp4', 'video', 2048, 1920, 1080,
    v_member, v_family::text || '/2026/09/ls337-ok_thumb.jpg', 384, 512, 30, now() - interval '1 hour'
  );
  if (select created_at from public.media where id = v_media_id) < now() - interval '1 minute' then
    raise exception 'FAIL：正常上傳的 media created_at 竟然不是接近 now()';
  end if;
  reset role;
  raise notice 'ok：member 直接 INSERT media.created_at 被 42501 擋下；不帶 created_at、鏡射完整 13 欄 MediaInsertPayload 的正常上傳仍成功、吃 default now()';
end;
$$;

rollback;

-- ===========================================================================
-- 3. growth_records.updated_at：member 直接 PATCH 這一欄不會被 42501 擋下（欄位級
--    grant 本來就要留給 upsert_growth_record 的 UPDATE 陳述式用），但寫進去的值
--    會被 BEFORE UPDATE trigger 覆寫成 now()，呼叫端指定的值不會生效。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_id uuid;
  v_updated_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select (public.upsert_growth_record(null, v_child, date '2026-03-01', 72.0, 9.0, null, 'LS337 原始'))
    .id into v_id;

  -- 直接 PATCH updated_at（不是走 upsert_growth_record）——grant 仍允許這一欄
  -- （upsert 的 UPDATE 陳述式需要它），所以這句不會撞 42501；驗的是「寫進去的值
  -- 是不是呼叫端指定的那個」。
  update public.growth_records set updated_at = '1970-01-01' where id = v_id;

  select updated_at into v_updated_at from public.growth_records where id = v_id;
  if v_updated_at < now() - interval '1 minute' then
    raise exception 'FAIL：growth_records.updated_at 竟然真的被寫成呼叫端指定的 1970-01-01（trigger 沒有覆寫），值＝%', v_updated_at;
  end if;
  reset role;
  raise notice 'ok：member 直接 PATCH growth_records.updated_at 沒有被 42501 擋下（欄位級 grant 仍開放，upsert_growth_record 需要），但寫進去的值被 BEFORE UPDATE trigger 覆寫成 now()，指定的 1970-01-01 沒有生效';
end;
$$;

rollback;

-- ===========================================================================
-- 4. child_food_records.updated_at：同上，換攻擊值 'infinity'（票面另一個指名值）
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_id uuid;
  v_updated_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select (public.upsert_child_food_record(v_child, 'banana', date '2026-03-01', null, null, null))
    .id into v_id;

  update public.child_food_records set updated_at = 'infinity' where id = v_id;

  select updated_at into v_updated_at from public.child_food_records where id = v_id;
  if v_updated_at = 'infinity'::timestamptz then
    raise exception 'FAIL：child_food_records.updated_at 竟然真的被寫成呼叫端指定的 infinity（trigger 沒有覆寫），值＝%', v_updated_at;
  end if;
  reset role;
  raise notice 'ok：member 直接 PATCH child_food_records.updated_at 一樣被 BEFORE UPDATE trigger 覆寫成 now()，指定的 infinity 沒有生效';
end;
$$;

rollback;

-- ===========================================================================
-- 5. device_tokens.updated_at：整表 INSERT／UPDATE grant（不是欄位級），直接
--    INSERT 自己的裝置列一樣不會被 42501 擋（policy 只認 user_id=自己），但寫進去
--    的 updated_at 一樣被 trigger 覆寫成 now()。
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_updated_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.device_tokens (token, user_id, platform, updated_at)
  values ('ls337-tamper-device', v_member, 'ios', '1970-01-01');

  select updated_at into v_updated_at from public.device_tokens where token = 'ls337-tamper-device';
  if v_updated_at < now() - interval '1 minute' then
    raise exception 'FAIL：device_tokens.updated_at 竟然真的被寫成呼叫端指定的 1970-01-01（trigger 沒有覆寫），值＝%', v_updated_at;
  end if;
  reset role;
  raise notice 'ok：member 直接 INSERT device_tokens 帶自訂 updated_at 沒有被 42501 擋下（整表 grant，policy 只認 user_id=自己），但寫進去的值被 BEFORE INSERT trigger 覆寫成 now()';
end;
$$;

rollback;

-- ===========================================================================
-- 6. 低優先子項：content_reports.created_at／blocked_users.created_at 同
--    albums／media 的修法，member 直接 INSERT 帶 created_at 一律 42501。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into v_album from public.albums where family_id = v_family limit 1;

  begin
    insert into public.content_reports (family_id, target_type, target_id, reporter_id, reason, created_at)
    values (v_family, 'album', v_album, v_member, 'LS337 測試檢舉', 'infinity');
    raise exception 'FAIL：member 直接 INSERT content_reports.created_at=''infinity'' 竟然成功';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.blocked_users (family_id, blocker_id, blocked_id, created_at)
    values (v_family, v_member, 'a0000000-0000-4000-8000-000000000003', 'infinity');
    raise exception 'FAIL：member 直接 INSERT blocked_users.created_at=''infinity'' 竟然成功';
  exception when insufficient_privilege then
    null;
  end;
  reset role;
  raise notice 'ok（低優先子項）：member 直接 INSERT content_reports／blocked_users 的 created_at 皆被 42501 擋下';
end;
$$;

rollback;

-- ===========================================================================
-- 7. m1 回歸（merge-review R1 m1，reviewer 實跑重現）：growth_records.author_id
--    的 FK `on delete set null`——作者刪除帳號時 Postgres 自動下的 RI UPDATE——
--    不能刷新 updated_at。以 postgres 身分操作（刪帳號本身不是 authenticated
--    走得到的路徑，這裡驗的是 FK RI 動作本身的副作用，不是授權）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_author uuid := gen_random_uuid();
  v_id uuid;
  v_updated_at_before timestamptz;
  v_author_id_after uuid;
  v_updated_at_after timestamptz;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_author, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls337-m1-growth@ls337.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_author, 'LS337 M1 測試作者')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);

  insert into public.growth_records (family_id, child_id, author_id, measured_on, height_cm, updated_at)
  values (v_family, v_child, v_author, date '2026-02-01', 70.0, timestamptz '2026-01-01')
  returning id, updated_at into v_id, v_updated_at_before;

  -- 刪除作者帳號：auth.users → profiles（on delete cascade）→
  -- growth_records.author_id（on delete set null）——這是 FK 的 RI 動作，不是
  -- 使用者編輯內容，不應該刷新 updated_at（m1）。
  delete from auth.users where id = v_author;

  select author_id, updated_at into v_author_id_after, v_updated_at_after
    from public.growth_records where id = v_id;

  if v_author_id_after is not null then
    raise exception 'FAIL：刪除作者帳號後 growth_records.author_id 竟然不是 NULL（FK on delete set null 沒有生效，測試前提不成立）';
  end if;
  if v_updated_at_after <> v_updated_at_before then
    raise exception 'FAIL（m1 回歸）：FK on delete set null 的 RI 動作竟然刷新了 growth_records.updated_at（before=%，after=%）', v_updated_at_before, v_updated_at_after;
  end if;
  reset role;
  raise notice 'ok（m1 回歸）：刪除作者帳號觸發的 FK RI 動作（author_id → NULL）不會刷新 growth_records.updated_at（before=after=%）', v_updated_at_before;
end;
$$;

rollback;

-- ===========================================================================
-- 8. m1 回歸：child_food_records 同型（author_id 同一種 FK on delete set null）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_author uuid := gen_random_uuid();
  v_id uuid;
  v_updated_at_before timestamptz;
  v_author_id_after uuid;
  v_updated_at_after timestamptz;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_author, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls337-m1-food@ls337.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_author, 'LS337 M1 測試作者（飲食）')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);

  insert into public.child_food_records (family_id, child_id, food_id, author_id, first_tried_on, updated_at)
  values (v_family, v_child, 'banana', v_author, date '2026-02-01', timestamptz '2026-01-01')
  returning id, updated_at into v_id, v_updated_at_before;

  delete from auth.users where id = v_author;

  select author_id, updated_at into v_author_id_after, v_updated_at_after
    from public.child_food_records where id = v_id;

  if v_author_id_after is not null then
    raise exception 'FAIL：刪除作者帳號後 child_food_records.author_id 竟然不是 NULL（FK on delete set null 沒有生效，測試前提不成立）';
  end if;
  if v_updated_at_after <> v_updated_at_before then
    raise exception 'FAIL（m1 回歸）：FK on delete set null 的 RI 動作竟然刷新了 child_food_records.updated_at（before=%，after=%）', v_updated_at_before, v_updated_at_after;
  end if;
  reset role;
  raise notice 'ok（m1 回歸）：刪除作者帳號觸發的 FK RI 動作不會刷新 child_food_records.updated_at（before=after=%）', v_updated_at_before;
end;
$$;

rollback;
