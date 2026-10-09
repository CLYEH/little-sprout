-- LS-430（LS-425 C3a 裁決）—— 飲食記錄專屬的照片不進時間軸。
--
-- C3a：從手機新加進 `child_food_records` 的照片只在該筆記錄內可見，不自動進「飲食記錄系統
-- 相簿」、不進時間軸當日卡。現況（126_food_record_media_orphan.sql 第 4 段先紅證實）：
-- `private.feed_sync_media()` 對每一列 `media` INSERT 都寫 `feed_items(kind='media')`——而
-- 「手機照片」是先 INSERT media、之後才 upsert 記錄綁定，所以 INSERT 當下無從得知它屬於飲食記錄
-- （同 LS-175 `notify_media_created` 檔頭的時間點限制），照片會以獨立照片卡出現在時間軸。
--
-- 做法（沿 LS-378 的「判準函式＋trigger 補刪＋feed_sync_media 同判準」三部件，不加 hidden 欄位）：
--   1. `private.media_hidden_as_food_record_only(family, media)`：照片「是否只屬於飲食記錄」
--      的唯一判準——掛在至少一筆有效（未軟刪）飲食記錄上，且不在任何日記（diary_media）、
--      任何相簿（album_media）。有日記／相簿歸屬的照片（含 03d 從家庭相簿挑到的）時間軸卡
--      照舊，只有「僅屬於飲食記錄」的才隱藏。
--   2. `child_food_records` AFTER INSERT／UPDATE OF media_id, deleted_at trigger：綁上有效記錄
--      時，把符合判準的照片 feed_items 列刪掉（`feed_item_children` 由 FK on delete cascade
--      一併清）。
--   3. `feed_sync_media()` 兩句 INSERT 的 WHERE 補同一判準：這支函式對 media 的每一次 UPDATE
--      都「先刪再寫回」（taken_at／deleted_at／width／height 仍有欄位級 UPDATE grant），不加判準
--      的話，被隱藏的照片只要被改一次欄位就會冒回時間軸（測試案 4b 釘住）。與
--      20260930051701_feed_items_seq.sql 的定義逐字相同，只在兩句 WHERE 各加一條判準。
--
-- 不需要「還原寫回」路徑：不再屬於「僅飲食記錄」只有兩種原因——(i) 記錄刪除／換照片，LS-430
-- 前一支 migration 的 trigger 會把無其他引用的 media 軟刪（軟刪的不該在時間軸）；(ii) 被掛進
-- 日記／相簿，而 app 目前沒有「把既有照片掛進另一篇日記／相簿」的路徑，且連結表增刪不重算是
-- LS-378 已寫明的既有限制，本票沿用，不擴大。
--
-- 已知殘留（刻意接受）：照片上傳到綁定記錄之間（數秒；或 upsert 失敗、使用者放棄時）時間軸
-- 上有一張未歸屬的照片卡——與日記編輯器「先上傳、後 attach」的既有行為相同；放棄／失敗後的
-- 孤兒由 client 軟刪或每日清理（24h）收掉，卡隨軟刪消失。`media_notify_insert`（「新增了 N
-- 張照片」家庭通知）同樣在 INSERT 當下發出，本票不動。
--
-- 破壞性：CREATE OR REPLACE FUNCTION（簽章不變，掛著它的三支 trigger 不必重建）＋新函式＋新
-- trigger，無 DROP／ALTER TABLE／REVOKE。

-- ---------------------------------------------------------------------------
-- 1. 判準函式（definer＋空 search_path，同 media_hidden_by_deleted_diary）
-- ---------------------------------------------------------------------------
create or replace function private.media_hidden_as_food_record_only(p_family_id uuid, p_media_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
           select 1 from public.child_food_records r
            where r.family_id = p_family_id and r.media_id = p_media_id and r.deleted_at is null
         )
     and not exists (
           select 1 from public.diary_media dm
            where dm.family_id = p_family_id and dm.media_id = p_media_id
         )
     and not exists (
           select 1 from public.album_media am
            where am.family_id = p_family_id and am.media_id = p_media_id
         );
$$;

revoke execute on function private.media_hidden_as_food_record_only(uuid, uuid) from public, anon;

comment on function private.media_hidden_as_food_record_only(uuid, uuid) is
  'LS-430：照片是否「只屬於飲食記錄」——掛在至少一筆有效飲食記錄、不在任何日記、不在任何相簿時為'
  ' true（C3a：不進時間軸當日卡）。由 private.feed_sync_media() 與'
  ' private.feed_hide_food_record_media() 共用。';

-- ---------------------------------------------------------------------------
-- 2. 記錄綁上照片 → 移除符合判準的 media 時間軸列
-- ---------------------------------------------------------------------------
create or replace function private.feed_hide_food_record_media()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.feed_items f
   where f.kind = 'media' and f.ref_id = new.media_id and f.family_id = new.family_id
     and private.media_hidden_as_food_record_only(new.family_id, new.media_id);
  return null;
end;
$$;

revoke execute on function private.feed_hide_food_record_media() from public, anon;

comment on function private.feed_hide_food_record_media() is
  'LS-430：child_food_records 綁上（或改綁）照片時，把「只屬於飲食記錄」的 media 自'
  ' feed_items 移除（feed_item_children 由 FK cascade 清）。見 private.'
  'media_hidden_as_food_record_only()。';

create trigger child_food_records_hide_media_feed
  after insert or update of media_id, deleted_at on public.child_food_records
  for each row
  when (new.media_id is not null and new.deleted_at is null)
  execute function private.feed_hide_food_record_media();

-- ---------------------------------------------------------------------------
-- 3. private.feed_sync_media()：兩句 INSERT 補同一判準
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_media()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kept_ids uuid[];
  v_kept_seqs bigint[];
begin
  if tg_op <> 'INSERT' then
    with gone as (
      delete from public.feed_items f using old_rows o
        where f.kind = 'media' and f.ref_id = o.id
      returning f.ref_id, f.seq
    )
    select array_agg(ref_id), array_agg(seq) into v_kept_ids, v_kept_seqs from gone;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at, seq)
      select n.family_id, 'media', n.id, coalesce(n.taken_at, n.created_at),
             coalesce(k.seq, nextval('private.feed_seq'))
        from new_rows n
        left join unnest(v_kept_ids, v_kept_seqs) as k(ref_id, seq) on k.ref_id = n.id
       where n.deleted_at is null
         and not private.media_hidden_by_deleted_diary(n.family_id, n.id)
         and not private.media_hidden_as_food_record_only(n.family_id, n.id);

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'media', n.id, mc.child_id, coalesce(n.taken_at, n.created_at)
        from new_rows n
        join public.media_children mc on mc.media_id = n.id
       where n.deleted_at is null
         and not private.media_hidden_by_deleted_diary(n.family_id, n.id)
         and not private.media_hidden_as_food_record_only(n.family_id, n.id)
    on conflict do nothing;
  end if;
  return null;
end;
$$;
