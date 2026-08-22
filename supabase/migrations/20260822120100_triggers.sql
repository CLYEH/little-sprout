-- LS-6 — DB 層的不變量（invariants）
--
-- 這裡的三組 trigger 對應 PLAN §5 最後三條「其他約束」與 §10-A：
--   1. 每個 family 恆有 ≥1 位 owner（§5、§9-A2：這條是帳號刪除流程能成立的基礎）
--   2. feed_items 由 trigger 維護（§5：事後補要重寫整個首頁查詢）
--   3. families.storage_used_bytes 由 media 的新增／刪除維護，並在超額時擋下上傳（§10-A 硬防線）
--
-- 一律用 statement-level trigger + transition table，不用 row-level：
--   - 一次上傳 50 張照片是常態（PLAN §4 推播彙總、Phase 1-4 背景上傳），row-level 會對同一個
--     families 列做 50 次 UPDATE，等於把同家庭的併發上傳序列化成 50 段鎖等待。
--   - statement-level 一句 SQL 聚合完，每個 statement 對每個 family 只鎖一次。
-- 所有函式都是 SECURITY DEFINER：它們必須看到完整資料才能判斷不變量，
-- 若受呼叫者的 RLS 影響（例如看不到別人的 owner 列）會做出錯誤結論。

-- ---------------------------------------------------------------------------
-- 1. 每個 family 恆有 ≥1 位 owner
-- ---------------------------------------------------------------------------

-- 建立家庭時把建立者寫成 owner：讓「恆有 ≥1 owner」從家庭誕生的那一刻就成立
-- （否則 INSERT family 與 INSERT member 之間存在一個沒有 owner 的空窗，
--  而且 family_members 的 INSERT policy 只允許 owner 加人，新家庭會鎖死自己）。
-- 同時滿足 §9-C5：全新使用者在沒有任何邀請碼的情況下必須能自己建立家庭。
create or replace function private.add_creator_as_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.created_by is not null then
    insert into public.family_members (family_id, user_id, role, can_upload)
    values (new.id, new.created_by, 'owner', true);
  end if;
  return null;
end;
$$;

create trigger families_add_creator_as_owner
  after insert on public.families
  for each row execute function private.add_creator_as_owner();

-- DELETE 與 UPDATE role 時檢查。用 statement-level + transition table 的關鍵理由：
-- 「把 A 降級、同時把 B 升為 owner」若寫成一句 UPDATE，row-level trigger 會在處理到 A 那列時
-- 誤判成沒有 owner。statement 結束後才檢查才是正確的時點。
create or replace function private.enforce_family_has_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_family_id uuid;
  v_lock uuid;
begin
  -- order by：本函式會取列鎖，兩個交易若以相反順序處理同一組家庭就會死鎖。
  -- 固定成 family_id 遞增，同一組家庭的鎖取得順序就一致。
  for v_family_id in select distinct family_id from removed_members order by 1 loop
    -- 先鎖住家庭列，再檢查 owner —— 這一行是正確性的關鍵，不是效能調整：
    -- READ COMMITTED 下「A 降級」與「B 降級」動到的是 family_members 的不同列，彼此不衝突，
    -- 若只讀不鎖，兩個交易都會看到「還有另一位 owner」而各自放行，commit 之後家庭剩 0 位 owner。
    -- 0 owner 的家庭沒有任何自救路徑（加人／改角色／刪內容／處理檢舉的 policy 全都要求 owner），
    -- 等於永久磚化。鎖住 families 列讓同一個家庭的降級／移除排隊，後到的那個才會讀到真實狀態。
    -- 序列化的範圍只有「同一個家庭的成員異動」，不同家庭之間互不影響。
    -- FOR NO KEY UPDATE 而非 FOR UPDATE：FOR UPDATE 與子表 FK 檢查取的 FOR KEY SHARE 互斥，
    -- 「先插子表、再動成員」的兩個併發交易會互相死鎖（reviewer 實測重現）；
    -- NO KEY UPDATE 不與 FOR KEY SHARE 衝突，但仍與自身互斥，序列化效果不變（reviewer 實測驗證）。
    select f.id into v_lock from public.families f where f.id = v_family_id for no key update;

    -- 找不到家庭 = 家庭本身被刪除（成員是 cascade 掉的），此時不需要 owner，不該報錯
    if v_lock is null then
      continue;
    end if;

    if not exists (
      select 1 from public.family_members m
      where m.family_id = v_family_id and m.role = 'owner'
    ) then
      raise exception '家庭 % 必須至少保留一位 owner（請先指派新 owner，再移除或降級原 owner）', v_family_id
        using errcode = 'LS001';
    end if;
  end loop;
  return null;
end;
$$;

create trigger family_members_owner_guard_delete
  after delete on public.family_members
  referencing old table as removed_members
  for each statement execute function private.enforce_family_has_owner();

-- 註：Postgres 不允許「有 transition table 的 trigger」再帶欄位清單
-- （after update OF role …），所以這裡對所有 UPDATE 都檢查一次。
-- 代價只有一次 EXISTS 查詢，換到的是「不可能有漏網的 UPDATE 路徑」。
create trigger family_members_owner_guard_update
  after update on public.family_members
  referencing old table as removed_members
  for each statement execute function private.enforce_family_has_owner();

-- ---------------------------------------------------------------------------
-- 2. feed_items 維護
--
-- occurred_at 的取法（時間軸要混排三種內容，排序語意必須一致）：
--   album → created_at（相簿沒有自己的「發生時間」）
--   media → coalesce(taken_at, created_at)（照片屬於它被拍的那天，EXIF 缺失才退回上傳時間）
--   diary → entry_date（補寫昨天的日記要出現在昨天，這正是 entry_date 存在的理由）
-- soft delete 的內容直接從 feed 移除；還原（deleted_at 設回 NULL）會再寫回來。
--
-- 三張表各一個函式而不是共用一個泛型函式：plpgsql 會快取語句計畫，
-- 同一個函式被掛在不同資料表的 transition table 上是計畫快取的已知地雷，不值得為省 20 行去踩。
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_albums()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'album' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
      select n.family_id, 'album', n.id, n.created_at
        from new_rows n where n.deleted_at is null;
  end if;
  return null;
end;
$$;

create trigger albums_feed_insert after insert on public.albums
  referencing new table as new_rows
  for each statement execute function private.feed_sync_albums();
create trigger albums_feed_update after update on public.albums
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.feed_sync_albums();
create trigger albums_feed_delete after delete on public.albums
  referencing old table as old_rows
  for each statement execute function private.feed_sync_albums();

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
        from new_rows n where n.deleted_at is null;
  end if;
  return null;
end;
$$;

create trigger media_feed_insert after insert on public.media
  referencing new table as new_rows
  for each statement execute function private.feed_sync_media();
create trigger media_feed_update after update on public.media
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.feed_sync_media();
create trigger media_feed_delete after delete on public.media
  referencing old table as old_rows
  for each statement execute function private.feed_sync_media();

create or replace function private.feed_sync_diaries()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'diary' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    -- entry_date 是 date，轉 timestamptz 一定要指定時區口徑。
    -- 直接 `::timestamptz` 會吃呼叫端 session 的 TimeZone：同一篇日記由台北與倫敦的連線寫入，
    -- occurred_at 會差 8 小時，時間軸的排序與「補寫昨天的日記」語意就不穩定。
    -- 固定用 UTC 午夜，讓 occurred_at 只由 entry_date 決定。
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
      select n.family_id, 'diary', n.id, (n.entry_date::timestamp at time zone 'utc')
        from new_rows n where n.deleted_at is null;
  end if;
  return null;
end;
$$;

create trigger diaries_feed_insert after insert on public.diaries
  referencing new table as new_rows
  for each statement execute function private.feed_sync_diaries();
create trigger diaries_feed_update after update on public.diaries
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.feed_sync_diaries();
create trigger diaries_feed_delete after delete on public.diaries
  referencing old table as old_rows
  for each statement execute function private.feed_sync_diaries();

-- ---------------------------------------------------------------------------
-- 3. families.storage_used_bytes 維護 + 額度硬防線（§10-A）
--
-- 口徑：storage_used_bytes = 該家庭所有「未 soft delete」media 的 byte_size 總和。
-- soft delete 會立刻釋放額度（誤刪救援期間仍佔用實體 bucket，但不佔使用者的額度——
-- 對使用者而言「刪了就該還我空間」，實體清理由日後的清理排程處理）。
-- 額度超過時 raise：這是硬防線，就算 app 端忘了擋也進不來。
-- ---------------------------------------------------------------------------
create or replace function private.media_storage_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_over uuid;
begin
  if tg_op = 'INSERT' then
    update public.families f
       set storage_used_bytes = f.storage_used_bytes + d.bytes
      from (select n.family_id, sum(n.byte_size) as bytes
              from new_rows n where n.deleted_at is null group by n.family_id) d
     where f.id = d.family_id;

  elsif tg_op = 'DELETE' then
    -- 已 soft delete 的列先前就已經從計數扣掉了，這裡不能重扣
    update public.families f
       set storage_used_bytes = f.storage_used_bytes - d.bytes
      from (select o.family_id, sum(o.byte_size) as bytes
              from old_rows o where o.deleted_at is null group by o.family_id) d
     where f.id = d.family_id;

  else
    update public.families f
       set storage_used_bytes = f.storage_used_bytes + d.bytes
      from (
        select s.family_id, sum(s.bytes) as bytes from (
          select n.family_id, case when n.deleted_at is null then n.byte_size else 0 end as bytes
            from new_rows n
          union all
          select o.family_id, - (case when o.deleted_at is null then o.byte_size else 0 end)
            from old_rows o
        ) s group by s.family_id
      ) d
     where f.id = d.family_id and d.bytes <> 0;
  end if;

  if tg_op <> 'DELETE' then
    select f.id into v_over
      from public.families f
     where f.id in (select distinct n.family_id from new_rows n)
       and f.storage_used_bytes > f.storage_quota_bytes
     limit 1;

    if v_over is not null then
      raise exception '家庭 % 已達儲存額度上限，無法再上傳', v_over
        using errcode = 'LS002';
    end if;
  end if;

  return null;
end;
$$;

create trigger media_storage_insert after insert on public.media
  referencing new table as new_rows
  for each statement execute function private.media_storage_sync();
create trigger media_storage_update after update on public.media
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.media_storage_sync();
create trigger media_storage_delete after delete on public.media
  referencing old table as old_rows
  for each statement execute function private.media_storage_sync();
