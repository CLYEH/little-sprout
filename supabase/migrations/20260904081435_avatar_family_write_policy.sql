-- LS-169 R2（merge-review R1 M1，orchestrator 裁定 (a)）——放寬頭像路徑的 UPDATE／DELETE
-- 授權判準為「與 update_child 同一角色」，維持固定路徑不變。
--
-- 問題：`{family_id}/avatars/{child_id}.jpg`（LS-169，`20260904060700_avatar_object_path.sql`）
-- 是固定路徑＋`upsert: true`——這是既有 media 物件（每次上傳都是新的 `{media_id}` 路徑）從
-- 未踩過的形狀：`media_bucket_update`／`media_bucket_delete` 的「上傳者本人」分支認的是
-- `storage.objects.owner`／`owner_id`（第一次寫入這個路徑的人），對每次都開新路徑的既有
-- media 流程這個分支永遠不可達（兩個成員不會寫到同一個物件）；頭像固定路徑第一次讓它可達，
-- 後果：owner 上傳頭像後，可編輯孩子資料的 member 換照片會被 RLS 拒絕（42501／403）——
-- 而且錯誤被 client 端誤判成「伺服器問題，請稍後再試」（永久拒絕，不是暫時性錯誤，見
-- `ChildAvatarUploadService.mapUploadError`，R2 m3 同一輪修正）。
--
-- 修法（orchestrator 裁定 (a)，不採「每次上傳唯一路徑」）：孩子頭像是家庭共有物，不是
-- 上傳者個人物件——`update_child` 本身的授權判準是「仍是該家庭 owner／member 的成員」
-- （`private.contributor_family_ids()`，見 `20260825030000_children_write_path_and_soft_delete.sql`
-- `update_child` 的 `role in ('owner','member')` 檢查，兩者逐字一致），頭像路徑的
-- UPDATE／DELETE 比照同一個判準，不再看 `storage.objects.owner`。**只新增一個 OR 分支**，
-- 既有的 `{yyyy}/{mm}` media 物件那個分支（owner／owner_id／`uploadable_family_ids()`）
-- 逐位不變——換照片以外的既有上傳／改名／刪除行為不受影響。
--
-- 為什麼是 UPDATE／DELETE，不動 INSERT：orchestrator 裁定文字明確限定「update／delete
-- 權限」；INSERT（頭像從未存在時的第一次上傳）維持 `uploadable_family_ids()`
-- （owner 恆可；member 看 can_upload）不變——同一次 PR 的 SQL 測試只驗「owner 上傳→member
-- 覆蓋」，不是「can_upload=false 的 member 也能做第一次上傳」，範圍不擴大。

create or replace function private.is_avatar_object_path(p_name text)
returns boolean
language sql
immutable
as $$
  select p_name ~ (
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    || '/avatars/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  );
$$;

-- LS-40 的既有慣例：schema private 的函式一律明寫 revoke/grant，不建立在「default
-- privileges 剛好收斂過」這件事上（見 `20260823030000_storage_policies.sql` 同一段註解）。
revoke execute on function private.is_avatar_object_path(text) from public;
grant execute on function private.is_avatar_object_path(text) to authenticated;

-- ALTER POLICY（不是 DROP+CREATE）：改的是既有 policy 的 USING／WITH CHECK 條件，
-- 不是把整條 policy 物件砍掉重建——`ALTER POLICY` 保留 policy 本身的身分／授予對象
-- （這裡沒有明寫 `TO authenticated` 也不影響，未指定時維持既有的角色指派不變），語意
-- 上是「放寬既有規則」而不是「移除又新增一個東西」。DROP POLICY 會被
-- `migration-breaking-check.sh` 的 D1 規則判成 DESTRUCTIVE（需要使用者本人在 PR 留
-- comment 核可），對「同一個 migration 內立刻用同名 CREATE POLICY 補回來」這種
-- 純粹放寬條件的變更是不必要的核可負擔——ALTER POLICY 只會被判 BREAKING（B1，PR body
-- 的 BREAKING: 段落＋docs/API.md 同 PR 更新即可），跟這次變更的實際風險等級一致；
-- 這個 repo 本來就有這個慣例，見 `20260825030000_children_write_path_and_soft_delete.sql`
-- 的 `alter policy children_insert ... with check (false)`。
alter policy media_bucket_update on storage.objects
  using (
    bucket_id = 'media'
    and (
      (storage.foldername(name))[1] in (select f::text from private.owned_family_ids() f)
      or (
        (owner = (select auth.uid()) or owner_id = (select auth.uid())::text)
        and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
      )
      -- R2 M1：頭像路徑改走「與 update_child 同一角色」判準，不看 owner／owner_id——
      -- 家庭共有物件，換照片這件事跟改名字／改生日是同一組授權問題。
      or (
        private.is_avatar_object_path(name)
        and (storage.foldername(name))[1] in (select f::text from private.contributor_family_ids() f)
      )
    )
  )
  with check (
    bucket_id = 'media'
    and private.is_media_object_path(name)
    and (
      (storage.foldername(name))[1] in (select f::text from private.owned_family_ids() f)
      or (
        (owner = (select auth.uid()) or owner_id = (select auth.uid())::text)
        and (owner is null or owner = (select auth.uid()))
        and (owner_id is null or owner_id = (select auth.uid())::text)
        and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
      )
      or (
        private.is_avatar_object_path(name)
        and (storage.foldername(name))[1] in (select f::text from private.contributor_family_ids() f)
      )
    )
  );

-- 同上，ALTER POLICY 而非 DROP+CREATE。
alter policy media_bucket_delete on storage.objects
  using (
    bucket_id = 'media'
    and (
      (storage.foldername(name))[1] in (select f::text from private.owned_family_ids() f)
      or (
        (owner = (select auth.uid()) or owner_id = (select auth.uid())::text)
        and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
      )
      or (
        private.is_avatar_object_path(name)
        and (storage.foldername(name))[1] in (select f::text from private.contributor_family_ids() f)
      )
    )
  );
