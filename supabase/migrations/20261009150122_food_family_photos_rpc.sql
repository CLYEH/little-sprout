-- LS-441（LS-425 C3a 的讀取面）—— 飲食記錄 03d「從家庭相簿挑」不列飲食專屬照片。
--
-- 現況：`SupabaseFoodAPIClient.listFamilyPhotos` 直查 `media`（type=photo、deleted_at is null），
-- 會把別筆飲食記錄「從手機加入」的專屬照片也列進選擇器。LS-430 已修時間軸與每日清理，判準函式
-- `private.media_hidden_as_food_record_only(family, media)` 是「照片只屬於飲食記錄」的唯一判準，
-- 這支 RPC 沿同一判準把它們排除（掛在有效飲食記錄、又在日記或相簿裡的照片照列）。
--
-- 為什麼是 security definer 而不是其他 food RPC 慣例的 security invoker：判準函式是 private schema
-- 函式，`harden_default_privileges`／60_default_privileges.sql 規定 authenticated 對 private 函式
-- 無 EXECUTE（除了 RLS 用的集合函式允許清單）；invoker 版本會在呼叫判準函式時 42501。不為此放寬
-- 允許清單，改由本函式以 definer 身分呼叫，並把 media_select／children_select 的授權條件手動寫進
-- 本體（`family_id in (select private.family_ids())`，`auth.uid()` 取自 JWT、不是參數；空 search_path）。
-- 呼叫者不屬於 p_child_id 的家庭 → 0 列，不報錯（同 list_child_food_records）。
--
-- 回傳欄位＝client `SupabaseFoodAPIClient.photoColumns`（id,storage_path,thumb_path,taken_at,created_at），
-- 新到舊（created_at desc, id desc）。p_limit 預設 300＝`FamilyPhotoQuery.limit`。
--
-- 破壞性：僅新增函式，無 DROP／ALTER TABLE／REVOKE 既有物件。

create or replace function public.list_family_photos_for_food(p_child_id uuid, p_limit int default 300)
returns table (
  id uuid,
  storage_path text,
  thumb_path text,
  taken_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, m.storage_path, m.thumb_path, m.taken_at, m.created_at
    from public.children c
    join public.media m on m.family_id = c.family_id
   where c.id = p_child_id
     and c.family_id in (select private.family_ids())
     and m.type = 'photo'
     and m.deleted_at is null
     and not private.media_hidden_as_food_record_only(m.family_id, m.id)
   order by m.created_at desc, m.id desc
   limit p_limit;
$$;

revoke execute on function public.list_family_photos_for_food(uuid, int) from public, anon;
grant execute on function public.list_family_photos_for_food(uuid, int) to authenticated;

comment on function public.list_family_photos_for_food(uuid, int) is
  'LS-441：03d 家庭相簿選擇器——該寶貝所屬家庭的未刪照片（新到舊，最多 p_limit 張），排除'
  ' private.media_hidden_as_food_record_only 判準下「只屬於飲食記錄」的照片。security definer（判準函式在 private），'
  '授權條件手動等同 media_select／children_select。';
