-- LS-66（LS-47 後端切片）— children 多寶貝 CRUD RPC、軟刪 30 天可還原、角色矩陣
--
-- 對應 LS-47 使用者定案（2026-08-25）第④題：「刪寶貝＝軟刪 30 天可還原，照片日記保留」，
-- 以及 orchestrator 建議方案第 2 點：「新增/編輯 owner＋member 皆可，刪除僅 owner」。
--
-- 本檔做六件事（R1 merge-reviewer PR #95 review 後擴大範圍，見下方各段落的 R1 標記）：
--   1. children 補 deleted_at／deleted_by 欄位＋反向索引，補 family_id 不可變 trigger。
--   2. 直接 INSERT/UPDATE/DELETE 收斂 RPC-only（比照 LS-48 對 diaries 的做法，理由同型：
--      現行 children_insert／children_update policy 是 owner-only，但本票要求 owner＋
--      member 都能新增／編輯——與其放寬 policy 讓「編輯內容」與「刪除」共用同一組寬鬆的
--      直接寫入面，不如收斂成 RPC-only，讓「新增／編輯」與「軟刪／還原」各自有語意單一、
--      權限各自正確的入口，且軟刪的 30 天還原邊界只能在 RPC 裡做，直接 UPDATE 做不到；
--      DELETE 一併收回是 R1 I5——直接硬刪會繞過 30 天保護，見第 2 段）。
--   3. 四支 RPC：create_child／update_child／set_child_deleted／list_children。
--      set_child_deleted 的軟刪方向自 R1 I1/I2 起是 no-op（見該函式說明）。
--   4. children_select policy：**成員可讀，含已軟刪的列**（R1 I3/I4——原本設計是軟刪列
--      僅 owner 可見，review 指出 member/viewer 會因此拿到 get_family_timeline 回傳、
--      卻解不開名字的 child_id，對 LS-67 UI 是個洞；改為只有「還原」這個動作限 owner，
--      讀取不分角色，見第 2 段）。
--   5. diaries／albums 新增 BEFORE INSERT/UPDATE trigger：已軟刪的孩子不能再被指定為
--      新內容的 child_id（R1 I3，見第 4 段，新碼 LS044）。
--   6. 錯誤碼 LS040-044；docs/API.md／LSErrorCode／60_ 白名單同步（不在本檔，另見對應檔案）。
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
  '軟刪時間戳；NULL＝仍是有效的孩子檔案。R1 I5：直接 DELETE 已收回（見第 2 段），現在
  沒有任何硬刪路徑——軟刪／還原唯一路徑是 public.set_child_deleted()。重複軟刪是
  no-op，不刷新這個時間戳（R1 I1/I2，見 set_child_deleted 說明），還原後再刪才重新計時。
  超過 30 天前的清除／永久保留策略留給排程票，該票須以這個時間戳為基準（R1 I2）。';

comment on column public.children.deleted_by is
  '執行軟刪的 owner（還原時清成 NULL，見 set_child_deleted）。重複軟刪不覆寫這欄
  （R1 I1，語意對齊 LS-57 對 diaries/albums/comments 的 deleted_by 推導規則——理由同：
  避免用一次重複軟刪把歸屬洗成別人）。on delete set null：那位 owner 之後刪帳號，這欄
  不該連帶讓孩子檔案的其他資料失效。';

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

-- R1 I5：DELETE 也一併收回。原本 children_delete policy（owner-only）留著直接硬刪
-- 路徑，review 實測 owner 對一個 29 天前才軟刪、理論上還在 30 天保護窗內的孩子直接
-- `.delete()`，會直接把整列連 albums/diaries 的 child_id 反查關聯一起清光（FK
-- on delete set null），30 天可還原的保證形同虛設——LS-47 定案的硬刪流程本就該走
-- §10 破壞性流程，不是這裡順手留一條後門。收回之後 children 完全沒有硬刪路徑（連
-- owner 也沒有）；「30 天後怎麼真正清除或永久保留」留給排程票，屆時若要開放硬刪，
-- 必須是那張票明確設計、走 §10 授權，不是本票遺留的隱性能力。
alter policy children_delete on public.children using (false);

revoke delete on public.children from authenticated;

-- R1 I3/I4：children_select **刻意不動**——保留 20260822120200_rls_policies.sql
-- 原本的 `family_id in (select private.family_ids())`，同家庭任何角色（owner／
-- member／viewer）都讀得到全部列，不分軟刪與否。這個檔案較早的版本曾經把軟刪列
-- 收斂成僅 owner 可見（加了 `and (deleted_at is null or family_id in (select
-- private.owned_family_ids()))` 這段 OR 子查詢），merge-reviewer PR #95 review
-- 指出這會製造一個洞：get_family_timeline／feed_items 對軟刪孩子的行為完全不變
-- （§8），member／viewer 拿到的 child_id 因此可能指向一個他們用 list_children／
-- 直接查表都解不開的孩子——LS-67 做 UI（寶貝徽章、篩選 chip 顯示名字）一定會撞到。
-- 修法：讀取權限不分角色、不分軟刪與否，只有「還原」這個動作收斂在
-- set_child_deleted 的 owner-only 授權檢查裡（不是靠 RLS 擋讀取）。這裡不留一句
-- ALTER POLICY 把它設回原值（那會是純粹的 no-op SQL，且會被
-- migration-breaking-check 的關鍵字偵測器誤判成又一條 BREAKING 敘述）——policy
-- 本身沒有變過，值得記錄的只有「曾經考慮過收斂、決定不收斂」這個裁量本身，寫在
-- 這段註解就夠。
comment on table public.children is
  '家庭孩子檔案。INSERT／UPDATE／DELETE 唯一的寫入路徑是 public.create_child() /
  public.update_child() / public.set_child_deleted()（LS-66；DELETE 自 R1 I5 起
  也收斂——目前完全沒有硬刪路徑，連 owner 也沒有，30 天後的清除策略留給排程票）。
  authenticated 對這三種操作沒有 policy 也沒有 grant。SELECT 不分角色、不分軟刪
  與否——同家庭任何成員都讀得到全部列（含已軟刪、deleted_at/deleted_by 皆可見），
  只有「還原」這個動作收斂在 set_child_deleted 的 owner-only 授權（R1 I3/I4，
  merge-reviewer PR #95 review：member/viewer 需要能解析 get_family_timeline
  回傳的已軟刪 child_id，讀取權限不該比內容本身的可見範圍更窄）。';

-- ---------------------------------------------------------------------------
-- 3. 寫入 RPC
--
-- 錯誤碼延續既有序號（最新是 LS026，LS-58）。orchestrator 指派：本票新碼從 LS040
-- 起跳，避開 LS-57（同時在飛，實際佔用 LS027——見
-- 20260825040000_deletion_attribution.sql，本票與其不撞號）：
--   LS040 孩子檔案的 family_id 不可變（trigger，見上）
--   LS041 孩子檔案不存在，或（update_child 情境）已被軟刪除須先還原
--   LS042 不是仍是該家庭 owner/member 的成員，無法編輯孩子檔案
--   LS043 這個孩子檔案已被移除超過 30 天，無法還原
--   LS044 寶貝已移除，無法歸屬新內容（R1 I3，diaries/albums 的 BEFORE INSERT/UPDATE
--         trigger，見第 4 段）
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
--
-- 軟刪（p_deleted = true）方向：**重複呼叫是 no-op，不覆寫 deleted_at／deleted_by**
-- （R1 I1/I2，merge-reviewer PR #95 review）。這裡刻意跟 set_diary_deleted／
-- set_album_deleted／set_comment_deleted 那套「重複呼叫同一個方向不特別檢查目前
-- 狀態」的既有慣例不一樣——原本的實作也是那樣（每次呼叫 true 都把 deleted_at 刷新成
-- 新的 now()、deleted_by 刷新成這次呼叫的 owner），review 抓到兩個問題，兩個都只有
-- children 才有（diaries/albums/comments 沒有 30 天邊界，不受影響）：
--   1. **30 天時鐘可以被無限延後**：owner 只要在 30 天內對同一個孩子再呼叫一次
--      set_child_deleted(true)，deleted_at 就會刷新成新的 now()，30 天窗口跟著整個
--      往後推——「30 天不可還原」這個邊界因此形同虛設，owner 可以永遠讓孩子檔案停在
--      「可還原」狀態。
--   2. **deleted_by 可能被偷換**：語意上跟 LS-57 對 diaries/albums/comments 訂的規則
--      是同一類風險（LS-57 防的是「作者用重複軟刪把歸屬從 owner 洗成自己」；children
--      的 set_child_deleted 僅 owner 能呼叫，不會有作者冒充的問題，但同一家庭若有
--      多位 owner，重複軟刪一樣會讓 deleted_by 從「A 刪的」變成「B 重新呼叫之後變成
--      B 刪的」，稽核紀錄失真）。
-- 修法：只有「從 active 到已軟刪」這一次真正的狀態轉換（`v_child.deleted_at is
-- null`）才寫入 `deleted_at = now(), deleted_by = v_uid`；對已經是軟刪狀態的孩子
-- 再呼叫一次 true，函式完全不執行任何 UPDATE，deleted_at／deleted_by 原封不動。
-- 這與 LS-57 對 diaries/albums/comments 的 deleted_by 推導規則（同一次轉換才寫入、
-- 重複軟刪維持 OLD 值）方向一致，但 children 額外把 deleted_at 也一併凍結——LS-57
-- 那三張表沒有 30 天邊界，deleted_at 刷新與否對它們的規則無影響，不需要凍結；
-- children 若只凍結 deleted_by 不凍結 deleted_at，問題 1（時鐘延後）依然成立。
-- 還原（p_deleted = false）之後再重新軟刪，因為 deleted_at 那時已經是 NULL，會被
-- 判定成「從 active 到已軟刪」的真正轉換，重新計時、重新歸屬——這是刻意的，不是
-- 上述凍結規則的例外：「還原」本身就是一個需要 owner 授權的動作（30 天內、owner-only），
-- 一旦真的還原成功，代表這個孩子檔案回到 active 狀態，之後的刪除本來就該是全新的
-- 一次刪除。對本來就是 active 的孩子呼叫 false 仍是 no-op（deleted_at/deleted_by
-- 維持 NULL，沒有東西可還原）。
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

  if p_deleted then
    -- 只有「從 active 到已軟刪」這一次真正的狀態轉換才寫入；對已經是軟刪狀態的孩子
    -- 再呼叫一次 true 完全不執行 UPDATE（no-op，見上方檔頭說明——R1 I1/I2）。
    if v_child.deleted_at is null then
      update public.children c
         set deleted_at = now(), deleted_by = v_uid
       where c.id = p_child_id;
    end if;
  else
    if v_child.deleted_at is not null
       and v_child.deleted_at < now() - interval '30 days' then
      raise exception '這個孩子檔案已被移除超過 30 天，無法還原' using errcode = 'LS043';
    end if;

    update public.children c
       set deleted_at = null, deleted_by = null
     where c.id = p_child_id;
  end if;
end;
$$;

revoke execute on function public.set_child_deleted(uuid, boolean) from public, anon;
grant execute on function public.set_child_deleted(uuid, boolean) to authenticated;

-- list_children：該家庭任何角色的成員都能呼叫（§3「Viewer 只能看與留言」不限制讀）。
-- security invoker（預設，未寫 security definer，同 get_family_timeline 的既有慣例）：
-- 完全依賴 children_select policy——同家庭任何角色都看得到全部列，含已軟刪的（R1
-- I3/I4，見 children_select 的裁量說明），`deleted_at` 對所有呼叫者一律是唯讀旗標，
-- 只有 set_child_deleted 的還原方向限 owner。這支 RPC 沒有任何需要繞過 RLS 才查得到
-- 的資料，跟 get_family_timeline 同一個理由（見該函式在 API.md 的說明）。傳一個自己
-- 不屬於的 p_family_id 不會報錯，只會回傳 0 列（RLS 自然過濾），不需要在函式裡再
-- 手動重複一次 family_ids() 檢查。
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

-- ---------------------------------------------------------------------------
-- 4. 已軟刪的孩子不能再被指定為新內容的 child_id（R1 I3，merge-reviewer PR #95 review）
--
-- 實測發現的洞：owner 軟刪 child 2a 之後，member 呼叫 create_diary_entry(...,
-- child_id=2a, ...) 仍然成功——create_diary_entry／albums 的直接寫入都不看
-- children.deleted_at。「已移除」的語意因此有洞：一個孩子 31 天後永久不可還原，
-- 內容卻還能持續累積掛到他底下。修法：diaries／albums 各加一支 BEFORE INSERT/UPDATE
-- trigger，凡是把 child_id 指向一個已軟刪的孩子，一律拋 LS044。
--
-- 「既有內容不動」（票面用語）具體落地成：**只在 child_id 這個欄位真的被指定成新值
-- 時才檢查**（INSERT 恆檢查；UPDATE 只在 `new.child_id is distinct from old.child_id`
-- 時檢查），不是「這張表任何一次 UPDATE 都要重新驗證 child_id」。理由：
--   - update_diary_entry 是 PUT 語意，每次呼叫都會把 child_id 整欄位重寫一次（即使
--     呼叫端傳的是跟原本一樣的值）。若不分青紅皂白地每次 UPDATE 都驗證，會變成
--     「孩子被軟刪之後，這篇日記從此連 body 都不能再編輯」——這已經超出票面「不能再
--     被掛上新內容」的範圍，變成懲罰既有內容，跟「既有內容不動」的精神直接衝突。
--   - set_diary_deleted／set_album_deleted／owner 對 albums 的建立者直接
--     `.update()` 軟刪或還原，都只碰 deleted_at 一欄，不會動到 child_id，
--     `new.child_id is distinct from old.child_id` 為 false，這兩個操作完全不受
--     影響——不分青紅皂白版本的另一個後果會是：孩子被軟刪之後，掛在他底下的相簿／
--     日記連自己的軟刪／還原都做不了，這不是票面要的行為。
-- 這支 trigger 是 SECURITY DEFINER＋search_path 收斂（跟本檔第 1 段的
-- children_family_immutable 同一個理由：不依賴呼叫當下 children_select RLS 是否
-- 恰好放行——children_select 目前雖然對所有角色開放，但這支 trigger 的正確性不該
-- 綁在「RLS 目前剛好這樣設」這個可能會變動的前提上，直接繞過 RLS 讀最真實的狀態）。
-- 兩張表共用同一支函式：邏輯完全相同（都只依賴 child_id／family_id 兩個同名欄位），
-- 沒有理由分別各寫一份、日後各自漂移。
--
-- **已知限制（R2 I7，merge-reviewer PR #95 review，接受不修）**：這支 trigger 讀
-- `children` 時沒有取任何鎖，存在一個毫秒級的 TOCTOU 窗口——session A 開始
-- `create_diary_entry(child_id=X)`（trigger 讀到 X 還是 active，INSERT 通過）但
-- 交易還沒 commit；同時 session B 呼叫 `set_child_deleted(X, true)` 並先 commit；
-- A 之後才 commit，結果是一則 `child_id = X` 的日記掛在一個當下已經軟刪的孩子
-- 底下。這與本票「既有內容保留」的設計相容（時間軸照樣顯示、`list_children` 照樣
-- 解析得到名字），只讓「已移除的孩子不會再累積新內容」這句話有個 ε 例外，不是
-- 資料完整性問題（`child_id` 依然指向一個真實存在、同家庭的孩子）。收斂的代價是
-- 把 `exists(...)` 改成 `select 1 from public.children where id = new.child_id
-- for key share`——每次 diaries/albums 寫入都對 children 列多加一次鎖，換一個
-- 極窄時間窗口的邊界情況，判斷不值得，故意留著，不開後續票。
-- ---------------------------------------------------------------------------

create or replace function private.enforce_child_not_deleted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.child_id is not null
     and (tg_op = 'INSERT' or new.child_id is distinct from old.child_id)
     and exists (
       select 1 from public.children c
        where c.id = new.child_id and c.deleted_at is not null
     ) then
    raise exception '寶貝已移除，無法歸屬新內容' using errcode = 'LS044';
  end if;
  return new;
end;
$$;

create trigger diaries_child_not_deleted
  before insert or update on public.diaries
  for each row execute function private.enforce_child_not_deleted();

create trigger albums_child_not_deleted
  before insert or update on public.albums
  for each row execute function private.enforce_child_not_deleted();
