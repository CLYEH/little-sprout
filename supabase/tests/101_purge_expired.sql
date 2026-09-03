-- LS-153 驗收：private.purge_expired() —— 軟刪／刪帳號請求超過 30 天硬刪
--
-- 每段用 begin…rollback 包住（除了明確要驗證「跨兩次呼叫」的冪等段，那段本身
-- 只讀不寫，不需要 rollback 邊界），不需要額外 cleanup。所有時間邊界一律以
-- `v_now := clock_timestamp()` 這種區塊內自建的基準點推算 `deleted_at`，不寫死日曆
-- 日期——測試在任何時候跑結果都一樣，且直接對應 `purge_expired(p_now)` 的注入式
-- 設計本身就是為了讓呼叫端能控制「現在」是什麼時候。
--
-- 邊界判準（migration 檔頭已說明、這裡釘成可重複驗證的事實）：`deleted_at < p_now -
-- interval '30 days'` 才清——29 天前不清、剛好 30 天前也不清（邊界含，語意對齊
-- set_child_deleted 的還原判準）、31 天前清。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 邊界矩陣＋跨家庭隔離：五張表（diaries／albums／comments／media／children）各自
--    的 deleted_at，A 家放「31 天前」（該清），B 家放「29 天前」與「剛好 30 天前」
--    （皆不該清）——同一次 purge_expired() 呼叫，A 家被清、B 家完全不受影響，一次
--    驗完邊界與跨家庭隔離兩件事。
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner_a uuid := 'c1000000-0000-4000-8000-000000000001';
  v_owner_b uuid := 'c1000000-0000-4000-8000-000000000002';
  v_family_a uuid := 'c2000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'c2000000-0000-4000-8000-000000000002';
  v_diary_a uuid := 'c3000000-0000-4000-8000-000000000001';
  v_diary_b29 uuid := 'c3000000-0000-4000-8000-000000000002';
  v_diary_b30 uuid := 'c3000000-0000-4000-8000-000000000003';
  v_album_a uuid := 'c4000000-0000-4000-8000-000000000001';
  v_album_b29 uuid := 'c4000000-0000-4000-8000-000000000002';
  v_album_b30 uuid := 'c4000000-0000-4000-8000-000000000003';
  v_comment_a uuid := 'c5000000-0000-4000-8000-000000000001';
  v_comment_b29 uuid := 'c5000000-0000-4000-8000-000000000002';
  v_comment_b30 uuid := 'c5000000-0000-4000-8000-000000000003';
  v_media_a uuid := 'c6000000-0000-4000-8000-000000000001';
  v_media_b29 uuid := 'c6000000-0000-4000-8000-000000000002';
  v_media_b30 uuid := 'c6000000-0000-4000-8000-000000000003';
  v_child_a uuid := 'c7000000-0000-4000-8000-000000000001';
  v_child_b29 uuid := 'c7000000-0000-4000-8000-000000000002';
  v_child_b30 uuid := 'c7000000-0000-4000-8000-000000000003';
  v_result jsonb;
  v_n int;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-a@ls153.test', now(), now(), '{}', '{}'),
    (v_owner_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-b@ls153.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner_a, 'LS153 A 家'), (v_owner_b, 'LS153 B 家')
  on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values
    (v_family_a, 'LS153 邊界測試 A 家（31 天前，該清）', v_owner_a),
    (v_family_b, 'LS153 邊界測試 B 家（29／30 天前，不該清）', v_owner_b);

  insert into public.diaries (id, family_id, author_id, body, entry_date, deleted_at) values
    (v_diary_a, v_family_a, v_owner_a, 'A 家 31 天前軟刪的日記', current_date - 40, v_now - interval '31 days'),
    (v_diary_b29, v_family_b, v_owner_b, 'B 家 29 天前軟刪的日記', current_date - 40, v_now - interval '29 days'),
    (v_diary_b30, v_family_b, v_owner_b, 'B 家剛好 30 天前軟刪的日記', current_date - 40, v_now - interval '30 days');

  insert into public.albums (id, family_id, title, created_by, deleted_at) values
    (v_album_a, v_family_a, 'A 家 31 天前軟刪的相簿', v_owner_a, v_now - interval '31 days'),
    (v_album_b29, v_family_b, 'B 家 29 天前軟刪的相簿', v_owner_b, v_now - interval '29 days'),
    (v_album_b30, v_family_b, 'B 家剛好 30 天前軟刪的相簿', v_owner_b, v_now - interval '30 days');

  insert into public.comments (id, family_id, target_type, target_id, author_id, body, deleted_at) values
    (v_comment_a, v_family_a, 'diary', v_diary_a, v_owner_a, 'A 家 31 天前軟刪的留言', v_now - interval '31 days'),
    (v_comment_b29, v_family_b, 'diary', v_diary_b29, v_owner_b, 'B 家 29 天前軟刪的留言', v_now - interval '29 days'),
    (v_comment_b30, v_family_b, 'diary', v_diary_b30, v_owner_b, 'B 家剛好 30 天前軟刪的留言', v_now - interval '30 days');

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, deleted_at) values
    (v_media_a, v_family_a, v_family_a::text || '/2026/07/' || v_media_a::text || '.jpg', 'photo', 100, v_now, 10, 10, v_owner_a, v_now - interval '31 days'),
    (v_media_b29, v_family_b, v_family_b::text || '/2026/07/' || v_media_b29::text || '.jpg', 'photo', 100, v_now, 10, 10, v_owner_b, v_now - interval '29 days'),
    (v_media_b30, v_family_b, v_family_b::text || '/2026/07/' || v_media_b30::text || '.jpg', 'photo', 100, v_now, 10, 10, v_owner_b, v_now - interval '30 days');

  insert into public.children (id, family_id, name, birthday, deleted_at) values
    (v_child_a, v_family_a, 'A 家 31 天前軟刪的孩子', date '2023-01-01', v_now - interval '31 days'),
    (v_child_b29, v_family_b, 'B 家 29 天前軟刪的孩子', date '2023-01-01', v_now - interval '29 days'),
    (v_child_b30, v_family_b, 'B 家剛好 30 天前軟刪的孩子', date '2023-01-01', v_now - interval '30 days');

  select private.purge_expired(v_now) into v_result;
  raise notice 'purge_expired 回傳：%', v_result;

  if (v_result->'deleted_counts'->>'diaries')::int <> 1
     or (v_result->'deleted_counts'->>'albums')::int <> 1
     or (v_result->'deleted_counts'->>'comments')::int <> 1
     or (v_result->'deleted_counts'->>'media')::int <> 1
     or (v_result->'deleted_counts'->>'children')::int <> 1 then
    raise exception 'FAIL：deleted_counts 應該五張表各清 1 筆（A 家的 31 天前列），實際 %', v_result->'deleted_counts';
  end if;
  if (v_result->>'failed_count')::int <> 0 then
    raise exception 'FAIL：這次呼叫不該有任何失敗，實際 failed_count=%', v_result->>'failed_count';
  end if;

  -- A 家：五張表的列全部清空
  select count(*) into v_n from public.diaries where id = v_diary_a;
  if v_n <> 0 then raise exception 'FAIL：A 家 31 天前的日記沒被清掉'; end if;
  select count(*) into v_n from public.albums where id = v_album_a;
  if v_n <> 0 then raise exception 'FAIL：A 家 31 天前的相簿沒被清掉'; end if;
  select count(*) into v_n from public.comments where id = v_comment_a;
  if v_n <> 0 then raise exception 'FAIL：A 家 31 天前的留言沒被清掉'; end if;
  select count(*) into v_n from public.media where id = v_media_a;
  if v_n <> 0 then raise exception 'FAIL：A 家 31 天前的 media 沒被清掉'; end if;
  select count(*) into v_n from public.children where id = v_child_a;
  if v_n <> 0 then raise exception 'FAIL：A 家 31 天前的孩子沒被清掉'; end if;

  -- B 家：29 天前／剛好 30 天前的列全部原封不動（跨家庭隔離＋邊界含 30 天不清）
  select count(*) into v_n from public.diaries where id in (v_diary_b29, v_diary_b30);
  if v_n <> 2 then raise exception 'FAIL：B 家 29／30 天前的日記應該都還在，實際剩 % 筆', v_n; end if;
  select count(*) into v_n from public.albums where id in (v_album_b29, v_album_b30);
  if v_n <> 2 then raise exception 'FAIL：B 家 29／30 天前的相簿應該都還在，實際剩 % 筆', v_n; end if;
  select count(*) into v_n from public.comments where id in (v_comment_b29, v_comment_b30);
  if v_n <> 2 then raise exception 'FAIL：B 家 29／30 天前的留言應該都還在，實際剩 % 筆', v_n; end if;
  select count(*) into v_n from public.media where id in (v_media_b29, v_media_b30);
  if v_n <> 2 then raise exception 'FAIL：B 家 29／30 天前的 media 應該都還在，實際剩 % 筆', v_n; end if;
  select count(*) into v_n from public.children where id in (v_child_b29, v_child_b30);
  if v_n <> 2 then raise exception 'FAIL：B 家 29／30 天前的孩子應該都還在，實際剩 % 筆', v_n; end if;

  -- purge_runs 留了一列觀測紀錄
  select count(*) into v_n from private.purge_runs where p_now = v_now;
  if v_n <> 1 then raise exception 'FAIL：purge_runs 沒有留下這次呼叫的紀錄（p_now=%），實際 % 列', v_now, v_n; end if;

  raise notice 'ok：邊界矩陣＋跨家庭隔離——A 家 31 天前的五張表列全清，B 家 29／30 天前的列一筆不少（30 天邊界含，不清）';
end;
$$;

rollback;

-- ===========================================================================
-- 2. media 硬刪：Storage 佇列內容＋額度對帳（storage_used_bytes 硬刪前後不變）
--
-- 走完整生命週期（上傳→軟刪→backdate deleted_at→硬刪），不是直接插入已軟刪的列
-- ——這樣「軟刪當下已經扣過額度」這件事本身也被這段測試真正走過一次，不是假設。
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'c1000000-0000-4000-8000-000000000003';
  v_family uuid := 'c2000000-0000-4000-8000-000000000003';
  v_media_with_thumb uuid := 'c6000000-0000-4000-8000-000000000004';
  v_media_no_thumb uuid := 'c6000000-0000-4000-8000-000000000005';
  v_media_active uuid := 'c6000000-0000-4000-8000-000000000006';
  v_path_with_thumb text;
  v_thumb_path text;
  v_path_no_thumb text;
  v_used bigint;
  v_result jsonb;
  v_n int;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-storage@ls153.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_owner, 'LS153 Storage 測試')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, 'LS153 Storage 測試家', v_owner);

  v_path_with_thumb := v_family::text || '/2026/07/' || v_media_with_thumb::text || '.jpg';
  v_thumb_path := v_family::text || '/2026/07/' || v_media_with_thumb::text || '_thumb.jpg';
  v_path_no_thumb := v_family::text || '/2026/07/' || v_media_no_thumb::text || '.jpg';

  -- 三張照片：一張有縮圖、一張沒有、一張仍是 active（永不軟刪，作對照組）
  insert into public.media (id, family_id, storage_path, thumb_path, thumb_width, thumb_height, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_with_thumb, v_family, v_path_with_thumb, v_thumb_path, 50, 50, 'photo', 300000, v_now, 100, 100, v_owner);
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_no_thumb, v_family, v_path_no_thumb, 'photo', 200000, v_now, 100, 100, v_owner);
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_media_active, v_family, v_family::text || '/2026/07/' || v_media_active::text || '.jpg', 'photo', 111111, v_now, 100, 100, v_owner);

  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> 300000 + 200000 + 111111 then
    raise exception 'FAIL：三張照片上傳後 storage_used_bytes 應為 %，實際 %', 300000 + 200000 + 111111, v_used;
  end if;

  -- 軟刪前兩張（走真正的欄位級 UPDATE 路徑，authenticated 對 media.deleted_at 有
  -- 欄位級 grant，20260822120000_init_schema.sql:364）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.media set deleted_at = v_now where id in (v_media_with_thumb, v_media_no_thumb);
  reset role;
  set local role postgres;

  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> 111111 then
    raise exception 'FAIL：軟刪兩張之後 storage_used_bytes 應只剩 active 那張的 111111，實際 %', v_used;
  end if;

  -- backdate：模擬「31 天前就已經軟刪」，繞過 UI 沒有的時間旅行能力，直接用 postgres
  -- 身分改（測試前置條件，不是驗證對象本身）
  update public.media set deleted_at = v_now - interval '31 days'
   where id in (v_media_with_thumb, v_media_no_thumb);

  select private.purge_expired(v_now) into v_result;

  if (v_result->'deleted_counts'->>'media')::int <> 2 then
    raise exception 'FAIL：應該清掉兩張過期照片，deleted_counts.media=%', v_result->'deleted_counts'->>'media';
  end if;
  if (v_result->>'storage_enqueued')::int <> 3 then
    raise exception 'FAIL：storage_enqueued 應為 3（有縮圖那張 2 條路徑＋沒縮圖那張 1 條），實際 %', v_result->>'storage_enqueued';
  end if;

  -- 額度對帳：硬刪前後 storage_used_bytes 不變（軟刪當下就已經扣過，見上方註解）
  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> 111111 then
    raise exception 'FAIL：硬刪兩張已軟刪照片之後，storage_used_bytes 不該再變動，應仍是 111111，實際 %', v_used;
  end if;

  -- Storage 佇列內容：兩張各自該有的路徑，一字不差
  select count(*) into v_n from public.purge_storage_queue
   where media_id = v_media_with_thumb and object_path in (v_path_with_thumb, v_thumb_path)
     and bucket_id = 'media' and family_id = v_family;
  if v_n <> 2 then
    raise exception 'FAIL：有縮圖的照片應該收進佇列 2 條路徑（原圖＋縮圖），實際 %', v_n;
  end if;
  select count(*) into v_n from public.purge_storage_queue
   where media_id = v_media_no_thumb and object_path = v_path_no_thumb
     and bucket_id = 'media' and family_id = v_family;
  if v_n <> 1 then
    raise exception 'FAIL：沒有縮圖的照片應該只收進佇列 1 條路徑（原圖），實際 %', v_n;
  end if;
  select count(*) into v_n from public.purge_storage_queue where family_id = v_family;
  if v_n <> 3 then
    raise exception 'FAIL：這個家庭的佇列總筆數應為 3，實際 %', v_n;
  end if;

  -- active 那張完全不受影響
  select count(*) into v_n from public.media where id = v_media_active;
  if v_n <> 1 then raise exception 'FAIL：active 的照片不該被清掉'; end if;

  raise notice 'ok：media 硬刪——Storage 佇列路徑（含／不含縮圖）正確、storage_used_bytes 硬刪前後不變（軟刪當下已扣過，不重扣）';
end;
$$;

rollback;

-- ===========================================================================
-- 3. profiles 硬刪：deletion_requested_at 29／31 天邊界＋cascade（family_members／
--    reactions／device_tokens 消失，diaries.author_id／content_reports.reporter_id
--    set null，其他家庭的資料不受影響——混合案：這個人同時是「已離開」家 A 的前成員
--    （情況 3 留下的殘影，family_members 已經沒有他了）也是仍在家 B 的活躍成員。
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner_family uuid := 'd1000000-0000-4000-8000-000000000001';  -- 家 A 的 owner（陪襯，不受影響）
  v_purged uuid := 'd1000000-0000-4000-8000-000000000002';        -- 31 天前請求刪除，該清
  v_fresh uuid := 'd1000000-0000-4000-8000-000000000003';         -- 29 天前請求刪除，不該清
  v_family_a uuid := 'd2000000-0000-4000-8000-000000000001';
  v_diary_active uuid := 'd3000000-0000-4000-8000-000000000001';  -- v_purged 在家 A 還沒被清掉前留下的日記
  v_report_id uuid := 'd4000000-0000-4000-8000-000000000001';
  v_n int;
  v_author uuid;
  v_reporter uuid;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner_family, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-p-owner@ls153.test', now(), now(), '{}', '{}'),
    (v_purged, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-p-purged@ls153.test', now(), now(), '{}', '{}'),
    (v_fresh, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-p-fresh@ls153.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values
    (v_owner_family, 'LS153 家 A owner'),
    (v_purged, 'LS153 31 天前請求刪除'),
    (v_fresh, 'LS153 29 天前請求刪除')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into public.families (id, name, created_by) values (v_family_a, 'LS153 profiles 測試家', v_owner_family);
  -- v_purged 仍是家 A 的活躍 member（模擬情況 3 之後、purge 之前的過渡期）
  insert into public.family_members (family_id, user_id, role) values (v_family_a, v_purged, 'member');
  insert into public.diaries (id, family_id, author_id, body, entry_date) values
    (v_diary_active, v_family_a, v_purged, 'v_purged 離開前留下的日記', current_date - 5);
  insert into public.content_reports (id, family_id, target_type, target_id, reporter_id, reason) values
    (v_report_id, v_family_a, 'diary', v_diary_active, v_purged, 'v_purged 送出的檢舉');
  insert into public.reactions (id, family_id, target_type, target_id, user_id) values
    ('d5000000-0000-4000-8000-000000000001', v_family_a, 'diary', v_diary_active, v_purged);
  insert into public.device_tokens (token, user_id) values ('ls153-purge-token', v_purged);

  update public.profiles set deletion_requested_at = v_now - interval '31 days' where id = v_purged;
  update public.profiles set deletion_requested_at = v_now - interval '29 days' where id = v_fresh;

  perform private.purge_expired(v_now);

  select count(*) into v_n from public.profiles where id = v_purged;
  if v_n <> 0 then raise exception 'FAIL：31 天前請求刪除的 profiles 列沒被清掉'; end if;

  select count(*) into v_n from public.profiles where id = v_fresh;
  if v_n <> 1 then raise exception 'FAIL：29 天前請求刪除的 profiles 列不該被清掉'; end if;

  -- cascade：family_members／reactions／device_tokens 三張表屬於 v_purged 的列全部消失
  select count(*) into v_n from public.family_members where user_id = v_purged;
  if v_n <> 0 then raise exception 'FAIL：v_purged 的 family_members 列沒有 cascade 清掉'; end if;
  select count(*) into v_n from public.reactions where user_id = v_purged;
  if v_n <> 0 then raise exception 'FAIL：v_purged 的 reactions 列沒有 cascade 清掉'; end if;
  select count(*) into v_n from public.device_tokens where user_id = v_purged;
  if v_n <> 0 then raise exception 'FAIL：v_purged 的 device_tokens 列沒有 cascade 清掉'; end if;

  -- set null：diaries.author_id／content_reports.reporter_id，內容本身留著
  select author_id into v_author from public.diaries where id = v_diary_active;
  if v_author is not null then raise exception 'FAIL：diaries.author_id 應被 set null，實際 %', v_author; end if;
  select count(*) into v_n from public.diaries where id = v_diary_active and deleted_at is null;
  if v_n <> 1 then raise exception 'FAIL：v_purged 的舊日記本身不該被連坐刪除，只該 set null'; end if;

  select reporter_id into v_reporter from public.content_reports where id = v_report_id;
  if v_reporter is not null then raise exception 'FAIL：content_reports.reporter_id 應被 set null，實際 %', v_reporter; end if;

  -- 家 A owner 完全不受影響
  select count(*) into v_n from public.profiles where id = v_owner_family;
  if v_n <> 1 then raise exception 'FAIL：家 A owner 不該被清掉'; end if;
  select count(*) into v_n from public.families where id = v_family_a;
  if v_n <> 1 then raise exception 'FAIL：家 A 本身不該被清掉（families 沒有 deleted_at，見 migration 檔頭）'; end if;

  raise notice 'ok：profiles 硬刪——29／31 天邊界正確，cascade（family_members／reactions／device_tokens）與 set null（diaries.author_id／content_reports.reporter_id）皆正確，家 A 本身與 owner 不受影響';
end;
$$;

rollback;

-- ===========================================================================
-- 4. 冪等重跑：同一個 p_now 連續呼叫兩次，第二次必須全部歸零、不炸
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'e5000000-0000-4000-8000-000000000001';
  v_family uuid := 'e5000000-0000-4000-8000-000000000002';
  v_diary uuid := 'e5000000-0000-4000-8000-000000000003';
  v_result1 jsonb;
  v_result2 jsonb;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls153-idem@ls153.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_owner, 'LS153 冪等測試')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, 'LS153 冪等測試家', v_owner);
  insert into public.diaries (id, family_id, author_id, body, entry_date, deleted_at)
  values (v_diary, v_family, v_owner, '該被清掉的日記', current_date - 40, v_now - interval '31 days');

  select private.purge_expired(v_now) into v_result1;
  if (v_result1->'deleted_counts'->>'diaries')::int <> 1 then
    raise exception 'FAIL：第一次呼叫應該清掉 1 筆日記，實際 %', v_result1->'deleted_counts'->>'diaries';
  end if;

  select private.purge_expired(v_now) into v_result2;
  if (v_result2->'deleted_counts'->>'diaries')::int <> 0
     or (v_result2->>'storage_enqueued')::int <> 0
     or (v_result2->>'failed_count')::int <> 0 then
    raise exception 'FAIL：同一個 p_now 重跑第二次應該全部歸零，實際 %', v_result2;
  end if;

  raise notice 'ok：冪等重跑——同一個 p_now 連續呼叫兩次，第二次全部歸零、沒有報錯';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 授權邊界：authenticated 不能呼叫 private.purge_expired()；service_role 能讀／刪
--    purge_storage_queue，但不能寫入（唯一寫入路徑是 purge_expired() 本身，見
--    migration 註解）；authenticated／anon 對 purge_storage_queue 兩層防線（grant＋
--    RLS）皆擋。
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';  -- fixtures 既有的 A 家 member
begin
  if has_function_privilege('authenticated', 'private.purge_expired(timestamptz)', 'execute') then
    raise exception 'FAIL：authenticated 竟然對 private.purge_expired() 有 EXECUTE';
  end if;
  if has_function_privilege('anon', 'private.purge_expired(timestamptz)', 'execute') then
    raise exception 'FAIL：anon 竟然對 private.purge_expired() 有 EXECUTE';
  end if;
  if not has_function_privilege('service_role', 'private.purge_expired(timestamptz)', 'execute') then
    raise exception 'FAIL：service_role 應該對 private.purge_expired() 有 EXECUTE（harden_default_privileges.sql 的全域預設）';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform private.purge_expired();
    raise exception 'FAIL：authenticated 竟然能實際呼叫 private.purge_expired()（不只是 grant 位元檢查，這裡真的打一次）';
  exception when sqlstate '42501' then
    null; -- ok
  end;
  reset role;

  raise notice 'ok：授權邊界——authenticated／anon 對 private.purge_expired() 皆無 EXECUTE（位元檢查＋實際呼叫皆驗過），service_role 有';
end;
$$;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_probe_id uuid := 'f9000000-0000-4000-8000-000000000001';
  v_n int;
begin
  set local role postgres;
  insert into public.purge_storage_queue (id, bucket_id, object_path) values
    (v_probe_id, 'media', 'probe/only-for-60_default_privileges-style-grant-check.jpg');
  reset role;

  -- authenticated／anon：grant 層直接擋（42501），連 RLS 都用不到
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform 1 from public.purge_storage_queue where id = v_probe_id;
    raise exception 'FAIL：authenticated 竟然能 SELECT public.purge_storage_queue';
  exception when sqlstate '42501' then
    null; -- ok
  end;
  reset role;

  -- service_role：SELECT／DELETE 可用，INSERT 不行（沒有 grant，唯一寫入路徑是
  -- purge_expired() 本身，見 migration 註解）
  set local role service_role;
  select count(*) into v_n from public.purge_storage_queue where id = v_probe_id;
  if v_n <> 1 then
    raise exception 'FAIL：service_role 應該 SELECT 得到剛才用 postgres 身分塞進去的探針列';
  end if;

  begin
    insert into public.purge_storage_queue (bucket_id, object_path) values ('media', 'probe/service-role-should-not-be-able-to-insert.jpg');
    raise exception 'FAIL：service_role 竟然能直接 INSERT public.purge_storage_queue（唯一寫入路徑該是 purge_expired()）';
  exception when sqlstate '42501' then
    null; -- ok
  end;

  delete from public.purge_storage_queue where id = v_probe_id;
  reset role;

  set local role postgres;
  select count(*) into v_n from public.purge_storage_queue where id = v_probe_id;
  if v_n <> 0 then
    raise exception 'FAIL：service_role 的 DELETE 沒有真的生效';
  end if;
  reset role;

  raise notice 'ok：purge_storage_queue 授權邊界——authenticated 無 SELECT（grant 層擋），service_role 可 SELECT／DELETE、不可 INSERT，且 DELETE 確實生效';
end;
$$;

rollback;

-- ===========================================================================
-- 6. pg_cron 排程（若本環境有啟用）：job 名稱／指令正確；本機開發映像若沒有
--    shared_preload_libraries 載入 pg_cron，只留 NOTICE，不算測試失敗（migration
--    本身即為 fail-soft 設計，見 20260903110908_purge_expired.sql 檔頭）。
-- ===========================================================================
do $$
declare
  v_schedule text;
  v_command text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice '略過：本環境沒有啟用 pg_cron（fail-soft 設計預期內，見 migration 檔頭）';
    return;
  end if;

  select schedule, command into v_schedule, v_command
    from cron.job where jobname = 'ls153-purge-expired-daily';

  if v_schedule is null then
    raise exception 'FAIL：pg_cron 已啟用，但找不到 ls153-purge-expired-daily 這個 job';
  end if;
  if v_command <> 'select private.purge_expired();' then
    raise exception 'FAIL：ls153-purge-expired-daily 的 command 不對，實際 %', v_command;
  end if;

  raise notice 'ok：pg_cron 排程存在，schedule=%，command=%', v_schedule, v_command;
end;
$$;
