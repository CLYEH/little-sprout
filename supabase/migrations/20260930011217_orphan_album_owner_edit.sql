-- LS-408 — 孤兒相簿（作者已離開家庭／帳號已刪）由家庭 owner 接手編輯
--
-- 來源：LS-401（v0.27.18）讓相簿不隨作者刪帳號軟刪，但 `albums_update` 只放行建立者
-- 本人（`created_by = auth.uid()`）——作者離開後標題／封面無人可改（寶貝標記
-- `set_album_children` 同為建立者限定，本票不動）。使用者 2026-09-30 裁決：owner 接手
-- 編輯「要」（池 81471a87）。
--
-- 改動：`alter policy albums_update` 的 USING／WITH CHECK 各加一條 owner-on-orphan 分支，
-- 作者分支（`created_by = auth.uid()` 且仍是 contributor）逐字不動。
--
--   孤兒判定（兩種都算）：
--     1. `created_by IS NULL`——auth.users 已刪，`albums.created_by` 對 profiles 是
--        `on delete set null`（20260822120000_init_schema.sql:154），profiles 對 auth.users
--        是 cascade；
--     2. `created_by` 指向的人不在該家庭的 family_members——`delete_my_account()` 先刪
--        family_members 列、profiles 要等 Edge Function 刪 auth.users 才消失（期間
--        created_by 仍指向還在的 profile）；被 owner 移除的成員、purge tombstone 路徑
--        （created_by 指向 tombstone 列）同屬此類。
--   被降級成 viewer 的作者仍在 family_members，**不算孤兒**（他自己已不能改，owner 也
--   不接手——降級是家庭內的權限調整，不是離開）。
--
--   可寫欄位不變：albums 的 UPDATE 欄位級 grant 只有 title、cover_media_id
--   （20260825040000_deletion_attribution.sql:266，albums 沒有 description 欄位——票文
--   「描述」無對應欄位，child_id 已於 20260902011514 移入 album_children）。owner 走這條
--   分支改不到 created_by／deleted_at／family_id；軟刪／還原仍走 set_album_deleted。
--
-- 規格分歧與取捨：
--   a) (a) RLS policy 分支 vs (b) SECURITY DEFINER RPC `update_orphan_album`：走 (a)——
--      與既有 owner-only 軟刪同型、client 不用改呼叫（直接 `.update()` 即可），欄位範圍
--      由既有欄位級 grant 兜住，不必在新 RPC 重述一遍可寫欄位（少一份會漂移的清單）。
--      代價是 RLS 條件需要判「作者是否還在家庭」，這是跨表查詢——tests/50 立下的規矩是
--      policy 不得有 correlated SubPlan（每列重算）。解法：判定用 SECURITY DEFINER 集合
--      函式 `private.owned_family_member_pairs()` 一次吐出「我是 owner 的家庭的所有
--      (family_id, user_id)」，policy 寫成
--        (family_id, created_by) NOT IN (select … from private.owned_family_member_pairs())
--      是 **hashed SubPlan**（每個 statement 只建一次雜湊表，與 family_ids() 同型），
--      不是逐列 SubPlan。EXPLAIN 證據見 PR／handoff；不逐列重算的斷言由 tests/50 的偵測
--      機制覆蓋（本票不新增 albums 大表，albums 每家庭列數小，且 policy 短路：作者
--      分支先成立就不建雜湊表）。
--      family_members.user_id 為 NOT NULL，所以 NOT IN 沒有 NULL 陷阱；created_by 為
--      NULL 的列由 `created_by IS NULL` 明寫分支涵蓋，不依賴 NOT IN 對 NULL 的行為。
--   b) 只放行 owner，不放 member：票文範圍——接手編輯是家庭管理權，與 set_album_deleted
--      的 owner 分支同級。
--   c) 併發（作者刪帳號交易中 owner 同時 update）：RLS 判定用 statement 快照。
--      delete_my_account() 尚未 commit 時，owner 的 UPDATE 看到作者仍是成員 → 影響 0 列
--      （與 commit 前的既有契約一致，不會寫到一半）；commit 後才進來的 UPDATE 看到孤兒
--      → 成功。兩者都不會產生「作者與 owner 各自寫入」的髒結果：作者自己的 UPDATE 在
--      family_members 列被刪之後 USING 不成立（contributor_family_ids 不含），
--      不會與 owner 分支同時為真。albums 列本身的 row lock 序列化同一列的兩個 UPDATE。
--      本檔不取任何新鎖、不改 delete_my_account()。
--   d) 不回填、不轉移相簿所有權（票文「不做」）：created_by 維持原樣，孤兒狀態由判定式
--      即時計算，不寫入任何旗標欄位。
--
-- 與既有 trigger 的關係：albums 上 before update 的 deletion_attribution／
-- not_suspended、after update 的 feed／notify trigger 對這條路徑照常觸發，
-- 不需要調整（owner 改的仍是 title／cover_media_id，與作者改沒有差別）。

create or replace function private.owned_family_member_pairs()
returns table (family_id uuid, user_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id, m.user_id
    from public.family_members m
   where m.family_id in (
     select o.family_id from public.family_members o
      where o.user_id = auth.uid() and o.role = 'owner'
   );
$$;

revoke execute on function private.owned_family_member_pairs() from public, anon;
grant execute on function private.owned_family_member_pairs() to authenticated;

alter policy albums_update on public.albums
  using (
    (
      created_by = (select auth.uid())
      and family_id in (select private.contributor_family_ids())
    )
    or (
      family_id in (select private.owned_family_ids())
      and (
        created_by is null
        or (family_id, created_by) not in (
          select p.family_id, p.user_id from private.owned_family_member_pairs() p
        )
      )
    )
  )
  with check (
    (
      created_by = (select auth.uid())
      and family_id in (select private.contributor_family_ids())
    )
    or (
      family_id in (select private.owned_family_ids())
      and (
        created_by is null
        or (family_id, created_by) not in (
          select p.family_id, p.user_id from private.owned_family_member_pairs() p
        )
      )
    )
  );

comment on table public.albums is
  '家庭相簿。直接 .update()（title／cover_media_id）：建立者本人、仍是該家庭 owner/member 時放行'
  '（albums_update policy，LS-52 收斂）；LS-408 起另放行「孤兒相簿」給該家庭 owner——'
  'created_by 為 NULL 或不再是該家庭成員（刪帳號／被移除）。作者仍在家庭時 owner 不得直接改'
  '別人的相簿；owner 對別人（在職作者）相簿唯一的操作是軟刪／還原，走'
  ' public.set_album_deleted() RPC（LS-52），只碰 deleted_at 一欄。硬刪（DELETE）仍是'
  ' 20260822120200_rls_policies.sql 既有的 albums_delete policy（僅 owner）。';
