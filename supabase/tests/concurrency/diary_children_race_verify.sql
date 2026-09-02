-- LS-121 併發場景驗證：終態必須是 S2（後 commit 的一方）的完整集合 {D}，
-- 不能是 {B, C, D} 這種混合結果，也不能是 S1 的 {B, C}（若 S2 真的被 S1 的鎖擋住、
-- 且解除阻塞後正確覆蓋，最終一定是 S2 的集合）。

\set ON_ERROR_STOP on

do $$
declare
  v_children uuid[];
  v_expected uuid[] := array['28000000-0000-4000-8000-000000000004']::uuid[];
  v_body text;
begin
  select array_agg(child_id order by child_id) into v_children
    from public.diary_children where diary_id = '58000000-0000-4000-8000-000000000001';

  select body into v_body from public.diaries where id = '58000000-0000-4000-8000-000000000001';

  if v_children is distinct from v_expected then
    raise exception
      'FAIL 併發：終態應該是 S2 的完整集合 {D}（%），實際是 %——覆蓋語意在併發下沒有正確互斥',
      v_expected, coalesce(v_children, array[]::uuid[]);
  end if;

  if v_body <> 'S2 改的內容' then
    raise exception 'FAIL 併發：終態的 body 應該是 S2 寫入的內容，實際是 %', v_body;
  end if;

  raise notice 'ok 併發：兩個連線同時 update_diary_entry 覆蓋同一篇日記的孩子標記，終態正確是後 commit 那一方的完整集合，沒有混合';
end;
$$;
