-- LS-415（池 a7b8a567，源自 LS-383 QA R1 95f183be，P2）——時間軸同日排序穩定鍵 `seq`
--
-- 問題：diary（`entry_date`）與 food_first（`first_tried_on`）的 `occurred_at` 都轉成 UTC 午夜，
-- 同一天的兩種卡片 `occurred_at` 完全相同；keyset 第二鍵 `ref_id` 是隨機 uuid，所以同日卡片順序
-- 隨機、與建立順序無關。照片／相簿卡帶時分秒，但同一次批次上傳（同一個交易的 now()）也會撞。
--
-- 做法：
--   1. `feed_items.seq bigint not null default nextval('private.feed_seq')`——單調遞增的建立順序。
--      **共用一條 sequence**（`private.feed_seq`）而不是每表一條：feed_item_children 的 seq 不自己
--      取號，而是由 BEFORE INSERT trigger 從同 (kind, ref_id) 的 feed_items 列複製（見第 4 段），
--      所以「家族版」與「per-child 版」同一個項目永遠是同一個 seq，兩種視角的同日順序一致。
--      不用 identity（要回填，見第 2 段）。sequence 放 private schema：client 不需要（也不該）
--      有任何權限；寫入者是 SECURITY DEFINER 的 trigger 函式（表擁有者）。
--   2. 回填順序＝來源列 `created_at`（diary→diaries、album→albums、media→media、
--      food_first→child_food_records），同秒再以 `ref_id` 定序；來源列查不到（feed_items 對來源表
--      沒有外鍵，是既有的多型關聯設計）則退用該列的 occurred_at 當排序依據。
--      這個 migration 是單一交易：`alter table` 的 ACCESS EXCLUSIVE 鎖持有到 commit，回填期間
--      不會有 trigger 併發寫入 feed_items；commit 後併發 insert 取到的 nextval 一定大於回填最大值
--      （下面 setval 在同一交易內完成）。
--   3. 索引改 `(family_id, occurred_at desc, seq desc)`（child 表 `(family_id, child_id,
--      occurred_at desc, seq desc)`），舊索引 drop。child 表的舊索引兼作 FK2 (family_id,
--      child_id) 的反向索引，新索引前綴相同，功能不減。
--   4. `feed_item_children` BEFORE INSERT trigger 複製 seq——**所有** 寫入 feed_item_children 的
--      路徑（六支 trigger 函式，都是 `insert ... select ... from feed_items` 或緊接在 feed_items
--      insert 之後）不需要逐一改欄位清單。
--   5. **seq 必須撐過 delete＋reinsert**：五支 `private.feed_sync_*` statement trigger 對 UPDATE 的
--      做法是「刪掉舊列、寫入新列」（albums／media／diaries／child_food_records 任何欄位的
--      UPDATE 都會觸發，例如改日記內文、改相簿標題、補縮圖）。若 seq 每次重取號，
--      編輯過的卡片會跳到同日最新——與「建立順序」相反。所以 albums／diaries／media／food 四支
--      函式在 delete 時用 `returning` 把舊 seq 存起來，reinsert 時沿用（沒有舊 seq 才 nextval）。
--      `feed_sync_diary_media_visibility`（LS-378）的「還原」是把先前被刪掉的 media 列寫回，
--      沒有舊 seq 可沿用，取新號＝視為剛出現，不改動該函式（media 卡的 occurred_at 帶時分秒，
--      同秒才需要 seq）。日記還原（deleted_at 翻回 NULL）走 feed_sync_diaries 的 INSERT 分支，
--      同樣沒有舊 seq（軟刪時列已被刪）→ 取新號，還原後排在同日最後面，這是可接受的取捨。
--   6. `get_family_timeline`：`order by occurred_at desc, seq desc`；游標參數形狀不變
--      （`p_cursor_occurred_at`, `p_cursor_ref_id`），函式內以 ref_id 反查 seq（見該函式上方說明）。
--
-- 不做：改 occurred_at 語意、iOS、相簿／照片卡的 occurred_at 來源、正式站部署。
-- 本檔之後 client 看到的資料行為：只有同一個 occurred_at 的項目之間的先後改變了（新→舊依建立順序）。

-- ---------------------------------------------------------------------------
-- 1. sequence 與欄位（先允許 NULL，回填後才收緊）
-- ---------------------------------------------------------------------------
create sequence private.feed_seq as bigint;

alter table public.feed_items add column seq bigint;
alter table public.feed_item_children add column seq bigint;

-- ---------------------------------------------------------------------------
-- 2. 回填：feed_items 依來源 created_at、同秒 ref_id；再把 feed_item_children 對齊
-- ---------------------------------------------------------------------------
with ranked as (
  select f.kind, f.ref_id,
         row_number() over (
           order by coalesce(d.created_at, a.created_at, m.created_at, c.created_at, f.occurred_at),
                    f.ref_id
         ) as rn
    from public.feed_items f
    left join public.diaries d on f.kind = 'diary' and d.id = f.ref_id
    left join public.albums a on f.kind = 'album' and a.id = f.ref_id
    left join public.media m on f.kind = 'media' and m.id = f.ref_id
    left join public.child_food_records c on f.kind = 'food_first' and c.id = f.ref_id
)
update public.feed_items f
   set seq = r.rn
  from ranked r
 where f.kind = r.kind and f.ref_id = r.ref_id;

update public.feed_item_children c
   set seq = f.seq
  from public.feed_items f
 where f.kind = c.kind and f.ref_id = c.ref_id;

-- 下一個 nextval 從「回填最大值 + 1」開始（空表從 1 開始）。
select setval('private.feed_seq', coalesce((select max(seq) from public.feed_items), 0) + 1, false);

alter table public.feed_items alter column seq set default nextval('private.feed_seq');
alter table public.feed_items alter column seq set not null;
alter table public.feed_item_children alter column seq set not null;

comment on column public.feed_items.seq is
  'LS-415：建立順序（單調遞增，private.feed_seq）。時間軸 keyset 的第二排序鍵：order by occurred_at desc, seq desc。同一項目在 UPDATE 觸發的 delete＋reinsert 之間沿用舊 seq。';
comment on column public.feed_item_children.seq is
  'LS-415：與同 (kind, ref_id) 的 feed_items.seq 相同（BEFORE INSERT trigger 複製），讓 per-child 時間軸與家族時間軸的同日順序一致。';

-- ---------------------------------------------------------------------------
-- 3. 索引：keyset 第二鍵 ref_id → seq
-- ---------------------------------------------------------------------------
create index feed_items_family_occurred_seq_idx
  on public.feed_items (family_id, occurred_at desc, seq desc);
drop index public.feed_items_family_occurred_idx;

create index feed_item_children_family_child_occurred_seq_idx
  on public.feed_item_children (family_id, child_id, occurred_at desc, seq desc);
drop index public.feed_item_children_family_child_occurred_idx;

-- ---------------------------------------------------------------------------
-- 4. feed_item_children.seq：BEFORE INSERT 從 feed_items 複製
--    （FK feed_item_children_feed_items_fkey 保證同 (kind, ref_id) 的 feed_items 列存在；
--    查不到時 seq 為 NULL，由 NOT NULL 約束 fail loud，不悄悄取新號造成兩視角順序分歧）
-- ---------------------------------------------------------------------------
create or replace function private.feed_item_children_set_seq()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select f.seq into new.seq
    from public.feed_items f
   where f.kind = new.kind and f.ref_id = new.ref_id;
  return new;
end;
$$;

create trigger feed_item_children_set_seq before insert on public.feed_item_children
  for each row execute function private.feed_item_children_set_seq();

-- ---------------------------------------------------------------------------
-- 5. 四支 feed_sync_* 函式：UPDATE 的 delete＋reinsert 沿用舊 seq
--    （本體與各自最新版逐字相同，只改 delete／insert 兩句：
--      albums  ← 20260902011514 第 7 段；diaries ← 同檔；
--      media   ← 20260924103521 第 3 段；food_first ← 20260918205141 第 7 段）
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_albums()
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
        where f.kind = 'album' and f.ref_id = o.id
      returning f.ref_id, f.seq
    )
    select array_agg(ref_id), array_agg(seq) into v_kept_ids, v_kept_seqs from gone;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at, seq)
      select n.family_id, 'album', n.id, n.created_at,
             coalesce(k.seq, nextval('private.feed_seq'))
        from new_rows n
        left join unnest(v_kept_ids, v_kept_seqs) as k(ref_id, seq) on k.ref_id = n.id
       where n.deleted_at is null;

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'album', n.id, ac.child_id, n.created_at
        from new_rows n
        join public.album_children ac on ac.album_id = n.id
       where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create or replace function private.feed_sync_diaries()
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
        where f.kind = 'diary' and f.ref_id = o.id
      returning f.ref_id, f.seq
    )
    select array_agg(ref_id), array_agg(seq) into v_kept_ids, v_kept_seqs from gone;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at, seq)
      select n.family_id, 'diary', n.id, (n.entry_date::timestamp at time zone 'utc'),
             coalesce(k.seq, nextval('private.feed_seq'))
        from new_rows n
        left join unnest(v_kept_ids, v_kept_seqs) as k(ref_id, seq) on k.ref_id = n.id
       where n.deleted_at is null;

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'diary', n.id, dc.child_id, (n.entry_date::timestamp at time zone 'utc')
        from new_rows n
        join public.diary_children dc on dc.diary_id = n.id
       where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

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

create or replace function private.feed_sync_food_records()
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
        where f.kind = 'food_first' and f.ref_id = o.id
      returning f.ref_id, f.seq
    )
    select array_agg(ref_id), array_agg(seq) into v_kept_ids, v_kept_seqs from gone;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at, seq)
      select n.family_id, 'food_first', n.id, (n.first_tried_on::timestamp at time zone 'utc'),
             coalesce(k.seq, nextval('private.feed_seq'))
        from new_rows n
        left join unnest(v_kept_ids, v_kept_seqs) as k(ref_id, seq) on k.ref_id = n.id
       where n.deleted_at is null;

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'food_first', n.id, n.child_id, (n.first_tried_on::timestamp at time zone 'utc')
        from new_rows n where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. get_family_timeline：排序鍵 (occurred_at desc, seq desc)；游標形狀不變
--
--    與 20260918205141_food_encyclopedia.sql:778 的定義逐字相同（該檔函式上方有完整的
--    LS-262／LS-243／LS-325 說明；下方本體註解裡的「函式頭」「宣告段」指的就是那份），
--    只有這幾處變動：
--      a) 排序：八條分支（家族／per-child × 有無游標 × 有無封鎖）內層 `order by
--         occurred_at desc, ref_id desc` 改 `occurred_at desc, seq desc`，內層子查詢多帶 seq，
--         外層 `order by p.occurred_at desc, p.seq desc`（回傳欄位不變，seq 不外露）。
--      b) 游標：仍收 (p_cursor_occurred_at, p_cursor_ref_id)。函式內以 p_cursor_ref_id 反查
--         游標列（家族版查 feed_items、per-child 版查 feed_item_children，都依
--         family_id [＋child_id] ＋ occurred_at ±1ms 視窗縮小索引範圍）取得 seq 與列上的真實
--         occurred_at，再以 (occurred_at, seq) < (真實 occurred_at, 游標 seq) 翻頁。
--         per-child 路徑不歧義：同一 ref_id 在 child 表可有多列（不同 child_id），但查詢
--         已帶 child_id，且它們的 seq 都相同（第 4 段）。
--      c) **游標列已不存在**（兩頁之間被刪、軟刪或改期）：查不到 seq 時退回舊的
--         (occurred_at, ref_id) 比較——不報錯、不讓 app 分頁中斷；代價是這個游標所在的同日
--         群組翻頁順序不保證（極少見的競態，且不會重複／遺漏以外的錯誤）。不沿用 LS022 類
--         錯誤碼，因為那會把使用者卡在「載入更多」失敗。
--      d) 附帶修正：iOS 以毫秒精度序列化游標時間，而 media／album 的 occurred_at 是微秒精度；
--         舊寫法拿截斷後的值做 `<` 比較，會漏掉介於截斷值與真實值之間的列。現在命中游標列後
--         比較用列上的真實值。
--    keyset 走新索引 (family_id, occurred_at desc, seq desc)／(family_id, child_id,
--    occurred_at desc, seq desc)：`occurred_at <= v_cursor_at` 是索引範圍條件，其後的
--    `occurred_at < … or seq < …` 只濾掉游標同一瞬間的少數列（EXPLAIN 見 PR body）。
-- ---------------------------------------------------------------------------
create or replace function public.get_family_timeline(
  p_family_id uuid,
  p_child_id uuid default null,
  p_cursor_occurred_at timestamptz default null,
  p_cursor_ref_id uuid default null,
  p_limit integer default 20
)
returns table (
  kind public.feed_kind,
  ref_id uuid,
  occurred_at timestamptz,
  taken_at timestamptz,
  child_ids uuid[],
  comment_count bigint
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  -- LS-243：呼叫者在這個家庭封鎖過的所有人，一次性算成陣列（不是逐列呼叫
  -- private.blocked_pairs()）——comment_count 子查詢在下面對每一列（最多 v_limit
  -- 列）都要判斷一次作者是否被封鎖，若沿用 child_ids 那種「per-row 呼叫 SQL
  -- 函式」的寫法，v_limit 上限 100 時就是 100 次 private.blocked_pairs() 呼叫；
  -- 改成陣列後，每一列只是一個常數陣列的 in-memory 成員檢查，不再有額外函式呼叫，
  -- 見 supabase/tests/50_rls_plan_no_percall_subquery.sql 對 comment_count 的
  -- 效能回歸段落。空陣列（無封鎖）時 `= any('{}')` 恆為 false，語意與「沒有封鎖」
  -- 完全一致，不需要另外判斷是否為空。
  v_blocked_ids uuid[] := array(
    select bp.blocked_id from private.blocked_pairs() bp where bp.family_id = p_family_id
  );
  -- 一次性判斷（不是逐列）：呼叫者在這個家庭封鎖過任何人嗎？絕大多數情況是 false，
  -- 走完全未加過濾條件的原始查詢，效能不受影響（見上方說明）。沿用 v_blocked_ids
  -- 算出來的陣列，不再另外呼叫一次 private.blocked_pairs()。
  v_has_blocks boolean := coalesce(array_length(v_blocked_ids, 1), 0) > 0;
  -- LS-415：游標列的穩定次序鍵與「資料庫裡的真實」occurred_at（見函式上方說明）。
  v_cursor_seq bigint;
  v_cursor_at timestamptz := p_cursor_occurred_at;
begin
  if (p_cursor_occurred_at is null) <> (p_cursor_ref_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_occurred_at／p_cursor_ref_id）'
      using errcode = 'LS022';
  end if;

  -- LS-415：游標形狀不變，函式內以 p_cursor_ref_id 反查游標列的 seq 與真實 occurred_at。
  -- occurred_at 用 ±1ms 視窗只為縮小索引範圍（iOS 端以毫秒精度序列化游標時間，見
  -- SupabaseTimelineAPIClient.iso8601String，而 media／album 的 occurred_at 是微秒精度，
  -- 等值比對會落空）；命中後比較改用列上的真實 occurred_at，不用客戶端帶來的截斷值。
  -- 查不到（游標列在兩頁之間被刪、軟刪或改期）→ v_cursor_seq 維持 NULL、v_cursor_at 維持
  -- 客戶端值，分頁條件退回舊的 (occurred_at, ref_id) 比較，不報錯、不中斷分頁。
  if p_cursor_ref_id is not null then
    if p_child_id is null then
      select f.seq, f.occurred_at into v_cursor_seq, v_cursor_at
        from public.feed_items f
       where f.family_id = p_family_id
         and f.occurred_at between p_cursor_occurred_at - interval '1 millisecond'
                               and p_cursor_occurred_at + interval '1 millisecond'
         and f.ref_id = p_cursor_ref_id
       limit 1;
    else
      select fc.seq, fc.occurred_at into v_cursor_seq, v_cursor_at
        from public.feed_item_children fc
       where fc.family_id = p_family_id
         and fc.child_id = p_child_id
         and fc.occurred_at between p_cursor_occurred_at - interval '1 millisecond'
                                and p_cursor_occurred_at + interval '1 millisecond'
         and fc.ref_id = p_cursor_ref_id
       limit 1;
    end if;
    if not found then
      v_cursor_at := p_cursor_occurred_at;
    end if;
  end if;

  if p_child_id is null then
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at, f.seq
                from public.feed_items f
               where f.family_id = p_family_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at, f.seq
                from public.feed_items f
               where f.family_id = p_family_id
               order by f.occurred_at desc, f.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at, f.seq
                from public.feed_items f
               where f.family_id = p_family_id
                 and f.occurred_at <= v_cursor_at
                 and (f.occurred_at < v_cursor_at
                      or (case when v_cursor_seq is not null then f.seq < v_cursor_seq
                               else f.ref_id < p_cursor_ref_id end))
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at, f.seq
                from public.feed_items f
               where f.family_id = p_family_id
                 and f.occurred_at <= v_cursor_at
                 and (f.occurred_at < v_cursor_at
                      or (case when v_cursor_seq is not null then f.seq < v_cursor_seq
                               else f.ref_id < p_cursor_ref_id end))
               order by f.occurred_at desc, f.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      end if;
    end if;
  else
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at, fc.seq
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at, fc.seq
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
               order by fc.occurred_at desc, fc.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at, fc.seq
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and fc.occurred_at <= v_cursor_at
                 and (fc.occurred_at < v_cursor_at
                      or (case when v_cursor_seq is not null then fc.seq < v_cursor_seq
                               else fc.ref_id < p_cursor_ref_id end))
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                     when 'media' then (select array_agg(mc.child_id order by mc.child_id)
                                          from public.media_children mc where mc.media_id = p.ref_id)
                     -- LS-325：food_first 恆為單一孩子（child_food_records.child_id
                     -- 是 NOT NULL 單一欄位，不是連結表），直接包成單元素陣列，不需要
                     -- 額外的連結表 join（跟 diary／album／media 三個既有分支不同）。
                     when 'food_first' then (select array[cfr.child_id]
                                               from public.child_food_records cfr
                                              where cfr.id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     -- LS-325：food_first 不是 content_target_type 的成員（本票不擴充
                     -- comments/reactions 的 target_type，卡片互動留給日後的票），
                     -- 直接轉型會撞 22P02（invalid_text_representation）；用 CASE 短路，
                     -- food_first 這個分支永遠不評估到右邊的轉型，讓比對結果是 NULL
                     -- （WHERE 視為不成立），comment_count 自然是 0，不是報錯。
                     and cm.target_type = (case when p.kind::text = 'food_first' then null
                                                 else (p.kind::text)::public.content_target_type end)
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at, fc.seq
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and fc.occurred_at <= v_cursor_at
                 and (fc.occurred_at < v_cursor_at
                      or (case when v_cursor_seq is not null then fc.seq < v_cursor_seq
                               else fc.ref_id < p_cursor_ref_id end))
               order by fc.occurred_at desc, fc.seq desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.seq desc;
      end if;
    end if;
  end if;
end;
$$;
