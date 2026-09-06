-- LS-213 範圍 1（b）驗收：private.soft_delete_unreferenced_media(p_grace, p_now)
--
-- 來源：LS-96 comment c2050d43（LS-212 merge-review R3 8d1e57bc 查實）——離線放棄
-- 編輯器路徑留下的殘留是一列 `deleted_at IS NULL` 的活 media 列，Storage PUT 與
-- insert 都成功、只有後續 attachMedia／softDeleteMedia 沒能完成，UI 上看不見、
-- 使用者刪不掉，永久佔用 families.storage_used_bytes 額度。
--
-- 判準（migration 檔頭已說明，這裡釘成可重複驗證的事實）：
-- `deleted_at is null and type in ('photo','video') and created_at < p_now - p_grace
--  and 未被 diary_media／album_media 引用` 才軟刪；已引用、或未超過寬限期的列
-- 一律不動。
--
-- 每段用 begin…rollback 包住，所有時間邊界以 `v_now := clock_timestamp()` 這種
-- 區塊內自建的基準點推算 `created_at`，不寫死日曆日期。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 三案矩陣＋額度回落＋邊界（含 24 小時邊界不算超過，語意對齊 purge_expired
--    的 30 天邊界判準）：
--    a) 未引用、超過寬限期 → 軟刪，額度回落
--    b) 未引用、剛好在寬限期邊界（created_at = p_now - grace）→ 不動（邊界不算超過）
--    c) 未引用、未超過寬限期（1 小時前）→ 不動
--    d) 被 diary_media 引用、超過寬限期 → 不動
--    e) 被 album_media 引用、超過寬限期 → 不動
--    f) 未引用、超過寬限期，但已經被軟刪過（deleted_at 非 NULL）→ 不重複處理
--       （驗證冪等：主查詢的 `deleted_at is null` 本身就排除它，這裡驗證它的
--       deleted_at／額度確實維持原樣，沒有被誤觸碰）
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'dc000000-0000-4000-8000-000000000001';
  v_family uuid := 'dc000000-0000-4000-8000-000000000002';
  v_diary uuid := 'dc000000-0000-4000-8000-000000000003';
  v_album uuid := 'dc000000-0000-4000-8000-000000000004';
  v_media_orphan_old uuid := 'dc000000-0000-4000-8000-000000000010';
  v_media_orphan_boundary uuid := 'dc000000-0000-4000-8000-000000000011';
  v_media_orphan_recent uuid := 'dc000000-0000-4000-8000-000000000012';
  v_media_referenced_diary uuid := 'dc000000-0000-4000-8000-000000000013';
  v_media_referenced_album uuid := 'dc000000-0000-4000-8000-000000000014';
  v_media_already_deleted uuid := 'dc000000-0000-4000-8000-000000000015';
  v_quota_before bigint;
  v_quota_after bigint;
  v_n int;
  v_result int;
  v_check_deleted_at timestamptz;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls213-a@ls213.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_owner, 'LS213 未引用活列測試')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, 'LS213 未引用活列測試家', v_owner);
  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_diary, v_family, v_owner, '用來引用 media 的日記', current_date);
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '用來引用 media 的相簿', v_owner);

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at, deleted_at) values
    (v_media_orphan_old, v_family, v_family::text || '/2026/07/' || v_media_orphan_old::text || '.jpg', 'photo', 1000, v_now, 10, 10, v_owner, v_now - interval '25 hours', null),
    (v_media_orphan_boundary, v_family, v_family::text || '/2026/07/' || v_media_orphan_boundary::text || '.jpg', 'photo', 2000, v_now, 10, 10, v_owner, v_now - interval '24 hours', null),
    (v_media_orphan_recent, v_family, v_family::text || '/2026/07/' || v_media_orphan_recent::text || '.jpg', 'photo', 4000, v_now, 10, 10, v_owner, v_now - interval '1 hours', null),
    (v_media_referenced_diary, v_family, v_family::text || '/2026/07/' || v_media_referenced_diary::text || '.jpg', 'photo', 8000, v_now, 10, 10, v_owner, v_now - interval '25 hours', null),
    (v_media_referenced_album, v_family, v_family::text || '/2026/07/' || v_media_referenced_album::text || '.jpg', 'video', 16000, v_now, 10, 10, v_owner, v_now - interval '25 hours', null),
    (v_media_already_deleted, v_family, v_family::text || '/2026/07/' || v_media_already_deleted::text || '.jpg', 'photo', 32000, v_now, 10, 10, v_owner, v_now - interval '25 hours', v_now - interval '10 hours');

  insert into public.diary_media (diary_id, media_id, family_id) values (v_diary, v_media_referenced_diary, v_family);
  insert into public.album_media (album_id, media_id, family_id) values (v_album, v_media_referenced_album, v_family);

  select storage_used_bytes into v_quota_before from public.families where id = v_family;
  -- 額度應該是六張 media 列裡「deleted_at is null」的五張加總：
  -- 1000+2000+4000+8000+16000 = 31000（v_media_already_deleted 一開始就是已軟刪，
  -- INSERT 時 media_storage_sync 的 trigger 不會把它算進額度）。
  if v_quota_before <> 31000 then
    raise exception 'FAIL：初始額度應為 31000（五張未刪列加總），實際 %', v_quota_before;
  end if;

  select private.soft_delete_unreferenced_media(interval '24 hours', v_now) into v_result;
  raise notice 'soft_delete_unreferenced_media 回傳：%', v_result;

  if v_result <> 1 then
    raise exception 'FAIL：這次呼叫應該只軟刪 1 筆（v_media_orphan_old），實際回傳 %', v_result;
  end if;

  -- a) 未引用、超過寬限期 → 軟刪
  select deleted_at into v_check_deleted_at from public.media where id = v_media_orphan_old;
  if v_check_deleted_at is null then
    raise exception 'FAIL：v_media_orphan_old 應該已被軟刪，實際 deleted_at 仍是 NULL';
  end if;

  -- b) 剛好在寬限期邊界 → 不動
  select count(*) into v_n from public.media where id = v_media_orphan_boundary and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：v_media_orphan_boundary（剛好 24 小時前）不該被軟刪，deleted_at 應仍是 NULL';
  end if;

  -- c) 未超過寬限期 → 不動
  select count(*) into v_n from public.media where id = v_media_orphan_recent and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：v_media_orphan_recent（1 小時前，未超過寬限期）不該被軟刪';
  end if;

  -- d) 被 diary_media 引用 → 不動
  select count(*) into v_n from public.media where id = v_media_referenced_diary and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：v_media_referenced_diary（被 diary_media 引用）不該被軟刪';
  end if;

  -- e) 被 album_media 引用 → 不動
  select count(*) into v_n from public.media where id = v_media_referenced_album and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：v_media_referenced_album（被 album_media 引用）不該被軟刪';
  end if;

  -- f) 已經軟刪過的列：deleted_at 維持原本的值（v_now - 10 小時），不會被這次呼叫
  --    覆寫成新的 p_now（用 <> 而非 pg_sleep 後的精確比對——原始值與 v_now 相差
  --    10 小時，跟「被這次呼叫覆寫成 v_now」的差距天差地遠，不會有時間流逝造成
  --    的誤判空間）。
  select deleted_at into v_check_deleted_at from public.media where id = v_media_already_deleted;
  if v_check_deleted_at <> v_now - interval '10 hours' then
    raise exception 'FAIL：v_media_already_deleted 的 deleted_at 不該被這次呼叫改動，實際 %', v_check_deleted_at;
  end if;

  -- 額度回落：只有 v_media_orphan_old（byte_size=1000）被軟刪，額度應該只少 1000。
  select storage_used_bytes into v_quota_after from public.families where id = v_family;
  if v_quota_after <> v_quota_before - 1000 then
    raise exception 'FAIL：額度應該只回落 1000（v_media_orphan_old 的 byte_size），實際 %（原始 %）', v_quota_after, v_quota_before;
  end if;

  -- 冪等重跑：同一個 p_now 再呼叫一次，不該有第二筆被軟刪（v_media_orphan_old
  -- 這次的 deleted_at 已非 NULL，主查詢的 WHERE 條件本身就排除它）。
  select private.soft_delete_unreferenced_media(interval '24 hours', v_now) into v_result;
  if v_result <> 0 then
    raise exception 'FAIL：冪等重跑不該再軟刪任何列，實際回傳 %', v_result;
  end if;
  select storage_used_bytes into v_n from public.families where id = v_family;
  if v_n <> v_quota_after then
    raise exception 'FAIL：冪等重跑後額度不該再變動，實際 %（預期 %）', v_n, v_quota_after;
  end if;

  raise notice 'ok：三案矩陣＋24 小時邊界＋額度回落＋冪等重跑全部通過';
end;
$$;

rollback;

-- ===========================================================================
-- 2. 預設寬限期＝24 小時的迴歸測試（LS-213 票文「寬限期常數集中一處」）：不顯式
--    傳入 p_grace，只控制 p_now，驗證「剛好超過 24 小時」被軟刪、「還沒滿 24
--    小時」不動——防止未來有人把預設值改掉而沒人發現。
-- ===========================================================================
begin;

do $$
declare
  v_now timestamptz := clock_timestamp();
  v_owner uuid := 'dc100000-0000-4000-8000-000000000001';
  v_family uuid := 'dc100000-0000-4000-8000-000000000002';
  v_media_just_over uuid := 'dc100000-0000-4000-8000-000000000010';
  v_media_just_under uuid := 'dc100000-0000-4000-8000-000000000011';
  v_n int;
  v_result int;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls213-b@ls213.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_owner, 'LS213 預設寬限期測試')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, 'LS213 預設寬限期測試家', v_owner);

  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at, deleted_at) values
    (v_media_just_over, v_family, v_family::text || '/2026/07/' || v_media_just_over::text || '.jpg', 'photo', 100, v_now, 10, 10, v_owner, v_now - interval '24 hours' - interval '1 second', null),
    (v_media_just_under, v_family, v_family::text || '/2026/07/' || v_media_just_under::text || '.jpg', 'photo', 200, v_now, 10, 10, v_owner, v_now - interval '23 hours 59 minutes', null);

  -- 不傳 p_grace，只傳 p_now——驗證預設值本身（'24 hours'），不是呼叫端自己選的參數。
  select private.soft_delete_unreferenced_media(p_now => v_now) into v_result;
  if v_result <> 1 then
    raise exception 'FAIL：預設 24 小時寬限期下應該只軟刪 v_media_just_over 這 1 筆，實際回傳 %', v_result;
  end if;

  select count(*) into v_n from public.media where id = v_media_just_over and deleted_at is not null;
  if v_n <> 1 then
    raise exception 'FAIL：v_media_just_over（超過預設 24 小時寬限期 1 秒）應該被軟刪';
  end if;

  select count(*) into v_n from public.media where id = v_media_just_under and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：v_media_just_under（還沒滿預設 24 小時寬限期）不該被軟刪';
  end if;

  raise notice 'ok：預設寬限期（24 小時）迴歸測試通過';
end;
$$;

rollback;
