-- LS-409 — set_album_children 放行「owner 且相簿為孤兒」，孤兒判定抽成單一來源
--
-- 來源：LS-408（#583）讓家庭 owner 可 `.update()` 孤兒相簿的標題／封面，但寶貝標記走
-- `set_album_children` RPC，它的授權仍是「建立者本人」——owner 在孤兒相簿同一次送出改標題
-- ＋改標記時，標題寫入成功、RPC 回 LS045，兩個呼叫非交易（LS-408 handoff 範圍 4、
-- merge-review R1 i3）。同批處理 R1 i2：`owned_family_member_pairs()` 沒有像同類 helper
-- 過濾停權帳號／停用家庭（見下方取捨 b）。
--
-- 改動：
--   1. 新增 `private.owned_orphan_album_ids()`——「我是 owner 的（未停權）家庭裡，孤兒相簿的
--      id 集合」，孤兒判定的**唯一定義處**（`created_by IS NULL`，或 `(family_id, created_by)`
--      不在 `owned_family_member_pairs()`；語意與 LS-408 逐字相同，含「降級成 viewer 的作者
--      仍在 family_members，不算孤兒」）。
--   2. `albums_update` policy 的 owner 分支改成 `id in (select private.owned_orphan_album_ids())`
--      （USING／WITH CHECK 皆是）；作者分支逐字不動。
--   3. `set_album_children` 授權改為「作者本人（仍是 owner/member）OR 相簿 id 在
--      owned_orphan_album_ids() 內」；簽名、錯誤碼（非授權仍 LS045）、鎖、覆蓋語意不變。
--
-- 規格分歧與取捨：
--   a) 單一來源的形狀：票文給了兩條路——(i) `private.is_orphan_album(album_id)` 逐列呼叫、
--      (ii) 重用 helper。走集合函式 `owned_orphan_album_ids()`（Set-returning、無參數），
--      理由是 LS-408 立下的規矩（tests/50）：policy 不得逐列重算。`is_orphan_album(id)` 放進
--      policy 會變成「每列一次函式呼叫（內含 family_members 查詢）」；集合函式寫成
--      `id in (select …)` 是 **hashed SubPlan**（每個 statement 只算一次，與
--      owned_family_ids() 同型）。RPC 端只查一列，`p_album_id in (select …)` 同一個函式，
--      代價是多算「owner 家庭內所有孤兒相簿」（每家庭相簿數十～數百列，可忽略），換得
--      policy 與 RPC 沒有第二份判定式可漂移。
--      副作用：LS-408 policy 內的「created_by is null or (family_id, created_by) not in …」
--      整段從 policy 移進函式；policy 只剩 `id in (…)`。孤兒條件只剩本函式一處定義
--      （現行孤兒判定只剩本函式一處；LS-408 舊 migration 內的 policy 文字已被本檔的
--      `alter policy` 取代，只是歷史，`git grep 'not in ('` 可對照）。）
--   b) `owned_family_member_pairs()` 補過濾 vs 註解：**選註解，不補過濾**。原因與 R1 i2 的
--      直覺相反——該 helper 只用在 `NOT IN` 方向，回傳集合是「安全側的 superset」：加上
--      caller_is_active()／family_is_active() 過濾會讓集合在「呼叫者被停權／家庭停用」時變空，
--      `(family_id, created_by) NOT IN (空集合)` 恆為真，等於**所有相簿都被判成孤兒**——
--      過濾越多、孤兒判定越寬，方向錯了。停權語意現在由 owned_orphan_album_ids() 內的
--      `family_id in (select private.owned_family_ids())`（已含 caller_is_active()／
--      family_is_active()）一次擋住，而且 owned_orphan_album_ids() 是唯一呼叫者。helper 的
--      函式註解寫明「只能用在 NOT IN 方向、並與 owned_family_ids() 搭配」。
--      tests/122 §3 守停用家庭／停權 owner 不放行。
--   c) 授權失敗仍是 LS045（不改錯誤碼）；停權／停用家庭的 owner 呼叫孤兒相簿也是 LS045
--      （owned_family_ids() 為空）。作者分支沿用舊條件（`created_by = uid` 且仍是
--      owner/member），沒有加停權檢查——與舊行為一致，不在本票範圍。
--   d) 併發：同 LS-408 c)——policy 與函式讀 statement 快照；RPC 在 `for update` 鎖住相簿列
--      之後才判定，函式讀的 family_members 是該 statement 快照（READ COMMITTED 下每個
--      statement 各自快照，鎖取得後的判定 statement 看得到已 commit 的刪帳號）。作者刪帳號
--      交易未 commit 時 owner 呼叫 → LS045（同 commit 前契約）；commit 後 → 成功。
--      本檔不取任何新鎖、不改 delete_my_account()。

create or replace function private.owned_orphan_album_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select a.id from public.albums a
   where a.family_id in (select private.owned_family_ids())
     and (
       a.created_by is null
       or (a.family_id, a.created_by) not in (
         select p.family_id, p.user_id from private.owned_family_member_pairs() p
       )
     );
$$;

revoke execute on function private.owned_orphan_album_ids() from public, anon;
grant execute on function private.owned_orphan_album_ids() to authenticated;

comment on function private.owned_orphan_album_ids() is
  'LS-409：呼叫者是 owner 的（未停權）家庭裡，孤兒相簿的 id 集合——孤兒判定的唯一定義處。'
  '孤兒＝created_by 為 NULL，或 created_by 不在該家庭的 family_members（降級成 viewer 仍在表內，'
  '不算孤兒）。albums_update policy 的 owner 分支與 set_album_children 共用。';

comment on function private.owned_family_member_pairs() is
  'LS-408：呼叫者是 owner 的家庭的全部 (family_id, user_id) 成員對（不含停權／停用過濾）。'
  '只能用在 NOT IN 方向、並與 owned_family_ids() 搭配（見 owned_orphan_album_ids()）：'
  '加上停權過濾會讓集合在呼叫者被停權時變空，NOT IN 對空集合恆真，反而把所有相簿判成孤兒。'
  '（LS-409 檢討 LS-408 R1 i2 的結論：不補過濾。）';

alter policy albums_update on public.albums
  using (
    (
      created_by = (select auth.uid())
      and family_id in (select private.contributor_family_ids())
    )
    or id in (select private.owned_orphan_album_ids())
  )
  with check (
    (
      created_by = (select auth.uid())
      and family_id in (select private.contributor_family_ids())
    )
    or id in (select private.owned_orphan_album_ids())
  );

create or replace function public.set_album_children(
  p_album_id uuid,
  p_child_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_album public.albums%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法設定相簿的寶貝標記' using errcode = '42501';
  end if;

  select a.* into v_album from public.albums a where a.id = p_album_id for update;

  if not found then
    raise exception '相簿不存在' using errcode = 'LS023';
  end if;

  -- 授權：作者本人（仍是該家庭 owner/member），或（LS-409）該家庭 owner 對孤兒相簿——
  -- 孤兒判定與 albums_update policy 同一來源 private.owned_orphan_album_ids()。
  if not (
       (
         v_album.created_by is not distinct from v_uid
         and exists (
           select 1 from public.family_members m
            where m.family_id = v_album.family_id and m.user_id = v_uid and m.role in ('owner', 'member')
         )
       )
       or p_album_id in (select private.owned_orphan_album_ids())
     ) then
    raise exception '只有仍是該家庭 owner/member 的建立者，或該家庭 owner（相簿為孤兒時），能設定這本相簿的寶貝標記' using errcode = 'LS045';
  end if;

  delete from public.album_children ac
   where ac.album_id = p_album_id
     and not exists (select 1 from unnest(p_child_ids) as x where x = ac.child_id);

  insert into public.album_children (family_id, album_id, child_id)
  select v_album.family_id, p_album_id, u.child_id
    from (select distinct x as child_id from unnest(p_child_ids) as x where x is not null) u
   where not exists (
     select 1 from public.album_children ac
      where ac.album_id = p_album_id and ac.child_id = u.child_id
   );
end;
$$;

revoke execute on function public.set_album_children(uuid, uuid[]) from public, anon;
grant execute on function public.set_album_children(uuid, uuid[]) to authenticated;
