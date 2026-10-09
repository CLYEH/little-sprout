-- LS-444（池 LS-413 fbf8319b；來源 LS-441 merge-review R1 m1）——
-- `list_family_photos_for_food` 先把 family_id 解成單值再過濾 media。
--
-- 現況（20261009150122_food_family_photos_rpc.sql）：`children c join media m on m.family_id = c.family_id`
-- 把 family_id 當成 join 欄位，planner 無法在 `media` 上用 `(family_id, created_at desc, id desc)` 索引
-- 依序往下走並在 limit 提早停，而是對全家庭每張 media 先跑 `private.media_hidden_as_food_record_only`
-- 的三個 EXISTS 再排序。reviewer 實測 10,000 張 39.6ms。
--
-- 改法：`media.family_id = (scalar subquery)`——子查詢是 uncorrelated 的 InitPlan（每次呼叫只算一次、
-- 找不到寶貝／不屬於呼叫者家庭時為 NULL，`family_id = NULL` 不成立 → 回空），media 側變成單值等值過濾，
-- 走既有 partial index `media_family_created_idx (family_id, created_at desc, id desc) where deleted_at is null`
-- 依序往下走，掃到 p_limit 張通過判準的就停。reviewer 手測改寫版 10,000 張 6.9ms。不需要新索引。
--
-- 與現行語意相同：回傳欄位、排序（created_at desc, id desc）、p_limit 語意（0 → 空、null → 不限）、
-- 判準（not private.media_hidden_as_food_record_only）、授權條件（definer 函式內
-- `family_id in (select private.family_ids())`，auth.uid() 取自 JWT）、空 search_path。
-- 唯一的行為差：寶貝已軟刪（children.deleted_at is not null）改回空——現行只擋「不屬於呼叫者家庭」，
-- 對已軟刪寶貝仍列出家庭照片；client 不會對已軟刪寶貝開 03d，此為邊界收緊（票文範圍 1 明列）。
--
-- 破壞性：僅 create or replace 同簽名函式（回傳型別、參數、grant 不變），無 DROP／ALTER TABLE／REVOKE 既有物件。

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
    from public.media m
   where m.family_id = (select c.family_id
                          from public.children c
                         where c.id = p_child_id
                           and c.deleted_at is null
                           and c.family_id in (select private.family_ids()))
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
  '授權條件手動等同 media_select／children_select。LS-444：先以子查詢解出 family_id（單值）再過濾 media，'
  '走 media_family_created_idx 並在 limit 提早停。';
