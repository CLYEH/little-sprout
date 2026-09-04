-- LS-155 驗收：delete_my_account() 一併軟刪呼叫者的 media（含相簿內與日記
-- 附帶、含已退出家庭仍留有的），額度立即釋放，並與 LS-153 的 purge_expired() 端到端
-- 銜接（軟刪滿 30 天後硬刪＋Storage 入列）。
--
-- R2（merge-review R1 `b68e89d3`）新增段落 3-6：
--   3.（i4-a）呼叫者已退出但留有 media 的家庭——M1 修法 (a) 不縮小範圍的直接驗證。
--   4.（i4-b）跨多家庭一次軟刪，逐家額度歸屬正確（避免混算）。
--   5.（M2）media_select RLS 加 deleted_at is null 之後，家庭其他成員讀不到 U 已軟
--      刪的 media——日記附圖、相簿封面兩條路徑各驗一次。
--   6.（m2）finalize_account_deletion() 重跑一次 media 軟刪，接住 delete_my_account()
--      交易提交窗口內在飛上傳留下的孤兒列（直接建構孤兒狀態驗證修法本身，時序本身的
--      死鎖/競態證明見 supabase/tests/concurrency/delete_account_vs_finalize_media_*.sql）。
-- 三連線的鎖序死鎖回歸（M1 修法本身的正確性證明）不在本檔——那是需要多個真正並行
-- 連線的場景，見 supabase/tests/concurrency/delete_account_vs_finalize_media_*.sql，
-- 已掛進 supabase/tests/run.sh。
--
-- 沿用 91_delete_account.sql／101_purge_expired.sql 的既有測試風格：每段
-- begin…rollback 包住，不需要額外 cleanup；UUID 前綴 e6／e7／e8 未被其他測試檔使用
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

-- ===========================================================================
-- 3.（R2，i4-a）呼叫者已退出（從未／不再是成員）但留有 media 的家庭：
--    delete_my_account() 仍必須軟刪它、釋放額度——M1 修法 (a) 不縮小範圍的
--    直接驗證（U1 全程不是任何家庭的成員，media 迴圈完全靠反查 media 表本身找到
--    這個家庭，不依賴 family_members）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'e9000000-0000-4000-8000-000000000001';
  v_owner uuid := 'e9000000-0000-4000-8000-000000000002';
  v_u1 uuid := 'e9000000-0000-4000-8000-000000000003';
  v_media uuid := 'e9000000-0000-4000-8000-000000000004';
  v_deleted_at timestamptz;
  v_used bigint;
  v_requested timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-i4a-owner@ls155.test', now(), now(), '{}', '{}'),
    (v_u1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-i4a-u1@ls155.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner, 'R2 i4a owner'), (v_u1, 'R2 i4a U1')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into public.families (id, name, created_by) values (v_family, 'R2 i4a 家（U1 從未加入）', v_owner);
  -- 刻意不把 v_u1 加進 family_members——模擬「已退出／從未加入，但留有 media」。
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media, v_family, v_family::text || '/2026/08/' || v_media::text || '.jpg', 'photo', 500000, now(), 10, 10, v_u1);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  set local role postgres;
  select deleted_at into v_deleted_at from public.media where id = v_media;
  if v_deleted_at is null then
    raise exception 'FAIL i4-a：已退出家庭留下的 media 沒有被軟刪';
  end if;

  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> 0 then
    raise exception 'FAIL i4-a：已退出家庭的額度沒有正確釋放，預期 0，實際 %', v_used;
  end if;

  select deletion_requested_at into v_requested from public.profiles where id = v_u1;
  if v_requested is null then
    raise exception 'FAIL i4-a：U1 的 deletion_requested_at 沒有被標記';
  end if;

  raise notice 'ok i4-a：U1 從未是家庭成員、只留有 media——delete_my_account() 仍正確軟刪並釋放額度（M1 修法不縮小範圍）';
end;
$$;

rollback;

-- ===========================================================================
-- 4.（R2，i4-b）跨多家庭一次軟刪，逐家額度歸屬正確：U1 在 F1 是現役成員、F2／F3
--    只留有 media（已退出／從未加入）；同一次 delete_my_account() 呼叫要正確處理
--    三個家庭，且每個家庭各自的 storage_used_bytes 只釋放 U1 那一份、不能互相
--    混算或漏算。
-- ===========================================================================
begin;

do $$
declare
  v_f1 uuid := 'e9000000-0000-4000-8000-000000000011';  -- U1 現役成員
  v_f2 uuid := 'e9000000-0000-4000-8000-000000000012';  -- U1 只留有 media
  v_f3 uuid := 'e9000000-0000-4000-8000-000000000013';  -- U1 只留有 media
  v_owner uuid := 'e9000000-0000-4000-8000-000000000014';
  v_u1 uuid := 'e9000000-0000-4000-8000-000000000015';
  v_media_u1_f1 uuid := 'e9000000-0000-4000-8000-000000000021';
  v_media_u1_f2 uuid := 'e9000000-0000-4000-8000-000000000022';
  v_media_u1_f3 uuid := 'e9000000-0000-4000-8000-000000000023';
  v_media_owner_f1 uuid := 'e9000000-0000-4000-8000-000000000031';
  v_media_owner_f2 uuid := 'e9000000-0000-4000-8000-000000000032';
  v_media_owner_f3 uuid := 'e9000000-0000-4000-8000-000000000033';
  v_n int;
  v_used1 bigint; v_used2 bigint; v_used3 bigint;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-i4b-owner@ls155.test', now(), now(), '{}', '{}'),
    (v_u1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-i4b-u1@ls155.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner, 'R2 i4b owner'), (v_u1, 'R2 i4b U1')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into public.families (id, name, created_by) values
    (v_f1, 'R2 i4b F1（U1 現役）', v_owner),
    (v_f2, 'R2 i4b F2（U1 只留 media）', v_owner),
    (v_f3, 'R2 i4b F3（U1 只留 media）', v_owner);
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_f1, v_u1, 'member', true);

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
    (v_media_u1_f1, v_f1, v_f1::text || '/2026/08/' || v_media_u1_f1::text || '.jpg', 'photo', 111, now(), 10, 10, v_u1),
    (v_media_u1_f2, v_f2, v_f2::text || '/2026/08/' || v_media_u1_f2::text || '.jpg', 'photo', 222, now(), 10, 10, v_u1),
    (v_media_u1_f3, v_f3, v_f3::text || '/2026/08/' || v_media_u1_f3::text || '.jpg', 'photo', 333, now(), 10, 10, v_u1),
    (v_media_owner_f1, v_f1, v_f1::text || '/2026/08/' || v_media_owner_f1::text || '.jpg', 'photo', 1000, now(), 10, 10, v_owner),
    (v_media_owner_f2, v_f2, v_f2::text || '/2026/08/' || v_media_owner_f2::text || '.jpg', 'photo', 2000, now(), 10, 10, v_owner),
    (v_media_owner_f3, v_f3, v_f3::text || '/2026/08/' || v_media_owner_f3::text || '.jpg', 'photo', 3000, now(), 10, 10, v_owner);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  set local role postgres;

  select count(*) into v_n from public.media
   where id in (v_media_u1_f1, v_media_u1_f2, v_media_u1_f3) and deleted_at is not null;
  if v_n <> 3 then
    raise exception 'FAIL i4-b：U1 跨三個家庭的 media 應該全部軟刪，實際 % 筆', v_n;
  end if;

  select count(*) into v_n from public.media
   where id in (v_media_owner_f1, v_media_owner_f2, v_media_owner_f3) and deleted_at is null;
  if v_n <> 3 then
    raise exception 'FAIL i4-b：owner 三個家庭各自的 media 不該被連帶軟刪';
  end if;

  select storage_used_bytes into v_used1 from public.families where id = v_f1;
  select storage_used_bytes into v_used2 from public.families where id = v_f2;
  select storage_used_bytes into v_used3 from public.families where id = v_f3;
  if v_used1 <> 1000 or v_used2 <> 2000 or v_used3 <> 3000 then
    raise exception 'FAIL i4-b：三個家庭的額度應該只各自釋放 U1 那一份（預期 F1=1000/F2=2000/F3=3000），實際 F1=%/F2=%/F3=%',
      v_used1, v_used2, v_used3;
  end if;

  -- F1：U1 正確離開（現役成員的既有離開流程）；F2／F3：U1 從未是成員，成員數不變
  -- （F2／F3 各自仍有 owner 一位——families 的 add_creator_as_owner trigger 自動
  -- 把建立者加進去，U1 從未加入這兩個家庭，不受這句 delete_my_account() 影響）。
  select count(*) into v_n from public.family_members where family_id = v_f1 and user_id = v_u1;
  if v_n <> 0 then
    raise exception 'FAIL i4-b：U1 應該已離開 F1';
  end if;
  select count(*) into v_n from public.family_members where family_id in (v_f2, v_f3);
  if v_n <> 2 then
    raise exception 'FAIL i4-b：F2／F3 應該各自仍只有 owner 一位（U1 從未加入，不受影響），實際共 % 位', v_n;
  end if;

  raise notice 'ok i4-b：跨三個家庭一次 delete_my_account()，media 全部正確軟刪、額度逐家歸屬正確不混算（F1=%/F2=%/F3=%）', v_used1, v_used2, v_used3;
end;
$$;

rollback;

-- ===========================================================================
-- 5.（R2，M2）media_select RLS 加 deleted_at is null 之後，家庭其他成員讀不到 U
--    已軟刪的 media——日記附圖、相簿封面兩條路徑各驗一次（reviewer E4 情境的
--    常駐回歸）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'e9000000-0000-4000-8000-000000000021';
  v_v uuid := 'e9000000-0000-4000-8000-000000000022';   -- V：owner，留下
  v_u uuid := 'e9000000-0000-4000-8000-000000000023';   -- U：刪帳號
  v_diary uuid := 'e9000000-0000-4000-8000-000000000024';
  v_album uuid := 'e9000000-0000-4000-8000-000000000025';
  v_media uuid := 'e9000000-0000-4000-8000-000000000026'; -- U 上傳，V 的日記附上、V 的相簿當封面
  v_n int;
  v_cover uuid;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-m2-v@ls155.test', now(), now(), '{}', '{}'),
    (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-m2-u@ls155.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_v, 'R2 M2 V'), (v_u, 'R2 M2 U')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into public.families (id, name, created_by) values (v_family, 'R2 M2 家', v_v);
  insert into public.family_members (family_id, user_id, role, can_upload) values (v_family, v_u, 'member', true);
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media, v_family, v_family::text || '/2026/08/' || v_media::text || '.jpg', 'photo', 100, now(), 10, 10, v_u);
  insert into public.diaries (id, family_id, author_id, body, entry_date) values (v_diary, v_family, v_v, 'R2 M2 V 的日記', current_date);
  insert into public.diary_media (diary_id, media_id, family_id, sort_order) values (v_diary, v_media, v_family, 0);
  insert into public.albums (id, family_id, title, created_by, cover_media_id) values (v_album, v_family, 'R2 M2 V 的相簿', v_v, v_media);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  -- 以 V 的身分讀（等同 app 端 fetchMedia(ids:) 的 select * from media where id in (...)）
  perform set_config('request.jwt.claims', json_build_object('sub', v_v, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 路徑一：日記附圖（fetchDiaryMediaLinks → fetchMedia）
  select count(*) into v_n
    from public.diary_media dm join public.media m on m.id = dm.media_id
   where dm.diary_id = v_diary and dm.media_id = v_media;
  if v_n <> 0 then
    raise exception 'FAIL M2：V 透過日記附圖路徑仍讀得到 U 已軟刪的 media（RLS 沒有過濾 deleted_at）';
  end if;

  -- 路徑二：相簿封面（fetchAlbums → fetchMedia）
  select count(*) into v_n
    from public.albums a join public.media m on m.id = a.cover_media_id
   where a.id = v_album and a.cover_media_id = v_media;
  if v_n <> 0 then
    raise exception 'FAIL M2：V 透過相簿封面路徑仍讀得到 U 已軟刪的 media（RLS 沒有過濾 deleted_at）';
  end if;

  -- 直接查也一樣讀不到
  select count(*) into v_n from public.media where id = v_media;
  if v_n <> 0 then
    raise exception 'FAIL M2：V 直接查 media（by id）仍讀得到 U 已軟刪的列';
  end if;
  reset role;

  -- 對照：連結列本身（diary_media／album.cover_media_id）沒有被動過，純粹是
  -- media_select RLS 把已軟刪的列擋下來——用 postgres 身分（繞過 RLS）確認底層
  -- 資料原封不動，證明這是可見性修法，不是資料被清掉。
  set local role postgres;
  select count(*) into v_n from public.diary_media where diary_id = v_diary and media_id = v_media;
  if v_n <> 1 then
    raise exception 'FAIL M2 對照：diary_media 連結列不該被動到（本票設計是靠 RLS 隱藏，不是刪連結列），實際 %', v_n;
  end if;
  select cover_media_id into v_cover from public.albums where id = v_album;
  if v_cover is distinct from v_media then
    raise exception 'FAIL M2 對照：albums.cover_media_id 不該被動到';
  end if;

  raise notice 'ok M2：U 刪帳號後，V 透過日記附圖／相簿封面／直接查詢三條路徑皆讀不到已軟刪的 media（RLS 立即隱藏，底層連結列與封面欄位本身不變）';
end;
$$;

rollback;

-- ===========================================================================
-- 6.（R2，m2）finalize_account_deletion() 重跑一次 media 軟刪，接住
--    delete_my_account() 交易提交窗口內在飛上傳留下的孤兒列——直接建構「已標記
--    deletion_requested_at、已離開家庭、但還留著一張 deleted_at 為 NULL 的 media」
--    這個孤兒狀態（模擬 reviewer E5b 實測到的競態結果），驗證 finalize 本身能接住，
--    不需要真正重現時序（時序本身不影響這支函式「重跑一次同樣的軟刪」這個修法是否
--    正確接住孤兒，只影響孤兒會不會出現——出現之後怎麼被接住是這裡要驗的）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'e9000000-0000-4000-8000-000000000041';
  v_owner uuid := 'e9000000-0000-4000-8000-000000000042';
  v_u uuid := 'e9000000-0000-4000-8000-000000000043';
  v_media_old uuid := 'e9000000-0000-4000-8000-000000000044';   -- delete_my_account() 已軟刪的舊列
  v_media_orphan uuid := 'e9000000-0000-4000-8000-000000000045'; -- 提交窗口內在飛上傳，deleted_at 仍 NULL
  v_used bigint;
  v_deleted_old timestamptz;
  v_deleted_orphan timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-m2fin-owner@ls155.test', now(), now(), '{}', '{}'),
    (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls155-r2-m2fin-u@ls155.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner, 'R2 m2 owner'), (v_u, 'R2 m2 U')
  on conflict (id) do update set display_name = excluded.display_name, deletion_requested_at = null;

  insert into public.families (id, name, created_by) values (v_family, 'R2 m2 家', v_owner);
  -- 模擬 delete_my_account() 已經跑完：U 已經離開家庭（沒有 family_members 列）、
  -- 已標記 deletion_requested_at、舊的那張 media 已經軟刪。
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, deleted_at) values
    (v_media_old, v_family, v_family::text || '/2026/08/' || v_media_old::text || '.jpg', 'photo', 1000, now(), 10, 10, v_u, now());
  -- 孤兒列：模擬提交窗口內在飛上傳，deleted_at 仍是 NULL。
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
    (v_media_orphan, v_family, v_family::text || '/2026/08/' || v_media_orphan::text || '.jpg', 'photo', 2000, now(), 10, 10, v_u);
  update public.profiles set deletion_requested_at = now() where id = v_u;

  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> 2000 then
    raise exception 'FAIL m2 前置條件：孤兒列插入後 storage_used_bytes 應為 2000（舊列已軟刪不計），實際 %', v_used;
  end if;

  set local role service_role;
  perform public.finalize_account_deletion(v_u);
  reset role;

  set local role postgres;
  select deleted_at into v_deleted_old from public.media where id = v_media_old;
  select deleted_at into v_deleted_orphan from public.media where id = v_media_orphan;
  if v_deleted_orphan is null then
    raise exception 'FAIL m2：finalize_account_deletion() 沒有把在飛上傳的孤兒列軟刪';
  end if;
  if v_deleted_old is null then
    raise exception 'FAIL m2：finalize_account_deletion() 不該動到已經軟刪的舊列的 deleted_at（應維持非 NULL，這裡只是確認它還在）';
  end if;

  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> 0 then
    raise exception 'FAIL m2：孤兒列軟刪後額度應該釋放為 0，實際 %', v_used;
  end if;

  raise notice 'ok m2：finalize_account_deletion() 正確重跑 media 軟刪，接住提交窗口內在飛上傳留下的孤兒列並釋放額度';
end;
$$;

rollback;
