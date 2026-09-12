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
--
-- R2（merge-review R1 comment 80d7242c，PR #339 head c0cc2d9）：
-- F5（minor）新增第 0 段——service_role 對 media 兩欄 grant 的正向對照，比照
-- LS-151 `92_delete_account_edge_guard.sql` 的既有慣例，防止日後誤收／誤放寬。
-- F6（minor，實測）：第 1／2 段原本斷言
-- `private.soft_delete_unreferenced_media()` 的**全域**回傳值，本機容器是所有
-- worktree 共用的，另一顆 worktree 留下一列未引用的過期 media 就會讓斷言誤判成
-- 本測試自己的 fixture 出錯——改成本測試家庭範圍內的計數斷言，全域回傳值只印
-- NOTICE 供參考。新增第 3／4 段：`purge_storage_unknown_media_paths()`（含
-- reviewer 已驗證的正向不變量——30 天救援窗內已軟刪 media 不誤判為孤兒）與
-- `purge_storage_queue_enqueue_orphans()` 的路徑驗證（F4）。
--
-- LS-222（收口 LS-213 R2 merge-review N3，comment 0e4c0eed）：新增第 5／6 段。
-- N3 指出 index.ts 原本自帶的 MEDIA_OBJECT_PATH_RE 跟 private.is_media_object_path()
-- 不等價（縮圖分支：TS 允許任何既有副檔名、SQL 只認 .jpg），落差區間的物件（例如
-- {uuid}_thumb.png）會被靜默丟棄、無計數回報。第 5 段驗證新函式
-- `purge_storage_classify_orphan_paths()` 正確把這類落差樣本分進 invalid_paths；
-- 第 6 段驗證新函式 `purge_storage_queue_enqueue_orphans_v2()` 的 dropped 回傳值
-- 正確計數。兩支舊函式（`purge_storage_unknown_media_paths`／
-- `purge_storage_queue_enqueue_orphans`）維持不動，第 3／4 段的既有測試繼續驗證
-- 它們自己的行為沒有被本票動到（見新 migration 檔頭「為什麼是新函式名」的說明）。
-- 第 7 段（來源 LS-96 comment c601ccd0）：orphan_scan_cursor 專屬 grant／RLS
-- 正向對照——這張表是唯一由 EF 直接經 PostgREST 讀寫的新表，60_default_privileges.sql
-- 第 1 段的通掃只驗證機制本身，這裡補實際 grant 狀態的專屬斷言。
--
-- LS-227（DESTRUCTIVE，v1 移除）：`public.purge_storage_queue_enqueue_orphans`
-- （text, uuid, text[]，returns integer）已由 LS-222 的 `_v2` 全面取代，LS-223
-- sweeper（comment `3cbe31bb`）確認生產零呼叫端、唯一呼叫端就是本檔原第 4 段
-- 自測——使用者 DESTRUCTIVE-APPROVED 核可後移除函式本體，原第 4 段測試一併
-- 刪除（第 3／5／6／7 段驗證的是仍然存在的函式，保留，段號不重排，避免無關
-- diff）。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 0.（F5）正向對照：service_role 對 public.media 只有欄位級 SELECT
-- （storage_path、thumb_path），沒有整表 SELECT、沒有 UPDATE——比照 LS-151
-- `92_delete_account_edge_guard.sql` 第 0 段的既有慣例。
-- ===========================================================================
do $$
begin
  if not has_column_privilege('service_role', 'public.media', 'storage_path', 'select') then
    raise exception 'FAIL：service_role 沒有 media.storage_path 的 SELECT grant——purge-storage 的 purge_storage_unknown_media_paths() 讀不到這一欄';
  end if;
  if not has_column_privilege('service_role', 'public.media', 'thumb_path', 'select') then
    raise exception 'FAIL：service_role 沒有 media.thumb_path 的 SELECT grant——purge-storage 的 purge_storage_unknown_media_paths() 讀不到這一欄';
  end if;
  if has_column_privilege('service_role', 'public.media', 'byte_size', 'select') then
    raise exception 'FAIL：service_role 竟然對 media.byte_size 有 SELECT grant（收斂範圍以外的欄位不該開放）';
  end if;
  if has_table_privilege('service_role', 'public.media', 'select') then
    raise exception 'FAIL：service_role 竟然有 media 的整表 SELECT grant（本票只該開 storage_path／thumb_path 兩欄，見 migration 1b 段）';
  end if;
  if has_table_privilege('service_role', 'public.media', 'update') then
    raise exception 'FAIL：service_role 竟然有 media 的 UPDATE grant（本票不需要 service_role 寫 media，見 migration 1b 段）';
  end if;
  raise notice 'ok：service_role 對 media 只有欄位級 SELECT（storage_path、thumb_path），沒有整表 SELECT，沒有 UPDATE';
end;
$$;

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
  raise notice 'soft_delete_unreferenced_media 回傳：%（全域值，本機容器共用，僅供參考——F6：下面斷言改用本測試家庭範圍內的計數）', v_result;

  -- F6：不能斷言全域回傳值——本機容器是所有 worktree 共用的，別的 worktree
  -- 留下的未引用過期 media 列也會被這次呼叫一起軟刪，讓全域回傳值 > 1，
  -- 跟本測試 fixture 本身是否正確無關。改成本測試家庭範圍內的計數。
  -- 排除 v_media_already_deleted：那一列插入時就已經是 deleted_at 非 NULL（案 f
  -- 的既有狀態，不是這次呼叫造成的），計數時要扣掉，否則本家庭的基準值就不是 0。
  select count(*) into v_n from public.media
   where family_id = v_family and deleted_at is not null and id <> v_media_already_deleted;
  if v_n <> 1 then
    raise exception 'FAIL：這次呼叫應該只在本測試家庭內軟刪 1 筆（v_media_orphan_old），實際本家庭（不含案 f 既有的已軟刪列）有 % 筆 deleted_at 非 NULL', v_n;
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
  raise notice 'soft_delete_unreferenced_media 冪等重跑回傳：%（全域值，僅供參考）', v_result;

  -- F6：同上，改斷言本測試家庭範圍內的軟刪列數維持不變（仍是 1，不含案 f 既有
  -- 的已軟刪列），不看全域回傳值。
  select count(*) into v_n from public.media
   where family_id = v_family and deleted_at is not null and id <> v_media_already_deleted;
  if v_n <> 1 then
    raise exception 'FAIL：冪等重跑後本測試家庭（不含案 f 既有的已軟刪列）的軟刪列數不該改變，實際 %（預期仍是 1）', v_n;
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
  -- F6：不斷言全域回傳值（本機容器共用），下面兩條 id 範圍的斷言天生免疫容器
  -- 共用噪音（只看這兩個特定 id 的狀態），已經足夠驗證預設寬限期行為正確。
  raise notice 'soft_delete_unreferenced_media 回傳：%（全域值，僅供參考）', v_result;

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

-- ===========================================================================
-- 3.（LS-213 R2，merge-review R1 F2）public.purge_storage_unknown_media_paths
--    (p_paths) 行為驗證，含 reviewer 已驗證的正向不變量：30 天救援窗內已軟刪的
--    media（原圖＋縮圖）仍視為「有對應列」，不會被誤判為孤兒物件。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'dc200000-0000-4000-8000-000000000001';
  v_family uuid := 'dc200000-0000-4000-8000-000000000002';
  v_media_active uuid := 'dc200000-0000-4000-8000-000000000010';
  v_media_soft_deleted uuid := 'dc200000-0000-4000-8000-000000000011';
  v_path_active text;
  v_path_soft_deleted text;
  v_thumb_soft_deleted text;
  v_path_unknown text := 'dc200000-0000-4000-8000-000000000002/2026/07/dc200000-0000-4000-8000-0000000000ff.jpg';
  v_result text[];
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls213-c@ls213.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_owner, 'LS213 unknown_media_paths 測試')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, 'LS213 unknown_media_paths 測試家', v_owner);

  v_path_active := v_family::text || '/2026/07/' || v_media_active::text || '.jpg';
  v_path_soft_deleted := v_family::text || '/2026/07/' || v_media_soft_deleted::text || '.jpg';
  v_thumb_soft_deleted := v_family::text || '/2026/07/' || v_media_soft_deleted::text || '_thumb.jpg';

  insert into public.media (id, family_id, storage_path, thumb_path, thumb_width, thumb_height, type, byte_size, taken_at, width, height, uploaded_by, deleted_at) values
    (v_media_active, v_family, v_path_active, null, null, null, 'photo', 100, now(), 10, 10, v_owner, null),
    -- 3 天前軟刪，仍在 30 天救援窗內——正向不變量：原圖與縮圖都不該被判定為孤兒。
    (v_media_soft_deleted, v_family, v_path_soft_deleted, v_thumb_soft_deleted, 5, 5, 'photo', 200, now(), 10, 10, v_owner, now() - interval '3 days');

  select public.purge_storage_unknown_media_paths(
    array[v_path_active, v_path_soft_deleted, v_thumb_soft_deleted, v_path_unknown]
  ) into v_result;

  if v_result <> array[v_path_unknown] then
    raise exception 'FAIL：purge_storage_unknown_media_paths 應該只回傳真正查不到列的路徑（%），實際 %', v_path_unknown, v_result;
  end if;

  raise notice 'ok：purge_storage_unknown_media_paths 正確排除活列與 30 天救援窗內已軟刪列（原圖＋縮圖），只回傳真正未知的路徑 %', v_result;
end;
$$;

rollback;

-- ===========================================================================
-- 5.（LS-222，收口 LS-213 R2 merge-review N3）public.purge_storage_classify_
--    orphan_paths(p_paths) 行為驗證：形狀不合規的路徑（含票文點名的落差樣本
--    {uuid}_thumb.png）進 invalid_paths，不會混進 orphan_paths；合法形狀裡真正
--    沒有 media 列引用的才進 orphan_paths；30 天救援窗內已軟刪 media（原圖＋
--    縮圖）的正向不變量繼續成立（內部組合既有
--    purge_storage_unknown_media_paths()，同一份查詢，不重複實作）。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'dc400000-0000-4000-8000-000000000001';
  v_family uuid := 'dc400000-0000-4000-8000-000000000002';
  v_media_active uuid := 'dc400000-0000-4000-8000-000000000010';
  v_media_soft_deleted uuid := 'dc400000-0000-4000-8000-000000000011';
  v_path_active text;
  v_path_soft_deleted text;
  v_thumb_soft_deleted text;
  v_path_unknown text := 'dc400000-0000-4000-8000-000000000002/2026/07/dc400000-0000-4000-8000-0000000000ff.jpg';
  -- 落差樣本：LS-213 R2 merge-review N3 指出的具體案例——SQL 只認縮圖 .jpg，
  -- 這個 .png 縮圖形狀完全不合規（不論有沒有對應 media 列都一樣），必須落進
  -- invalid_paths，不能混進 orphan_paths。
  v_path_bad_thumb text := 'dc400000-0000-4000-8000-000000000002/2026/07/dc400000-0000-4000-8000-0000000000ee_thumb.png';
  v_orphan_paths text[];
  v_invalid_paths text[];
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls222-classify@ls213.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_owner, 'LS222 classify_orphan_paths 測試')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, 'LS222 classify_orphan_paths 測試家', v_owner);

  v_path_active := v_family::text || '/2026/07/' || v_media_active::text || '.jpg';
  v_path_soft_deleted := v_family::text || '/2026/07/' || v_media_soft_deleted::text || '.jpg';
  v_thumb_soft_deleted := v_family::text || '/2026/07/' || v_media_soft_deleted::text || '_thumb.jpg';

  insert into public.media (id, family_id, storage_path, thumb_path, thumb_width, thumb_height, type, byte_size, taken_at, width, height, uploaded_by, deleted_at) values
    (v_media_active, v_family, v_path_active, null, null, null, 'photo', 100, now(), 10, 10, v_owner, null),
    -- 3 天前軟刪，仍在 30 天救援窗內——正向不變量：原圖與縮圖都不該被判定為孤兒。
    (v_media_soft_deleted, v_family, v_path_soft_deleted, v_thumb_soft_deleted, 5, 5, 'photo', 200, now(), 10, 10, v_owner, now() - interval '3 days');

  select orphan_paths, invalid_paths
    into v_orphan_paths, v_invalid_paths
    from public.purge_storage_classify_orphan_paths(
      array[v_path_active, v_path_soft_deleted, v_thumb_soft_deleted, v_path_unknown, v_path_bad_thumb]
    );

  if v_invalid_paths <> array[v_path_bad_thumb] then
    raise exception 'FAIL：invalid_paths 應該只有落差樣本 %（.png 縮圖形狀不合規），實際 %', v_path_bad_thumb, v_invalid_paths;
  end if;

  if v_orphan_paths <> array[v_path_unknown] then
    raise exception 'FAIL：orphan_paths 應該只有真正查不到列的路徑 %（不含形狀不合規的落差樣本、不含活列／救援窗內軟刪列），實際 %', v_path_unknown, v_orphan_paths;
  end if;

  raise notice 'ok：purge_storage_classify_orphan_paths 正確把 %（.png 縮圖）分進 invalid_paths、% 分進 orphan_paths，活列與 30 天救援窗內已軟刪列（原圖＋縮圖）皆未誤判', v_path_bad_thumb, v_path_unknown;
end;
$$;

rollback;

-- ===========================================================================
-- 6.（LS-222，收口 LS-213 R2 merge-review N3）public.purge_storage_queue_
--    enqueue_orphans_v2(p_bucket_id, p_family_id, p_object_paths) 行為驗證：
--    與舊版 purge_storage_queue_enqueue_orphans() 同一組防禦性重驗（前綴＋形狀），
--    差別是這支額外回傳 dropped——不合規的路徑不再靜默消失，呼叫端拿得到計數。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'dc500000-0000-4000-8000-000000000001';
  v_other_family uuid := 'dc500000-0000-4000-8000-000000000099';
  v_media_id uuid := 'dc500000-0000-4000-8000-000000000010';
  v_valid_path text;
  v_wrong_prefix_path text;
  v_bad_shape_path text;
  v_n int;
  v_enqueued int;
  v_dropped int;
begin
  set local role postgres;

  v_valid_path := v_family::text || '/2026/07/' || v_media_id::text || '.jpg';
  v_wrong_prefix_path := v_other_family::text || '/2026/07/' || v_media_id::text || '.jpg';
  v_bad_shape_path := v_family::text || '/not-a-valid-media-path.txt';

  select enqueued, dropped
    into v_enqueued, v_dropped
    from public.purge_storage_queue_enqueue_orphans_v2(
      'media', v_family, array[v_valid_path, v_wrong_prefix_path, v_bad_shape_path]
    );

  if v_enqueued <> 1 then
    raise exception 'FAIL：三條路徑裡只有 1 條合法（前綴符合 p_family_id 且形狀合規），enqueued 應該是 1，實際 %', v_enqueued;
  end if;

  if v_dropped <> 2 then
    raise exception 'FAIL：三條路徑裡有 2 條該被丟棄（家庭前綴不符一條、形狀不合規一條），dropped 應該是 2，實際 %（LS-222 要修的正是這個計數過去完全沒有回報）', v_dropped;
  end if;

  select count(*) into v_n from public.purge_storage_queue where object_path = v_valid_path;
  if v_n <> 1 then
    raise exception 'FAIL：合法路徑 % 應該已排入佇列', v_valid_path;
  end if;

  select count(*) into v_n from public.purge_storage_queue where object_path = v_wrong_prefix_path;
  if v_n <> 0 then
    raise exception 'FAIL：家庭前綴不符的路徑 % 不該被排入佇列', v_wrong_prefix_path;
  end if;

  select count(*) into v_n from public.purge_storage_queue where object_path = v_bad_shape_path;
  if v_n <> 0 then
    raise exception 'FAIL：形狀不合規的路徑 % 不該被排入佇列', v_bad_shape_path;
  end if;

  raise notice 'ok：purge_storage_queue_enqueue_orphans_v2 正確回報 enqueued=%／dropped=%，且實際排入佇列的內容與 v1 行為一致', v_enqueued, v_dropped;
end;
$$;

rollback;

-- ===========================================================================
-- 7.（LS-222，來源 LS-96 comment c601ccd0）public.orphan_scan_cursor 的專屬
--    grant／RLS 正向對照——這張表是唯一由 purge-storage Edge Function 直接經
--    PostgREST 讀寫（不經 SECURITY DEFINER RPC 包裝）的新表（LS-213 R2 建立），
--    本票（LS-222）觸碰它的分段寫回，`60_default_privileges.sql` 第 1 段的
--    default privileges 通掃只驗證「任何新表對 anon/authenticated 天生零權限」
--    這個機制本身，不是對 orphan_scan_cursor 實際 grant 狀態的專屬斷言——比照
--    第 0 段（F5）對 media 的既有慣例，這裡直接對這張表補正向對照。
-- ===========================================================================
do $$
begin
  if not has_table_privilege('service_role', 'public.orphan_scan_cursor', 'select') then
    raise exception 'FAIL：service_role 沒有 orphan_scan_cursor 的 SELECT grant——purge-storage 的續掃游標讀取會炸';
  end if;
  if not has_table_privilege('service_role', 'public.orphan_scan_cursor', 'insert') then
    raise exception 'FAIL：service_role 沒有 orphan_scan_cursor 的 INSERT grant——第一次寫入游標（該表還是空的）會炸';
  end if;
  if not has_table_privilege('service_role', 'public.orphan_scan_cursor', 'update') then
    raise exception 'FAIL：service_role 沒有 orphan_scan_cursor 的 UPDATE grant——第二次起的續掃游標 upsert 會炸';
  end if;
  if has_table_privilege('service_role', 'public.orphan_scan_cursor', 'delete') then
    raise exception 'FAIL：service_role 竟然有 orphan_scan_cursor 的 DELETE grant（migration 只 grant select, insert, update，見 1d 段既有設計——游標列只會被 upsert 歸零，不會被刪除）';
  end if;

  if has_table_privilege('anon', 'public.orphan_scan_cursor', 'select') then
    raise exception 'FAIL：anon 竟然可以讀 orphan_scan_cursor（這張表只給 purge-storage 的 service_role 用，不是任何登入者看得到的資料）';
  end if;
  if has_table_privilege('anon', 'public.orphan_scan_cursor', 'insert') then
    raise exception 'FAIL：anon 竟然可以寫 orphan_scan_cursor';
  end if;
  if has_table_privilege('authenticated', 'public.orphan_scan_cursor', 'select') then
    raise exception 'FAIL：authenticated 竟然可以讀 orphan_scan_cursor（這張表跟任何使用者身分無關，純粹是 Edge Function 自己跨 invocation 的狀態）';
  end if;
  if has_table_privilege('authenticated', 'public.orphan_scan_cursor', 'insert') then
    raise exception 'FAIL：authenticated 竟然可以寫 orphan_scan_cursor';
  end if;
  if has_table_privilege('authenticated', 'public.orphan_scan_cursor', 'update') then
    raise exception 'FAIL：authenticated 竟然可以更新 orphan_scan_cursor';
  end if;

  if not exists (
    select 1 from pg_class where oid = 'public.orphan_scan_cursor'::regclass and relrowsecurity
  ) then
    raise exception 'FAIL：orphan_scan_cursor 沒有啟用 RLS（migration 1d 段 alter table ... enable row level security）';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orphan_scan_cursor') then
    raise exception 'FAIL：orphan_scan_cursor 竟然有 policy（設計是 RLS enabled＋無 policy，靠 grant 本身把 anon/authenticated 擋在外面，見 migration 1d 段既有說明）';
  end if;

  raise notice 'ok：orphan_scan_cursor 只對 service_role 開 select/insert/update（無 delete），anon／authenticated 皆零權限，RLS enabled 且無 policy';
end;
$$;
