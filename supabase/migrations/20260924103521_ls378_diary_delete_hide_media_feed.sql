-- LS-378（LS-190 QA 附帶發現，使用者 2026-09-24 裁 190a）—— 刪除日記時，附帶照片的
-- `feed_items(kind='media')` 隨日記自時間軸隱藏（只動 feed 層，照片本身與相簿不動）。
--
-- 現況（實作前核對）：
--   - 照片與日記的關聯只在 `public.diary_media`（20260822120000_init_schema.sql:216）；
--     `media` 本身不知道自己掛在哪裡。
--   - 日記軟刪／還原唯一路徑是 `public.set_diary_deleted(p_diary_id, p_deleted)`
--     （20260824010000_diaries_write_path_and_timeline.sql:211，只寫 deleted_at），另有
--     帳號刪除／停權流程對作者全部日記的批次 `update public.diaries set deleted_at`。
--     還原（p_deleted=false）存在，所以票面邊界 (b)「有復原路徑才對稱復原」成立。
--   - `private.feed_sync_diaries()` 只清日記自己那一列 feed_items（kind='diary'）；
--     附帶照片的 feed_items(kind='media') 由 `private.feed_sync_media()` 維護
--     （20260822120100_triggers.sql:141，最新定義在 20260917155738_media_children.sql:131），
--     只看 media.deleted_at——日記被刪，照片那一列原封不動，於是「日記刪了照片還在」。
--
-- 做法：沿既有「軟刪 → 從 feed_items 刪列、還原 → 寫回」的寫法（不加 hidden 欄位），
-- 三個部件共用同一個判準函式：
--   1. private.media_hidden_by_deleted_diary()：一張照片「該不該因為日記被刪而從時間軸
--      消失」的唯一判準。
--   2. diaries 新增一支 AFTER UPDATE statement-level trigger：deleted_at 由 NULL→非 NULL
--      時刪掉符合判準的照片 feed 列；非 NULL→NULL（還原）時把該日記的照片寫回。
--   3. private.feed_sync_media()（CREATE OR REPLACE）：INSERT 分支加上同一個判準。
--      這支函式對 media 的**每一次** UPDATE 都「先刪再寫回」（authenticated 仍有
--      taken_at／deleted_at／width／height 的欄位級 UPDATE grant），不加判準的話，
--      被隱藏的照片只要被改一次欄位就會重新冒回時間軸。
--   另有一次性回填（第 4 段）：本 migration 之前就已軟刪、仍在 30 天救援窗內的日記，
--   附帶照片同樣移除（見第 4 段理由）。
--
-- 判準（票面邊界 a／c 的取捨）：照片**至少掛在一篇已軟刪的日記**，且**沒有掛在任何
-- 未刪的日記**，且**沒有掛在任何相簿（album_media）**時才隱藏。
--   (a) 也在相簿裡 → 保留。相簿是使用者「刻意收藏這張照片」的地方，時間軸上的照片卡
--       本來就同時代表「相簿裡的這張照片」；使用者裁的是「照片仍留相簿」，時間軸只少
--       日記那一組。相簿本身被軟刪時是否也要連帶隱藏不在本票範圍（相簿軟刪目前也不動
--       media 的 feed 列），所以這裡只看 album_media 有沒有連結、不看 albums.deleted_at，
--       避免在本票偷偷引進「相簿軟刪隱藏照片」的新語意。
--   (c) 也掛在另一篇未刪的日記 → 保留；等那一篇也被刪，最後一篇被刪時才隱藏。
--   沒有掛在任何日記的照片（例如只在相簿、或上傳後尚未連結）→ 判準恆為 false，不受影響。
--
-- 已知不涵蓋（寫明，不是遺漏）：判準只在「日記軟刪／還原」與「media 本身寫入」時求值；
-- 之後才對 diary_media／album_media 增刪連結（例如把已隱藏的照片掛進相簿）不會重算。
-- 目前 app 沒有這條路徑——日記與相簿「加入照片」一律是新上傳一列 media 再連結
-- （SupabaseDiaryAPIClient.attachMedia／SupabaseAlbumsAPIClient 皆然），沒有「把既有照片
-- 掛進另一篇日記／相簿」或「移除連結」的 UI；日後開這種功能時要回頭補連結表的 trigger。
--
-- 併發：兩篇共用同一張照片的日記被兩個交易同時刪除時，各自的快照都看到「另一篇還活著」，
-- 兩邊都判定保留，最後兩篇都刪了照片卻還在（write skew）；日記刪除與同一張照片的 UPDATE
-- 同時發生也有同型的問題（feed_sync_media 用舊快照判定「日記還活著」而寫回）。第 2 段的
-- trigger 在判定前先對涉及的 media 列取 FOR NO KEY UPDATE 鎖（依 id 排序，避免 ABBA）：
-- 後到的交易會等先到的 commit，READ COMMITTED 下下一句 SQL 取新快照，看得到對方的結果。
-- media 列的 UPDATE 本身就持有同一把列鎖，所以 feed_sync_media 那側不必另外取鎖。
-- 鎖序：既有會同時寫 diaries 與 media 的函式（delete_account_media／停權流程）都是先
-- diaries 後 media，與本 trigger（diaries UPDATE 之後才鎖 media）同向。
--
-- 本檔沒有 DROP／TRUNCATE／改欄位型別；第 3 段是對既有 private.feed_sync_media() 的
-- CREATE OR REPLACE（簽章不變、掛著它的三支 trigger 不必重建）。

-- ---------------------------------------------------------------------------
-- 1. 判準函式
--
-- 三個子查詢都帶 family_id，走既有 diary_media_media_idx／album_media_media_idx
-- （(family_id, media_id)，init_schema.sql:229 與 album_media 同型）。
-- security definer：schema private 的函式一律 definer＋空 search_path
-- （supabase/tests/60_default_privileges.sql 第 9 段通掃）；呼叫端兩支 trigger 函式本身
-- 也是 definer，讀 diary_media／album_media／diaries 不受呼叫者 RLS 影響。
-- ---------------------------------------------------------------------------
create or replace function private.media_hidden_by_deleted_diary(p_family_id uuid, p_media_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
           select 1
             from public.diary_media dm
             join public.diaries d on d.id = dm.diary_id
            where dm.family_id = p_family_id and dm.media_id = p_media_id
              and d.deleted_at is not null
         )
     and not exists (
           select 1
             from public.diary_media dm
             join public.diaries d on d.id = dm.diary_id
            where dm.family_id = p_family_id and dm.media_id = p_media_id
              and d.deleted_at is null
         )
     and not exists (
           select 1
             from public.album_media am
            where am.family_id = p_family_id and am.media_id = p_media_id
         );
$$;

revoke execute on function private.media_hidden_by_deleted_diary(uuid, uuid) from public, anon;

comment on function private.media_hidden_by_deleted_diary(uuid, uuid) is
  'LS-378：照片是否因附帶的日記被軟刪而自時間軸隱藏——至少掛在一篇已軟刪日記、沒有掛在'
  '任何未刪日記、也不在任何相簿（album_media）時為 true。由 private.feed_sync_media() 與'
  ' private.feed_sync_diary_media_visibility() 共用，見 20260924103521 檔頭。';

-- ---------------------------------------------------------------------------
-- 2. diaries 軟刪／還原 → 附帶照片的 feed_items(kind='media')
--
-- 獨立一支 trigger，不改 private.feed_sync_diaries()：後者只負責日記自己那一列
-- （kind='diary'），兩件事互不依賴、觸發順序無關。
-- 只處理 deleted_at 真的翻轉的列：編輯內容（update_diary_entry）、對已刪日記再刪一次
-- （set_diary_deleted 重複呼叫會刷新 deleted_at）都不動照片。
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_diary_media_visibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from old_rows o join new_rows n on n.id = o.id
     where (o.deleted_at is null) <> (n.deleted_at is null)
  ) then
    return null;
  end if;

  -- 併發：先鎖住涉及的 media 列（理由見檔頭「併發」段）。
  perform 1
    from public.media m
   where m.id in (
     select dm.media_id
       from old_rows o
       join new_rows n on n.id = o.id
       join public.diary_media dm on dm.family_id = n.family_id and dm.diary_id = n.id
      where (o.deleted_at is null) <> (n.deleted_at is null)
   )
   order by m.id
   for no key update;

  -- 軟刪：移除「只掛在已軟刪日記、不在相簿」的照片（feed_item_children 由 FK
  -- on delete cascade 一併清掉，同 feed_sync_media 的既有刪除路徑）。
  delete from public.feed_items f
   where f.kind = 'media'
     and f.ref_id in (
       select dm.media_id
         from old_rows o
         join new_rows n on n.id = o.id
         join public.diary_media dm on dm.family_id = n.family_id and dm.diary_id = n.id
        where o.deleted_at is null and n.deleted_at is not null
     )
     and private.media_hidden_by_deleted_diary(f.family_id, f.ref_id);

  -- 還原：把該日記的照片寫回（照片本身已軟刪的不寫回；已經在 feed 裡的——例如也在
  -- 相簿、或掛在另一篇未刪日記——on conflict 略過）。欄位與 occurred_at 口徑逐字沿用
  -- private.feed_sync_media() 的 INSERT 分支；feed_item_children 同理，依 media_children
  -- 當下的集合展開（還原動作沒有動到 media_children，連結表自己的 trigger 不會觸發）。
  insert into public.feed_items (family_id, kind, ref_id, occurred_at)
    select m.family_id, 'media', m.id, coalesce(m.taken_at, m.created_at)
      from public.media m
     where m.deleted_at is null
       and m.id in (
         select dm.media_id
           from old_rows o
           join new_rows n on n.id = o.id
           join public.diary_media dm on dm.family_id = n.family_id and dm.diary_id = n.id
          where o.deleted_at is not null and n.deleted_at is null
       )
  on conflict (kind, ref_id) do nothing;

  insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
    select m.family_id, 'media', m.id, mc.child_id, coalesce(m.taken_at, m.created_at)
      from public.media m
      join public.media_children mc on mc.media_id = m.id
     where m.deleted_at is null
       and m.id in (
         select dm.media_id
           from old_rows o
           join new_rows n on n.id = o.id
           join public.diary_media dm on dm.family_id = n.family_id and dm.diary_id = n.id
          where o.deleted_at is not null and n.deleted_at is null
       )
  on conflict do nothing;

  return null;
end;
$$;

create trigger diaries_media_feed_visibility after update on public.diaries
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.feed_sync_diary_media_visibility();

-- ---------------------------------------------------------------------------
-- 3. private.feed_sync_media()：INSERT 分支加判準
--
-- 與 20260917155738_media_children.sql:131 的定義逐字相同，只在兩句 INSERT 的 WHERE
-- 各加一條 `and not private.media_hidden_by_deleted_diary(n.family_id, n.id)`。
-- 新上傳（tg_op='INSERT'）時照片還沒有任何 diary_media 連結，判準恆為 false，行為不變。
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_media()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'media' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
      select n.family_id, 'media', n.id, coalesce(n.taken_at, n.created_at)
        from new_rows n
       where n.deleted_at is null
         and not private.media_hidden_by_deleted_diary(n.family_id, n.id);

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'media', n.id, mc.child_id, coalesce(n.taken_at, n.created_at)
        from new_rows n
        join public.media_children mc on mc.media_id = n.id
       where n.deleted_at is null
         and not private.media_hidden_by_deleted_diary(n.family_id, n.id)
    on conflict do nothing;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. 一次性回填：本 migration 之前就已軟刪（仍在 30 天救援窗內）的日記
--
-- 第 2 段的 trigger 只在之後的 deleted_at 翻轉時觸發；不回填的話，正式站上已經刪掉
-- 的日記，附帶照片會一直留在時間軸直到 30 天後硬刪——正是本票要修的症狀（同
-- 20260824010000 F3「ADD COLUMN 不會觸發 trigger、既有列要回填」的教訓）。
-- 這裡刪的是 trigger 維護的衍生列：日記還原時第 2 段會寫回，不是資料消失。
-- 天生冪等：重跑時符合條件的列已經不在。
-- ---------------------------------------------------------------------------
delete from public.feed_items f
 where f.kind = 'media'
   and exists (
     select 1
       from public.diary_media dm
       join public.diaries d on d.id = dm.diary_id
      where dm.family_id = f.family_id and dm.media_id = f.ref_id
        and d.deleted_at is not null
   )
   and private.media_hidden_by_deleted_diary(f.family_id, f.ref_id);
