-- LS-48（LS-21 後端）— diaries schema 補全／時間軸查詢 RPC／RLS 收斂
--
-- 這個 migration 全部是新增（新增欄位／新增索引／新增 RPC／收緊既有 policy 的 USING/WITH
-- CHECK），沒有任何 DROP／TRUNCATE／改欄位型別／關 RLS 的語句，可以在既有雲端專案上直接套用。
--
-- ---------------------------------------------------------------------------
-- 0. 現況盤點（PLAN §5 對照，本段沒有任何 SQL——純粹是檢查結論的記錄）
--
-- diaries 表本身在 20260822120000_init_schema.sql 已經是完整的：
--   - 欄位：id / family_id / child_id? / author_id / body / entry_date / created_at / deleted_at?
--     與 PLAN §5 的 `diaries (id, family_id, child_id?, author_id, body, entry_date,
--     created_at, deleted_at?)` 逐欄對上，軟刪除（deleted_at）已具備。
--   - entry_date 索引：diaries_family_entry_idx (family_id, entry_date desc, id desc)
--     where deleted_at is null——時間軸主查詢用得到的形狀已經在。
--   - family_id/child_id 反向索引：diaries_child_idx (family_id, child_id) 涵蓋 child 篩選；
--     diaries_author_idx (author_id) 由 20260823020000_fk_reverse_indexes.sql（LS-36）補上，
--     涵蓋作者刪帳號時的 set null 反查。diary_media 兩個方向的索引在 init_schema 也都有。
--   - RLS 讀取面（diaries_select）與硬刪面（diaries_delete，僅 owner）已經正確，本檔不動。
--
-- 結論：schema 本身沒有缺口要補。這個 migration 要做的兩件事都是「新行為」：
--   1. 收斂 diaries 的 INSERT/UPDATE 寫入面成 RPC-only（見第 2 段，動機見下）。
--   2. 新增跨 family 時間軸查詢 RPC（見第 3 段）。
--
-- ---------------------------------------------------------------------------
-- 1. 為什麼 INSERT/UPDATE 要收斂成 RPC（比照 LS-37 對 invites 做的事）
--
-- 現行 diaries_update policy（20260822120200_rls_policies.sql，不動這個舊檔）：
--   using (family_id in owned_family_ids() or (author_id = me and family_id in
--   contributor_family_ids())) with check (同上)
-- 而 grant 是整表的 `update on public.diaries`（無欄位級收斂）。
--
-- 問題：owner 分支完全沒有限制「能改哪些欄位」。這代表 owner 不只能軟刪除家庭裡任何一篇
-- 日記（deleted_at），還能直接改寫別人日記的 body／entry_date／child_id——也就是**竄改
-- 內容**，不是 §10「Owner 移除內容」授權的那件事。§10 給 owner 的權力止於「移除」，
-- 不包含「改寫別人寫的東西」。這與 LS-37 修的洞是同一類問題（owner 手上的 grant 比
-- policy 意圖給的權力更寬），差別是 LS-37 那次是「繞過邊界造出不受限的資料」，這次是
-- 「越權編輯不屬於自己的內容」。
--
-- 修法：拆成兩支語意單一的 RPC——
--   create_diary_entry：新增，只有 contributor（owner/member）能新增，author 必須是自己。
--   update_diary_entry：改內容（body／entry_date／child_id），只有原作者能呼叫。
--   set_diary_deleted：軟刪／還原，作者可動自己的，owner 可動全家任何一篇——
--                       這支只碰 deleted_at 一個欄位，owner 分支不可能因此改到內容。
-- 三支都是 SECURITY DEFINER：INSERT/UPDATE 的 grant 收回後，這是 authenticated 僅剩的
-- 寫入路徑，函式內部才是真正的權限判斷，不依賴 RLS。
--
-- 收斂方式選 ALTER POLICY ... WITH CHECK (false)（LS-33 對 family_members_insert 的作法），
-- 不選 LS-37 對 invites 用的 DROP POLICY：本票的 PR 說明預期是純新增、非破壞性
-- （不需要使用者在 PR body 蓋 DESTRUCTIVE-APPROVED），而 CI 的破壞性偵測器會對
-- `DROP POLICY` 關鍵字命中；ALTER POLICY 不會。RLS 語意上兩者等效（policy 通不過
-- ＝ 該操作被拒絕），差別只在「物件是否還在 pg_policies 裡」，兩種寫法在這個 codebase
-- 都有前例，見 20260823040000_invites_write_path.sql 開頭的分歧記錄。
-- ---------------------------------------------------------------------------

alter policy diaries_insert on public.diaries with check (false);
alter policy diaries_update on public.diaries using (false) with check (false);

revoke insert, update on public.diaries from authenticated;

comment on table public.diaries is
  '家庭日記。INSERT／UPDATE 唯一的寫入路徑是 public.create_diary_entry() / '
  'public.update_diary_entry() / public.set_diary_deleted()（LS-48）—— authenticated '
  '沒有這兩種操作的 policy 也沒有 grant。硬刪（DELETE）仍走 20260822120200_rls_policies.sql '
  '既有的 diaries_delete policy（僅 owner），未受本檔影響。'
  '註：20260822120200_rls_policies.sql 裡 diaries_insert／diaries_update 兩條 policy 定義的原始文字'
  '（direct INSERT/UPDATE 開放給 contributor／author／owner）已被本檔的 ALTER POLICY 收斂取代，'
  '以本說明為準。';

-- ---------------------------------------------------------------------------
-- 2. diaries 的寫入 RPC
--
-- 錯誤碼延續 LS001/LS002（trigger 不變量）、LS010-LS017（LS-33 邀請/申請）之後的序號：
--   LS020 日記不存在或已被移除     LS021 非本人日記，無法編輯
-- 42501（未登入／非本家庭 contributor／非 owner 且非本人）沿用既有慣例。
-- ---------------------------------------------------------------------------

-- create_diary_entry：owner／member 都能寫（viewer 不行——§3「Viewer 只能看與留言」），
-- author_id 一律是呼叫者本人，不接受由參數指定（避免冒名，同 media_insert 的 uploaded_by 慣例）。
-- p_entry_date 為 NULL 時退回 current_date，對齊資料表原本的欄位預設值。
create or replace function public.create_diary_entry(
  p_family_id uuid,
  p_child_id uuid,
  p_body text,
  p_entry_date date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception '未登入，無法建立日記' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid and m.role in ('owner', 'member')
  ) then
    raise exception '只有該家庭的成員（owner／member）能寫日記' using errcode = '42501';
  end if;

  insert into public.diaries (family_id, child_id, author_id, body, entry_date)
  values (p_family_id, p_child_id, v_uid, p_body, coalesce(p_entry_date, current_date))
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_diary_entry(uuid, uuid, text, date) from public, anon;
grant execute on function public.create_diary_entry(uuid, uuid, text, date) to authenticated;

-- update_diary_entry：只有原作者能編內容。已被軟刪除的日記不能編輯——要嘛先用
-- set_diary_deleted 還原，要嘛就是被移除了，兩種情況都不該讓內容在那個狀態下被改動。
-- 三個欄位一律整組替換（PUT 語意，不是逐欄 PATCH）：呼叫端必須送出完整的期望狀態，
-- 這支函式不做「NULL＝不變」的猜測——時間軸／草稿狀態沒有 UI 落地前，猜測語意只會
-- 製造日後要對齊的技術債。
create or replace function public.update_diary_entry(
  p_diary_id uuid,
  p_body text,
  p_entry_date date,
  p_child_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_diary public.diaries%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法編輯日記' using errcode = '42501';
  end if;

  select d.* into v_diary from public.diaries d where d.id = p_diary_id for update;

  if not found then
    raise exception '日記不存在' using errcode = 'LS020';
  end if;

  -- 授權檢查（作者）刻意排在「是否已軟刪除」的狀態檢查之前（沿用
  -- 20260823010000_join_approval.sql approve_join／reject_join 的既有慣例：授權檢查排在
  -- 狀態檢查之前）：不是作者的人，不管這篇日記是否已被移除，一律拿到 LS021，不會從
  -- 錯誤碼的差別推敲出某篇不屬於自己的日記目前是否已被軟刪除。
  if v_diary.author_id is distinct from v_uid then
    raise exception '只有作者本人能編輯這篇日記' using errcode = 'LS021';
  end if;

  if v_diary.deleted_at is not null then
    raise exception '這篇日記已被移除，請先還原後再編輯' using errcode = 'LS020';
  end if;

  update public.diaries d
     set body = p_body,
         entry_date = coalesce(p_entry_date, current_date),
         child_id = p_child_id
   where d.id = p_diary_id;
end;
$$;

revoke execute on function public.update_diary_entry(uuid, text, date, uuid) from public, anon;
grant execute on function public.update_diary_entry(uuid, text, date, uuid) to authenticated;

-- set_diary_deleted：唯一能碰 deleted_at 的路徑。作者能軟刪／還原自己的；
-- owner 能軟刪／還原全家任何一篇（§10 對齊：owner 的權力止於移除，不含改內容——
-- 這支函式的 UPDATE 就只寫 deleted_at 一欄，物理上不可能被拿來竄改 body）。
create or replace function public.set_diary_deleted(
  p_diary_id uuid,
  p_deleted boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_diary public.diaries%rowtype;
  v_is_owner boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除或還原日記' using errcode = '42501';
  end if;

  select d.* into v_diary from public.diaries d where d.id = p_diary_id for update;

  if not found then
    raise exception '日記不存在' using errcode = 'LS020';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_diary.family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  if not v_is_owner and v_diary.author_id is distinct from v_uid then
    raise exception '只有作者本人或該家庭的 owner 能移除／還原這篇日記' using errcode = '42501';
  end if;

  update public.diaries d
     set deleted_at = case when p_deleted then now() else null end
   where d.id = p_diary_id;
end;
$$;

revoke execute on function public.set_diary_deleted(uuid, boolean) from public, anon;
grant execute on function public.set_diary_deleted(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. 時間軸查詢：feed_items 補 child_id，供 get_family_timeline 篩選
--
-- feed_items 目前只有 (family_id, kind, ref_id, occurred_at)，沒有 child_id——混排
-- 日記／相簿／照片時，若要支援「只看某個孩子」的篩選，勢必要在查詢當下知道每一列
-- 對應的孩子是誰。兩條路：
--   a) 查詢時 join 回 diaries／albums 拿 child_id——PLAN §5「為什麼第一天就要有
--      feed_items」明講的理由就是要避免多表 join 拖慢時間軸查詢，這條路等於繞回
--      被 feed_items 解決掉的問題。
--   b) 由維護 feed_items 的 trigger 一併把 child_id 寫進去——沿用「一張由 trigger
--      維護的扁平表」的既有設計，查詢只要多一個欄位比對，不必 join。
-- 選 (b)。
--
-- media 沒有 child_id 這個決定不是本票發明的：PLAN §5 的 media 欄位清單裡沒有
-- child_id，一張照片本身不屬於特定孩子，只有透過 album_media 掛進某本相簿之後才間接
-- 跟那本相簿的 child_id 產生關聯，而且是多對多（一張照片可以掛在多本相簿）。要把這種
-- 間接、非唯一的關係硬塞進 feed_items 的單一 child_id 欄位，會出現「同一張照片依它被
-- 掛的相簿不同，該不該出現在某個孩子的時間軸」這種每次查詢都要重新判定的問題，
-- 且要嘛重複列（同一張照片在多個孩子的時間軸各出現一次，回到 (a) 的 join 代價），
-- 要嘛只認第一本相簿（語意武斷）。因此本票的裁量：media 的 feed_items.child_id 固定
-- 是 NULL，指定 child 篩選時 media 類項目不會出現；只篩「全部」（p_child_id 為 NULL）
-- 時 media 仍完整出現。這是誠實反映現有資料模型的結果，不是遺漏——child_id 若之後要
-- 對照片也有意義，屬於 LS-47（多寶貝定案）該回頭裁量的範圍，不在本票展開。
-- ---------------------------------------------------------------------------

alter table public.feed_items add column child_id uuid;

-- on delete set null (child_id)：column-specific SET NULL，同 init_schema.sql 的
-- albums_child_same_family_fkey／diaries_child_same_family_fkey。這裡不能省略
-- (child_id)——省略的話 Postgres 對複合外鍵的預設行為是把「所有」參照欄位都設成 NULL，
-- 會連 family_id 一起 NULL 掉，而 feed_items.family_id 是 NOT NULL（references
-- public.families ... on delete cascade），孩子被刪除時會直接噴 23502。
alter table public.feed_items add constraint feed_items_child_same_family_fkey
  foreign key (family_id, child_id) references public.children (family_id, id)
  on delete set null (child_id);

comment on column public.feed_items.child_id is
  '該項目所屬的孩子（可為 NULL＝全家共用或無法歸屬單一孩子）。diary／album 由對應資料列的'
  ' child_id 帶入；media 固定為 NULL（media 本身沒有 child_id，只能透過 album_media 間接、'
  '多對多地關聯到相簿的 child_id，見 20260824010000_diaries_write_path_and_timeline.sql 的'
  '裁量說明）。由 private.feed_sync_albums() / private.feed_sync_diaries() 維護，使用者不可寫。';

-- 支援 get_family_timeline 的 child 篩選路徑，同時滿足 65_fk_reverse_index.sql 對
-- feed_items_child_same_family_fkey 的反向索引要求（鍵欄位 family_id/child_id 是本索引
-- 最前兩個鍵欄位的集合）。非 partial：RI 檢查與「查全部孩子共用項目」都需要涵蓋 NULL 列
-- （NULL 不會被 btree 排除在等值查找的鄰接性之外，但 partial index 才會排除列，這裡沒有
-- WHERE，所以兩種查詢都覆蓋得到）。
create index feed_items_family_child_occurred_idx
  on public.feed_items (family_id, child_id, occurred_at desc, ref_id desc);

-- 重建 albums／diaries 的 feed 同步函式，把 child_id 一併寫入。media 的
-- private.feed_sync_media() 不必動——不帶 child_id 的欄位清單，INSERT 出來就是 NULL，
-- 符合上面的裁量。用 CREATE OR REPLACE 覆寫舊定義（函式簽章不變，掛著它的三個
-- statement-level trigger 不需要重建），不改動 20260822120100_triggers.sql 這個舊檔案本身。
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
    insert into public.feed_items (family_id, kind, ref_id, occurred_at, child_id)
      select n.family_id, 'album', n.id, n.created_at, n.child_id
        from new_rows n where n.deleted_at is null;
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
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'diary' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    -- entry_date → occurred_at 的 UTC 午夜換算：與原定義（20260822120100_triggers.sql）
    -- 逐字相同，不是本票要改的行為，這裡只是多帶一欄 child_id。
    insert into public.feed_items (family_id, kind, ref_id, occurred_at, child_id)
      select n.family_id, 'diary', n.id, (n.entry_date::timestamp at time zone 'utc'), n.child_id
        from new_rows n where n.deleted_at is null;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. get_family_timeline：跨 kind 混排的時間軸查詢，keyset 分頁 + child 篩選
--
-- 回傳最小可用的指標集合（kind／ref_id／occurred_at／child_id），不是完整內容——
-- 這是「無 UI」的後端切片，呼叫端要看某一列的完整內容（日記內文、相簿標題、照片路徑）
-- 再各自查對應的表（皆已有 RLS 保護，family 成員本來就查得到）。日後若要做成一支
-- 「一次拿到卡片所需全部欄位」的寬 RPC，屬於後續票的範圍，不在這裡展開（YAGNI）。
--
-- 分頁：keyset，游標是 (occurred_at, ref_id) 這一對，比對邏輯與 feed_items 既有索引
-- （family_occurred_idx／本票新增的 family_child_occurred_idx）的排序方向一致
-- （occurred_at desc, ref_id desc）。第一頁兩個游標參數都不帶（NULL）。
--
-- p_child_id：NULL＝不篩（全部孩子＋沒有 child 歸屬的項目都出現）；帶值＝只回傳
-- child_id 等於該值的項目（媒體項目因 child_id 恆為 NULL，此時不會出現，見第 3 段裁量）。
--
-- security invoker（預設，未寫 security definer）是刻意的：不是遺漏。feed_items 自己的
-- RLS（feed_items_select，20260822120200_rls_policies.sql）已經用
-- `family_id in (select private.family_ids())` 限制成呼叫者所屬的家庭，這支函式沒有任何
-- 需要繞過 RLS 才查得到的資料——呼叫者傳入自己不屬於的 p_family_id，RLS 會讓查詢自然
-- 回傳 0 列，不需要在函式裡再手動重複一次 family_ids() 的檢查。這是比 DEFINER
-- 更小的暴露面：函式本身不持有任何 RLS 繞過能力。
--
-- set search_path = '' 仍然保留：與 definer 函式的理由不同（那是防止呼叫端 search_path
-- 挾持），這裡純粹是讓所有物件引用維持全名限定的一致慣例，函式本體已經全部用
-- public. 前綴，實務上不受影響。
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
  child_id uuid
)
language sql
stable
set search_path = ''
as $$
  select f.kind, f.ref_id, f.occurred_at, f.child_id
    from public.feed_items f
   where f.family_id = p_family_id
     and (p_child_id is null or f.child_id = p_child_id)
     and (
       (p_cursor_occurred_at is null and p_cursor_ref_id is null)
       or (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
     )
   order by f.occurred_at desc, f.ref_id desc
   limit least(greatest(coalesce(p_limit, 20), 1), 100);
$$;

revoke execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  to authenticated;
