-- LS-155 驗收：delete_my_account() 情況 3 一併軟刪呼叫者的 media（含相簿內與日記
-- 附帶），額度立即釋放，並與 LS-153 的 purge_expired() 端到端銜接（軟刪滿 30 天後
-- 硬刪＋Storage 入列）。
--
-- 沿用 91_delete_account.sql／101_purge_expired.sql 的既有測試風格：每段
-- begin…rollback 包住，不需要額外 cleanup；UUID 前綴 e6／e7 未被其他測試檔使用
-- （見 supabase/tests/00_fixtures.sql 等既有檔案的命名規約）。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1.（a）（b）情況 3：U 有獨立上傳＋相簿內＋日記附帶三張 media，家庭另一位成員 V
--    也有自己的 media；U 呼叫 delete_my_account() 後，U 的三張 media 全部
--    deleted_at 非 null、V 的不變，album_media／diary_media 連結列不動，家庭的
--    storage_used_bytes 立即只釋放 U 的部分（V 的額度不受影響）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'e6000000-0000-4000-8000-000000000001';
  v_owner uuid := 'e6000000-0000-4000-8000-000000000002';   -- V：家庭 owner，留下
  v_leaver uuid := 'e6000000-0000-4000-8000-000000000003';  -- U：member，自刪帳號
  v_diary uuid := 'e6000000-0000-4000-8000-000000000004';
  v_album uuid := 'e6000000-0000-4000-8000-000000000005';
  v_media_indep uuid := 'e6000000-0000-4000-8000-000000000006';  -- U 獨立上傳
  v_media_diary uuid := 'e6000000-0000-4000-8000-000000000007'; -- U 上傳、日記附帶
  v_media_album uuid := 'e6000000-0000-4000-8000-000000000008'; -- U 上傳、相簿內
  v_media_v uuid := 'e6000000-0000-4000-8000-000000000009';      -- V 自己的 media
  v_used_before bigint;
  v_used_after bigint;
  v_n int;
  v_deleted_at timestamptz;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-owner@ls155.test', now(), now(), '{}', '{}'),
    (v_leaver, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-leaver@ls155.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner, 'LS155 owner'), (v_leaver, 'LS155 leaver')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into public.families (id, name, created_by) values (v_family, 'LS155 測試家', v_owner);
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_leaver, 'member', true);

  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_diary, v_family, v_owner, 'LS155 測試日記', current_date);
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, 'LS155 測試相簿', v_owner);

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
    (v_media_indep, v_family, v_family::text || '/2026/08/' || v_media_indep::text || '.jpg',
     'photo', 100000, now(), 100, 100, v_leaver),
    (v_media_diary, v_family, v_family::text || '/2026/08/' || v_media_diary::text || '.jpg',
     'photo', 200000, now(), 100, 100, v_leaver),
    (v_media_album, v_family, v_family::text || '/2026/08/' || v_media_album::text || '.jpg',
     'photo', 300000, now(), 100, 100, v_leaver),
    (v_media_v, v_family, v_family::text || '/2026/08/' || v_media_v::text || '.jpg',
     'photo', 400000, now(), 100, 100, v_owner);

  insert into public.diary_media (diary_id, media_id, family_id, sort_order)
  values (v_diary, v_media_diary, v_family, 0);
  insert into public.album_media (album_id, media_id, family_id, sort_order)
  values (v_album, v_media_album, v_family, 0);

  select storage_used_bytes into v_used_before from public.families where id = v_family;
  if v_used_before <> 1000000 then
    raise exception 'FAIL：前置條件不對，插入 4 張 media 之後 storage_used_bytes 應為 1000000，實際 %', v_used_before;
  end if;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_leaver, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  set local role postgres;

  -- U 的三張 media（獨立上傳／日記附帶／相簿內）全部軟刪
  select deleted_at into v_deleted_at from public.media where id = v_media_indep;
  if v_deleted_at is null then
    raise exception 'FAIL：U 獨立上傳的 media 沒有被軟刪';
  end if;
  select deleted_at into v_deleted_at from public.media where id = v_media_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：U 日記附帶的 media 沒有被軟刪';
  end if;
  select deleted_at into v_deleted_at from public.media where id = v_media_album;
  if v_deleted_at is null then
    raise exception 'FAIL：U 相簿內的 media 沒有被軟刪';
  end if;

  -- V 自己的 media 完全不受影響
  select deleted_at into v_deleted_at from public.media where id = v_media_v;
  if v_deleted_at is not null then
    raise exception 'FAIL：不屬於 U 的 V 的 media 竟然被連帶軟刪';
  end if;

  -- diary_media／album_media 連結列不動（靠 media.deleted_at 軟刪隱藏，不是刪連結列）
  select count(*) into v_n from public.diary_media
   where diary_id = v_diary and media_id = v_media_diary;
  if v_n <> 1 then
    raise exception 'FAIL：diary_media 連結列不該被動到，實際剩 % 列', v_n;
  end if;
  select count(*) into v_n from public.album_media
   where album_id = v_album and media_id = v_media_album;
  if v_n <> 1 then
    raise exception 'FAIL：album_media 連結列不該被動到，實際剩 % 列', v_n;
  end if;

  -- 額度立即釋放：只釋放 U 的 3 張（100000+200000+300000=600000），V 的 400000
  -- 仍計入額度——既有 private.media_storage_sync() trigger 自動處理，不需要
  -- delete_my_account() 額外寫任何程式碼。
  select storage_used_bytes into v_used_after from public.families where id = v_family;
  if v_used_after <> 400000 then
    raise exception 'FAIL：額度沒有正確立即釋放，預期剩 400000（僅 V 的 media），實際 %', v_used_after;
  end if;

  -- U 離開家庭，V 仍是 owner，家庭存活
  select count(*) into v_n from public.family_members where family_id = v_family and user_id = v_leaver;
  if v_n <> 0 then
    raise exception 'FAIL：U 呼叫 delete_my_account() 後仍留在 family_members';
  end if;
  select count(*) into v_n from public.family_members where family_id = v_family and user_id = v_owner and role = 'owner';
  if v_n <> 1 then
    raise exception 'FAIL：V 應該仍是家庭 owner';
  end if;

  raise notice 'ok（a）（b）：情況 3——U 的三張 media（獨立上傳／日記附帶／相簿內）全部軟刪、V 的不變、連結列不動、額度立即只釋放 U 的 600000 bytes';
end;
$$;

rollback;

-- ===========================================================================
-- 2.（c）端到端銜接 LS-153：U 呼叫 delete_my_account() 軟刪 media 之後，滿 30 天由
--    private.purge_expired() 硬刪，且 private.media_storage_queue_sync() trigger
--    正確把 storage_path 收進 public.purge_storage_queue；家庭 owner 自己的 media
--    不受影響、不入列。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'e7000000-0000-4000-8000-000000000001';
  v_owner uuid := 'e7000000-0000-4000-8000-000000000002';
  v_leaver uuid := 'e7000000-0000-4000-8000-000000000003';
  v_diary uuid := 'e7000000-0000-4000-8000-000000000004';
  v_media_indep uuid := 'e7000000-0000-4000-8000-000000000005';
  v_media_diary uuid := 'e7000000-0000-4000-8000-000000000006';
  v_media_owner uuid := 'e7000000-0000-4000-8000-000000000007';
  v_path_indep text;
  v_path_diary text;
  v_path_owner text;
  v_call_time timestamptz;
  v_result jsonb;
  v_n int;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-purge-owner@ls155.test', now(), now(), '{}', '{}'),
    (v_leaver, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-purge-leaver@ls155.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner, 'LS155 purge owner'), (v_leaver, 'LS155 purge leaver')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into public.families (id, name, created_by) values (v_family, 'LS155 purge 測試家', v_owner);
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_leaver, 'member', true);

  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_diary, v_family, v_owner, 'LS155 purge 測試日記', current_date);

  v_path_indep := v_family::text || '/2026/08/' || v_media_indep::text || '.jpg';
  v_path_diary := v_family::text || '/2026/08/' || v_media_diary::text || '.jpg';
  v_path_owner := v_family::text || '/2026/08/' || v_media_owner::text || '.jpg';

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
    (v_media_indep, v_family, v_path_indep, 'photo', 100, now(), 10, 10, v_leaver),
    (v_media_diary, v_family, v_path_diary, 'photo', 100, now(), 10, 10, v_leaver),
    (v_media_owner, v_family, v_path_owner, 'photo', 100, now(), 10, 10, v_owner);

  insert into public.diary_media (diary_id, media_id, family_id, sort_order)
  values (v_diary, v_media_diary, v_family, 0);

  v_call_time := clock_timestamp();
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_leaver, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  set local role postgres;

  -- 前置條件：U 的兩張 media 已軟刪，owner 的沒有（91/1 已經驗過這個行為本身，這裡
  -- 只是確認銜接 purge_expired() 之前的起點是對的）。
  select count(*) into v_n from public.media
   where id in (v_media_indep, v_media_diary) and deleted_at is not null;
  if v_n <> 2 then
    raise exception 'FAIL：前置條件不對，U 的兩張 media 應該已軟刪，實際 %', v_n;
  end if;

  -- 模擬「30 天後」：purge_expired() 的截止線是 p_now - 30 天；用呼叫
  -- delete_my_account() 當下的時間點往後推 31 天當 p_now，兩張 media 的 deleted_at
  -- （約等於 v_call_time）必然早於這個截止線。
  select private.purge_expired(v_call_time + interval '31 days') into v_result;
  raise notice 'purge_expired 回傳：%', v_result;

  -- U 的兩張 media 被硬刪
  select count(*) into v_n from public.media where id in (v_media_indep, v_media_diary);
  if v_n <> 0 then
    raise exception 'FAIL：U 的 media 應該已被 purge_expired() 硬刪，實際還剩 % 列', v_n;
  end if;

  -- 兩張都正確入列 Storage 清除佇列（media_storage_queue_sync trigger）
  select count(*) into v_n from public.purge_storage_queue
   where family_id = v_family and object_path in (v_path_indep, v_path_diary);
  if v_n <> 2 then
    raise exception 'FAIL：U 的兩張 media 應該入列 purge_storage_queue，實際 % 筆', v_n;
  end if;

  -- owner 自己的 media 完全不受影響、不入列
  select count(*) into v_n from public.media where id = v_media_owner and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：owner 自己的 media 不該被 purge_expired() 硬刪';
  end if;
  select count(*) into v_n from public.purge_storage_queue where object_path = v_path_owner;
  if v_n <> 0 then
    raise exception 'FAIL：owner 自己的 media 不該入列 purge_storage_queue';
  end if;

  raise notice 'ok（c）：delete_my_account() 軟刪的 media 滿 30 天後由 purge_expired() 正確硬刪並入列 purge_storage_queue，owner 自己的 media 不受影響';
end;
$$;

rollback;
