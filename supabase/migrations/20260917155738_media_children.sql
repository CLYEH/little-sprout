-- LS-317（LS-249 後端先行）—— media ↔ 孩子標記 `media_children` 連結表，
-- `set_media_children`／`set_media_children_batch` RPC，`get_family_timeline`
-- media 項 `child_ids` 回填。
--
-- 背景：LS-304 R1 merge-review `c3c1f8e9` 核實——`media` 表沒有任何 child 欄，
-- `docs/API.md:849-852`（LS-121 當時的版本）明文「media 類項目的 `child_ids`
-- 恆為空陣列」；LS-251 核可稿 Import 01 群卡的「指定寶貝」欄因此是 UI 空轉
-- （`ImportPlan.Group.babyIDs` 只被 `ImportGroupCardView` 讀寫，coordinator 從不
-- 讀）。LS-304 票文「不做後端變更」合規，故另開本票補後端；本票**不做** iOS 端
-- 接線（見 LS-317 票文「不做」段）。
--
-- 先例（沿用寫法，不重新發明）：
--   - `supabase/migrations/20260902011514_diary_album_multi_child_tags.sql`——
--     `diary_children`／`album_children` 連結表結構、RLS、LS044 守門 trigger、
--     `feed_item_children` 扁平查詢表與其維護 trigger、`set_album_children` 的
--     刪多補少覆蓋語意，本票對 `media` 逐條套用同一套。
--   - `supabase/migrations/20260822120100_triggers.sql`（`private.feed_sync_media()`
--     既有定義）——本票用 `CREATE OR REPLACE` 追加還原時重新展開
--     `feed_item_children` 的分支，函式簽章與既有兩個分支（DELETE／INSERT 主體）
--     不變。
--   - `supabase/migrations/20260913163828_media_taken_at_hardening.sql`——
--     `get_family_timeline` 目前的完整定義（`taken_at`／`comment_count` 已疊加在
--     `child_ids` 之上，八個 `return query` 分支）。本票只在每個分支的 `child_ids`
--     CASE 裡插入 `when 'media'` 分支，不改動其餘欄位、不改回傳型別——因此不需要
--     `DROP FUNCTION`，直接 `CREATE OR REPLACE`（OUT 參數型別未變）。
--
-- ---------------------------------------------------------------------------
-- 0. 授權設計：`set_media_children` 的呼叫者門檻沿用 `media_update` RLS policy
--    的既有判準（`20260822120200_rls_policies.sql`），不是新發明的規則——
--    「上傳者本人且當下仍有上傳權」或「該家庭 owner」，跟「誰能軟刪一張照片」
--    是同一組人；標記孩子跟軟刪一樣屬於「對這張照片的處置權」，不是「內容編輯權」
--    （`albums`/`diaries` 的建立者分支模式在這裡不適用，`media` 沒有 hybrid 模式）。
--    票面要求「非上傳者且非 owner 被拒 `42501`」（不是像 `set_album_children` 那樣
--    另開 `LS045` 這種合併碼）——這裡直接沿用裸 `42501`，字面照票。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. 連結表：media_children（結構、索引、comment 逐條對齊 album_children 先例）
-- ---------------------------------------------------------------------------
create table public.media_children (
  family_id uuid not null references public.families (id) on delete cascade,
  media_id uuid not null,
  child_id uuid not null,
  primary key (media_id, child_id),
  constraint media_children_media_fkey foreign key (family_id, media_id)
    references public.media (family_id, id) on delete cascade,
  constraint media_children_child_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete cascade
);

create index media_children_family_media_idx on public.media_children (family_id, media_id);
create index media_children_family_child_idx on public.media_children (family_id, child_id);

comment on table public.media_children is
  '照片／影片 ↔ 孩子多對多標記（LS-317，沿 LS-121 album_children／diary_children
  先例）。INSERT／DELETE 唯一路徑是 public.set_media_children() /
  public.set_media_children_batch()（SECURITY DEFINER，繞過本表的 grant 收斂）；
  authenticated 沒有直接 INSERT/UPDATE/DELETE 的 grant，只有 SELECT（同家庭任一
  角色，含 viewer）。沒有 UPDATE 語意——「改標記」是同一交易內先 DELETE 多的、
  再 INSERT 少的，不是對既有列做 UPDATE。';

alter table public.media_children enable row level security;

create policy media_children_select on public.media_children for select to authenticated
  using (family_id in (select private.family_ids()));

-- 沒有 INSERT/UPDATE/DELETE policy——RLS 預設拒絕；唯一寫入路徑是下面的
-- SECURITY DEFINER RPC（表擁有者身分執行，繞過 RLS）。
grant select on public.media_children to authenticated;

-- LS044 守門：重用既有 private.enforce_child_not_deleted()（20260825030000
-- 定義），只掛 BEFORE INSERT（連結表沒有 UPDATE 語意，見上方 comment）。
create trigger media_children_not_deleted
  before insert on public.media_children
  for each row execute function private.enforce_child_not_deleted();

-- LS052／LS053：media_children 是全新的帶 family_id 內容表，比照
-- 20260904212530_suspension_and_registrations.sql 對 diary_children／
-- album_children 的既定做法補上這道縱深防禦（該票之後才新建的表，需要在自己的
-- 建表 migration 裡掛，不會自動繼承既有表的補掛——同 growth_records
-- 20260913065021_growth_records.sql 第 5 段的既定慣例）。DELETE 分支對這張表
-- 不是恆 no-op（set_media_children 的刪多補少會真的 DELETE），三種操作都掛。
create trigger media_children_not_suspended
  before insert or update or delete on public.media_children
  for each row execute function private.enforce_not_suspended();

-- ---------------------------------------------------------------------------
-- 2. feed_item_children 維護：media_children 異動時的 AFTER INSERT/DELETE trigger
--    （沿 feed_sync_diary_children／feed_sync_album_children 先例，各表一支函式，
--    理由同該檔第 6 段：泛型 trigger 函式共用是語句計畫快取的已知地雷）。
-- ---------------------------------------------------------------------------
create or replace function private.feed_sync_media_children()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.feed_item_children
     where kind = 'media' and ref_id = old.media_id and child_id = old.child_id;
    return old;
  end if;

  insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
  select f.family_id, 'media', f.ref_id, new.child_id, f.occurred_at
    from public.feed_items f
   where f.kind = 'media' and f.ref_id = new.media_id
  on conflict do nothing;
  return new;
end;
$$;

create trigger media_children_feed_insert after insert on public.media_children
  for each row execute function private.feed_sync_media_children();
create trigger media_children_feed_delete after delete on public.media_children
  for each row execute function private.feed_sync_media_children();

-- ---------------------------------------------------------------------------
-- 3. private.feed_sync_media()：追加還原時重新展開 feed_item_children
--
-- 沿 feed_sync_albums／feed_sync_diaries（20260902011514 第 7 段）同一個理由：
-- 軟刪期間改標記，media_children 照樣落地但 feed_item_children 維持 0 列（該
-- media 本來就不在 feed_items 裡）；還原（deleted_at 設回 NULL）觸發這支函式的
-- INSERT 分支，此時必須主動把 media_children 當下的集合展開回
-- feed_item_children——不能指望第 2 段的連結表 trigger（那支只在 media_children
-- 本身被 INSERT/DELETE 時觸發，還原動作沒有動到連結表）。新上傳時這裡的 join
-- 天生 0 列（media 先 insert、media_children 是後續才呼叫 set_media_children
-- 才會有的列），no-op，交給第 2 段接手，兩處分工不是重複。
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
        from new_rows n where n.deleted_at is null;

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'media', n.id, mc.child_id, coalesce(n.taken_at, n.created_at)
        from new_rows n
        join public.media_children mc on mc.media_id = n.id
       where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. RPC：set_media_children（單張）／set_media_children_batch（批次，供匯入
--    一次多張用）
--
-- 授權門檻沿 media_update policy（見第 0 段）：v_media.family_id in
-- owned_family_ids() 或（uploaded_by = 呼叫者 且 family_id in
-- uploadable_family_ids()）。找不到該筆 media／授權不足皆是裸 `42501`（不另開新
-- LSnnn 碼——本票是純後端票、不碰 Swift，任何新碼都要求同步改 AppError.swift，
-- error-codes-check.sh 三方對帳；票面驗收本身也只要求「非上傳者非 owner 被拒
-- 42501」，沒有另外要求「找不到」要有獨立碼）。
--
-- 覆蓋語意（刪多補少）沿 set_album_children 逐字：p_child_ids 為 NULL 或空陣列＝
-- 清空；非空＝全覆蓋、去重、過濾 NULL 元素；任一元素跨家庭 23503（複合外鍵）；
-- 任一元素指向已軟刪的孩子 LS044（第 1 段 trigger）。
--
-- 併發：對目標 media 列用 FOR UPDATE 鎖住，media_children 的刪多補少在同一個
-- 交易、同一把鎖之後執行——理由與 update_diary_entry／set_album_children 的既有
-- 併發保證一致（見 20260902011514 檔頭第 8 段）：兩個連線同時對同一張照片呼叫
-- set_media_children，後動的那個被這把鎖擋住直到先動的那個 commit，終態一定是
-- 後 commit 那次呼叫的完整集合，不會是兩次呼叫的合併。
-- ---------------------------------------------------------------------------
create or replace function public.set_media_children(
  p_media_id uuid,
  p_child_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_media public.media%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法設定照片的寶貝標記' using errcode = '42501';
  end if;

  select m.* into v_media from public.media m where m.id = p_media_id for update;

  -- 找不到這筆 media：裸 `42501`（不另開新 LSnnn 碼）——本票是純後端票、不碰
  -- Swift，任何新 LSnnn 碼都要求同步改 LittleSprout/Errors/AppError.swift
  -- （error-codes-check.sh 三方對帳），票面驗收本身也只要求「非上傳者非 owner
  -- 被拒 42501」；不能省略這個檢查直接讓下面的授權判斷「自然落空」——`v_media`
  -- 全欄位為 NULL 時，`NULL in (...)`／`NULL = v_uid` 的結果是 NULL 而不是
  -- false，plpgsql 的 `IF NULL THEN` 不會進入該分支（NULL 既不算 true 也不算
  -- false），會直接跳過下面的 raise、往後執行到 INSERT 撞上 `family_id` 的
  -- NOT NULL 約束（23502），不是預期的 42501。
  if not found then
    raise exception '照片不存在' using errcode = '42501';
  end if;

  if not (
    v_media.family_id in (select private.owned_family_ids())
    or (v_media.uploaded_by = v_uid and v_media.family_id in (select private.uploadable_family_ids()))
  ) then
    raise exception '只有上傳者本人（且當下仍有上傳權）或該家庭 owner 能設定這張照片的寶貝標記'
      using errcode = '42501';
  end if;

  delete from public.media_children mc
   where mc.media_id = p_media_id
     and not exists (select 1 from unnest(p_child_ids) as x where x = mc.child_id);

  insert into public.media_children (family_id, media_id, child_id)
  select v_media.family_id, p_media_id, u.child_id
    from (select distinct x as child_id from unnest(p_child_ids) as x where x is not null) u
   where not exists (
     select 1 from public.media_children mc
      where mc.media_id = p_media_id and mc.child_id = u.child_id
   );
end;
$$;

revoke execute on function public.set_media_children(uuid, uuid[]) from public, anon;
grant execute on function public.set_media_children(uuid, uuid[]) to authenticated;

-- set_media_children_batch：批次版本，直接在迴圈內呼叫 set_media_children()（同一
-- 個 v_uid／同一個交易，不是重複實作授權與覆蓋邏輯）——單一交易、任何一筆的授權
-- 失敗或 LS044／23503 都會讓整個函式呼叫拋出例外，外層交易整批 rollback（票面
-- 「批次原子性：一筆壞 child 全 rollback」）。p_items 形狀：
-- `[{"media_id": "<uuid>", "child_ids": ["<uuid>", ...]}]`；單一元素缺
-- media_id／child_ids 皆視為該元素的資料錯誤，一樣整批 rollback（fail loud，不
-- 靜默跳過壞元素）。
--
-- merge-review R1 m1（`f2a7305` 版本已實測重現 40P01）：迴圈依 p_items 陣列給定的
-- 順序逐筆呼叫 set_media_children，每筆內部的 `select ... for update` 取到的列鎖
-- 持有到整個批次交易結束——若呼叫端給的陣列順序不同，兩個連線對同一組 media 用
-- 相反順序呼叫會累積成相反的鎖序，構成 ABBA 循環等待。改法：`with ordinality`
-- 取出陣列元素原始序號＋依 `media_id` 排序後才逐筆處理，讓任何呼叫端不論陣列
-- 順序為何，同一批次內對這組 media 的鎖序永遠一致（遞增 media_id）——兩個重疊
-- 批次因此只會排隊、不會出現循環等待。同一 media_id 在單一批次內重複出現時仍是
-- 「陣列原始序號較後者勝」（`order by media_id, ord` 讓同 media_id 的多筆元素照
-- 原始 ord 遞增處理，最後一筆蓋掉前面幾筆，語意不變）。
create or replace function public.set_media_children_batch(p_items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_item jsonb;
  v_count integer;
begin
  if v_uid is null then
    raise exception '未登入，無法設定照片的寶貝標記' using errcode = '42501';
  end if;

  -- merge-review R1 i1：實測 200 筆 35 ms，離 1 秒很遠，本不擋；但呼叫端若一次送
  -- 幾千筆，會是一個長交易持有同等數量的 media 列鎖。上限抓 500（票面驗收批次量
  -- 200 的 2.5 倍，留足匯入分批的彈性，同時避免無上限），超過拋 22023（見
  -- docs/API.md §4 對應段落）。
  select count(*) into v_count from jsonb_array_elements(coalesce(p_items, '[]'::jsonb));
  if v_count > 500 then
    raise exception '批次筆數超過上限（500），實際 % 筆', v_count using errcode = '22023';
  end if;

  for v_item in
    select e.value
      from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as e(value, ord)
     order by (e.value->>'media_id'), e.ord
  loop
    perform public.set_media_children(
      (v_item->>'media_id')::uuid,
      (select array_agg(x::uuid)
         from jsonb_array_elements_text(coalesce(v_item->'child_ids', '[]'::jsonb)) x)
    );
  end loop;
end;
$$;

revoke execute on function public.set_media_children_batch(jsonb) from public, anon;
grant execute on function public.set_media_children_batch(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. get_family_timeline：child_ids CASE 加 'media' 分支（沿 media_children 聚合，
--    同 'diary'／'album' 分支的既有寫法）。
--
-- 不需要 DROP FUNCTION——OUT 參數型別（returns table 清單）完全不變，只是八個
-- return query 分支各自的 child_ids CASE 運算式多一個 WHEN；CREATE OR REPLACE
-- 對「本體變、型別不變」的既有函式是合法操作。參數簽章不變
-- （get_family_timeline(uuid, uuid, timestamptz, uuid, integer)），docs/API.md
-- §9 機械對帳清單的 RPC 簽章那一行因此不用改。
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
begin
  if (p_cursor_occurred_at is null) <> (p_cursor_ref_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_occurred_at／p_cursor_ref_id）'
      using errcode = 'LS022';
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
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
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. merge-review R1 i3（20260902011514_diary_album_multi_child_tags.sql:140-141
--    是既有 migration，immutable gate 不能改；只能在本票 migration 末尾補一句
--    comment on table 訂正）：feed_item_children 的表註解原文列了「四支 trigger
--    函式維護」，本票新增 private.feed_sync_media_children()（第 2 段）並讓既有
--    private.feed_sync_media()（第 3 段，CREATE OR REPLACE）首次也寫入這張表——
--    維護 feed_item_children 的 trigger 函式從四支變六支
--    （feed_sync_diary_children／feed_sync_album_children／feed_sync_diaries／
--    feed_sync_albums／feed_sync_media_children／feed_sync_media）。
-- ---------------------------------------------------------------------------
comment on table public.feed_item_children is
  'get_family_timeline 篩 child 用的扁平查詢表（LS-121）：一個時間軸項目標記 N 個孩子
  就有 N 列，每列 (kind, ref_id, child_id) 各自可以被等值篩選、走
  feed_item_children_family_child_occurred_idx 做 keyset 分頁——不篩 child 的查詢
  完全不碰這張表，走 feed_items 本身（一個項目一列，天然不重複）。完全由
  private.feed_sync_diary_children() / private.feed_sync_album_children() /
  private.feed_sync_diaries() / private.feed_sync_albums() /
  private.feed_sync_media_children() / private.feed_sync_media()（LS-317 起，後兩支）
  六支 trigger 函式維護，authenticated 沒有任何寫入 grant。';
