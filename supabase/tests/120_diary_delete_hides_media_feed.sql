-- LS-378 — 刪除日記時，附帶照片的 feed_items(kind='media') 隨日記自時間軸隱藏
-- （20260924103521_ls378_diary_delete_hide_media_feed.sql）。
--
-- 角色沿用 00_fixtures.sql：A 家（fa…001）member=a2（a0…002，日記作者、可上傳）。
-- 軟刪／還原一律以 a2 身分走 set_diary_deleted（正式路徑），資料準備以 postgres 身分直寫。
--
-- 照片配置（一張照片一個邊界）：
--   m_only    只掛在 D1                          → D1 刪除後隱藏、還原後回來（主案例）
--   m_album   掛在 D1＋fixture 相簿 4a…001        → 邊界 (a)：保留
--   m_shared  掛在 D1＋D2                         → 邊界 (c)：D2 還活著時保留；D2 也刪了才隱藏
--   m_free    沒掛任何日記／相簿                  → 不受影響（對照組）
--
-- Mutation 自證見 LS-378 handoff（每支 mutation 的斷言訊息原文）。

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album  uuid := '4a000000-0000-4000-8000-000000000001';
  v_child  uuid := '2a000000-0000-4000-8000-000000000001';
  v_d1 uuid;
  v_d2 uuid;
  v_m_only uuid;
  v_m_album uuid;
  v_m_shared uuid;
  v_m_free uuid;
  v_occurred timestamptz;
  v_n int;
begin
  -- ---- 資料準備（postgres） -------------------------------------------------
  insert into public.diaries (family_id, author_id, body, entry_date)
  values (v_family, v_author, 'LS-378 D1', current_date) returning id into v_d1;
  insert into public.diaries (family_id, author_id, body, entry_date)
  values (v_family, v_author, 'LS-378 D2', current_date) returning id into v_d2;

  insert into public.media (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_family, v_family || '/2026/09/ls378-only.jpg', 'photo', 1024, now() - interval '3 hours', 100, 100, v_author)
  returning id into v_m_only;
  insert into public.media (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_family, v_family || '/2026/09/ls378-album.jpg', 'photo', 1024, now() - interval '3 hours', 100, 100, v_author)
  returning id into v_m_album;
  insert into public.media (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_family, v_family || '/2026/09/ls378-shared.jpg', 'photo', 1024, now() - interval '3 hours', 100, 100, v_author)
  returning id into v_m_shared;
  insert into public.media (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_family, v_family || '/2026/09/ls378-free.jpg', 'photo', 1024, now() - interval '3 hours', 100, 100, v_author)
  returning id into v_m_free;

  insert into public.diary_media (diary_id, media_id, family_id, sort_order) values
    (v_d1, v_m_only, v_family, 0),
    (v_d1, v_m_album, v_family, 1),
    (v_d1, v_m_shared, v_family, 2),
    (v_d2, v_m_shared, v_family, 0);
  insert into public.album_media (album_id, media_id, family_id, sort_order)
  values (v_album, v_m_album, v_family, 99);
  -- m_only 標了寶貝：驗還原時 feed_item_children 一併寫回（寶貝篩選下也回來）
  insert into public.media_children (family_id, media_id, child_id) values (v_family, v_m_only, v_child);

  select count(*) into v_n from public.feed_items
   where kind = 'media' and ref_id in (v_m_only, v_m_album, v_m_shared, v_m_free);
  if v_n <> 4 then
    raise exception 'SETUP FAIL：四張照片刪日記前應全在 feed_items，實際 % 張', v_n;
  end if;
  if not exists (select 1 from public.feed_item_children where kind = 'media' and ref_id = v_m_only and child_id = v_child) then
    raise exception 'SETUP FAIL：m_only 標了寶貝，刪日記前 feed_item_children 應有對應列';
  end if;

  -- ---- 1. 作者軟刪 D1 ----------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_d1, true);

  -- 走時間軸 RPC（iOS 實際讀的入口）確認 m_only 消失、其餘三張仍在
  if exists (select 1 from public.get_family_timeline(v_family, null, null, null, 100) t
              where t.kind = 'media' and t.ref_id = v_m_only) then
    raise exception 'FAIL：刪除日記 D1 後，只掛在 D1 的照片仍出現在 get_family_timeline（日記刪了照片還在）';
  end if;
  if exists (select 1 from public.get_family_timeline(v_family, v_child, null, null, 100) t
              where t.kind = 'media' and t.ref_id = v_m_only) then
    raise exception 'FAIL：刪除日記 D1 後，只掛在 D1 的照片仍出現在寶貝篩選的 get_family_timeline（feed_item_children 沒跟著清）';
  end if;
  reset role;

  if exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_only) then
    raise exception 'FAIL：刪除日記 D1 後，只掛在 D1 的照片的 feed_items(kind=media) 仍在';
  end if;
  if not exists (select 1 from public.media where id = v_m_only and deleted_at is null) then
    raise exception 'FAIL：刪除日記只該動 feed 層，media 列本身卻不見或被軟刪了（190a 裁決：照片本身不動）';
  end if;
  if not exists (select 1 from public.diary_media where diary_id = v_d1 and media_id = v_m_only) then
    raise exception 'FAIL：刪除日記不該動 diary_media 連結（還原要靠它把照片寫回）';
  end if;
  if not exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_album) then
    raise exception 'FAIL（邊界 a）：照片同時在相簿裡，刪除日記後 feed_items 卻被移除了——相簿照片應留在時間軸';
  end if;
  if not exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_shared) then
    raise exception 'FAIL（邊界 c）：照片同時掛在另一篇未刪的日記 D2，刪除 D1 後 feed_items 卻被移除了';
  end if;
  if not exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_free) then
    raise exception 'FAIL：沒掛任何日記的照片不該受刪日記影響，feed_items 卻不見了';
  end if;
  raise notice 'ok：刪除 D1 → 只掛在 D1 的照片自時間軸（含寶貝篩選）消失，media／diary_media 列仍在；相簿內（a）、他日記共用（c）、無關照片的 feed 皆保留';

  -- ---- 2. 被隱藏的照片之後被 UPDATE，不得重新冒回時間軸 -------------------------
  -- feed_sync_media 對 media 每次 UPDATE 都先刪再寫回；authenticated 有 width 等欄位級
  -- UPDATE grant，這裡用上傳者本人走 RLS 改一次。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.media set width = 200 where id = v_m_only;
  reset role;
  if (select width from public.media where id = v_m_only) <> 200 then
    raise exception 'SETUP FAIL：上傳者對 m_only 的 UPDATE 沒有生效，本段前提不成立';
  end if;
  if exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_only) then
    raise exception 'FAIL：日記已刪的照片被 UPDATE 一次（width）後重新出現在 feed_items——feed_sync_media 的寫回沒套用隱藏判準';
  end if;
  raise notice 'ok：日記已刪的照片被 UPDATE 後仍不在時間軸';

  -- ---- 3. 共用照片的最後一篇日記也刪了 → 才隱藏 ------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_d2, true);
  reset role;
  if exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_shared) then
    raise exception 'FAIL（邊界 c）：共用照片的兩篇日記都刪了，feed_items 仍在';
  end if;
  if not exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_album) then
    raise exception 'FAIL（邊界 a）：相簿內的照片在兩篇日記都刪後被移除了';
  end if;
  raise notice 'ok：共用照片在最後一篇日記（D2）也刪除時才隱藏；相簿照片仍保留';

  -- ---- 4. 還原 D1（邊界 b：對稱復原）---------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_d1, false);
  if not exists (select 1 from public.get_family_timeline(v_family, null, null, null, 100) t
                  where t.kind = 'media' and t.ref_id = v_m_only) then
    raise exception 'FAIL（邊界 b）：還原日記 D1 後，它的照片沒有回到 get_family_timeline';
  end if;
  if not exists (select 1 from public.get_family_timeline(v_family, v_child, null, null, 100) t
                  where t.kind = 'media' and t.ref_id = v_m_only) then
    raise exception 'FAIL（邊界 b）：還原日記 D1 後，標了寶貝的照片沒有回到寶貝篩選的時間軸（feed_item_children 沒寫回）';
  end if;
  reset role;

  select occurred_at into v_occurred from public.feed_items where kind = 'media' and ref_id = v_m_only;
  if v_occurred is distinct from (select coalesce(taken_at, created_at) from public.media where id = v_m_only) then
    raise exception 'FAIL（邊界 b）：還原寫回的 occurred_at（%）與 feed_sync_media 口徑 coalesce(taken_at, created_at) 不一致', v_occurred;
  end if;
  if not exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_shared) then
    raise exception 'FAIL（邊界 b／c）：還原 D1 後，D1 裡的共用照片（D2 仍刪除）沒有寫回';
  end if;
  select count(*) into v_n from public.feed_items where kind = 'media' and ref_id = v_m_album;
  if v_n <> 1 then
    raise exception 'FAIL：還原 D1 後，原本就在時間軸的相簿照片應恰好 1 列，實際 %', v_n;
  end if;
  raise notice 'ok：還原 D1 → 照片（含寶貝篩選列）寫回，occurred_at 同 feed_sync_media 口徑；已在時間軸的相簿照片不重複';

  -- ---- 5. 照片本身已軟刪 → 還原日記不得把它寫回 ------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_d1, true);
  update public.media set deleted_at = now() where id = v_m_only;
  perform public.set_diary_deleted(v_d1, false);
  reset role;
  if exists (select 1 from public.feed_items where kind = 'media' and ref_id = v_m_only) then
    raise exception 'FAIL：照片本身已軟刪，還原日記時卻把它寫回了 feed_items';
  end if;
  raise notice 'ok：照片本身已軟刪時，還原日記不會把它寫回時間軸';
end;
$$;

rollback;
