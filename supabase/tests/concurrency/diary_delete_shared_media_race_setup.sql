-- LS-378 併發場景「兩篇共用同一張照片的日記被兩個交易同時刪除」的場景資料。
--
-- 沒有 media 列鎖時是 write skew：S1 刪 D1、S2 刪 D2，各自的快照都看到「另一篇還活著」，
-- 兩邊都判定照片保留，兩篇都刪了照片卻還在時間軸。修法見
-- 20260924103521_ls378_diary_delete_hide_media_feed.sql 檔頭「併發」段（trigger 先對
-- 涉及的 media 列取 FOR NO KEY UPDATE 鎖，後到者等先到者 commit 後以新快照判定）。
--
-- 每次執行前重建（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'f3780000-0000-4000-8000-000000000001';
delete from auth.users where id = 'd3780000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('d3780000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'diary-shared-media-race-owner@ls378.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('d3780000-0000-4000-8000-000000000001', '共用照片刪日記競態家 owner')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f3780000-0000-4000-8000-000000000001', '共用照片刪日記競態家', 'd3780000-0000-4000-8000-000000000001');

insert into public.diaries (id, family_id, author_id, body, entry_date) values
  ('53780000-0000-4000-8000-000000000001', 'f3780000-0000-4000-8000-000000000001',
   'd3780000-0000-4000-8000-000000000001', 'LS-378 競態 D1', current_date),
  ('53780000-0000-4000-8000-000000000002', 'f3780000-0000-4000-8000-000000000001',
   'd3780000-0000-4000-8000-000000000001', 'LS-378 競態 D2', current_date);

insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
  ('33780000-0000-4000-8000-000000000001', 'f3780000-0000-4000-8000-000000000001',
   'f3780000-0000-4000-8000-000000000001/2026/09/33780000-0000-4000-8000-000000000001.jpg',
   'photo', 400000, now(), 10, 10, 'd3780000-0000-4000-8000-000000000001');

insert into public.diary_media (diary_id, media_id, family_id, sort_order) values
  ('53780000-0000-4000-8000-000000000001', '33780000-0000-4000-8000-000000000001',
   'f3780000-0000-4000-8000-000000000001', 0),
  ('53780000-0000-4000-8000-000000000002', '33780000-0000-4000-8000-000000000001',
   'f3780000-0000-4000-8000-000000000001', 0);

do $$
begin
  if not exists (select 1 from public.feed_items
                  where kind = 'media' and ref_id = '33780000-0000-4000-8000-000000000001') then
    raise exception 'SETUP FAIL：共用照片初始應在 feed_items';
  end if;
  raise notice 'ok setup：共用照片刪日記競態家就緒，照片同時掛在 D1／D2 且在時間軸';
end;
$$;
