-- LS-6：由 trigger 維護的兩個衍生狀態
--   feed_items（PLAN §5「為什麼第一天就要有」）
--   families.storage_used_bytes（§10-A 成本硬防線）
--
-- 兩者都是「資料庫自己算」的欄位，app 端不會也不該去維護它們；
-- 一旦 trigger 有洞，錯誤會安靜地累積（時間軸缺項、額度算錯放行超量上傳），
-- 所以每一條路徑（新增／soft delete／還原／硬刪／一次多列）都要有測試。

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- feed_items
-- ---------------------------------------------------------------------------
do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_media uuid;
  v_diary uuid;
  v_album uuid;
  v_at timestamptz;
  v_n int;
  v_taken timestamptz := now() - interval '400 days';
begin
  -- 相簿：occurred_at = created_at
  insert into public.albums (family_id, title, created_by)
  values (v_family, '測試相簿', 'a0000000-0000-4000-8000-000000000001')
  returning id into v_album;
  select occurred_at into v_at from public.feed_items where kind = 'album' and ref_id = v_album;
  if v_at is null then raise exception 'FAIL：新增相簿沒有產生 feed_items'; end if;

  -- 照片：有 taken_at 就用 taken_at（照片屬於它被拍的那天，不是被上傳的那天）
  insert into public.media (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (v_family, v_family || '/2026/08/feed-1.jpg', 'photo', 10, v_taken, 100, 100,
          'a0000000-0000-4000-8000-000000000001')
  returning id into v_media;
  select occurred_at into v_at from public.feed_items where kind = 'media' and ref_id = v_media;
  if v_at is distinct from v_taken then
    raise exception 'FAIL：media 的 feed occurred_at 應為 taken_at %，實際 %', v_taken, v_at;
  end if;

  -- 日記：用 entry_date（補寫昨天的日記要出現在昨天）
  insert into public.diaries (family_id, author_id, body, entry_date)
  values (v_family, 'a0000000-0000-4000-8000-000000000001', '補寫的日記', date '2020-01-01')
  returning id into v_diary;
  select occurred_at into v_at from public.feed_items where kind = 'diary' and ref_id = v_diary;
  if v_at is distinct from (date '2020-01-01')::timestamptz then
    raise exception 'FAIL：diary 的 feed occurred_at 應為 entry_date，實際 %', v_at;
  end if;
  raise notice 'ok feed：album/media/diary 新增都會進時間軸，occurred_at 取法正確';

  -- soft delete → 從時間軸消失；還原 → 回來（§5 誤刪救援路徑）
  update public.media set deleted_at = now() where id = v_media;
  select count(*) into v_n from public.feed_items where kind = 'media' and ref_id = v_media;
  if v_n <> 0 then raise exception 'FAIL：soft delete 後 feed_items 還在'; end if;

  update public.media set deleted_at = null where id = v_media;
  select count(*) into v_n from public.feed_items where kind = 'media' and ref_id = v_media;
  if v_n <> 1 then raise exception 'FAIL：還原後 feed_items 沒有回來'; end if;
  raise notice 'ok feed：soft delete 移除、還原後回到時間軸';

  -- 硬刪 → 一併移除（feed_items 是多型關聯，沒有外鍵可以幫忙 cascade）
  delete from public.media where id = v_media;
  select count(*) into v_n from public.feed_items where kind = 'media' and ref_id = v_media;
  if v_n <> 0 then raise exception 'FAIL：硬刪後 feed_items 沒有跟著移除'; end if;
  raise notice 'ok feed：硬刪同步移除時間軸項目';

  -- 一次 INSERT 多列（批次上傳 50 張是常態）：statement-level trigger 必須每列都處理到
  insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
  select v_family, v_family || '/2026/08/bulk-' || i || '.jpg', 'photo', 10, 100, 100,
         'a0000000-0000-4000-8000-000000000001'
    from generate_series(1, 5) i;
  select count(*) into v_n from public.feed_items f
   where f.kind = 'media'
     and f.ref_id in (select m.id from public.media m
                       where m.storage_path like v_family || '/2026/08/bulk-%');
  if v_n <> 5 then raise exception 'FAIL：一次插 5 列只產生 % 列 feed_items', v_n; end if;
  raise notice 'ok feed：一句 INSERT 5 列 → 5 列時間軸項目';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- storage_used_bytes
-- ---------------------------------------------------------------------------
begin;
do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_base bigint;
  v_used bigint;
  v_id uuid;
begin
  select storage_used_bytes into v_base from public.families where id = v_family;

  -- 一句 INSERT 三列 → 一次加總，不是三次各加一次
  insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
  select v_family, v_family || '/2026/08/q-' || i || '.jpg', 'photo', 1000, 100, 100, v_owner
    from generate_series(1, 3) i;
  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> v_base + 3000 then
    raise exception 'FAIL 用量：插入 3×1000 後應為 %，實際 %', v_base + 3000, v_used;
  end if;

  select id into v_id from public.media
   where family_id = v_family and storage_path = v_family || '/2026/08/q-1.jpg';

  -- soft delete 立刻釋放額度
  update public.media set deleted_at = now() where id = v_id;
  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> v_base + 2000 then
    raise exception 'FAIL 用量：soft delete 後應為 %，實際 %', v_base + 2000, v_used;
  end if;

  -- 還原要加回來
  update public.media set deleted_at = null where id = v_id;
  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> v_base + 3000 then
    raise exception 'FAIL 用量：還原後應為 %，實際 %', v_base + 3000, v_used;
  end if;

  -- 已 soft delete 的列被硬刪，不能重複扣（會把用量算成負的）
  update public.media set deleted_at = now() where id = v_id;
  delete from public.media where id = v_id;
  select storage_used_bytes into v_used from public.families where id = v_family;
  if v_used <> v_base + 2000 then
    raise exception 'FAIL 用量：硬刪已 soft delete 的列後應為 %，實際 %（重複扣款）', v_base + 2000, v_used;
  end if;
  raise notice 'ok 用量：新增／soft delete／還原／硬刪 四條路徑的加減都正確';
end;
$$;

-- 額度硬防線：超過就擋（§10-A：沒有上限就是把信用卡交給陌生人）
do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_used bigint;
  v_after bigint;
begin
  select storage_used_bytes into v_used from public.families where id = v_family;
  update public.families set storage_quota_bytes = v_used + 500 where id = v_family;

  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values (v_family, v_family || '/2026/08/over.jpg', 'photo', 1000, 100, 100, v_owner);
    raise exception 'FAIL：超過額度還是讓照片寫進來了';
  exception when sqlstate 'LS002' then
    raise notice 'ok 額度：超額上傳被擋下 → %', sqlerrm;
  end;

  select storage_used_bytes into v_after from public.families where id = v_family;
  if v_after <> v_used then
    raise exception 'FAIL：超額被擋下之後用量卻變了（% → %）', v_used, v_after;
  end if;

  -- 額度內的上傳仍然要放行
  insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values (v_family, v_family || '/2026/08/fits.jpg', 'photo', 400, 100, 100, v_owner);
  raise notice 'ok 額度：剩餘空間放得下的上傳仍然放行';
end;
$$;
rollback;
