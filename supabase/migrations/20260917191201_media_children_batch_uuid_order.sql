-- LS-320（LS-317 merge-review R2 `a63b98e8` i6）——`set_media_children_batch`
-- 的鎖序排序改用 `::uuid` 而不是裸字串，讓「所有呼叫端對同一組 media 得到同一個
-- 全序」這個保證與 collation 無關。
--
-- 來源：`supabase/migrations/20260917155738_media_children.sql:279`（m1 修法）目前
-- 是 `order by (e.value->>'media_id'), e.ord`——`e.value->>'media_id'` 是呼叫端送
-- 來的字面字串，同一顆 uuid 可以有多種合法文字形（大小寫、有無連字號、大括號），
-- text 排序對不同文字形不保證與 uuid 排序一致；只有在本機／正式站現行的
-- `en_US.UTF-8` collation 下（primary weight 不分大小寫、忽略標點）才剛好與 uuid
-- 排序一致，`C`／`POSIX` collation 會分歧（reviewer 已實測本機當下無實害，見
-- LS-317 review comment `a63b98e8`）。
--
-- 只改這一行：把排序鍵從裸字串換成 `::uuid`（loop 內本來就有
-- `(v_item->>'media_id')::uuid` 的轉型，這裡只是把同一個轉型提前到排序時），
-- 語意與轉型失敗的 fail-loud 行為都不變——不是 `CREATE OR REPLACE` 之外的行為
-- 變更，函式簽章、回傳型別、授權判斷、覆蓋語意、批次原子性、筆數上限皆未動。
-- 舊 migration（`20260917155738_media_children.sql`）不可改（migration-immutable
-- gate），故另開本檔用 `CREATE OR REPLACE` 覆寫。
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
     order by (e.value->>'media_id')::uuid, e.ord
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
