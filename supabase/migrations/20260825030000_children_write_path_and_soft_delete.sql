-- LS-66（LS-47 後端切片）— children 多寶貝 CRUD RPC、軟刪 30 天可還原、角色矩陣
--
-- 對應 LS-47 使用者定案（2026-08-25）第④題：「刪寶貝＝軟刪 30 天可還原，照片日記保留」，
-- 以及 orchestrator 建議方案第 2 點：「新增/編輯 owner＋member 皆可，刪除僅 owner」。
--
-- 本檔做四件事：
--   1. children 補 deleted_at／deleted_by 欄位＋反向索引，補 family_id 不可變 trigger。
--   2. 直接 INSERT/UPDATE 收斂 RPC-only（比照 LS-48 對 diaries 的做法，理由同型：現行
--      children_insert／children_update policy 是 owner-only，但本票要求 owner＋member
--      都能新增／編輯——與其放寬 policy 讓「編輯內容」與「刪除」共用同一組寬鬆的直接寫入
--      面，不如收斂成 RPC-only，讓「新增／編輯」與「軟刪／還原」各自有語意單一、權限
--      各自正確的入口，且軟刪的 30 天還原邊界只能在 RPC 裡做，直接 UPDATE 做不到）。
--   3. 四支 RPC：create_child／update_child／set_child_deleted／list_children。
--   4. children_select policy 收斂：軟刪旗標（含被軟刪的列本身）只有 owner 看得到，
--      member／viewer 完全看不到已軟刪的孩子——這一層在 RLS 做，不是只靠 list_children
--      RPC 自己過濾，直接 `.from("children").select()` 一樣受這條規則保護。
--
-- ---------------------------------------------------------------------------
-- 0. 現況盤點
--
-- children 在 20260822120000_init_schema.sql 已有 id／family_id／name／birthday／
-- avatar_url／created_at，＋ (family_id, id) 複合 UNIQUE（供 albums/diaries 複合外鍵用）、
-- family_id 的單欄索引。目前沒有 deleted_at／deleted_by，direct INSERT/UPDATE/DELETE
-- 皆 owner-only（20260822120200_rls_policies.sql children_insert／children_update／
-- children_delete 三條 policy）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. schema：軟刪欄位＋反向索引＋family_id 不可變 trigger
-- ---------------------------------------------------------------------------

alter table public.children
  add column deleted_at timestamptz,
  add column deleted_by uuid references public.profiles (id) on delete set null;

comment on column public.children.deleted_at is
  '軟刪時間戳；NULL＝仍是有效的孩子檔案。硬刪（DELETE）走既有 children_delete policy
  （owner-only，不受本票影響），軟刪／還原唯一路徑是 public.set_child_deleted()。';

comment on column public.children.deleted_by is
  '執行軟刪的 owner（還原時清成 NULL，見 set_child_deleted）。on delete set null：
  那位 owner 之後刪帳號，這欄不該連帶讓孩子檔案的其他資料失效。';

-- children.children_deleted_by_fkey 的反向索引（65_fk_reverse_index.sql 會掃到）：
-- 某位 owner 刪帳號時，要能反查「他曾經軟刪過哪些孩子檔案」把 deleted_by set null。
-- 非 partial（涵蓋全部列，不是只覆蓋 deleted_by 非 NULL 的列）——RI 檢查要對「所有」
-- 列都成立，理由與 20260823020000_fk_reverse_indexes.sql 對其他 profiles 外鍵的裁量相同。
create index children_deleted_by_idx on public.children (deleted_by);

-- family_id 不可變：與 diaries／albums／comments 用「RPC 參數根本不接受改 family_id」
-- 保證不同——children 收斂成 RPC-only 之後，唯一能寫這張表的路徑就是本檔下面幾支
-- SECURITY DEFINER RPC，理論上「RPC 不傳 family_id 參數」已經足夠。但這裡多加一層
-- DB trigger 是刻意的防禦，不是重複：SECURITY DEFINER 函式以表擁有者身分執行、繞過
-- RLS，往後任何一次修改 update_child／set_child_deleted 的 PR，若不小心在 UPDATE
-- 語句裡多寫了 family_id 欄位，人工 review 才是唯一防線；有這支 trigger，那個
-- 疏漏會在套用 migration／跑測試的當下就直接炸掉，不必等到 review 發現或（更糟）
-- 上線後才被發現孩子檔案被搬過家。trigger 沒有查任何資料庫物件（只比較 NEW／OLD
-- 兩個列的欄位值），本可以是 invoker，但比照本 schema 其他 trigger 函式一律
-- SECURITY DEFINER＋search_path 收斂的慣例，不另立例外（60_default_privileges.sql
-- 第 9 段的 v_exceptions 維持只有 is_media_object_path 一支）。
create or replace function private.enforce_children_family_immutable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.family_id is distinct from old.family_id then
    raise exception '孩子檔案建立後不能被搬到別的家庭（family_id 不可變）'
      using errcode = 'LS040';
  end if;
  return new;
end;
$$;

create trigger children_family_immutable
  before update on public.children
  for each row execute function private.enforce_children_family_immutable();

-- ---------------------------------------------------------------------------
-- 2. 直接 INSERT/UPDATE 收斂 RPC-only（比照 LS-48 對 diaries 的三個理由：縮權不刪物件、
-- 可逆、不動既有資料——手法同樣是 ALTER POLICY ... (WITH CHECK) (false) + REVOKE，
-- 詳細理由見 20260824010000_diaries_write_path_and_timeline.sql 第 1 段，不重複貼一次）
-- ---------------------------------------------------------------------------

alter policy children_insert on public.children with check (false);
alter policy children_update on public.children using (false) with check (false);

revoke insert, update on public.children from authenticated;

-- children_select 收斂：軟刪的孩子檔案（deleted_at 非 NULL）只有該家庭的 owner 看得到；
-- member／viewer 的 SELECT 完全篩不到那些列，不只是「看不到 deleted_at 這個欄位值」，
-- 是連那一整列都不存在於他們的查詢結果——這樣 list_children RPC（security invoker，
-- 依賴這條 policy）跟任何直接 `.from("children").select()` 的呼叫端行為一致，不會有
-- 「RPC 過濾了，但直接查表沒過濾」這種兩張皮。
alter policy children_select on public.children
  using (
    family_id in (select private.family_ids())
    and (deleted_at is null or family_id in (select private.owned_family_ids()))
  );

comment on table public.children is
  '家庭孩子檔案。INSERT／UPDATE 唯一的寫入路徑是 public.create_child() /
  public.update_child() / public.set_child_deleted()（LS-66）——authenticated 沒有
  這兩種操作的 policy 也沒有 grant。硬刪（DELETE）仍走
  20260822120200_rls_policies.sql 既有的 children_delete policy（僅 owner），
  未受本檔影響。軟刪的孩子檔案（deleted_at 非 NULL）只有該家庭 owner 讀得到
  （children_select policy 已收斂，member／viewer 完全查不到那些列）。';

-- ---------------------------------------------------------------------------
-- 3. 寫入 RPC
--
-- 錯誤碼延續既有序號（最新是 LS026，LS-58）。orchestrator 指派：本票新碼從 LS040
-- 起跳，避開 LS-57（同時在飛、也會動 children/deleted_by 相鄰的錯誤碼區段）可能
-- 佔用的 LS027-LS039：
--   LS040 孩子檔案的 family_id 不可變（trigger，見上）
--   LS041 孩子檔案不存在，或（update_child 情境）已被軟刪除須先還原
--   LS042 不是仍是該家庭 owner/member 的成員，無法編輯孩子檔案
--   LS043 這個孩子檔案已被移除超過 30 天，無法還原
-- 42501（未登入／非本家庭 owner/member／非本家庭 owner）沿用既有慣例。
-- ---------------------------------------------------------------------------

-- create_child：owner／member 都能建（viewer 不行，§3「Viewer 只能看與留言」的同一條
-- 界線——建立孩子檔案是產出內容的一種）。不接受呼叫端指定 id／deleted_at 之類欄位，
-- 只開放語意上真的該由使用者填的四個欄位。
create or replace function public.create_child(
  p_family_id uuid,
  p_name text,
  p_birthday date,
  p_avatar_url text
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
    raise exception '未登入，無法建立孩子檔案' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid and m.role in ('owner', 'member')
  ) then
    raise exception '只有該家庭的成員（owner／member）能建立孩子檔案' using errcode = '42501';
  end if;

  insert into public.children (family_id, name, birthday, avatar_url)
  values (p_family_id, p_name, p_birthday, p_avatar_url)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_child(uuid, text, date, text) from public, anon;
grant execute on function public.create_child(uuid, text, date, text) to authenticated;

-- update_child：只有仍是該家庭 owner/member 的成員能編輯（跟 create_child 同一條門檻，
-- 但這裡是對已存在的列動態檢查，不是建立時的靜態檢查——被降級成 viewer 之後就不能
-- 再編輯，即使他當初是建立者，因為 children 不像 albums/diaries 有「建立者」欄位，
-- 誰都能編任何一個孩子的檔案，門檻只看「現在還是不是這個家庭的 owner/member」）。
-- 已被軟刪除的孩子檔案不能編輯——要嘛先用 set_child_deleted 還原，要嘛就是被移除了，
-- 兩種情況都不該讓內容在那個狀態下被改動（同 update_diary_entry 的理由）。
-- 授權檢查排在狀態檢查之前（沿用 join_approval／update_diary_entry 的既有慣例）：
-- 未通過授權的人，不管這個孩子檔案是否已被軟刪除，一律拿到 LS042。
-- PUT 語意（整組替換，不是逐欄 PATCH），理由同 update_diary_entry：沒有 UI 落地前，
-- 猜測「NULL＝不變」的 PATCH 語意只會製造日後要對齊的技術債。
create or replace function public.update_child(
  p_child_id uuid,
  p_name text,
  p_birthday date,
  p_avatar_url text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_child public.children%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法編輯孩子檔案' using errcode = '42501';
  end if;

  select c.* into v_child from public.children c where c.id = p_child_id for update;

  if not found then
    raise exception '孩子檔案不存在' using errcode = 'LS041';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = v_child.family_id and m.user_id = v_uid and m.role in ('owner', 'member')
  ) then
    raise exception '只有仍是該家庭 owner/member 的成員能編輯孩子檔案' using errcode = 'LS042';
  end if;

  if v_child.deleted_at is not null then
    raise exception '這個孩子檔案已被移除，請先還原後再編輯' using errcode = 'LS041';
  end if;

  update public.children c
     set name = p_name,
         birthday = p_birthday,
         avatar_url = p_avatar_url
   where c.id = p_child_id;
end;
$$;

revoke execute on function public.update_child(uuid, text, date, text) from public, anon;
grant execute on function public.update_child(uuid, text, date, text) to authenticated;

-- set_child_deleted：僅 owner（LS-47 定案第②題：「刪除僅 owner」，比 albums/diaries/
-- comments 的 set_*_deleted 更窄——那三支的建立者本人也能軟刪／還原自己的東西，children
-- 沒有「建立者」欄位這個概念，且刪除孩子檔案是比刪一篇日記重得多的破壞性動作，門檻
-- 對齊§10「Owner 移除內容」，不下放給 member）。
--
-- 30 天可還原邊界（本票獨有，diaries/albums/comments 的 set_*_deleted 沒有這個概念）：
-- p_deleted = false 且目前 deleted_at 已超過 30 天前，直接擋下、不執行還原，拋 LS043。
-- 「超過 30 天之後怎麼處理（真正清除／永久保留）」是排程票的範圍，本票只做這個語意——
-- 30 天內可還原、超過就不再開放 UI 這條路（RPC 層面就先擋，不是留給 UI 自己判斷）。
-- 軟刪（p_deleted = true）沒有邊界檢查：可以對已軟刪的孩子再次呼叫 true（idempotent，
-- deleted_at 被刷新成新的 now()，deleted_by 刷新成這次呼叫的 owner），也可以對本來就
-- 是 active 的孩子呼叫 false（no-op，deleted_at/deleted_by 維持 NULL）——與
-- set_diary_deleted／set_album_deleted／set_comment_deleted 對「重複呼叫同一個方向」
-- 的既有慣例一致（它們都不特別檢查目前狀態，此處只在「還原」方向多加 30 天檢查）。
create or replace function public.set_child_deleted(
  p_child_id uuid,
  p_deleted boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_child public.children%rowtype;
  v_is_owner boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除或還原孩子檔案' using errcode = '42501';
  end if;

  select c.* into v_child from public.children c where c.id = p_child_id for update;

  if not found then
    raise exception '孩子檔案不存在' using errcode = 'LS041';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_child.family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  if not v_is_owner then
    raise exception '只有該家庭的 owner 能移除或還原孩子檔案' using errcode = '42501';
  end if;

  if not p_deleted and v_child.deleted_at is not null
     and v_child.deleted_at < now() - interval '30 days' then
    raise exception '這個孩子檔案已被移除超過 30 天，無法還原' using errcode = 'LS043';
  end if;

  update public.children c
     set deleted_at = case when p_deleted then now() else null end,
         deleted_by = case when p_deleted then v_uid else null end
   where c.id = p_child_id;
end;
$$;

revoke execute on function public.set_child_deleted(uuid, boolean) from public, anon;
grant execute on function public.set_child_deleted(uuid, boolean) to authenticated;

-- list_children：該家庭任何角色的成員都能呼叫（§3「Viewer 只能看與留言」不限制讀）。
-- security invoker（預設，未寫 security definer，同 get_family_timeline 的既有慣例）：
-- 完全依賴上面收斂過的 children_select policy——呼叫者是這個家庭的 owner 才看得到
-- 已軟刪的列，member／viewer 只會看到 active 的孩子，這支 RPC 沒有任何需要繞過 RLS
-- 才查得到的資料，跟 get_family_timeline 同一個理由（見該函式在 API.md 的說明）。
-- 傳一個自己不屬於的 p_family_id 不會報錯，只會回傳 0 列（RLS 自然過濾），不需要在
-- 函式裡再手動重複一次 family_ids() 檢查。
create or replace function public.list_children(p_family_id uuid)
returns table (
  id uuid,
  name text,
  birthday date,
  avatar_url text,
  deleted_at timestamptz,
  created_at timestamptz
)
language sql
stable
set search_path = ''
as $$
  select c.id, c.name, c.birthday, c.avatar_url, c.deleted_at, c.created_at
    from public.children c
   where c.family_id = p_family_id
   order by c.birthday, c.id;
$$;

revoke execute on function public.list_children(uuid) from public, anon;
grant execute on function public.list_children(uuid) to authenticated;
